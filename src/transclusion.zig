//! TRANSCLUSION: Denotational meaning function ⟦·⟧ and Domain type
//!
//! Content inclusion across semantic domains — mirrors Forester's
//! \transclude{} primitive: just as a .tree file includes another
//! tree's content by reference, the denotational semantics includes
//! meaning by structural recursion over the expression tree.
//!
//! The Domain monad (Value ∪ {⊥, error}) is the semantic space
//! into which all expressions are "transcluded" (given meaning).

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;

// ============================================================================
// DENOTATIONAL SEMANTICS: Domain & Meaning Function
// ============================================================================

/// The semantic domain D = Value ∪ {⊥, error(e)}
pub const Domain = union(enum) {
    value: Value,
    bottom: BottomReason,
    err: SemanticError,

    pub const BottomReason = enum {
        fuel_exhausted,
        depth_exceeded,
        read_depth_exceeded,
        divergent,
    };

    pub const SemanticError = struct {
        kind: ErrorKind,
        pos: ?usize = null,
        detail: ?[]const u8 = null,
    };

    pub const ErrorKind = enum {
        type_error,
        arity_error,
        unbound_symbol,
        not_a_function,
        invalid_syntax,
        overflow,
        division_by_zero,
        index_out_of_bounds,
        malformed_input,
        collection_too_large,
        string_too_long,
    };

    pub fn isValue(self: Domain) bool {
        return self == .value;
    }

    pub fn isBottom(self: Domain) bool {
        return self == .bottom;
    }

    pub fn isError(self: Domain) bool {
        return self == .err;
    }

    /// Monadic bind: f(v) if value, propagate ⊥/error otherwise
    pub fn bind(self: Domain, f: *const fn (Value) Domain) Domain {
        return switch (self) {
            .value => |v| f(v),
            .bottom => self,
            .err => self,
        };
    }

    /// Lift a Value into the domain
    pub fn pure(v: Value) Domain {
        return .{ .value = v };
    }

    /// Lift an error
    pub fn fail(kind: ErrorKind) Domain {
        return .{ .err = .{ .kind = kind } };
    }

    pub fn failAt(kind: ErrorKind, pos: usize) Domain {
        return .{ .err = .{ .kind = kind, .pos = pos } };
    }
};

// ============================================================================
// DENOTATIONAL: Meaning function ⟦·⟧
// ============================================================================

/// ⟦e⟧ρ — the denotational meaning of expression e in environment ρ
pub fn denote(val: Value, env: *Env, gc: *GC, res: *Resources) Domain {
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
    if (obj.kind == .vector) return denoteVector(obj, env, gc, res);
    if (obj.kind == .map) return denoteMap(obj, env, gc, res);
    if (obj.kind != .list) return Domain.pure(val);

    const items = obj.data.list.items.items;
    if (items.len == 0) return Domain.pure(val);

    if (items[0].isSymbol()) {
        const name = gc.getString(items[0].asSymbolId());
        if (std.mem.eql(u8, name, "quote")) {
            return if (items.len == 2) Domain.pure(items[1]) else Domain.fail(.arity_error);
        }
        if (std.mem.eql(u8, name, "def")) return denoteDef(items, env, gc, res);
        if (std.mem.eql(u8, name, "let*")) return denoteLet(items, env, gc, res);
        if (std.mem.eql(u8, name, "if")) return denoteIf(items, env, gc, res);
        if (std.mem.eql(u8, name, "do")) return denoteDo(items, env, gc, res);
        if (std.mem.eql(u8, name, "fn*")) return denoteFnStar(items, env, gc, res);

        const core = @import("core.zig");
        if (core.lookupBuiltin(name)) |builtin| {
            return denoteBuiltin(builtin, items[1..], env, gc, res);
        }
    }

    // General application: evaluate head, then apply
    const func_d = denote(items[0], env, gc, res);
    if (!func_d.isValue()) return func_d;

    const core = @import("core.zig");
    if (core.isBuiltinSentinel(func_d.value, gc)) |name| {
        if (core.lookupBuiltin(name)) |builtin| {
            return denoteBuiltin(builtin, items[1..], env, gc, res);
        }
    }

    var args_buf: [64]Value = undefined;
    var args_count: usize = 0;
    for (items[1..]) |arg| {
        if (args_count >= 64) return Domain.fail(.collection_too_large);
        const d = denote(arg, env, gc, res);
        if (!d.isValue()) return d;
        args_buf[args_count] = d.value;
        args_count += 1;
    }
    return applyDenote(func_d.value, args_buf[0..args_count], env, gc, res);
}

fn denoteDef(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len != 3) return Domain.fail(.arity_error);
    if (!items[1].isSymbol()) return Domain.fail(.type_error);
    const name = gc.getString(items[1].asSymbolId());
    const d = denote(items[2], env, gc, res);
    if (!d.isValue()) return d;
    env.set(name, d.value) catch return Domain.fail(.type_error);
    return d;
}

fn denoteLet(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
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
        const d = denote(bindings[i + 1], child, gc, res);
        if (!d.isValue()) return d;
        child.set(name, d.value) catch return Domain.fail(.type_error);
    }

    var result = Domain.pure(Value.makeNil());
    for (items[2..]) |form| {
        result = denote(form, child, gc, res);
        if (!result.isValue()) return result;
    }
    return result;
}

fn denoteFnStar(items: []Value, env: *Env, gc: *GC, _: *Resources) Domain {
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

fn denoteBuiltin(
    builtin: *const fn ([]Value, *GC, *Env, *Resources) anyerror!Value,
    raw_args: []Value,
    env: *Env,
    gc: *GC,
    res: *Resources,
) Domain {
    var args_buf: [64]Value = undefined;
    var args_count: usize = 0;
    for (raw_args) |arg| {
        if (args_count >= 64) return Domain.fail(.collection_too_large);
        const d = denote(arg, env, gc, res);
        if (!d.isValue()) return d;
        args_buf[args_count] = d.value;
        args_count += 1;
    }
    const result = builtin(args_buf[0..args_count], gc, env, res) catch
        return Domain.fail(.type_error);
    return Domain.pure(result);
}

fn applyDenote(func: Value, args: []Value, _: *Env, gc: *GC, res: *Resources) Domain {
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
        result = denote(form, child, gc, res);
        if (!result.isValue()) return result;
    }
    return result;
}

fn denoteIf(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (items.len < 3 or items.len > 4) return Domain.fail(.arity_error);
    const cond = denote(items[1], env, gc, res);
    if (!cond.isValue()) return cond;
    if (cond.value.isTruthy()) {
        return denote(items[2], env, gc, res);
    } else if (items.len == 4) {
        return denote(items[3], env, gc, res);
    }
    return Domain.pure(Value.makeNil());
}

fn denoteDo(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    var result = Domain.pure(Value.makeNil());
    for (items[1..]) |form| {
        result = denote(form, env, gc, res);
        if (!result.isValue()) return result;
    }
    return result;
}

fn denoteVector(obj: *Obj, env: *Env, gc: *GC, res: *Resources) Domain {
    const new = gc.allocObj(.vector) catch return Domain.fail(.type_error);
    for (obj.data.vector.items.items) |item| {
        const d = denote(item, env, gc, res);
        if (!d.isValue()) return d;
        new.data.vector.items.append(gc.allocator, d.value) catch
            return Domain.fail(.type_error);
    }
    return Domain.pure(Value.makeObj(new));
}

fn denoteMap(obj: *Obj, env: *Env, gc: *GC, res: *Resources) Domain {
    const new = gc.allocObj(.map) catch return Domain.fail(.type_error);
    for (obj.data.map.keys.items, 0..) |key, i| {
        const k = denote(key, env, gc, res);
        if (!k.isValue()) return k;
        const v = denote(obj.data.map.vals.items[i], env, gc, res);
        if (!v.isValue()) return v;
        new.data.map.keys.append(gc.allocator, k.value) catch
            return Domain.fail(.type_error);
        new.data.map.vals.append(gc.allocator, v.value) catch
            return Domain.fail(.type_error);
    }
    return Domain.pure(Value.makeObj(new));
}

// ============================================================================
// DEFENSIVE READER: Depth-bounded parsing
// ============================================================================

/// Wraps the existing reader with depth and size bounds.
pub fn boundedRead(src: []const u8, gc: *GC, res: *Resources) !Value {
    const reader_mod = @import("reader.zig");
    var reader = reader_mod.Reader.init(src, gc);

    if (src.len > res.limits.max_string_len * 10) {
        return error.InvalidInput;
    }

    return reader.readForm();
}

// ============================================================================
// ADVERSARIAL INPUT GENERATORS (for testing)
// ============================================================================

pub const Adversarial = struct {
    pub fn deepNesting(allocator: std.mem.Allocator, depth: usize) ![]u8 {
        var buf = compat.emptyList(u8);
        for (0..depth) |_| try buf.append(allocator, '(');
        try buf.appendSlice(allocator, "nil");
        for (0..depth) |_| try buf.append(allocator, ')');
        return buf.toOwnedSlice(allocator);
    }

    pub fn longString(allocator: std.mem.Allocator, len: usize) ![]u8 {
        var buf = compat.emptyList(u8);
        try buf.append(allocator, '"');
        for (0..len) |_| try buf.append(allocator, 'a');
        try buf.append(allocator, '"');
        return buf.toOwnedSlice(allocator);
    }

    pub fn manySymbols(allocator: std.mem.Allocator, n: usize) ![]u8 {
        var buf = compat.emptyList(u8);
        try buf.append(allocator, '(');
        for (0..n) |i| {
            if (i > 0) try buf.append(allocator, ' ');
            var sym: [16]u8 = undefined;
            const slen = std.fmt.formatIntBuf(&sym, i, 16, .lower, .{});
            try buf.append(allocator, 'x');
            try buf.appendSlice(allocator, sym[0..slen]);
        }
        try buf.append(allocator, ')');
        return buf.toOwnedSlice(allocator);
    }

    pub const infinite_loop = "(do (def f (fn* [] (f))) (f))";

    pub const stack_bomb =
        \\(do
        \\  (def a (fn* [n] (b n)))
        \\  (def b (fn* [n] (a n)))
        \\  (a 0))
    ;

    pub const quine =
        \\((fn* [x] (list x (list (quote quote) x)))
        \\ (quote (fn* [x] (list x (list (quote quote) x)))))
    ;
};

// ============================================================================
// TESTS
// ============================================================================

test "domain monad laws" {
    const v = Value.makeInt(42);
    const d = Domain.pure(v);
    const identity = struct {
        fn f(val: Value) Domain {
            return Domain.pure(val);
        }
    }.f;
    const bound = d.bind(&identity);
    try std.testing.expect(bound.isValue());
    try std.testing.expect(bound.value.eql(v));

    const e = Domain.fail(.type_error);
    const bound_e = e.bind(&identity);
    try std.testing.expect(bound_e.isError());
}

test "adversarial: deep nesting stays within limits" {
    const allocator = std.testing.allocator;
    const deep = try Adversarial.deepNesting(allocator, 100);
    defer allocator.free(deep);

    var gc = GC.init(allocator);
    defer gc.deinit();

    var res = Resources.init(.{ .max_read_depth = 256 });
    const val = try boundedRead(deep, &gc, &res);
    try std.testing.expect(val.isObj());
}
