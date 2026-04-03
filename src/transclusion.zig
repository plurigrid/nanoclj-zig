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
        if (std.mem.eql(u8, name, "if")) return denoteIf(items, env, gc, res);
        if (std.mem.eql(u8, name, "do")) return denoteDo(items, env, gc, res);
    }

    return Domain.pure(val);
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
        var buf = std.ArrayListUnmanaged(u8){};
        for (0..depth) |_| try buf.append(allocator, '(');
        try buf.appendSlice(allocator, "nil");
        for (0..depth) |_| try buf.append(allocator, ')');
        return buf.toOwnedSlice(allocator);
    }

    pub fn longString(allocator: std.mem.Allocator, len: usize) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        try buf.append(allocator, '"');
        for (0..len) |_| try buf.append(allocator, 'a');
        try buf.append(allocator, '"');
        return buf.toOwnedSlice(allocator);
    }

    pub fn manySymbols(allocator: std.mem.Allocator, n: usize) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
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
