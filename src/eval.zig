const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const pluralism = @import("pluralism.zig");

/// Plural-aware truthiness: dispatches through pluralTruth when
/// the current world's truth mode is non-classical.
/// For classical mode, this is equivalent to Value.isTruthy().
/// For intuitionistic mode, 0 and negative numbers become falsy.
/// For paraconsistent mode, nil and 0 yield Trit.both which is
/// treated as truthy (dialetheia: both-true-and-false counts as true).
inline fn pluralIsTruthy(v: Value) bool {
    const world = pluralism.getWorld();
    if (world.truth == .classical) return v.isTruthy();
    const trit = pluralism.pluralTruth(v, world.truth);
    // .true_ and .both are truthy; only .false_ is falsy
    return trit != .false_;
}

/// Unmetered resources for the legacy eval path.
/// Builtins still tick, but fuel is effectively infinite.
var unmetered_res: Resources = Resources.unmetered();

pub const EvalError = error{
    SymbolNotFound,
    NotAFunction,
    InvalidArgs,
    ArityError,
    OutOfMemory,
    TypeError,
    EvalFailed,
    ThrownException,
    RecurCalled,
};

/// Last thrown exception value (set by throw, read by catch).
var thrown_value: Value = Value.makeNil();

pub fn eval(val: Value, env: *Env, gc: *GC) EvalError!Value {
    if (val.isNil() or val.isBool() or val.isInt() or val.isString() or val.isKeyword()) {
        return val;
    }
    if (!val.isObj() and !val.isSymbol()) {
        // float
        return val;
    }
    if (val.isSymbol()) {
        const name = gc.getString(val.asSymbolId());
        return env.get(name) orelse return error.SymbolNotFound;
    }

    const obj = val.asObj();
    if (obj.kind == .vector) return evalVector(obj, env, gc);
    if (obj.kind == .map) return evalMap(obj, env, gc);
    if (obj.kind != .list) return val;

    const items = obj.data.list.items.items;
    if (items.len == 0) return val;

    // Check special forms
    if (items[0].isSymbol()) {
        const name = gc.getString(items[0].asSymbolId());
        if (std.mem.eql(u8, name, "quote")) {
            if (items.len != 2) return error.ArityError;
            return items[1];
        }
        if (std.mem.eql(u8, name, "def")) return evalDef(items, env, gc);
        if (std.mem.eql(u8, name, "let*")) return evalLet(items, env, gc);
        if (std.mem.eql(u8, name, "if")) return evalIf(items, env, gc);
        if (std.mem.eql(u8, name, "do")) return evalDo(items, env, gc);
        if (std.mem.eql(u8, name, "fn*")) return evalFnStar(items, env, gc);
        if (std.mem.eql(u8, name, "defn")) return evalDefn(items, env, gc);
        if (std.mem.eql(u8, name, "deftest")) return evalDeftest(items, env, gc);
        if (std.mem.eql(u8, name, "testing")) return evalTesting(items, env, gc);
        if (std.mem.eql(u8, name, "ns")) return evalNs(items, env, gc);
        if (std.mem.eql(u8, name, "in-ns")) return evalInNs(items, env, gc);
        if (std.mem.eql(u8, name, "defmacro")) return evalDefmacro(items, env, gc);
        if (std.mem.eql(u8, name, "macroexpand-1")) return evalMacroexpand1(items, env, gc);
        if (std.mem.eql(u8, name, "defmulti")) return evalDefmulti(items, env, gc);
        if (std.mem.eql(u8, name, "defmethod")) return evalDefmethod(items, env, gc);
        if (std.mem.eql(u8, name, "defprotocol")) return evalDefprotocol(items, env, gc);
        if (std.mem.eql(u8, name, "extend-type")) return evalExtendType(items, env, gc);
        if (std.mem.eql(u8, name, "->")) return evalThreadFirst(items, env, gc);
        if (std.mem.eql(u8, name, "->>")) return evalThreadLast(items, env, gc);
        if (std.mem.eql(u8, name, "some->")) return evalSomeThread(items, env, gc, true);
        if (std.mem.eql(u8, name, "some->>")) return evalSomeThread(items, env, gc, false);
        if (std.mem.eql(u8, name, "as->")) return evalAsThread(items, env, gc);
        if (std.mem.eql(u8, name, "doto")) return evalDoto(items, env, gc);
        if (std.mem.eql(u8, name, "for")) return evalFor(items, env, gc);
        if (std.mem.eql(u8, name, "doseq")) return evalDoseq(items, env, gc);
        if (std.mem.eql(u8, name, "dotimes")) return evalDotimes(items, env, gc);
        if (std.mem.eql(u8, name, "loop")) return evalLoop(items, env, gc);
        if (std.mem.eql(u8, name, "when-let")) return evalWhenLet(items, env, gc);
        if (std.mem.eql(u8, name, "if-let")) return evalIfLet(items, env, gc);
        if (std.mem.eql(u8, name, "when-not")) return evalWhenNot(items, env, gc);
        if (std.mem.eql(u8, name, "if-not")) return evalIfNot(items, env, gc);
        if (std.mem.eql(u8, name, "cond->")) return evalCondThread(items, env, gc, true);
        if (std.mem.eql(u8, name, "cond->>")) return evalCondThread(items, env, gc, false);
        if (std.mem.eql(u8, name, "condp")) return evalCondp(items, env, gc);
        if (std.mem.eql(u8, name, "case")) return evalCase(items, env, gc);
        if (std.mem.eql(u8, name, "letfn")) return evalLetfn(items, env, gc);
        if (std.mem.eql(u8, name, "colorspace")) return evalColorspace(items, env, gc);
        if (std.mem.eql(u8, name, "blend")) return evalBlend(items, env, gc);
        if (std.mem.eql(u8, name, "try")) return evalTry(items, env, gc);
        if (std.mem.eql(u8, name, "throw")) {
            if (items.len != 2) return error.ArityError;
            thrown_value = try eval(items[1], env, gc);
            return error.ThrownException;
        }
        if (std.mem.eql(u8, name, "recur")) {
            recur_args.items.len = 0;
            for (items[1..]) |arg| {
                const v = try eval(arg, env, gc);
                recur_args.append(gc.allocator, v) catch return error.OutOfMemory;
            }
            return error.RecurCalled;
        }
    }

    // Check builtins before general application
    if (items[0].isSymbol()) {
        const sym_name = gc.getString(items[0].asSymbolId());
        const core = @import("core.zig");
        if (core.lookupBuiltin(sym_name)) |builtin| {
            var args = @import("compat.zig").emptyList(Value);
            defer args.deinit(gc.allocator);
            for (items[1..]) |arg| {
                const v = try eval(arg, env, gc);
                args.append(gc.allocator, v) catch return error.OutOfMemory;
            }
            return builtin(args.items, gc, env, &unmetered_res) catch return error.EvalFailed;
        }
    }

    // Macro expansion: resolve head, if it's a macro, expand then eval result
    const func = try eval(items[0], env, gc);
    if (func.isObj() and func.asObj().kind == .macro_fn) {
        // Pass unevaluated args to macro
        const expanded = try apply(func, items[1..], env, gc);
        return eval(expanded, env, gc);
    }

    // Function application
    var args = @import("compat.zig").emptyList(Value);
    defer args.deinit(gc.allocator);
    for (items[1..]) |arg| {
        const v = try eval(arg, env, gc);
        args.append(gc.allocator, v) catch return error.OutOfMemory;
    }
    return apply(func, args.items, env, gc);
}

fn evalVector(obj: *Obj, env: *Env, gc: *GC) EvalError!Value {
    const new = gc.allocObj(.vector) catch return error.OutOfMemory;
    for (obj.data.vector.items.items) |item| {
        const v = try eval(item, env, gc);
        new.data.vector.items.append(gc.allocator, v) catch return error.OutOfMemory;
    }
    return Value.makeObj(new);
}

fn evalMap(obj: *Obj, env: *Env, gc: *GC) EvalError!Value {
    const new = gc.allocObj(.map) catch return error.OutOfMemory;
    for (obj.data.map.keys.items, 0..) |key, i| {
        const k = try eval(key, env, gc);
        const v = try eval(obj.data.map.vals.items[i], env, gc);
        new.data.map.keys.append(gc.allocator, k) catch return error.OutOfMemory;
        new.data.map.vals.append(gc.allocator, v) catch return error.OutOfMemory;
    }
    return Value.makeObj(new);
}

fn evalDef(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len != 3) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    const name = gc.getString(items[1].asSymbolId());
    const val = try eval(items[2], env, gc);
    env.set(name, val) catch return error.OutOfMemory;
    return val;
}

fn evalLet(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const bindings_obj = items[1].asObj();
    const bindings = if (bindings_obj.kind == .vector)
        bindings_obj.data.vector.items.items
    else if (bindings_obj.kind == .list)
        bindings_obj.data.list.items.items
    else
        return error.TypeError;
    if (bindings.len % 2 != 0) return error.ArityError;

    const child = env.createChild() catch return error.OutOfMemory;
    gc.trackEnv(child) catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < bindings.len) : (i += 2) {
        const val = try eval(bindings[i + 1], child, gc);
        try bindPattern(bindings[i], val, child, gc);
    }

    var result = Value.makeNil();
    for (items[2..]) |form| {
        result = try eval(form, child, gc);
    }
    return result;
}

/// Bind a destructuring pattern to a value.
/// Supports: simple symbol, sequential [a b & rest], associative {:keys [a b]}.
fn bindPattern(pattern: Value, val: Value, env_child: *Env, gc: *GC) EvalError!void {
    if (pattern.isSymbol()) {
        const name = gc.getString(pattern.asSymbolId());
        env_child.set(name, val) catch return error.OutOfMemory;
        return;
    }
    if (!pattern.isObj()) return error.TypeError;
    const pat_obj = pattern.asObj();

    // Sequential destructuring: [a b c & rest]
    if (pat_obj.kind == .vector) {
        const pats = pat_obj.data.vector.items.items;
        const src_items = getSeqItems(val);
        var pi: usize = 0;
        var si: usize = 0;
        while (pi < pats.len) : (pi += 1) {
            if (pats[pi].isSymbol() and std.mem.eql(u8, gc.getString(pats[pi].asSymbolId()), "&")) {
                // Rest binding: everything from si onward
                pi += 1;
                if (pi >= pats.len) return error.TypeError;
                const rest_obj = gc.allocObj(.list) catch return error.OutOfMemory;
                if (src_items) |items| {
                    for (items[si..]) |item| {
                        rest_obj.data.list.items.append(gc.allocator, item) catch return error.OutOfMemory;
                    }
                }
                try bindPattern(pats[pi], Value.makeObj(rest_obj), env_child, gc);
                return;
            }
            const v = if (src_items) |items| (if (si < items.len) items[si] else Value.makeNil()) else Value.makeNil();
            try bindPattern(pats[pi], v, env_child, gc);
            si += 1;
        }
        return;
    }

    // Associative destructuring: {:keys [a b]} or {local-name :key}
    if (pat_obj.kind == .map) {
        const keys = pat_obj.data.map.keys.items;
        const vals = pat_obj.data.map.vals.items;
        for (keys, vals) |k, v| {
            if (k.isKeyword() and std.mem.eql(u8, gc.getString(k.asKeywordId()), "keys")) {
                // {:keys [a b c]} — each symbol name becomes a keyword lookup
                if (!v.isObj()) return error.TypeError;
                const syms = switch (v.asObj().kind) {
                    .vector => v.asObj().data.vector.items.items,
                    .list => v.asObj().data.list.items.items,
                    else => return error.TypeError,
                };
                for (syms) |sym| {
                    if (!sym.isSymbol()) return error.TypeError;
                    const name = gc.getString(sym.asSymbolId());
                    const kw_id = gc.internString(name) catch return error.OutOfMemory;
                    const lookup = mapGet(val, Value.makeKeyword(kw_id), gc);
                    env_child.set(name, lookup) catch return error.OutOfMemory;
                }
            } else if (v.isKeyword()) {
                // {local-sym :key} — bind keyword lookup to local symbol
                if (!k.isSymbol()) return error.TypeError;
                const name = gc.getString(k.asSymbolId());
                const lookup = mapGet(val, v, gc);
                env_child.set(name, lookup) catch return error.OutOfMemory;
            }
        }
        return;
    }
    return error.TypeError;
}

fn getSeqItems(val: Value) ?[]Value {
    if (val.isNil()) return null;
    if (!val.isObj()) return null;
    const obj = val.asObj();
    return switch (obj.kind) {
        .vector => obj.data.vector.items.items,
        .list => obj.data.list.items.items,
        else => null,
    };
}

fn mapGet(map_val: Value, key: Value, gc: *GC) Value {
    if (!map_val.isObj()) return Value.makeNil();
    const obj = map_val.asObj();
    if (obj.kind != .map) return Value.makeNil();
    const semantics = @import("semantics.zig");
    for (obj.data.map.keys.items, obj.data.map.vals.items) |k, v| {
        if (semantics.structuralEq(k, key, gc)) return v;
    }
    return Value.makeNil();
}

/// (try body (catch e handler)) or (try body (catch e handler) (finally cleanup))
fn evalTry(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    // Find catch and finally clauses
    var catch_clause: ?[]Value = null;
    var finally_clause: ?[]Value = null;
    var body_end: usize = items.len;

    for (items[1..], 1..) |form, idx| {
        if (form.isObj() and form.asObj().kind == .list) {
            const sub = form.asObj().data.list.items.items;
            if (sub.len > 0 and sub[0].isSymbol()) {
                const sym = gc.getString(sub[0].asSymbolId());
                if (std.mem.eql(u8, sym, "catch")) {
                    catch_clause = sub;
                    if (body_end == items.len) body_end = idx;
                } else if (std.mem.eql(u8, sym, "finally")) {
                    finally_clause = sub;
                    if (body_end == items.len) body_end = idx;
                }
            }
        }
    }

    // Execute body
    const result = blk: {
        var r = Value.makeNil();
        for (items[1..body_end]) |form| {
            r = eval(form, env, gc) catch |err| {
                if (err == error.ThrownException) {
                    if (catch_clause) |cc| {
                        // (catch ExnType e handler-body...)
                        // We simplify: (catch e handler-body...)
                        if (cc.len >= 3) {
                            const child = env.createChild() catch break :blk Value.makeNil();
                            gc.trackEnv(child) catch break :blk Value.makeNil();
                            // cc[1] = exception binding symbol
                            if (cc[1].isSymbol()) {
                                const ename = gc.getString(cc[1].asSymbolId());
                                child.set(ename, thrown_value) catch {};
                            }
                            var catch_result = Value.makeNil();
                            for (cc[2..]) |cf| {
                                catch_result = eval(cf, child, gc) catch break :blk Value.makeNil();
                            }
                            break :blk catch_result;
                        }
                        break :blk Value.makeNil();
                    }
                    break :blk Value.makeNil();
                }
                break :blk Value.makeNil();
            };
        }
        break :blk r;
    };

    // Finally clause always runs
    if (finally_clause) |fc| {
        for (fc[1..]) |form| {
            _ = eval(form, env, gc) catch {};
        }
    }

    return result;
}

// ============================================================================
// TEST FRAMEWORK
// ============================================================================

pub var test_pass_count: usize = 0;
pub var test_fail_count: usize = 0;
pub var current_test_name: []const u8 = "";
pub var current_testing_label: []const u8 = "";

pub fn getTestCounts() struct { pass: usize, fail: usize } {
    return .{ .pass = test_pass_count, .fail = test_fail_count };
}

pub fn resetTestCounts() void {
    test_pass_count = 0;
    test_fail_count = 0;
}

/// (deftest name body...) — define and run a test
fn evalDeftest(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    current_test_name = gc.getString(items[1].asSymbolId());
    current_testing_label = "";
    var result = Value.makeNil();
    for (items[2..]) |form| {
        result = eval(form, env, gc) catch |err| {
            test_fail_count += 1;
            const compat = @import("compat.zig");
            const stderr = compat.stderrFile();
            compat.fileWriteAll(stderr, "FAIL in ");
            compat.fileWriteAll(stderr, current_test_name);
            compat.fileWriteAll(stderr, "\n");
            return err;
        };
    }
    return result;
}

/// (testing "description" body...) — group assertions
fn evalTesting(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    if (items[1].isString()) {
        current_testing_label = gc.getString(items[1].asStringId());
    }
    var result = Value.makeNil();
    for (items[2..]) |form| {
        result = try eval(form, env, gc);
    }
    current_testing_label = "";
    return result;
}

// ============================================================================
// NAMESPACES
// ============================================================================

const namespace = @import("namespace.zig");
const colorspace_mod = @import("colorspace.zig");
pub var ns_registry: ?namespace.NamespaceRegistry = null;
pub var cs_registry: ?colorspace_mod.ColorspaceRegistry = null;

pub fn initNamespaces(allocator: std.mem.Allocator, core_env: *Env) !void {
    ns_registry = try namespace.NamespaceRegistry.init(allocator, core_env);
    cs_registry = try colorspace_mod.ColorspaceRegistry.init(allocator, core_env);
}

/// (ns name) — legacy adapter: delegates to colorspace focus_on
fn evalNs(items: []Value, _: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    const ns_name = if (items[1].isSymbol())
        gc.getString(items[1].asSymbolId())
    else if (items[1].isString())
        gc.getString(items[1].asStringId())
    else
        return error.TypeError;
    if (cs_registry) |*reg| {
        _ = reg.focus_on(ns_name) catch return error.OutOfMemory;
    }
    if (ns_registry) |*reg| {
        _ = reg.switchTo(ns_name) catch return error.OutOfMemory;
    }
    return Value.makeSymbol(items[1].asSymbolId());
}

/// (in-ns 'name) — legacy adapter: delegates to colorspace focus_on
fn evalInNs(items: []Value, _: *Env, gc: *GC) EvalError!Value {
    if (items.len != 2) return error.ArityError;
    const ns_name = if (items[1].isSymbol())
        gc.getString(items[1].asSymbolId())
    else if (items[1].isString())
        gc.getString(items[1].asStringId())
    else
        return error.TypeError;
    if (cs_registry) |*reg| {
        _ = reg.focus_on(ns_name) catch return error.OutOfMemory;
    }
    if (ns_registry) |*reg| {
        _ = reg.switchTo(ns_name) catch return error.OutOfMemory;
    }
    return Value.makeNil();
}

/// (colorspace name-or-vec) — focus on a colorspace by name or [L a b] coordinates
fn evalColorspace(items: []Value, _: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    var reg = cs_registry orelse return Value.makeNil();
    _ = &reg;
    if (items[1].isSymbol()) {
        const name = gc.getString(items[1].asSymbolId());
        _ = cs_registry.?.focus_on(name) catch return error.OutOfMemory;
        return Value.makeSymbol(items[1].asSymbolId());
    }
    if (items[1].isKeyword()) {
        const name = gc.getString(items[1].asKeywordId());
        _ = cs_registry.?.focus_on(name) catch return error.OutOfMemory;
        return items[1];
    }
    // [L a b] or [L a b alpha] vector literal
    if (items[1].isObj() and items[1].asObj().kind == .vector) {
        const vec = items[1].asObj().data.vector.items.items;
        if (vec.len >= 3) {
            const color = colorspace_mod.Color{
                .L = if (vec[0].isFloat()) @as(f32, @floatCast(vec[0].asFloat())) else if (vec[0].isInt()) @as(f32, @floatFromInt(vec[0].asInt())) else 0.5,
                .a = if (vec[1].isFloat()) @as(f32, @floatCast(vec[1].asFloat())) else if (vec[1].isInt()) @as(f32, @floatFromInt(vec[1].asInt())) else 0.0,
                .b = if (vec[2].isFloat()) @as(f32, @floatCast(vec[2].asFloat())) else if (vec[2].isInt()) @as(f32, @floatFromInt(vec[2].asInt())) else 0.0,
                .alpha = if (vec.len > 3 and vec[3].isFloat()) @as(f32, @floatCast(vec[3].asFloat())) else 1.0,
            };
            const name = if (items.len > 2 and items[2].isSymbol())
                gc.getString(items[2].asSymbolId())
            else
                "anon";
            _ = cs_registry.?.focus_at(color, name) catch return error.OutOfMemory;
            return items[1];
        }
    }
    return error.TypeError;
}

/// (blend cs1 cs2 t result-name) — blend two colorspaces
fn evalBlend(items: []Value, _: *Env, gc: *GC) EvalError!Value {
    if (items.len < 4) return error.ArityError;
    var reg = cs_registry orelse return Value.makeNil();
    _ = &reg;
    const name1 = if (items[1].isSymbol()) gc.getString(items[1].asSymbolId()) else if (items[1].isKeyword()) gc.getString(items[1].asKeywordId()) else return error.TypeError;
    const name2 = if (items[2].isSymbol()) gc.getString(items[2].asSymbolId()) else if (items[2].isKeyword()) gc.getString(items[2].asKeywordId()) else return error.TypeError;
    const t_val = try eval(items[3], &struct { fn get() *Env { return cs_registry.?.currentEnv(); } }.get().*, gc);
    const t: f32 = if (t_val.isFloat()) @as(f32, @floatCast(t_val.asFloat())) else if (t_val.isInt()) @as(f32, @floatFromInt(t_val.asInt())) else 0.5;
    const result_name = if (items.len > 4 and items[4].isSymbol())
        gc.getString(items[4].asSymbolId())
    else
        "blended";
    _ = cs_registry.?.blend(name1, name2, t, result_name) catch return error.OutOfMemory;
    return Value.makeSymbol(try gc.internString(result_name));
}

fn evalIf(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3 or items.len > 4) return error.ArityError;
    const cond = try eval(items[1], env, gc);
    if (pluralIsTruthy(cond)) {
        return eval(items[2], env, gc);
    } else if (items.len == 4) {
        return eval(items[3], env, gc);
    }
    return Value.makeNil();
}

fn evalDo(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    var result = Value.makeNil();
    for (items[1..]) |form| {
        result = try eval(form, env, gc);
    }
    return result;
}

fn evalFnStar(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;

    // Multi-arity: (fn* ([x] body1) ([x y] body2) ...)
    // Detect: items[1] is a list whose first element is a vector (params)
    if (items[1].isObj() and items[1].asObj().kind == .list) {
        const first_arity = items[1].asObj().data.list.items.items;
        if (first_arity.len > 0 and first_arity[0].isObj() and first_arity[0].asObj().kind == .vector) {
            // It's multi-arity: items[1..] are all arity clauses
            return evalMultiArityFn(items[1..], env, gc);
        }
    }

    // Single arity: (fn* [params] body...)
    if (items.len < 3) return error.ArityError;
    return evalSingleArityFn(items[1..], env, gc);
}

fn evalSingleArityFn(arity_items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (!arity_items[0].isObj()) return error.TypeError;
    const params_obj = arity_items[0].asObj();
    const params = if (params_obj.kind == .vector)
        params_obj.data.vector.items.items
    else if (params_obj.kind == .list)
        params_obj.data.list.items.items
    else
        return error.TypeError;

    const fn_obj = gc.allocObj(.function) catch return error.OutOfMemory;
    var is_variadic = false;
    for (params) |p| {
        if (p.isSymbol() and std.mem.eql(u8, gc.getString(p.asSymbolId()), "&")) {
            is_variadic = true;
            continue;
        }
        fn_obj.data.function.params.append(gc.allocator, p) catch return error.OutOfMemory;
    }
    fn_obj.data.function.is_variadic = is_variadic;
    fn_obj.data.function.env = env;
    for (arity_items[1..]) |body_form| {
        fn_obj.data.function.body.append(gc.allocator, body_form) catch return error.OutOfMemory;
    }
    return Value.makeObj(fn_obj);
}

/// Multi-arity fn: store each arity as a fn object in a vector,
/// then wrap in a dispatch fn whose body contains the vector.
fn evalMultiArityFn(clauses: []Value, env: *Env, gc: *GC) EvalError!Value {
    const arities_vec = gc.allocObj(.vector) catch return error.OutOfMemory;
    for (clauses) |clause| {
        if (!clause.isObj() or clause.asObj().kind != .list) return error.TypeError;
        const clause_items = clause.asObj().data.list.items.items;
        if (clause_items.len < 2) return error.ArityError;
        const arity_fn = try evalSingleArityFn(clause_items, env, gc);
        arities_vec.data.vector.items.append(gc.allocator, arity_fn) catch return error.OutOfMemory;
    }
    // Wrapper fn: stores arities in body[0], dispatches by arg count
    const wrapper = gc.allocObj(.function) catch return error.OutOfMemory;
    wrapper.data.function.env = env;
    wrapper.data.function.is_variadic = true;
    wrapper.data.function.name = "__multi_arity__";
    wrapper.data.function.body.append(gc.allocator, Value.makeObj(arities_vec)) catch return error.OutOfMemory;
    return Value.makeObj(wrapper);
}

/// (defn name [params] body...) or (defn name ([x] ...) ([x y] ...))
fn evalDefn(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    const name = gc.getString(items[1].asSymbolId());

    // Multi-arity defn: (defn name ([x] body1) ([x y] body2))
    // Detect: items[2] is a list whose first element is a vector
    if (items[2].isObj() and items[2].asObj().kind == .list) {
        const first = items[2].asObj().data.list.items.items;
        if (first.len > 0 and first[0].isObj() and first[0].asObj().kind == .vector) {
            // Pass all arity clauses to evalFnStar as multi-arity
            var fn_items: [64]Value = undefined;
            fn_items[0] = items[0]; // placeholder
            const clauses = items[2..];
            if (clauses.len + 1 > fn_items.len) return error.ArityError;
            for (clauses, 0..) |c, i| fn_items[1 + i] = c;
            const fn_val = try evalFnStar(fn_items[0 .. 1 + clauses.len], env, gc);
            if (fn_val.isObj()) fn_val.asObj().data.function.name = name;
            env.set(name, fn_val) catch return error.OutOfMemory;
            const id = gc.internString(name) catch return error.OutOfMemory;
            env.setById(id, fn_val) catch return error.OutOfMemory;
            return fn_val;
        }
    }

    // Single arity: (defn name [params] body...)
    if (items.len < 4) return error.ArityError;
    var fn_items: [64]Value = undefined;
    fn_items[0] = items[0];
    fn_items[1] = items[2]; // params
    const body = items[3..];
    if (body.len + 2 > fn_items.len) return error.ArityError;
    for (body, 0..) |b, i| fn_items[2 + i] = b;
    const fn_val = try evalFnStar(fn_items[0 .. 2 + body.len], env, gc);
    if (fn_val.isObj()) fn_val.asObj().data.function.name = name;
    env.set(name, fn_val) catch return error.OutOfMemory;
    const id = gc.internString(name) catch return error.OutOfMemory;
    env.setById(id, fn_val) catch return error.OutOfMemory;
    return fn_val;
}

/// (defmacro name [params] body...)
fn evalDefmacro(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 4) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    const name = gc.getString(items[1].asSymbolId());

    // Build fn* from params + body, then change kind to macro_fn
    if (!items[2].isObj()) return error.TypeError;
    const params_obj = items[2].asObj();
    const params = if (params_obj.kind == .vector)
        params_obj.data.vector.items.items
    else if (params_obj.kind == .list)
        params_obj.data.list.items.items
    else
        return error.TypeError;

    const macro_obj = gc.allocObj(.macro_fn) catch return error.OutOfMemory;
    var is_variadic = false;
    for (params) |p| {
        if (p.isSymbol() and std.mem.eql(u8, gc.getString(p.asSymbolId()), "&")) {
            is_variadic = true;
            continue;
        }
        macro_obj.data.macro_fn.params.append(gc.allocator, p) catch return error.OutOfMemory;
    }
    macro_obj.data.macro_fn.is_variadic = is_variadic;
    macro_obj.data.macro_fn.env = env;
    macro_obj.data.macro_fn.name = name;
    for (items[3..]) |body_form| {
        macro_obj.data.macro_fn.body.append(gc.allocator, body_form) catch return error.OutOfMemory;
    }
    const val = Value.makeObj(macro_obj);
    env.set(name, val) catch return error.OutOfMemory;
    const id = gc.internString(name) catch return error.OutOfMemory;
    env.setById(id, val) catch return error.OutOfMemory;
    return val;
}

/// (defmulti name dispatch-fn)
fn evalDefmulti(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    const name = gc.getString(items[1].asSymbolId());
    const dispatch_fn = try eval(items[2], env, gc);
    const obj = gc.allocObj(.multimethod) catch return error.OutOfMemory;
    const compat = @import("compat.zig");
    obj.data.multimethod = .{
        .name = name,
        .dispatch_fn = dispatch_fn,
        .methods = compat.emptyList(@import("value.zig").MethodEntry),
        .default_method = null,
    };
    const val = Value.makeObj(obj);
    env.set(name, val) catch return error.OutOfMemory;
    const id = gc.internString(name) catch return error.OutOfMemory;
    env.setById(id, val) catch return error.OutOfMemory;
    return val;
}

/// (defmethod multi-name dispatch-val fn-impl)
/// e.g. (defmethod greet :english (fn [name] (str "Hello, " name)))
/// or   (defmethod greet :default (fn [name] (str "Hi, " name)))
fn evalDefmethod(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 4) return error.ArityError;
    // Resolve the multimethod
    const mm_val = try eval(items[1], env, gc);
    if (!mm_val.isObj() or mm_val.asObj().kind != .multimethod) return error.TypeError;
    const mm = &mm_val.asObj().data.multimethod;
    // Evaluate the dispatch value and the implementation fn
    const dispatch_val = try eval(items[2], env, gc);
    const impl_fn = try eval(items[3], env, gc);
    // Check for :default
    if (dispatch_val.isKeyword()) {
        const kw_name = gc.getString(dispatch_val.asKeywordId());
        if (std.mem.eql(u8, kw_name, "default")) {
            mm.default_method = impl_fn;
            return mm_val;
        }
    }
    // Check if method already exists for this dispatch value, replace if so
    const semantics = @import("semantics.zig");
    for (mm.methods.items, 0..) |m, i| {
        if (semantics.structuralEq(m.dispatch_val, dispatch_val, gc)) {
            mm.methods.items[i].impl_fn = impl_fn;
            return mm_val;
        }
    }
    // Add new method
    mm.methods.append(gc.allocator, .{
        .dispatch_val = dispatch_val,
        .impl_fn = impl_fn,
    }) catch return error.OutOfMemory;
    return mm_val;
}

/// (defprotocol Name (method-name [args]) ...)
fn evalDefprotocol(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    const name = gc.getString(items[1].asSymbolId());
    const obj = gc.allocObj(.protocol) catch return error.OutOfMemory;
    const compat = @import("compat.zig");
    const value_mod = @import("value.zig");
    obj.data.protocol = .{
        .name = name,
        .method_names = compat.emptyList([]const u8),
        .impls = compat.emptyList(value_mod.TypeImpl),
    };
    // Parse method signatures: each is a list (method-name [params])
    for (items[2..]) |sig| {
        if (sig.isObj() and sig.asObj().kind == .list) {
            const sig_items = sig.asObj().data.list.items.items;
            if (sig_items.len > 0 and sig_items[0].isSymbol()) {
                const mname = gc.getString(sig_items[0].asSymbolId());
                obj.data.protocol.method_names.append(gc.allocator, mname) catch return error.OutOfMemory;
            }
        } else if (sig.isSymbol()) {
            // Bare symbol = method name without signature
            obj.data.protocol.method_names.append(gc.allocator, gc.getString(sig.asSymbolId())) catch return error.OutOfMemory;
        }
    }
    const val = Value.makeObj(obj);
    env.set(name, val) catch return error.OutOfMemory;
    const id = gc.internString(name) catch return error.OutOfMemory;
    env.setById(id, val) catch return error.OutOfMemory;
    // Also define each method name as a function that dispatches through the protocol
    for (obj.data.protocol.method_names.items) |mname| {
        const mm_obj = gc.allocObj(.multimethod) catch return error.OutOfMemory;
        // Dispatch fn = type (first arg)
        const type_builtin = env.get("type") orelse Value.makeNil();
        mm_obj.data.multimethod = .{
            .name = mname,
            .dispatch_fn = type_builtin,
            .methods = compat.emptyList(value_mod.MethodEntry),
            .default_method = null,
        };
        const mm_val = Value.makeObj(mm_obj);
        env.set(mname, mm_val) catch return error.OutOfMemory;
        const mid = gc.internString(mname) catch return error.OutOfMemory;
        env.setById(mid, mm_val) catch return error.OutOfMemory;
    }
    return val;
}

/// (extend-type TypeName Protocol (method-name [params] body) ...)
fn evalExtendType(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    const type_name_sym = gc.getString(items[1].asSymbolId());
    // Map symbol names to type names: Vector → "vector", HashMap → "map", etc.
    const type_name = mapTypeName(type_name_sym);
    // items[2] = protocol name (ignored for dispatch, we use the method name)
    // items[3..] = (method-name [params] body...) groups
    var i: usize = 3;
    while (i < items.len) {
        const form = items[i];
        if (form.isObj() and form.asObj().kind == .list) {
            const parts = form.asObj().data.list.items.items;
            if (parts.len >= 3 and parts[0].isSymbol()) {
                const mname = gc.getString(parts[0].asSymbolId());
                // Build a fn from [params] + body
                var fn_items = @import("compat.zig").emptyList(Value);
                defer fn_items.deinit(gc.allocator);
                const fn_star = gc.internString("fn*") catch return error.OutOfMemory;
                fn_items.append(gc.allocator, Value.makeSymbol(fn_star)) catch return error.OutOfMemory;
                for (parts[1..]) |p| {
                    fn_items.append(gc.allocator, p) catch return error.OutOfMemory;
                }
                const fn_list = gc.allocObj(.list) catch return error.OutOfMemory;
                fn_list.data.list.items.appendSlice(gc.allocator, fn_items.items) catch return error.OutOfMemory;
                const impl_fn = try eval(Value.makeObj(fn_list), env, gc);
                // Register as a method on the multimethod named mname
                const mm_val = env.get(mname) orelse {
                    i += 1;
                    continue;
                };
                if (mm_val.isObj() and mm_val.asObj().kind == .multimethod) {
                    const mm = &mm_val.asObj().data.multimethod;
                    const dispatch_val = Value.makeString(gc.internString(type_name) catch return error.OutOfMemory);
                    const semantics = @import("semantics.zig");
                    var found = false;
                    for (mm.methods.items, 0..) |m, j| {
                        if (semantics.structuralEq(m.dispatch_val, dispatch_val, gc)) {
                            mm.methods.items[j].impl_fn = impl_fn;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        mm.methods.append(gc.allocator, .{
                            .dispatch_val = dispatch_val,
                            .impl_fn = impl_fn,
                        }) catch return error.OutOfMemory;
                    }
                }
            }
        }
        i += 1;
    }
    return Value.makeNil();
}

fn mapTypeName(sym: []const u8) []const u8 {
    if (std.mem.eql(u8, sym, "PersistentVector") or std.mem.eql(u8, sym, "Vector")) return "vector";
    if (std.mem.eql(u8, sym, "PersistentHashMap") or std.mem.eql(u8, sym, "HashMap")) return "map";
    if (std.mem.eql(u8, sym, "PersistentList") or std.mem.eql(u8, sym, "List")) return "list";
    if (std.mem.eql(u8, sym, "PersistentHashSet") or std.mem.eql(u8, sym, "Set")) return "set";
    if (std.mem.eql(u8, sym, "String")) return "string";
    if (std.mem.eql(u8, sym, "Number") or std.mem.eql(u8, sym, "Long")) return "integer";
    if (std.mem.eql(u8, sym, "Double") or std.mem.eql(u8, sym, "Float")) return "float";
    if (std.mem.eql(u8, sym, "Keyword")) return "keyword";
    if (std.mem.eql(u8, sym, "Symbol")) return "symbol";
    if (std.mem.eql(u8, sym, "Atom")) return "atom";
    if (std.mem.eql(u8, sym, "nil")) return "nil";
    if (std.mem.eql(u8, sym, "Object")) return "object"; // catch-all
    // Lowercase pass-through (already a type name)
    return sym;
}

// ============================================================================
// THREADING MACROS
// ============================================================================

/// Wrap a value in (quote val) so it survives re-evaluation.
/// Scalars (nil, bool, int, float, string, keyword) are self-evaluating.
fn quoteWrap(val: Value, gc: *GC) EvalError!Value {
    if (val.isNil() or val.isBool() or val.isInt() or val.isString() or val.isKeyword()) return val;
    if (!val.isObj() and !val.isSymbol()) return val; // float
    const q = gc.allocObj(.list) catch return error.OutOfMemory;
    const quote_sym = Value.makeSymbol(gc.internString("quote") catch return error.OutOfMemory);
    q.data.list.items.append(gc.allocator, quote_sym) catch return error.OutOfMemory;
    q.data.list.items.append(gc.allocator, val) catch return error.OutOfMemory;
    return Value.makeObj(q);
}

/// (-> x (f a) (g b)) => (g (f x a) b)
fn evalThreadFirst(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    var result = try eval(items[1], env, gc);
    for (items[2..]) |form| {
        const quoted = try quoteWrap(result, gc);
        if (form.isObj() and form.asObj().kind == .list) {
            const parts = form.asObj().data.list.items.items;
            const call = gc.allocObj(.list) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, parts[0]) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, quoted) catch return error.OutOfMemory;
            for (parts[1..]) |p| call.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
            result = try eval(Value.makeObj(call), env, gc);
        } else {
            const call = gc.allocObj(.list) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, form) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, quoted) catch return error.OutOfMemory;
            result = try eval(Value.makeObj(call), env, gc);
        }
    }
    return result;
}

/// (->> x (f a) (g b)) => (g a (f a x))
fn evalThreadLast(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    var result = try eval(items[1], env, gc);
    for (items[2..]) |form| {
        if (form.isObj() and form.asObj().kind == .list) {
            const parts = form.asObj().data.list.items.items;
            const call = gc.allocObj(.list) catch return error.OutOfMemory;
            for (parts) |p| call.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
            // Wrap result in (quote result) so eval doesn't re-evaluate it as a call
            const quoted = try quoteWrap(result, gc);
            call.data.list.items.append(gc.allocator, quoted) catch return error.OutOfMemory;
            result = try eval(Value.makeObj(call), env, gc);
        } else {
            const call = gc.allocObj(.list) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, form) catch return error.OutOfMemory;
            const quoted = try quoteWrap(result, gc);
            call.data.list.items.append(gc.allocator, quoted) catch return error.OutOfMemory;
            result = try eval(Value.makeObj(call), env, gc);
        }
    }
    return result;
}

/// (some-> x f g) / (some->> x f g) — thread but short-circuit on nil
fn evalSomeThread(items: []Value, env: *Env, gc: *GC, first: bool) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    var result = try eval(items[1], env, gc);
    for (items[2..]) |form| {
        if (result.isNil()) return Value.makeNil();
        const quoted = try quoteWrap(result, gc);
        if (form.isObj() and form.asObj().kind == .list) {
            const parts = form.asObj().data.list.items.items;
            const call = gc.allocObj(.list) catch return error.OutOfMemory;
            if (first) {
                call.data.list.items.append(gc.allocator, parts[0]) catch return error.OutOfMemory;
                call.data.list.items.append(gc.allocator, quoted) catch return error.OutOfMemory;
                for (parts[1..]) |p| call.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
            } else {
                for (parts) |p| call.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
                call.data.list.items.append(gc.allocator, quoted) catch return error.OutOfMemory;
            }
            result = try eval(Value.makeObj(call), env, gc);
        } else {
            const call = gc.allocObj(.list) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, form) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, quoted) catch return error.OutOfMemory;
            result = try eval(Value.makeObj(call), env, gc);
        }
    }
    return result;
}

/// (as-> expr name form1 form2 ...) — thread through named binding
fn evalAsThread(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    var result = try eval(items[1], env, gc);
    if (!items[2].isSymbol()) return error.TypeError;
    const bind_name = gc.getString(items[2].asSymbolId());
    for (items[3..]) |form| {
        env.set(bind_name, result) catch return error.OutOfMemory;
        result = try eval(form, env, gc);
    }
    return result;
}

/// (doto x (f a) (g b)) => x after calling (f x a), (g x b)
fn evalDoto(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    const x = try eval(items[1], env, gc);
    for (items[2..]) |form| {
        if (form.isObj() and form.asObj().kind == .list) {
            const parts = form.asObj().data.list.items.items;
            const call = gc.allocObj(.list) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, parts[0]) catch return error.OutOfMemory;
            call.data.list.items.append(gc.allocator, x) catch return error.OutOfMemory;
            for (parts[1..]) |p| call.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
            _ = try eval(Value.makeObj(call), env, gc);
        }
    }
    return x;
}

// ============================================================================
// CONTROL FLOW SPECIAL FORMS
// ============================================================================

/// (for [x coll] body) — list comprehension (simplified, single binding)
fn evalFor(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const bindings = items[1].asObj().data.vector.items.items;
    if (bindings.len < 2) return error.ArityError;
    if (!bindings[0].isSymbol()) return error.TypeError;
    const sym_name = gc.getString(bindings[0].asSymbolId());
    const coll = try eval(bindings[1], env, gc);
    const coll_items = seqItems(coll, gc) catch return error.TypeError;
    const result = gc.allocObj(.list) catch return error.OutOfMemory;
    for (coll_items) |item| {
        env.set(sym_name, item) catch return error.OutOfMemory;
        var val = Value.makeNil();
        for (items[2..]) |body| val = try eval(body, env, gc);
        result.data.list.items.append(gc.allocator, val) catch return error.OutOfMemory;
    }
    return Value.makeObj(result);
}

/// (doseq [x coll] body) — side-effecting iteration
fn evalDoseq(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const bindings = items[1].asObj().data.vector.items.items;
    if (bindings.len < 2) return error.ArityError;
    if (!bindings[0].isSymbol()) return error.TypeError;
    const sym_name = gc.getString(bindings[0].asSymbolId());
    const coll = try eval(bindings[1], env, gc);
    const coll_items = seqItems(coll, gc) catch return error.TypeError;
    for (coll_items) |item| {
        env.set(sym_name, item) catch return error.OutOfMemory;
        for (items[2..]) |body| _ = try eval(body, env, gc);
    }
    return Value.makeNil();
}

/// (dotimes [i n] body) — iterate i from 0 to n-1
fn evalDotimes(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const bindings = items[1].asObj().data.vector.items.items;
    if (bindings.len < 2) return error.ArityError;
    if (!bindings[0].isSymbol()) return error.TypeError;
    const sym_name = gc.getString(bindings[0].asSymbolId());
    const n_val = try eval(bindings[1], env, gc);
    if (!n_val.isInt()) return error.TypeError;
    const n = n_val.asInt();
    var i: i48 = 0;
    while (i < n) : (i += 1) {
        env.set(sym_name, Value.makeInt(i)) catch return error.OutOfMemory;
        for (items[2..]) |body| _ = try eval(body, env, gc);
    }
    return Value.makeNil();
}

/// (loop [bindings] body) — loop with recur support
fn evalLoop(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const binds = items[1].asObj().data.vector.items.items;
    if (binds.len % 2 != 0) return error.ArityError;
    const n_binds = binds.len / 2;
    // Create child env with bindings
    const child = env.createChild() catch return error.OutOfMemory;
    gc.trackEnv(child) catch return error.OutOfMemory;
    var bind_names: [16][]const u8 = undefined;
    var i: usize = 0;
    while (i < n_binds) : (i += 1) {
        if (!binds[i * 2].isSymbol()) return error.TypeError;
        bind_names[i] = gc.getString(binds[i * 2].asSymbolId());
        const val = try eval(binds[i * 2 + 1], child, gc);
        child.set(bind_names[i], val) catch return error.OutOfMemory;
    }
    // Loop: eval body, if recur, rebind and repeat
    while (true) {
        var result = Value.makeNil();
        for (items[2..]) |body| {
            result = eval(body, child, gc) catch |err| {
                if (err == error.RecurCalled) {
                    // Rebind from recur_args
                    var j: usize = 0;
                    while (j < n_binds and j < recur_args.items.len) : (j += 1) {
                        child.set(bind_names[j], recur_args.items[j]) catch return error.OutOfMemory;
                    }
                    break; // restart loop
                }
                return err;
            };
        } else {
            return result; // no recur, return last value
        }
    }
}

var recur_args: std.ArrayListUnmanaged(Value) = @import("compat.zig").emptyList(Value);

/// (when-let [x expr] body...) — bind and execute if truthy
fn evalWhenLet(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const binds = items[1].asObj().data.vector.items.items;
    if (binds.len < 2 or !binds[0].isSymbol()) return error.ArityError;
    const sym_name = gc.getString(binds[0].asSymbolId());
    const val = try eval(binds[1], env, gc);
    if (!pluralIsTruthy(val)) return Value.makeNil();
    env.set(sym_name, val) catch return error.OutOfMemory;
    var result = Value.makeNil();
    for (items[2..]) |body| result = try eval(body, env, gc);
    return result;
}

/// (if-let [x expr] then else?) — bind and branch
fn evalIfLet(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const binds = items[1].asObj().data.vector.items.items;
    if (binds.len < 2 or !binds[0].isSymbol()) return error.ArityError;
    const sym_name = gc.getString(binds[0].asSymbolId());
    const val = try eval(binds[1], env, gc);
    if (pluralIsTruthy(val)) {
        env.set(sym_name, val) catch return error.OutOfMemory;
        return eval(items[2], env, gc);
    }
    return if (items.len > 3) eval(items[3], env, gc) else Value.makeNil();
}

/// (when-not test body...) — execute body when test is falsy
fn evalWhenNot(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    const test_val = try eval(items[1], env, gc);
    if (pluralIsTruthy(test_val)) return Value.makeNil();
    var result = Value.makeNil();
    for (items[2..]) |body| result = try eval(body, env, gc);
    return result;
}

/// (if-not test then else?) — branch when test is falsy
fn evalIfNot(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    const cond_val = try eval(items[1], env, gc);
    if (!pluralIsTruthy(cond_val)) return eval(items[2], env, gc);
    return if (items.len > 3) eval(items[3], env, gc) else Value.makeNil();
}

/// (cond-> expr test1 form1 test2 form2 ...) — conditional threading
fn evalCondThread(items: []Value, env: *Env, gc: *GC, first: bool) EvalError!Value {
    if (items.len < 2) return error.ArityError;
    var result = try eval(items[1], env, gc);
    var i: usize = 2;
    while (i + 1 < items.len) : (i += 2) {
        const test_val = try eval(items[i], env, gc);
        if (pluralIsTruthy(test_val)) {
            const form = items[i + 1];
            if (form.isObj() and form.asObj().kind == .list) {
                const parts = form.asObj().data.list.items.items;
                const call = gc.allocObj(.list) catch return error.OutOfMemory;
                if (first) {
                    call.data.list.items.append(gc.allocator, parts[0]) catch return error.OutOfMemory;
                    call.data.list.items.append(gc.allocator, result) catch return error.OutOfMemory;
                    for (parts[1..]) |p| call.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
                } else {
                    for (parts) |p| call.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
                    call.data.list.items.append(gc.allocator, result) catch return error.OutOfMemory;
                }
                result = try eval(Value.makeObj(call), env, gc);
            } else {
                const call = gc.allocObj(.list) catch return error.OutOfMemory;
                call.data.list.items.append(gc.allocator, form) catch return error.OutOfMemory;
                call.data.list.items.append(gc.allocator, result) catch return error.OutOfMemory;
                result = try eval(Value.makeObj(call), env, gc);
            }
        }
    }
    return result;
}

/// (condp pred expr clause...) — like cond but with a predicate
fn evalCondp(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 4) return error.ArityError;
    const pred = try eval(items[1], env, gc);
    const expr = try eval(items[2], env, gc);
    var i: usize = 3;
    while (i + 1 < items.len) : (i += 2) {
        const test_val = try eval(items[i], env, gc);
        var test_args = [_]Value{ test_val, expr };
        const result = try apply(pred, &test_args, env, gc);
        if (pluralIsTruthy(result)) return eval(items[i + 1], env, gc);
    }
    // Odd trailing form = default
    if (i < items.len) return eval(items[i], env, gc);
    return error.EvalFailed; // no matching clause
}

/// (case expr val1 result1 val2 result2 ... default?)
fn evalCase(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    const expr = try eval(items[1], env, gc);
    const sem = @import("semantics.zig");
    var i: usize = 2;
    while (i + 1 < items.len) : (i += 2) {
        // case values are NOT evaluated (they're compile-time constants)
        if (sem.structuralEq(items[i], expr, gc)) return eval(items[i + 1], env, gc);
    }
    // Odd trailing form = default
    if (i < items.len) return eval(items[i], env, gc);
    return error.EvalFailed;
}

/// (letfn [(f [x] body) (g [y] body)] body...)
fn evalLetfn(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const bindings = items[1].asObj().data.vector.items.items;
    const child = env.createChild() catch return error.OutOfMemory;
    gc.trackEnv(child) catch return error.OutOfMemory;
    // First pass: bind all fn names to nil (allows mutual recursion)
    for (bindings) |b| {
        if (!b.isObj() or b.asObj().kind != .list) continue;
        const parts = b.asObj().data.list.items.items;
        if (parts.len < 3 or !parts[0].isSymbol()) continue;
        const fname = gc.getString(parts[0].asSymbolId());
        child.set(fname, Value.makeNil()) catch return error.OutOfMemory;
    }
    // Second pass: create fns with child env (sees all names)
    for (bindings) |b| {
        if (!b.isObj() or b.asObj().kind != .list) continue;
        const parts = b.asObj().data.list.items.items;
        if (parts.len < 3 or !parts[0].isSymbol()) continue;
        const fname = gc.getString(parts[0].asSymbolId());
        // Build (fn* [params] body...)
        const fn_list = gc.allocObj(.list) catch return error.OutOfMemory;
        const fn_star = gc.internString("fn*") catch return error.OutOfMemory;
        fn_list.data.list.items.append(gc.allocator, Value.makeSymbol(fn_star)) catch return error.OutOfMemory;
        for (parts[1..]) |p| fn_list.data.list.items.append(gc.allocator, p) catch return error.OutOfMemory;
        const fn_val = try eval(Value.makeObj(fn_list), child, gc);
        child.set(fname, fn_val) catch return error.OutOfMemory;
    }
    // Eval body in child env
    var result = Value.makeNil();
    for (items[2..]) |body| result = try eval(body, child, gc);
    return result;
}

fn seqItems(val: Value, gc: *GC) ![]Value {
    _ = gc;
    if (val.isNil()) return &[_]Value{};
    if (!val.isObj()) return error.TypeError;
    return switch (val.asObj().kind) {
        .list => val.asObj().data.list.items.items,
        .vector => val.asObj().data.vector.items.items,
        .set => val.asObj().data.set.items.items,
        else => error.TypeError,
    };
}

/// (macroexpand-1 form) — expand one level of macro without evaluating
fn evalMacroexpand1(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len != 2) return error.ArityError;
    const form = try eval(items[1], env, gc);
    if (!form.isObj() or form.asObj().kind != .list) return form;
    const list_items = form.asObj().data.list.items.items;
    if (list_items.len == 0) return form;
    if (!list_items[0].isSymbol()) return form;
    const head_name = gc.getString(list_items[0].asSymbolId());
    const head_val = env.get(head_name) orelse return form;
    if (!head_val.isObj() or head_val.asObj().kind != .macro_fn) return form;
    return apply(head_val, list_items[1..], env, gc);
}

pub fn apply(func: Value, args: []const Value, caller_env: *Env, gc: *GC) EvalError!Value {
    // Handle builtin sentinel keywords (e.g. +, zero?, str resolved from env)
    if (func.isKeyword()) {
        const core = @import("core.zig");
        if (core.isBuiltinSentinel(func, gc)) |bname| {
            if (core.lookupBuiltin(bname)) |builtin| {
                return builtin(@constCast(args), gc, caller_env, &unmetered_res) catch return error.EvalFailed;
            }
        }
        // Keyword as function: (:key m) => (get m :key), (:key m default) => (get m :key default)
        if (args.len >= 1 and args.len <= 2) {
            const result = mapGet(args[0], func, gc);
            if (!result.isNil() or args.len == 1) return result;
            return args[1]; // default value
        }
        return error.NotAFunction;
    }
    if (!func.isObj()) return error.NotAFunction;
    const obj = func.asObj();

    if (obj.kind == .function or obj.kind == .macro_fn) {
        const fn_data = if (obj.kind == .function) &obj.data.function else &obj.data.macro_fn;

        // Multi-arity dispatch: name == "__multi_arity__", body[0] = vector of fn objects
        if (fn_data.name) |n| {
            if (std.mem.eql(u8, n, "__multi_arity__") and fn_data.body.items.len > 0) {
                const arities_val = fn_data.body.items[0];
                if (arities_val.isObj() and arities_val.asObj().kind == .vector) {
                    // Try each arity: first try exact match, then variadic
                    for (arities_val.asObj().data.vector.items.items) |arity_val| {
                        if (!arity_val.isObj()) continue;
                        const arity_fn = arity_val.asObj();
                        if (arity_fn.kind != .function) continue;
                        const ad = &arity_fn.data.function;
                        const pcount = ad.params.items.len;
                        if (!ad.is_variadic and pcount == args.len) {
                            return apply(arity_val, args, caller_env, gc);
                        }
                        if (ad.is_variadic and args.len >= pcount - 1) {
                            return apply(arity_val, args, caller_env, gc);
                        }
                    }
                    return error.ArityError;
                }
            }
        }

        const fn_env = fn_data.env orelse return error.EvalFailed;
        const child = fn_env.createChild() catch return error.OutOfMemory;
        gc.trackEnv(child) catch return error.OutOfMemory;

        const params = fn_data.params.items;
        if (fn_data.is_variadic) {
            const required = params.len - 1;
            if (args.len < required) return error.ArityError;
            for (params[0..required], 0..) |p, i| {
                const pname = gc.getString(p.asSymbolId());
                child.set(pname, args[i]) catch return error.OutOfMemory;
            }
            const rest_obj = gc.allocObj(.list) catch return error.OutOfMemory;
            for (args[required..]) |a| {
                rest_obj.data.list.items.append(gc.allocator, a) catch return error.OutOfMemory;
            }
            const rest_name = gc.getString(params[required].asSymbolId());
            child.set(rest_name, Value.makeObj(rest_obj)) catch return error.OutOfMemory;
        } else {
            if (args.len != params.len) return error.ArityError;
            for (params, 0..) |p, i| {
                const pname = gc.getString(p.asSymbolId());
                child.set(pname, args[i]) catch return error.OutOfMemory;
            }
        }

        // Push stack frame for source location tracking
        const frame_name = fn_data.name orelse "<anonymous>";
        const loc = if (obj.meta) |m| @import("srcloc.zig").getLocFromMeta(m, gc) else null;
        @import("srcloc.zig").pushFrame(frame_name, loc);
        defer @import("srcloc.zig").popFrame();

        var result = Value.makeNil();
        for (fn_data.body.items) |form| {
            result = try eval(form, child, gc);
        }
        return result;
    }

    // partial_fn dispatch
    if (obj.kind == .partial_fn) {
        const pf = &obj.data.partial_fn;
        const bound = pf.bound_args.items;

        // Special dispatch: func == nil means comp/juxt/complement/constantly
        if (pf.func.isNil() and bound.len > 0 and bound[0].isKeyword()) {
            const marker = gc.getString(bound[0].asKeywordId());
            if (std.mem.eql(u8, marker, "__comp__")) {
                // (comp f g h) x = f(g(h(x)))
                const fns = bound[1..];
                var result = args;
                var tmp: [16]Value = undefined;
                var ri: usize = fns.len;
                while (ri > 0) {
                    ri -= 1;
                    const r = try apply(fns[ri], result, caller_env, gc);
                    tmp[0] = r;
                    result = tmp[0..1];
                }
                return result[0];
            }
            if (std.mem.eql(u8, marker, "__juxt__")) {
                // (juxt f g h) x = [(f x) (g x) (h x)]
                const fns = bound[1..];
                const vec = gc.allocObj(.vector) catch return error.OutOfMemory;
                for (fns) |f| {
                    const r = try apply(f, args, caller_env, gc);
                    vec.data.vector.items.append(gc.allocator, r) catch return error.OutOfMemory;
                }
                return Value.makeObj(vec);
            }
            if (std.mem.eql(u8, marker, "__complement__")) {
                const r = try apply(bound[1], args, caller_env, gc);
                return Value.makeBool(!pluralIsTruthy(r));
            }
            if (std.mem.eql(u8, marker, "__constantly__")) {
                return bound[1];
            }
            // SRFI-171 transducer dispatch (sector.zig Tier 5)
            const sector = @import("sector.zig");
            if (sector.dispatchTransducer(marker, bound, @constCast(args), gc, caller_env)) |result| {
                return result catch return error.EvalFailed;
            }
        }

        // Normal partial: prepend bound args
        const total_len = bound.len + args.len;
        if (total_len > 16) return error.ArityError;
        var combined: [16]Value = undefined;
        for (bound, 0..) |b, i| combined[i] = b;
        for (args, 0..) |a, i| combined[bound.len + i] = a;
        // Try as function object first
        if (pf.func.isObj()) {
            return apply(pf.func, combined[0..total_len], caller_env, gc);
        }
        // Builtin: resolve by name and call
        const core = @import("core.zig");
        if (core.isBuiltinSentinel(pf.func, gc)) |bname| {
            if (core.lookupBuiltin(bname)) |builtin| {
                return builtin(combined[0..total_len], gc, caller_env, &unmetered_res) catch return error.EvalFailed;
            }
        }
        return error.NotAFunction;
    }

    // Multimethod dispatch
    if (obj.kind == .multimethod) {
        const mm = &obj.data.multimethod;
        // Call dispatch function on the args to get the dispatch value
        const dispatch_result = try apply(mm.dispatch_fn, args, caller_env, gc);
        // Look up matching method
        const semantics = @import("semantics.zig");
        for (mm.methods.items) |m| {
            if (semantics.structuralEq(m.dispatch_val, dispatch_result, gc)) {
                return apply(m.impl_fn, args, caller_env, gc);
            }
        }
        // Fall back to :default
        if (mm.default_method) |default| {
            return apply(default, args, caller_env, gc);
        }
        return error.EvalFailed; // no matching method
    }

    return error.NotAFunction;
}
