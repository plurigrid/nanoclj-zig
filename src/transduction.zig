//! TRANSDUCTION: Fuel-bounded operational eval (signal transformation)
//!
//! The "how signals transform" layer — mirrors the horse BCI pipeline
//! (Signal→Sheaf→Descent→Decode). Each eval step is a transduction:
//! input signal (expression) → transformed signal (value/error/⊥).

const std = @import("std");
const value = @import("value.zig");
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
        const name = gc.getString(val.asSymbolId());
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
        const name = gc.getString(items[0].asSymbolId());
        if (std.mem.eql(u8, name, "quote")) {
            return if (items.len == 2) Domain.pure(items[1]) else Domain.fail(.arity_error);
        }
        if (std.mem.eql(u8, name, "def")) return evalBoundedDef(items, env, gc, res);
        if (std.mem.eql(u8, name, "let*")) return evalBoundedLet(items, env, gc, res);
        if (std.mem.eql(u8, name, "if")) return evalBoundedIf(items, env, gc, res);
        if (std.mem.eql(u8, name, "do")) return evalBoundedDo(items, env, gc, res);
        if (std.mem.eql(u8, name, "fn*")) return evalBoundedFnStar(items, env, gc, res);

        const core = @import("core.zig");
        if (core.lookupBuiltin(name)) |builtin| {
            return evalBoundedBuiltin(builtin, items[1..], env, gc, res);
        }
    }

    const func_d = evalBounded(items[0], env, gc, res);
    if (!func_d.isValue()) return func_d;

    const core = @import("core.zig");
    if (core.isBuiltinSentinel(func_d.value, gc)) |name| {
        if (core.lookupBuiltin(name)) |builtin| {
            return evalBoundedBuiltin(builtin, items[1..], env, gc, res);
        }
    }

    var args_buf: [64]Value = undefined;
    var args_count: usize = 0;
    for (items[1..]) |arg| {
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
    const name = gc.getString(items[1].asSymbolId());
    const d = evalBounded(items[2], env, gc, res);
    if (!d.isValue()) return d;
    env.set(name, d.value) catch return Domain.fail(.type_error);
    return d;
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
    var i: usize = 0;
    while (i < bindings.len) : (i += 2) {
        if (!bindings[i].isSymbol()) return Domain.fail(.type_error);
        const name = gc.getString(bindings[i].asSymbolId());
        const d = evalBounded(bindings[i + 1], child, gc, res);
        if (!d.isValue()) return d;
        child.set(name, d.value) catch return Domain.fail(.type_error);
    }

    var result = Domain.pure(Value.makeNil());
    for (items[2..]) |form| {
        result = evalBounded(form, child, gc, res);
        if (!result.isValue()) return result;
    }
    return result;
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

fn applyBounded(func: Value, args: []Value, _: *Env, gc: *GC, res: *Resources) Domain {
    if (!func.isObj()) return Domain.fail(.not_a_function);
    const obj = func.asObj();
    if (obj.kind != .function and obj.kind != .macro_fn) return Domain.fail(.not_a_function);

    const fn_data = if (obj.kind == .function) &obj.data.function else &obj.data.macro_fn;
    const fn_env = fn_data.env orelse return Domain.fail(.not_a_function);
    const child = fn_env.createChild() catch return Domain.fail(.type_error);
    gc.trackEnv(child) catch return Domain.fail(.type_error);

    const fn_params = fn_data.params.items;
    if (fn_data.is_variadic) {
        if (fn_params.len == 0) return Domain.fail(.arity_error);
        const required = fn_params.len - 1;
        if (args.len < required) return Domain.fail(.arity_error);
        for (fn_params[0..required], 0..) |p, i| {
            const name = gc.getString(p.asSymbolId());
            child.set(name, args[i]) catch return Domain.fail(.type_error);
        }
        const rest_obj = gc.allocObj(.list) catch return Domain.fail(.type_error);
        for (args[required..]) |a| {
            rest_obj.data.list.items.append(gc.allocator, a) catch
                return Domain.fail(.type_error);
        }
        const rest_name = gc.getString(fn_params[required].asSymbolId());
        child.set(rest_name, Value.makeObj(rest_obj)) catch return Domain.fail(.type_error);
    } else {
        if (args.len != fn_params.len) return Domain.fail(.arity_error);
        for (fn_params, 0..) |p, i| {
            const name = gc.getString(p.asSymbolId());
            child.set(name, args[i]) catch return Domain.fail(.type_error);
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
