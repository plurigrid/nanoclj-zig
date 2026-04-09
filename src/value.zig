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
    dense_f64, // Neanderthal-compatible: contiguous f64 buffer + stride
    trace, // Anglican-compatible: weighted execution trace (sample sites + log-weight)
    rational, // exact rational number: numerator/denominator (always GCD-normalized, denominator > 0)
    color, // first-class OKLAB color value (L, a, b, alpha as 4×f32)
    channel, // CSP channel (core.async-style buffered/unbuffered)
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
        func: *const fn (args: []Value, gc: *@import("gc.zig").GC, env: *@import("env.zig").Env, res: *@import("transitivity.zig").Resources) anyerror!Value,
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
    dense_f64: DenseF64,
    trace: TraceData,
    rational: Rational,
    color: @import("colorspace.zig").Color,
    channel: @import("channel.zig").ChannelData,
};

/// Neanderthal-compatible dense f64 vector.
/// Zero-copy bridge: raw []f64 buffer, stride for BLAS compatibility.
/// (fv 1.0 2.0 3.0) creates one; (neanderthal-buf v) extracts the slice.
pub const DenseF64 = struct {
    data: []f64,
    len: usize,
    stride: usize = 1,
    owned: bool = true, // false = view into another buffer

    pub fn get(self: *const DenseF64, i: usize) f64 {
        return self.data[i * self.stride];
    }

    pub fn set(self: *DenseF64, i: usize, v: f64) void {
        self.data[i * self.stride] = v;
    }

    pub fn dot(self: *const DenseF64, other: *const DenseF64) f64 {
        var sum: f64 = 0;
        const n = @min(self.len, other.len);
        for (0..n) |i| {
            sum += self.get(i) * other.get(i);
        }
        return sum;
    }

    pub fn norm(self: *const DenseF64) f64 {
        var sum: f64 = 0;
        for (0..self.len) |i| {
            const v = self.get(i);
            sum += v * v;
        }
        return @sqrt(sum);
    }

    pub fn axpy(self: *DenseF64, alpha: f64, other: *const DenseF64) void {
        const n = @min(self.len, other.len);
        for (0..n) |i| {
            self.data[i * self.stride] += alpha * other.get(i);
        }
    }
};

/// Anglican-compatible weighted execution trace.
/// A trace = sequence of sample sites + cumulative log-weight.
/// Each site = {name, value, log_prob} stored as parallel arrays.
/// Isomorphic to monad-bayes TracedT(WtT(m)).
pub const TraceData = struct {
    site_names: std.ArrayListUnmanaged(u32), // interned string IDs
    site_values: std.ArrayListUnmanaged(Value),
    site_log_probs: std.ArrayListUnmanaged(f64),
    log_weight: f64 = 0,
    /// Number of sample sites
    pub fn len(self: *const TraceData) usize {
        return self.site_names.items.len;
    }
    /// Accumulate a sample site
    pub fn observe(self: *TraceData, allocator: std.mem.Allocator, name_id: u32, val: Value, log_prob: f64) !void {
        try self.site_names.append(allocator, name_id);
        try self.site_values.append(allocator, val);
        try self.site_log_probs.append(allocator, log_prob);
        self.log_weight += log_prob;
    }
};

/// GCD helper for rational normalization (Euclidean algorithm on absolute values).
fn gcd(a_raw: i64, b_raw: i64) u64 {
    var a: u64 = if (a_raw < 0) @intCast(-a_raw) else @intCast(a_raw);
    var b: u64 = if (b_raw < 0) @intCast(-b_raw) else @intCast(b_raw);
    while (b != 0) {
        const t = b;
        b = a % b;
        a = t;
    }
    return if (a == 0) 1 else a;
}

/// Exact rational number: numerator / denominator.
/// Invariants: denominator > 0, gcd(|numerator|, denominator) == 1.
pub const Rational = struct {
    numerator: i64,
    denominator: i64,

    /// Create a normalized rational. Denominator is always positive and
    /// the fraction is reduced to lowest terms.
    pub fn init(num: i64, den: i64) Rational {
        if (den == 0) return .{ .numerator = 0, .denominator = 1 }; // fallback
        var n = num;
        var d = den;
        if (d < 0) { n = -n; d = -d; } // ensure denominator > 0
        const g: i64 = @intCast(gcd(n, d));
        return .{ .numerator = @divTrunc(n, g), .denominator = @divTrunc(d, g) };
    }

    pub fn isInteger(self: *const Rational) bool {
        return self.denominator == 1;
    }

    pub fn toFloat(self: *const Rational) f64 {
        return @as(f64, @floatFromInt(self.numerator)) / @as(f64, @floatFromInt(self.denominator));
    }
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

    /// Coerce to f64: works for int, float, rational. Returns null for non-numeric.
    pub fn asNumber(self: Value) ?f64 {
        if (self.isFloat()) return self.asFloat();
        if (self.isInt()) return @floatFromInt(self.asInt());
        if (self.isObj()) {
            const obj = self.asObj();
            if (obj.kind == .rational) return obj.data.rational.toFloat();
        }
        return null;
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
