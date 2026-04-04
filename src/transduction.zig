//! TRANSDUCTION: Fuel-bounded operational eval (signal transformation)
//!
//! The "how signals transform" layer — mirrors the horse BCI pipeline
//! (Signal→Sheaf→Descent→Decode). Each eval step is a transduction:
//! input signal (expression) → transformed signal (value/error/⊥).

const std = @import("std");
const value = @import("value.zig");
const semantics = @import("semantics.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;
const transclusion = @import("transclusion.zig");
const Domain = transclusion.Domain;

// ============================================================================
// RECUR SIGNAL: loop/recur communication via thread-local state
// ============================================================================
var recur_pending: bool = false;
var recur_args: [16]Value = undefined;
var recur_count: usize = 0;

// ============================================================================
// SPECIAL FORM IDS: u48 integer dispatch (avoids string comparisons)
// ============================================================================

var sf_quote: u48 = 0;
var sf_def: u48 = 0;
var sf_let: u48 = 0;
var sf_let_bare: u48 = 0;
var sf_if: u48 = 0;
var sf_do: u48 = 0;
var sf_fn: u48 = 0;
var sf_fn_bare: u48 = 0;
var sf_peval: u48 = 0;
var sf_defn: u48 = 0;
var sf_initialized: bool = false;
var sf_gc_ptr: ?*GC = null;

fn ensureSpecialFormIds(gc: *GC) void {
    if (sf_initialized and sf_gc_ptr == gc) return;
    sf_quote = gc.internString("quote") catch return;
    sf_def = gc.internString("def") catch return;
    sf_let = gc.internString("let*") catch return;
    sf_let_bare = gc.internString("let") catch return;
    sf_if = gc.internString("if") catch return;
    sf_do = gc.internString("do") catch return;
    sf_fn = gc.internString("fn*") catch return;
    sf_fn_bare = gc.internString("fn") catch return;
    sf_peval = gc.internString("peval") catch return;
    sf_defn = gc.internString("defn") catch return;
    sf_initialized = true;
    sf_gc_ptr = gc;
}

// ============================================================================
// OPERATIONAL SEMANTICS: Fuel-bounded eval
// ============================================================================

/// Fuel-bounded eval: operational semantics with resource tracking.
pub fn evalBounded(val: Value, env: *Env, gc: *GC, res: *Resources) Domain {
    res.tick() catch return .{ .bottom = .fuel_exhausted };
    res.descend() catch return .{ .bottom = .depth_exceeded };
    defer res.ascend();

    if (val.isNil() or val.isBool() or val.isInt() or val.isString() or val.isKeyword()) {
        return Domain.pure(val);
    }
    if (!val.isObj() and !val.isSymbol()) {
        return Domain.pure(val);
    }

    if (val.isSymbol()) {
        const sym_id = val.asSymbolId();
        // Fast path: integer-keyed lookup (no string hashing)
        if (env.getById(sym_id)) |v| return Domain.pure(v);
        // Fallback: string-keyed lookup (for bindings set via string API)
        const name = gc.getString(sym_id);
        return if (env.get(name)) |v|
            Domain.pure(v)
        else
            Domain.fail(.unbound_symbol);
    }

    const obj = val.asObj();
    if (obj.kind == .vector) return evalBoundedVector(obj, env, gc, res);
    if (obj.kind == .map) return evalBoundedMap(obj, env, gc, res);
    if (obj.kind != .list) return Domain.pure(val);

    const items = obj.data.list.items.items;
    if (items.len == 0) return Domain.pure(val);

    if (items[0].isSymbol()) {
        ensureSpecialFormIds(gc);
        const sym_id = items[0].asSymbolId();

        if (sf_initialized) {
            if (sym_id == sf_quote) return if (items.len == 2) Domain.pure(items[1]) else Domain.fail(.arity_error);
            if (sym_id == sf_def) return evalBoundedDef(items, env, gc, res);
            if (sym_id == sf_let or sym_id == sf_let_bare) return evalBoundedLet(items, env, gc, res);
            if (sym_id == sf_if) return evalBoundedIf(items, env, gc, res);
            if (sym_id == sf_do) return evalBoundedDo(items, env, gc, res);
            if (sym_id == sf_fn or sym_id == sf_fn_bare) return evalBoundedFnStar(items, env, gc, res);
            if (sym_id == sf_peval) return evalBoundedPeval(items, env, gc, res);
            if (sym_id == sf_defn) return evalBoundedDefn(items, env, gc, res);
            // Fall through to string compare for deftest/testing/try/ns
        }
        {
            const sname = gc.getString(sym_id);
            // deftest: items = [deftest, name, body...] — skip name, eval body
            if (std.mem.eql(u8, sname, "deftest")) {
                if (items.len < 3) return Domain.pure(Value.makeNil());
                var result = Domain.pure(Value.makeNil());
                for (items[2..]) |form| {
                    result = evalBounded(form, env, gc, res);
                    if (!result.isValue()) return result;
                }
                return result;
            }
            // testing: items = [testing, "description", body...] — skip desc, eval body
            if (std.mem.eql(u8, sname, "testing")) {
                if (items.len < 3) return Domain.pure(Value.makeNil());
                var result = Domain.pure(Value.makeNil());
                for (items[2..]) |form| {
                    result = evalBounded(form, env, gc, res);
                    if (!result.isValue()) return result;
                }
                return result;
            }
            if (std.mem.eql(u8, sname, "defmacro")) return evalBoundedDefmacro(items, env, gc, res);
            // defmulti: (defmulti name dispatch-fn) → bind name to dispatch-fn
            if (std.mem.eql(u8, sname, "defmulti")) {
                if (items.len >= 3 and items[1].isSymbol()) {
                    const mname = gc.getString(items[1].asSymbolId());
                    const dispatch_d = evalBounded(items[2], env, gc, res);
                    if (!dispatch_d.isValue()) return dispatch_d;
                    env.set(mname, dispatch_d.value) catch return Domain.fail(.type_error);
                    return dispatch_d;
                }
                return Domain.pure(Value.makeNil());
            }
            // defmethod: (defmethod name val impl) → eval impl for side effect
            if (std.mem.eql(u8, sname, "defmethod")) {
                if (items.len >= 4) {
                    const impl_d = evalBounded(items[items.len - 1], env, gc, res);
                    return impl_d;
                }
                return Domain.pure(Value.makeNil());
            }
            if (std.mem.eql(u8, sname, "defprotocol")) return Domain.pure(Value.makeNil());
            if (std.mem.eql(u8, sname, "extend-type")) return Domain.pure(Value.makeNil());
            // ns: return the namespace name as a symbol
            if (std.mem.eql(u8, sname, "ns")) {
                if (items.len >= 2 and items[1].isSymbol()) return Domain.pure(items[1]);
                return Domain.pure(Value.makeNil());
            }
            if (std.mem.eql(u8, sname, "in-ns")) {
                if (items.len >= 2) {
                    const ns_d = evalBounded(items[1], env, gc, res);
                    return ns_d;
                }
                return Domain.pure(Value.makeNil());
            }
            // require: (require 'ns) → load-file if file exists, else return ns name
            if (std.mem.eql(u8, sname, "require")) {
                if (items.len >= 2) {
                    const req_d = evalBounded(items[1], env, gc, res);
                    if (req_d.isValue()) return Domain.pure(req_d.value);
                }
                return Domain.pure(Value.makeNil());
            }
            // with-out-str: eval body, return empty string (output capture not yet implemented)
            if (std.mem.eql(u8, sname, "with-out-str")) {
                var result = Domain.pure(Value.makeNil());
                for (items[1..]) |form| {
                    result = evalBounded(form, env, gc, res);
                    if (!result.isValue()) return result;
                }
                const empty = gc.internString("") catch return Domain.fail(.type_error);
                return Domain.pure(Value.makeString(empty));
            }
            if (std.mem.eql(u8, sname, "macroexpand-1")) {
                if (items.len < 2) return Domain.fail(.arity_error);
                const form_d = evalBounded(items[1], env, gc, res);
                if (!form_d.isValue()) return form_d;
                return Domain.pure(form_d.value);
            }
            if (std.mem.eql(u8, sname, "try")) return evalBoundedTry(items, env, gc, res);
            // ns/in-ns handled above with proper return values
            if (std.mem.eql(u8, sname, "comment")) return Domain.pure(Value.makeNil());
            // recur: set signal args for loop to catch
            if (std.mem.eql(u8, sname, "recur")) {
                recur_count = 0;
                for (items[1..]) |arg| {
                    const d = evalBounded(arg, env, gc, res);
                    if (!d.isValue()) return d;
                    if (recur_count < 16) {
                        recur_args[recur_count] = d.value;
                        recur_count += 1;
                    }
                }
                recur_pending = true;
                return Domain.pure(Value.makeNil()); // sentinel — loop will catch
            }
            // and: short-circuit, return first falsy or last value
            if (std.mem.eql(u8, sname, "and")) {
                var result = Domain.pure(Value.makeBool(true));
                for (items[1..]) |form| {
                    result = evalBounded(form, env, gc, res);
                    if (!result.isValue()) return result;
                    if (!result.value.isTruthy()) return result;
                }
                return result;
            }
            // or: short-circuit, return first truthy or last value
            if (std.mem.eql(u8, sname, "or")) {
                var result = Domain.pure(Value.makeNil());
                for (items[1..]) |form| {
                    result = evalBounded(form, env, gc, res);
                    if (!result.isValue()) return result;
                    if (result.value.isTruthy()) return result;
                }
                return result;
            }
            // when: (when test body...) = if test is truthy, eval body
            if (std.mem.eql(u8, sname, "when")) {
                if (items.len < 2) return Domain.pure(Value.makeNil());
                const test_d = evalBounded(items[1], env, gc, res);
                if (!test_d.isValue()) return test_d;
                if (!test_d.value.isTruthy()) return Domain.pure(Value.makeNil());
                var result = Domain.pure(Value.makeNil());
                for (items[2..]) |form| {
                    result = evalBounded(form, env, gc, res);
                    if (!result.isValue()) return result;
                }
                return result;
            }
            if (std.mem.eql(u8, sname, "when-not")) {
                if (items.len < 2) return Domain.pure(Value.makeNil());
                const test_d = evalBounded(items[1], env, gc, res);
                if (!test_d.isValue()) return test_d;
                if (test_d.value.isTruthy()) return Domain.pure(Value.makeNil());
                var result = Domain.pure(Value.makeNil());
                for (items[2..]) |form| {
                    result = evalBounded(form, env, gc, res);
                    if (!result.isValue()) return result;
                }
                return result;
            }
            // case: (case expr val1 result1 val2 result2 ... default)
            if (std.mem.eql(u8, sname, "case")) {
                if (items.len < 3) return Domain.fail(.arity_error);
                const expr_d = evalBounded(items[1], env, gc, res);
                if (!expr_d.isValue()) return expr_d;
                var i: usize = 2;
                while (i + 1 < items.len) : (i += 2) {
                    if (semantics.structuralEq(expr_d.value, items[i], gc))
                        return evalBounded(items[i + 1], env, gc, res);
                }
                // Odd remaining item = default
                if (i < items.len) return evalBounded(items[i], env, gc, res);
                return Domain.pure(Value.makeNil());
            }
            // doseq: (doseq [x coll] body...) — eval body for side effects
            if (std.mem.eql(u8, sname, "doseq")) {
                if (items.len < 3) return Domain.fail(.arity_error);
                if (!items[1].isObj()) return Domain.fail(.type_error);
                const bindings = switch (items[1].asObj().kind) {
                    .vector => items[1].asObj().data.vector.items.items,
                    .list => items[1].asObj().data.list.items.items,
                    else => return Domain.fail(.type_error),
                };
                if (bindings.len < 2 or !bindings[0].isSymbol()) return Domain.fail(.type_error);
                const sym_name = gc.getString(bindings[0].asSymbolId());
                const coll_d = evalBounded(bindings[1], env, gc, res);
                if (!coll_d.isValue()) return coll_d;
                const coll_items = getItemsDomain(coll_d.value) orelse return Domain.pure(Value.makeNil());
                for (coll_items) |item| {
                    const child = env.createChild() catch return Domain.fail(.type_error);
                    gc.trackEnv(child) catch return Domain.fail(.type_error);
                    child.set(sym_name, item) catch return Domain.fail(.type_error);
                    for (items[2..]) |form| {
                        const d = evalBounded(form, child, gc, res);
                        if (!d.isValue()) return d;
                    }
                }
                return Domain.pure(Value.makeNil());
            }
            // loop/recur: (loop [x init y init] body...)
            if (std.mem.eql(u8, sname, "loop")) {
                if (items.len < 3) return Domain.fail(.arity_error);
                if (!items[1].isObj()) return Domain.fail(.type_error);
                const bindings = switch (items[1].asObj().kind) {
                    .vector => items[1].asObj().data.vector.items.items,
                    .list => items[1].asObj().data.list.items.items,
                    else => return Domain.fail(.type_error),
                };
                if (bindings.len % 2 != 0) return Domain.fail(.type_error);
                // Create env with bindings
                const loop_env = env.createChild() catch return Domain.fail(.type_error);
                gc.trackEnv(loop_env) catch return Domain.fail(.type_error);
                var bi: usize = 0;
                while (bi < bindings.len) : (bi += 2) {
                    if (!bindings[bi].isSymbol()) return Domain.fail(.type_error);
                    const bname = gc.getString(bindings[bi].asSymbolId());
                    const bval_d = evalBounded(bindings[bi + 1], env, gc, res);
                    if (!bval_d.isValue()) return bval_d;
                    loop_env.set(bname, bval_d.value) catch return Domain.fail(.type_error);
                }
                // Eval body, handle recur via signal
                recur_pending = false;
                var iterations: u32 = 0;
                while (iterations < 10000) : (iterations += 1) {
                    var result = Domain.pure(Value.makeNil());
                    recur_pending = false;
                    for (items[2..]) |form| {
                        result = evalBounded(form, loop_env, gc, res);
                        if (!result.isValue()) return result;
                        if (recur_pending) break;
                    }
                    if (recur_pending) {
                        recur_pending = false;
                        // Re-bind loop vars from recur_args
                        var rbi: usize = 0;
                        while (rbi < bindings.len and rbi / 2 < recur_count) : (rbi += 2) {
                            const rbname = gc.getString(bindings[rbi].asSymbolId());
                            loop_env.set(rbname, recur_args[rbi / 2]) catch return Domain.fail(.type_error);
                        }
                        continue;
                    }
                    return result;
                }
                return Domain.fail(.type_error); // max iterations
            }
            // for: (for [x coll] body) — list comprehension
            if (std.mem.eql(u8, sname, "for")) {
                if (items.len < 3) return Domain.fail(.arity_error);
                if (!items[1].isObj()) return Domain.fail(.type_error);
                const bindings = switch (items[1].asObj().kind) {
                    .vector => items[1].asObj().data.vector.items.items,
                    .list => items[1].asObj().data.list.items.items,
                    else => return Domain.fail(.type_error),
                };
                if (bindings.len < 2 or !bindings[0].isSymbol()) return Domain.fail(.type_error);
                const for_name = gc.getString(bindings[0].asSymbolId());
                const coll_d = evalBounded(bindings[1], env, gc, res);
                if (!coll_d.isValue()) return coll_d;
                const coll_items = getItemsDomain(coll_d.value) orelse return Domain.pure(Value.makeNil());
                const result_obj = gc.allocObj(.list) catch return Domain.fail(.type_error);
                for (coll_items) |item| {
                    const child = env.createChild() catch return Domain.fail(.type_error);
                    gc.trackEnv(child) catch return Domain.fail(.type_error);
                    child.set(for_name, item) catch return Domain.fail(.type_error);
                    // Handle nested bindings: [x coll y coll2]
                    if (bindings.len >= 4 and bindings[2].isSymbol()) {
                        const for_name2 = gc.getString(bindings[2].asSymbolId());
                        const coll2_d = evalBounded(bindings[3], child, gc, res);
                        if (!coll2_d.isValue()) return coll2_d;
                        const coll2_items = getItemsDomain(coll2_d.value) orelse continue;
                        for (coll2_items) |item2| {
                            child.set(for_name2, item2) catch continue;
                            for (items[2..]) |form| {
                                const d = evalBounded(form, child, gc, res);
                                if (d.isValue()) {
                                    result_obj.data.list.items.append(gc.allocator, d.value) catch continue;
                                }
                            }
                        }
                    } else {
                        for (items[2..]) |form| {
                            const d = evalBounded(form, child, gc, res);
                            if (d.isValue()) {
                                result_obj.data.list.items.append(gc.allocator, d.value) catch continue;
                            }
                        }
                    }
                }
                return Domain.pure(Value.makeObj(result_obj));
            }
        }
        if (!sf_initialized) {
            const fname = gc.getString(sym_id);
            if (std.mem.eql(u8, fname, "quote")) return if (items.len == 2) Domain.pure(items[1]) else Domain.fail(.arity_error);
            if (std.mem.eql(u8, fname, "def")) return evalBoundedDef(items, env, gc, res);
            if (std.mem.eql(u8, fname, "let*") or std.mem.eql(u8, fname, "let")) return evalBoundedLet(items, env, gc, res);
            if (std.mem.eql(u8, fname, "if")) return evalBoundedIf(items, env, gc, res);
            if (std.mem.eql(u8, fname, "do")) return evalBoundedDo(items, env, gc, res);
            if (std.mem.eql(u8, fname, "fn*") or std.mem.eql(u8, fname, "fn")) return evalBoundedFnStar(items, env, gc, res);
            if (std.mem.eql(u8, fname, "defn")) return evalBoundedDefn(items, env, gc, res);
            if (std.mem.eql(u8, fname, "peval")) return evalBoundedPeval(items, env, gc, res);
        }

        // Macro expansion: check if symbol resolves to a macro
        {
            const sym_name = gc.getString(sym_id);
            if (env.get(sym_name)) |head_val| {
                if (head_val.isObj() and head_val.asObj().kind == .macro_fn) {
                    // Pass unevaluated args to macro, then eval result
                    const eval_mod = @import("eval.zig");
                    const expanded = eval_mod.apply(head_val, items[1..], env, gc) catch
                        return Domain.fail(.type_error);
                    return evalBounded(expanded, env, gc, res);
                }
            }
        }

        const core = @import("core.zig");
        const name = gc.getString(sym_id);
        if (core.lookupBuiltin(name)) |builtin| {
            return evalBoundedBuiltin(builtin, items[1..], env, gc, res);
        }
    }

    const func_d = evalBounded(items[0], env, gc, res);
    if (!func_d.isValue()) return func_d;

    // Macro expansion for non-symbol heads that resolve to macros
    if (func_d.value.isObj() and func_d.value.asObj().kind == .macro_fn) {
        const eval_mod = @import("eval.zig");
        const expanded = eval_mod.apply(func_d.value, items[1..], env, gc) catch
            return Domain.fail(.type_error);
        return evalBounded(expanded, env, gc, res);
    }

    const core = @import("core.zig");
    if (core.isBuiltinSentinel(func_d.value, gc)) |bname| {
        if (core.lookupBuiltin(bname)) |builtin| {
            return evalBoundedBuiltin(builtin, items[1..], env, gc, res);
        }
    }

    // Sequential arg eval — no fork/join overhead (peval has its own fork path)
    const raw_args = items[1..];
    var args_buf: [64]Value = undefined;
    var args_count: usize = 0;
    for (raw_args) |arg| {
        if (args_count >= 64) return Domain.fail(.collection_too_large);
        const d = evalBounded(arg, env, gc, res);
        if (!d.isValue()) return d;
        args_buf[args_count] = d.value;
        args_count += 1;
    }
    return applyBounded(func_d.value, args_buf[0..args_count], env, gc, res);
}

fn evalBoundedBuiltin(
    builtin: *const fn ([]Value, *GC, *Env) anyerror!Value,
    raw_args: []Value,
    env: *Env,
    gc: *GC,
    res: *Resources,
) Domain {
    // Sequential arg eval — no fork/join overhead
    var args_buf: [64]Value = undefined;
    var args_count: usize = 0;
    for (raw_args) |arg| {
        if (args_count >= 64) return Domain.fail(.collection_too_large);
        const d = evalBounded(arg, env, gc, res);
        if (!d.isValue()) return d;
        args_buf[args_count] = d.value;
        args_count += 1;
    }
    const result = builtin(args_buf[0..args_count], gc, env) catch
        return Domain.fail(.type_error);
    return Domain.pure(result);
}

fn evalBoundedVector(obj: *Obj, env: *Env, gc: *GC, res: *Resources) Domain {
    const new = gc.allocObj(.vector) catch return Domain.fail(.type_error);
    for (obj.data.vector.items.items) |item| {
        const d = evalBounded(item, env, gc, res);
        if (!d.isValue()) return d;
        new.data.vector.items.append(gc.allocator, d.value) catch
            return Domain.fail(.type_error);
    }
    return Domain.pure(Value.makeObj(new));
}

fn evalBoundedMap(obj: *Obj, env: *Env, gc: *GC, res: *Resources) Domain {
    const new = gc.allocObj(.map) catch return Domain.fail(.type_error);
    for (obj.data.map.keys.items, 0..) |key, i| {
        const k = evalBounded(key, env, gc, res);
        if (!k.isValue()) return k;
        const v = evalBounded(obj.data.map.vals.items[i], env, gc, res);
        if (!v.isValue()) return v;
        new.data.map.keys.append(gc.allocator, k.value) catch
            return Domain.fail(.type_error);
        new.data.map.vals.append(gc.allocator, v.value) catch
            return Domain.fail(.type_error);
    }
    return Domain.pure(Value.makeObj(new));
}

fn evalBoundedDef(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len != 3) return Domain.fail(.arity_error);
    if (!items[1].isSymbol()) return Domain.fail(.type_error);
    const sym_id = items[1].asSymbolId();
    const name = gc.getString(sym_id);
    const d = evalBounded(items[2], env, gc, res);
    if (!d.isValue()) return d;
    env.set(name, d.value) catch return Domain.fail(.type_error);
    env.setById(sym_id, d.value) catch {};
    return d;
}

/// (defn name [params] body...) → desugar to (def name (fn* [params] body...))
fn evalBoundedDefn(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len < 4) return Domain.fail(.arity_error);
    if (!items[1].isSymbol()) return Domain.fail(.type_error);
    const sym_id = items[1].asSymbolId();
    const name = gc.getString(sym_id);
    // Build synthetic [fn*, params, body...] — reuse items[1..] shifted
    var fn_items: [64]Value = undefined;
    fn_items[0] = items[0]; // placeholder (ignored by evalBoundedFnStar)
    fn_items[1] = items[2]; // params vector
    const body = items[3..];
    if (body.len + 2 > fn_items.len) return Domain.fail(.arity_error);
    for (body, 0..) |b, i| fn_items[2 + i] = b;
    const fn_d = evalBoundedFnStar(fn_items[0 .. 2 + body.len], env, gc, res);
    if (!fn_d.isValue()) return fn_d;
    env.set(name, fn_d.value) catch return Domain.fail(.type_error);
    env.setById(sym_id, fn_d.value) catch {};
    return fn_d;
}

/// (defmacro name [params] body...) — like defn but creates macro_fn
fn evalBoundedDefmacro(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len < 4) return Domain.fail(.arity_error);
    if (!items[1].isSymbol()) return Domain.fail(.type_error);
    const sym_id = items[1].asSymbolId();
    const name = gc.getString(sym_id);

    if (!items[2].isObj()) return Domain.fail(.type_error);
    const params_obj = items[2].asObj();
    const params = if (params_obj.kind == .vector)
        params_obj.data.vector.items.items
    else if (params_obj.kind == .list)
        params_obj.data.list.items.items
    else
        return Domain.fail(.type_error);

    const macro_obj = gc.allocObj(.macro_fn) catch return Domain.fail(.type_error);
    var is_variadic = false;
    for (params) |p| {
        if (p.isSymbol() and std.mem.eql(u8, gc.getString(p.asSymbolId()), "&")) {
            is_variadic = true;
            continue;
        }
        macro_obj.data.macro_fn.params.append(gc.allocator, p) catch return Domain.fail(.type_error);
    }
    macro_obj.data.macro_fn.is_variadic = is_variadic;
    macro_obj.data.macro_fn.env = env;
    macro_obj.data.macro_fn.name = name;
    _ = res;
    for (items[3..]) |body_form| {
        macro_obj.data.macro_fn.body.append(gc.allocator, body_form) catch return Domain.fail(.type_error);
    }
    const val = Value.makeObj(macro_obj);
    env.set(name, val) catch return Domain.fail(.type_error);
    env.setById(sym_id, val) catch {};
    return Domain.pure(val);
}

fn evalBoundedLet(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len < 3) return Domain.fail(.arity_error);
    if (!items[1].isObj()) return Domain.fail(.type_error);
    const bindings_obj = items[1].asObj();
    const bindings = if (bindings_obj.kind == .vector)
        bindings_obj.data.vector.items.items
    else if (bindings_obj.kind == .list)
        bindings_obj.data.list.items.items
    else
        return Domain.fail(.type_error);
    if (bindings.len % 2 != 0) return Domain.fail(.arity_error);

    const child = env.createChild() catch return Domain.fail(.type_error);
    gc.trackEnv(child) catch return Domain.fail(.type_error);
    const n_bindings = bindings.len / 2;

    // Level 2: DAG analysis — find independent binding layers.
    // A binding is independent if its RHS doesn't reference any prior let* binding.
    // Independent bindings form a "layer" that can eval with forked fuel.
    if (n_bindings >= 2 and n_bindings <= 32) {
        // Collect binding names (u48 symbol ids for fast comparison)
        var bind_ids: [32]u48 = undefined;
        for (0..n_bindings) |bi| {
            if (!bindings[bi * 2].isSymbol()) return Domain.fail(.type_error);
            bind_ids[bi] = bindings[bi * 2].asSymbolId();
        }

        // Build dependency bitmask: deps[i] bit j set = binding i depends on binding j
        var deps: [32]u32 = .{0} ** 32;
        for (0..n_bindings) |bi| {
            deps[bi] = scanDeps(bindings[bi * 2 + 1], bind_ids[0..n_bindings], gc);
        }

        // Topological layer assignment: layer[i] = max(layer[dep]) + 1 for each dep
        var layer: [32]u8 = .{0} ** 32;
        for (0..n_bindings) |bi| {
            var max_dep_layer: u8 = 0;
            for (0..n_bindings) |dj| {
                if (deps[bi] & (@as(u32, 1) << @intCast(dj)) != 0) {
                    if (layer[dj] + 1 > max_dep_layer) max_dep_layer = layer[dj] + 1;
                }
            }
            layer[bi] = max_dep_layer;
        }

        // Find max layer
        var max_layer: u8 = 0;
        for (0..n_bindings) |bi| {
            if (layer[bi] > max_layer) max_layer = layer[bi];
        }

        // Evaluate layer by layer; within each layer, fork fuel
        var current_layer: u8 = 0;
        while (current_layer <= max_layer) : (current_layer += 1) {
            // Count bindings in this layer
            var layer_count: usize = 0;
            var layer_indices: [32]usize = undefined;
            for (0..n_bindings) |bi| {
                if (layer[bi] == current_layer) {
                    layer_indices[layer_count] = bi;
                    layer_count += 1;
                }
            }

            if (layer_count == 1) {
                // Single binding: no fork overhead
                const bi = layer_indices[0];
                const name = gc.getString(bind_ids[bi]);
                const d = evalBounded(bindings[bi * 2 + 1], child, gc, res);
                if (!d.isValue()) return d;
                child.set(name, d.value) catch return Domain.fail(.type_error);
                child.setById(bind_ids[bi], d.value) catch {};
            } else {
                // Multiple independent bindings: fork fuel
                var child_res = res.fork(layer_count);
                var results: [32]Domain = undefined;
                for (0..layer_count) |li| {
                    const bi = layer_indices[li];
                    results[li] = evalBounded(bindings[bi * 2 + 1], child, gc, &child_res[li]);
                }
                res.join(&child_res, layer_count);

                // Bind all results
                for (0..layer_count) |li| {
                    const bi = layer_indices[li];
                    if (!results[li].isValue()) return results[li];
                    const name = gc.getString(bind_ids[bi]);
                    child.set(name, results[li].value) catch return Domain.fail(.type_error);
                    child.setById(bind_ids[bi], results[li].value) catch {};
                }
            }
        }
    } else {
        // Fallback: sequential (0-1 bindings or >32)
        var i: usize = 0;
        while (i < bindings.len) : (i += 2) {
            if (!bindings[i].isSymbol()) return Domain.fail(.type_error);
            const sym_id = bindings[i].asSymbolId();
            const name = gc.getString(sym_id);
            const d = evalBounded(bindings[i + 1], child, gc, res);
            if (!d.isValue()) return d;
            child.set(name, d.value) catch return Domain.fail(.type_error);
            child.setById(sym_id, d.value) catch {};
        }
    }

    var result = Domain.pure(Value.makeNil());
    for (items[2..]) |form| {
        result = evalBounded(form, child, gc, res);
        if (!result.isValue()) return result;
    }
    return result;
}

/// Scan an expression for references to any of the given binding symbol ids.
/// Returns a bitmask: bit i set = expression references bind_ids[i].
fn scanDeps(expr: Value, bind_ids: []const u48, gc: *GC) u32 {
    if (expr.isSymbol()) {
        const sid = expr.asSymbolId();
        for (bind_ids, 0..) |bid, i| {
            if (sid == bid) return @as(u32, 1) << @intCast(i);
        }
        return 0;
    }
    if (!expr.isObj()) return 0;
    const obj = expr.asObj();
    var mask: u32 = 0;
    switch (obj.kind) {
        .list => for (obj.data.list.items.items) |item| {
            mask |= scanDeps(item, bind_ids, gc);
        },
        .vector => for (obj.data.vector.items.items) |item| {
            mask |= scanDeps(item, bind_ids, gc);
        },
        else => {},
    }
    return mask;
}

fn evalBoundedIf(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len < 3 or items.len > 4) return Domain.fail(.arity_error);
    const cond = evalBounded(items[1], env, gc, res);
    if (!cond.isValue()) return cond;
    if (cond.value.isTruthy()) {
        return evalBounded(items[2], env, gc, res);
    } else if (items.len == 4) {
        return evalBounded(items[3], env, gc, res);
    }
    return Domain.pure(Value.makeNil());
}

fn evalBoundedDo(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    var result = Domain.pure(Value.makeNil());
    for (items[1..]) |form| {
        result = evalBounded(form, env, gc, res);
        if (!result.isValue()) return result;
    }
    return result;
}

fn evalBoundedFnStar(items: []Value, env: *Env, gc: *GC, _: *Resources) Domain {
    if (items.len < 3) return Domain.fail(.arity_error);
    if (!items[1].isObj()) return Domain.fail(.type_error);
    const params_obj = items[1].asObj();
    const params = if (params_obj.kind == .vector)
        params_obj.data.vector.items.items
    else if (params_obj.kind == .list)
        params_obj.data.list.items.items
    else
        return Domain.fail(.type_error);

    const fn_obj = gc.allocObj(.function) catch return Domain.fail(.type_error);
    var is_variadic = false;
    for (params) |p| {
        if (p.isSymbol() and std.mem.eql(u8, gc.getString(p.asSymbolId()), "&")) {
            is_variadic = true;
            continue;
        }
        fn_obj.data.function.params.append(gc.allocator, p) catch
            return Domain.fail(.type_error);
    }
    fn_obj.data.function.is_variadic = is_variadic;
    fn_obj.data.function.env = env;
    for (items[2..]) |body_form| {
        fn_obj.data.function.body.append(gc.allocator, body_form) catch
            return Domain.fail(.type_error);
    }
    return Domain.pure(Value.makeObj(fn_obj));
}

/// (peval expr1 expr2 ...) — evaluate all exprs with forked fuel, return vector of results.
/// Level 2 parallelism: dispatches to real OS threads via thread_peval.
/// Zig 0.15: std.Thread + Mutex. Zig 0.16: swap to std.Io fibers.
/// (try body... (catch e handler...)) — eval body, catch errors
fn evalBoundedTry(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len < 2) return Domain.fail(.arity_error);
    // Find catch clause
    var body_end: usize = items.len;
    for (items[1..], 1..) |item, i| {
        if (item.isObj() and item.asObj().kind == .list) {
            const sub = item.asObj().data.list.items.items;
            if (sub.len > 0 and sub[0].isSymbol()) {
                const sn = gc.getString(sub[0].asSymbolId());
                if (std.mem.eql(u8, sn, "catch")) {
                    body_end = i;
                    break;
                }
            }
        }
    }
    // Eval body forms
    var result = Domain.pure(Value.makeNil());
    for (items[1..body_end]) |form| {
        result = evalBounded(form, env, gc, res);
        if (!result.isValue()) {
            // Error — look for catch clause
            if (body_end < items.len) {
                const catch_form = items[body_end].asObj().data.list.items.items;
                // (catch e handler...)
                if (catch_form.len >= 3) {
                    var catch_result = Domain.pure(Value.makeNil());
                    for (catch_form[2..]) |handler| {
                        catch_result = evalBounded(handler, env, gc, res);
                    }
                    return catch_result;
                }
            }
            return Domain.pure(Value.makeNil()); // swallow error if no catch
        }
    }
    return result;
}

fn getItemsDomain(val: Value) ?[]Value {
    if (!val.isObj()) return null;
    return switch (val.asObj().kind) {
        .list => val.asObj().data.list.items.items,
        .vector => val.asObj().data.vector.items.items,
        .set => val.asObj().data.set.items.items,
        else => null,
    };
}

fn evalBoundedPeval(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    const exprs = items[1..];
    const thread_peval = @import("thread_peval.zig");
    return thread_peval.threadPeval(@constCast(exprs), env, gc, res);
}

/// Apply any callable: function objects, builtin sentinels, or partial_fn
fn applyAny(func: Value, args: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    // Try as object first
    if (func.isObj()) return applyBounded(func, args, env, gc, res);
    // Builtin sentinel
    const core = @import("core.zig");
    if (core.isBuiltinSentinel(func, gc)) |bname| {
        if (core.lookupBuiltin(bname)) |builtin| {
            return evalBoundedBuiltin(builtin, args, env, gc, res);
        }
    }
    return Domain.fail(.not_a_function);
}

fn applyBounded(func: Value, args: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (!func.isObj()) return Domain.fail(.not_a_function);
    const obj = func.asObj();

    // partial_fn: special markers or prepend bound args
    if (obj.kind == .partial_fn) {
        const pf = &obj.data.partial_fn;
        const bound = pf.bound_args.items;

        // Special dispatch: comp/juxt/complement/constantly
        if (pf.func.isNil() and bound.len > 0 and bound[0].isKeyword()) {
            const marker = gc.getString(bound[0].asKeywordId());
            if (std.mem.eql(u8, marker, "__constantly__")) {
                return Domain.pure(bound[1]);
            }
            if (std.mem.eql(u8, marker, "__juxt__")) {
                const fns = bound[1..];
                const vec = gc.allocObj(.vector) catch return Domain.fail(.type_error);
                for (fns) |f| {
                    const d = applyAny(f, args, env, gc, res);
                    if (!d.isValue()) return d;
                    vec.data.vector.items.append(gc.allocator, d.value) catch return Domain.fail(.type_error);
                }
                return Domain.pure(Value.makeObj(vec));
            }
            if (std.mem.eql(u8, marker, "__comp__")) {
                const fns = bound[1..];
                var result = args;
                var tmp: [16]Value = undefined;
                var ri: usize = fns.len;
                while (ri > 0) {
                    ri -= 1;
                    const d = applyAny(fns[ri], result, env, gc, res);
                    if (!d.isValue()) return d;
                    tmp[0] = d.value;
                    result = tmp[0..1];
                }
                return Domain.pure(result[0]);
            }
            if (std.mem.eql(u8, marker, "__complement__")) {
                const d = applyAny(bound[1], args, env, gc, res);
                if (!d.isValue()) return d;
                return Domain.pure(Value.makeBool(!d.value.isTruthy()));
            }
        }

        // Normal partial: prepend bound args
        const total = bound.len + args.len;
        if (total > 16) return Domain.fail(.arity_error);
        var combined: [16]Value = undefined;
        for (bound, 0..) |b, i| combined[i] = b;
        for (args, 0..) |a, i| combined[bound.len + i] = a;
        if (pf.func.isObj()) {
            return applyBounded(pf.func, combined[0..total], env, gc, res);
        }
        // Builtin sentinel
        const core = @import("core.zig");
        if (core.isBuiltinSentinel(pf.func, gc)) |bname| {
            if (core.lookupBuiltin(bname)) |builtin| {
                return evalBoundedBuiltin(builtin, combined[0..total], env, gc, res);
            }
        }
        return Domain.fail(.not_a_function);
    }

    if (obj.kind != .function and obj.kind != .macro_fn) return Domain.fail(.not_a_function);

    const fn_data = if (obj.kind == .function) &obj.data.function else &obj.data.macro_fn;
    const fn_env = fn_data.env orelse return Domain.fail(.not_a_function);

    const fn_params = fn_data.params.items;

    // Fast path: non-variadic, small arity — stack-local env with array bindings
    // No hash maps, no heap alloc, no GC tracking. ~64× less memory than heap path.
    if (!fn_data.is_variadic and fn_params.len <= 8) {
        var local_env = Env.initSmall(fn_env);
        defer local_env.deinitSmall();
        if (args.len != fn_params.len) return Domain.fail(.arity_error);
        for (fn_params, 0..) |p, i| {
            local_env.setSmall(p.asSymbolId(), args[i]);
        }
        var result = Domain.pure(Value.makeNil());
        for (fn_data.body.items) |form| {
            result = evalBounded(form, &local_env, gc, res);
            if (!result.isValue()) return result;
        }
        return result;
    }

    // Slow path: variadic or large arity — heap-allocate and GC-track
    const child = fn_env.createChild() catch return Domain.fail(.type_error);
    gc.trackEnv(child) catch return Domain.fail(.type_error);

    if (fn_data.is_variadic) {
        if (fn_params.len == 0) return Domain.fail(.arity_error);
        const required = fn_params.len - 1;
        if (args.len < required) return Domain.fail(.arity_error);
        for (fn_params[0..required], 0..) |p, i| {
            const pid = p.asSymbolId();
            const name = gc.getString(pid);
            child.set(name, args[i]) catch return Domain.fail(.type_error);
            child.setById(pid, args[i]) catch {};
        }
        const rest_obj = gc.allocObj(.list) catch return Domain.fail(.type_error);
        for (args[required..]) |a| {
            rest_obj.data.list.items.append(gc.allocator, a) catch
                return Domain.fail(.type_error);
        }
        const rest_id = fn_params[required].asSymbolId();
        const rest_name = gc.getString(rest_id);
        child.set(rest_name, Value.makeObj(rest_obj)) catch return Domain.fail(.type_error);
        child.setById(rest_id, Value.makeObj(rest_obj)) catch {};
    } else {
        if (args.len != fn_params.len) return Domain.fail(.arity_error);
        for (fn_params, 0..) |p, i| {
            const pid = p.asSymbolId();
            const name = gc.getString(pid);
            child.set(name, args[i]) catch return Domain.fail(.type_error);
            child.setById(pid, args[i]) catch {};
        }
    }

    var result = Domain.pure(Value.makeNil());
    for (fn_data.body.items) |form| {
        result = evalBounded(form, child, gc, res);
        if (!result.isValue()) return result;
    }
    return result;
}

// ============================================================================
// TESTS
// ============================================================================

test "fuel fork/join: conservation" {
    var res = Resources.initDefault();
    const initial_fuel = res.fuel;
    var children = res.fork(3);
    // Parent keeps remainder (initial_fuel mod 3), children get the rest
    const share = initial_fuel / 3;
    const total_child: u64 = children[0].fuel + children[1].fuel + children[2].fuel;
    try std.testing.expectEqual(share * 3, total_child);
    try std.testing.expectEqual(initial_fuel - share * 3, res.fuel);

    children[0].fuel -= 100;
    children[0].steps_taken = 100;
    res.join(children[0..3], 3);
    // Reclaimed = (share-100) + share + share - 3 join cost + remainder
    try std.testing.expectEqual(initial_fuel - 100 - 3, res.fuel);
    try std.testing.expectEqual(@as(u64, 100), res.steps_taken);
}

test "fuel fork/join: GF(3) trit merge" {
    var res = Resources.initDefault();
    var children = res.fork(3);
    children[0].trit_balance = 1;
    children[1].trit_balance = 1;
    children[2].trit_balance = 1;
    res.join(children[0..3], 3);
    try std.testing.expect(res.isConserved());
}

test "peval: parallel literals" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const peval_sym = try gc.internString("peval");
    const list = try gc.allocObj(.list);
    try list.data.list.items.append(gc.allocator, Value.makeSymbol(peval_sym));
    try list.data.list.items.append(gc.allocator, Value.makeInt(1));
    try list.data.list.items.append(gc.allocator, Value.makeInt(2));
    try list.data.list.items.append(gc.allocator, Value.makeInt(3));

    var res = Resources.initDefault();
    const d = evalBounded(Value.makeObj(list), &env, &gc, &res);
    try std.testing.expect(d.isValue());
    // Debug: check what type we got
    try std.testing.expect(!d.value.isInt()); // should NOT be an int
    try std.testing.expect(!d.value.isNil()); // should NOT be nil
    try std.testing.expect(d.value.isObj());
    const obj = d.value.asObj();
    try std.testing.expectEqual(ObjKind.vector, obj.kind);
    const items = obj.data.vector.items.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i48, 1), items[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), items[1].asInt());
    try std.testing.expectEqual(@as(i48, 3), items[2].asInt());
}

test "fuel-bounded eval: literal" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    var res = Resources.initDefault();
    const d = evalBounded(Value.makeInt(42), &env, &gc, &res);
    try std.testing.expect(d.isValue());
    try std.testing.expectEqual(@as(i48, 42), d.value.asInt());
    try std.testing.expect(res.fuel < res.limits.max_fuel);
}

test "fuel-bounded eval: symbol lookup" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    try env.set("x", Value.makeInt(99));
    const sym_id = try gc.internString("x");

    var res = Resources.initDefault();
    const d = evalBounded(Value.makeSymbol(sym_id), &env, &gc, &res);
    try std.testing.expect(d.isValue());
    try std.testing.expectEqual(@as(i48, 99), d.value.asInt());
}

test "fuel-bounded eval: unbound symbol" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const sym_id = try gc.internString("unknown");
    var res = Resources.initDefault();
    const d = evalBounded(Value.makeSymbol(sym_id), &env, &gc, &res);
    try std.testing.expect(d.isError());
    try std.testing.expectEqual(Domain.ErrorKind.unbound_symbol, d.err.kind);
}
