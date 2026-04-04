const std = @import("std");

// NaN-boxed value representation.
// IEEE 754 double: sign(1) | exponent(11) | mantissa(52)
// Quiet NaN:       0 11111111111 1xxx...x  (bit 51 = quiet)
// We use the sign bit + lower 48 bits of mantissa for tag + payload.
//
// Layout when NaN-boxed (non-float):
//   bits 63..52 = 0x7FF8 | tag  (quiet NaN + 3-bit tag in bits 50..48)
//   bits 47..0  = payload (pointer or inline integer)
//
// If the value is NOT a quiet NaN with our marker, it's a plain f64.

pub const Tag = enum(u3) {
    nil = 0,
    boolean = 1,
    integer = 2,
    symbol = 3,
    keyword = 4,
    string = 5,
    object = 6, // heap object: list, vector, map, set, fn, macro
    _reserved = 7,
};

pub const ObjKind = enum(u8) {
    list,
    vector,
    map,
    set,
    function,
    macro_fn,
    atom,
    bc_closure, // bytecode VM closure
    builtin_ref, // reference to a core builtin function
    lazy_seq, // thunk-based lazy sequence
    partial_fn, // partial application capture
    multimethod, // defmulti dispatch fn + method table
    protocol, // defprotocol: method sigs + type→impl dispatch table
};

pub const Obj = struct {
    kind: ObjKind,
    marked: bool = false,
    is_transient: bool = false, // true = mutable (conj!/assoc!/dissoc! allowed)
    meta: ?*Obj = null, // optional metadata map
    data: ObjData,
};

pub const ObjData = union {
    list: struct { items: std.ArrayListUnmanaged(Value) },
    vector: struct { items: std.ArrayListUnmanaged(Value) },
    map: struct { keys: std.ArrayListUnmanaged(Value), vals: std.ArrayListUnmanaged(Value) },
    set: struct { items: std.ArrayListUnmanaged(Value) },
    function: FnData,
    macro_fn: FnData,
    atom: struct { val: Value },
    bc_closure: @import("bytecode.zig").Closure,
    builtin_ref: struct {
        func: *const fn (args: []Value, gc: *@import("gc.zig").GC, env: *@import("env.zig").Env) anyerror!Value,
        name: []const u8,
    },
    lazy_seq: struct {
        thunk: Value, // fn to call (zero-arg) to produce [first rest-thunk] or nil
        cached: ?Value = null, // memoized result once realized
    },
    partial_fn: struct {
        func: Value, // the original function
        bound_args: std.ArrayListUnmanaged(Value), // pre-bound arguments
    },
    multimethod: MultimethodData,
    protocol: ProtocolData,
};

pub const MultimethodData = struct {
    name: []const u8,
    dispatch_fn: Value, // fn to call on args to get dispatch value
    methods: std.ArrayListUnmanaged(MethodEntry), // dispatch-val → impl fn
    default_method: ?Value = null, // :default handler
};

pub const MethodEntry = struct {
    dispatch_val: Value,
    impl_fn: Value,
};

pub const ProtocolData = struct {
    name: []const u8,
    method_names: std.ArrayListUnmanaged([]const u8), // declared method names
    // type_name → method_name → impl fn
    impls: std.ArrayListUnmanaged(TypeImpl),
};

pub const TypeImpl = struct {
    type_name: []const u8, // e.g. "vector", "map", "list", "string", "number"
    methods: std.ArrayListUnmanaged(NamedMethod),
};

pub const NamedMethod = struct {
    name: []const u8,
    func: Value,
};

pub const FnData = struct {
    params: std.ArrayListUnmanaged(Value), // symbols
    body: std.ArrayListUnmanaged(Value),
    env: ?*@import("env.zig").Env,
    is_variadic: bool = false,
    name: ?[]const u8 = null,
};

const QNAN: u64 = 0x7FF8_0000_0000_0000;
const TAG_SHIFT: u6 = 48;
const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;

pub const Value = packed struct {
    bits: u64,

    pub fn makeFloat(f: f64) Value {
        return .{ .bits = @bitCast(f) };
    }

    pub fn makeNil() Value {
        return fromTagPayload(.nil, 0);
    }

    pub fn makeBool(b: bool) Value {
        return fromTagPayload(.boolean, @intFromBool(b));
    }

    pub fn makeInt(i: i48) Value {
        return fromTagPayload(.integer, @bitCast(@as(u48, @bitCast(i))));
    }

    pub fn makeSymbol(id: u48) Value {
        return fromTagPayload(.symbol, id);
    }

    pub fn makeKeyword(id: u48) Value {
        return fromTagPayload(.keyword, id);
    }

    pub fn makeString(id: u48) Value {
        return fromTagPayload(.string, id);
    }

    pub fn makeObj(ptr: *Obj) Value {
        return fromTagPayload(.object, @truncate(@intFromPtr(ptr)));
    }

    fn fromTagPayload(tag: Tag, payload: u48) Value {
        const t: u64 = @intFromEnum(tag);
        return .{ .bits = QNAN | (t << TAG_SHIFT) | @as(u64, payload) };
    }

    pub fn isFloat(self: Value) bool {
        return (self.bits & QNAN) != QNAN or self.bits == @as(u64, @bitCast(@as(f64, std.math.nan(f64))));
    }

    fn isTagged(self: Value) bool {
        return (self.bits & QNAN) == QNAN;
    }

    fn getTag(self: Value) Tag {
        if (!self.isTagged()) return .nil; // shouldn't be called
        const t: u3 = @truncate((self.bits >> TAG_SHIFT) & 0x7);
        return @enumFromInt(t);
    }

    fn getPayload(self: Value) u48 {
        return @truncate(self.bits & PAYLOAD_MASK);
    }

    /// Branchless tag check: compare upper 16 bits against expected pattern.
    /// QNAN | (tag << 48) occupies bits 63..48. Masking and comparing in one op.
    inline fn isTag(self: Value, comptime tag: Tag) bool {
        const expected: u64 = QNAN | (@as(u64, @intFromEnum(tag)) << TAG_SHIFT);
        return (self.bits & (QNAN | (@as(u64, 0x7) << TAG_SHIFT))) == expected;
    }

    pub fn isNil(self: Value) bool { return self.isTag(.nil); }
    pub fn isBool(self: Value) bool { return self.isTag(.boolean); }
    pub fn isInt(self: Value) bool { return self.isTag(.integer); }
    pub fn isSymbol(self: Value) bool { return self.isTag(.symbol); }
    pub fn isKeyword(self: Value) bool { return self.isTag(.keyword); }
    pub fn isString(self: Value) bool { return self.isTag(.string); }
    pub fn isObj(self: Value) bool { return self.isTag(.object); }

    pub fn asBool(self: Value) bool {
        return self.getPayload() != 0;
    }

    pub fn asInt(self: Value) i48 {
        return @bitCast(self.getPayload());
    }

    pub fn asFloat(self: Value) f64 {
        return @bitCast(self.bits);
    }

    pub fn asSymbolId(self: Value) u48 {
        return self.getPayload();
    }

    pub fn asKeywordId(self: Value) u48 {
        return self.getPayload();
    }

    pub fn asStringId(self: Value) u48 {
        return self.getPayload();
    }

    pub fn asObj(self: Value) *Obj {
        return @ptrFromInt(@as(usize, self.getPayload()));
    }

    /// Truthiness: nil and false are falsy, everything else truthy
    pub inline fn isTruthy(self: Value) bool {
        // Fast: nil is false, (bool, payload=0) is false, everything else is true
        if (self.isNil()) return false;
        if (self.isBool()) return self.getPayload() != 0;
        return true;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.bits == b.bits;
    }
};

test "nan boxing round trips" {
    const nil = Value.makeNil();
    try std.testing.expect(nil.isNil());

    const t = Value.makeBool(true);
    try std.testing.expect(t.isBool());
    try std.testing.expect(t.asBool());

    const i = Value.makeInt(42);
    try std.testing.expect(i.isInt());
    try std.testing.expectEqual(@as(i48, 42), i.asInt());

    const neg = Value.makeInt(-7);
    try std.testing.expectEqual(@as(i48, -7), neg.asInt());

    const f = Value.makeFloat(3.14);
    try std.testing.expect(!f.isNil());
    try std.testing.expect(!f.isInt());
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), f.asFloat(), 0.001);
}
