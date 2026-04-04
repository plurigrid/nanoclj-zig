const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

pub const EvalError = error{
    SymbolNotFound,
    NotAFunction,
    InvalidArgs,
    ArityError,
    OutOfMemory,
    TypeError,
    EvalFailed,
    ThrownException,
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
        if (std.mem.eql(u8, name, "try")) return evalTry(items, env, gc);
        if (std.mem.eql(u8, name, "throw")) {
            if (items.len != 2) return error.ArityError;
            thrown_value = try eval(items[1], env, gc);
            return error.ThrownException;
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
            return builtin(args.items, gc, env) catch return error.EvalFailed;
        }
    }

    // Function application
    const func = try eval(items[0], env, gc);
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

fn evalIf(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 3 or items.len > 4) return error.ArityError;
    const cond = try eval(items[1], env, gc);
    if (cond.isTruthy()) {
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
    if (items.len < 3) return error.ArityError;
    if (!items[1].isObj()) return error.TypeError;
    const params_obj = items[1].asObj();
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
    for (items[2..]) |body_form| {
        fn_obj.data.function.body.append(gc.allocator, body_form) catch return error.OutOfMemory;
    }
    return Value.makeObj(fn_obj);
}

/// (defn name [params] body...) => (def name (fn* [params] body...))
fn evalDefn(items: []Value, env: *Env, gc: *GC) EvalError!Value {
    if (items.len < 4) return error.ArityError;
    if (!items[1].isSymbol()) return error.TypeError;
    const name = gc.getString(items[1].asSymbolId());
    // Build synthetic fn* items
    var fn_items: [64]Value = undefined;
    fn_items[0] = items[0]; // placeholder
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

pub fn apply(func: Value, args: []const Value, _: *Env, gc: *GC) EvalError!Value {
    if (!func.isObj()) return error.NotAFunction;
    const obj = func.asObj();

    if (obj.kind == .function or obj.kind == .macro_fn) {
        const fn_data = if (obj.kind == .function) &obj.data.function else &obj.data.macro_fn;
        const fn_env = fn_data.env orelse return error.EvalFailed;
        const child = fn_env.createChild() catch return error.OutOfMemory;
        gc.trackEnv(child) catch return error.OutOfMemory;

        const params = fn_data.params.items;
        if (fn_data.is_variadic) {
            // last param gets rest
            const required = params.len - 1;
            if (args.len < required) return error.ArityError;
            for (params[0..required], 0..) |p, i| {
                const name = gc.getString(p.asSymbolId());
                child.set(name, args[i]) catch return error.OutOfMemory;
            }
            // rest as list
            const rest_obj = gc.allocObj(.list) catch return error.OutOfMemory;
            for (args[required..]) |a| {
                rest_obj.data.list.items.append(gc.allocator, a) catch return error.OutOfMemory;
            }
            const rest_name = gc.getString(params[required].asSymbolId());
            child.set(rest_name, Value.makeObj(rest_obj)) catch return error.OutOfMemory;
        } else {
            if (args.len != params.len) return error.ArityError;
            for (params, 0..) |p, i| {
                const name = gc.getString(p.asSymbolId());
                child.set(name, args[i]) catch return error.OutOfMemory;
            }
        }

        var result = Value.makeNil();
        for (fn_data.body.items) |form| {
            result = try eval(form, child, gc);
        }
        return result;
    }

    return error.NotAFunction;
}
