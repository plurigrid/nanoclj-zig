//! flow_value.zig — Clojure ↔ flow.zig value-ABI bridge.
//!
//! Closes the `−1 · capability` interleave slot: a flowmaps `:components`
//! entry `(fn [x] …)` arrives as a nanoclj `Value` and gets wrapped in a
//! `ComputeCtx` whose `call` converts `[]const V → []const Value`, dispatches
//! through `eval.apply`, then unboxes the result.
//!
//! Corresponds to the Sweedler-dual slot in Libkind-Spivak's Φ_{p,q}: the
//! comonad side (c_q) that the free-monad pump (m_p) consults.

const std = @import("std");
const flow = @import("flow.zig");
const value = @import("value.zig");
const eval = @import("eval.zig");

const Value = value.Value;
const Env = @import("env.zig").Env;
const GC = @import("gc.zig").GC;

/// Context carried by a flow `ComputeCtx`. Generic over the flow value type V
/// via two explicit coercion function pointers, so the same bridge works for
/// i64, f64, or any user-defined V with a Value encoding.
pub fn ClojureCompute(comptime V: type) type {
    return struct {
        func: Value,
        env: *Env,
        gc: *GC,
        from_v: *const fn (V) Value,
        to_v: *const fn (Value) V,
        arg_buf: [MAX_ARGS]Value = undefined,

        pub const MAX_ARGS: usize = 8;
        const Self = @This();

        /// Erase to `flow.Block(V).ComputeCtx` for flow integration.
        pub fn asComputeCtx(self: *Self) flow.Block(V).ComputeCtx {
            return .{ .ctx = self, .call = &Self.callErased };
        }

        fn callErased(ctx: *anyopaque, inputs: []const V) V {
            const self: *Self = @ptrCast(@alignCast(ctx));
            std.debug.assert(inputs.len <= MAX_ARGS);
            for (inputs, 0..) |v, i| self.arg_buf[i] = self.from_v(v);
            const result = eval.apply(self.func, self.arg_buf[0..inputs.len], self.env, self.gc) catch {
                return self.to_v(Value.makeNil());
            };
            return self.to_v(result);
        }
    };
}

// -------------------- stock coercions --------------------

pub fn i64FromValue(v: Value) i64 {
    if (v.isInt()) return @intCast(v.asInt());
    if (v.asNumber()) |f| return @intFromFloat(f);
    return 0;
}

pub fn i64ToValue(x: i64) Value {
    return Value.makeInt(@intCast(x));
}

pub fn f64FromValue(v: Value) f64 {
    return v.asNumber() orelse 0.0;
}

pub fn f64ToValue(x: f64) Value {
    return Value.makeFloat(x);
}

// ============================================================================
// Bidirectional teleportation tests — every interleave crossing roundtrips.
// ============================================================================

test "teleport i64: V → Value → V is identity (positive, negative, zero)" {
    for ([_]i64{ 0, 1, -1, 42, -7, 1_000_000, -1_000_000 }) |x| {
        const v = i64ToValue(x);
        try std.testing.expectEqual(x, i64FromValue(v));
    }
}

test "teleport f64: V → Value → V preserves bits through NaN-boxing" {
    for ([_]f64{ 0.0, 1.5, -2.25, 3.14159, -1000.0 }) |x| {
        const v = f64ToValue(x);
        try std.testing.expectEqual(x, f64FromValue(v));
    }
}

test "teleport Value (int): Value → i64 → Value preserves .eql" {
    const v0 = Value.makeInt(137);
    const x = i64FromValue(v0);
    const v1 = i64ToValue(x);
    try std.testing.expect(Value.eql(v0, v1));
}

test "teleport Value (float): Value → f64 → Value preserves .eql" {
    const v0 = Value.makeFloat(2.71828);
    const x = f64FromValue(v0);
    const v1 = f64ToValue(x);
    try std.testing.expect(Value.eql(v0, v1));
}

test "teleport cross-type: int Value → f64 → int Value (coerces via asNumber)" {
    const v0 = Value.makeInt(100);
    const as_f = f64FromValue(v0); // 100.0
    const v1 = f64ToValue(as_f); // float Value
    try std.testing.expectEqual(@as(f64, 100.0), v1.asNumber().?);
}

test "teleport live: (fn* [x] x) identity — read, eval, dispatch, unbox" {
    const GCMod = @import("gc.zig").GC;
    const EnvMod = @import("env.zig").Env;
    const Reader = @import("reader.zig").Reader;

    var gc = GCMod.init(std.testing.allocator);
    defer gc.deinit();
    var env = EnvMod.init(std.testing.allocator, null);
    env.is_root = true;
    defer env.deinit();

    var r = Reader.init("(fn* [x] x)", &gc);
    const form = try r.readForm();
    const func = try eval.eval(form, &env, &gc);

    var bridge = ClojureCompute(i64){
        .func = func,
        .env = &env,
        .gc = &gc,
        .from_v = &i64ToValue,
        .to_v = &i64FromValue,
    };
    const cc = bridge.asComputeCtx();
    // Roundtrip several values through the identity bridge.
    for ([_]i64{ 0, 7, -42, 1000 }) |x| {
        try std.testing.expectEqual(x, cc.call(cc.ctx, &[_]i64{x}));
    }
}

test "teleport live: flow pump drives a Clojure identity ctx end-to-end" {
    const GCMod = @import("gc.zig").GC;
    const EnvMod = @import("env.zig").Env;
    const Reader = @import("reader.zig").Reader;

    var gc = GCMod.init(std.testing.allocator);
    defer gc.deinit();
    var env = EnvMod.init(std.testing.allocator, null);
    env.is_root = true;
    defer env.deinit();

    var r = Reader.init("(fn* [x] x)", &gc);
    const form = try r.readForm();
    const func = try eval.eval(form, &env, &gc);

    var bridge = ClojureCompute(i64){
        .func = func,
        .env = &env,
        .gc = &gc,
        .from_v = &i64ToValue,
        .to_v = &i64FromValue,
    };
    const cc = bridge.asComputeCtx();

    const spec = flow.FlowSpec(i64){
        .blocks = &.{
            .{ .id = "s", .body = .{ .seed = 42 } },
            .{ .id = "b", .body = .{ .compute_ctx = cc } },
            .{ .id = "k", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "s", .dst = "b" },
            .{ .src = "b", .dst = "k" },
        },
        .exit = "k",
    };
    const exit = try flow.Flow(i64).inhabit(std.testing.allocator, spec);
    // seed 42 → identity bridge → sink = 42, roundtrip through eval.apply.
    try std.testing.expectEqual(@as(?i64, 42), exit.value);
}

test "ClojureCompute(i64): asComputeCtx yields a usable flow ComputeCtx" {
    var stub: ClojureCompute(i64) = undefined;
    stub.func = Value.makeInt(0);
    stub.env = undefined;
    stub.gc = undefined;
    stub.from_v = &i64ToValue;
    stub.to_v = &i64FromValue;
    const cc = stub.asComputeCtx();
    try std.testing.expect(cc.ctx == @as(*anyopaque, @ptrCast(&stub)));
    try std.testing.expect(cc.call == &ClojureCompute(i64).callErased);
}

test "ClojureCompute(f64): generic variant compiles" {
    var stub: ClojureCompute(f64) = undefined;
    stub.func = Value.makeFloat(0.0);
    stub.env = undefined;
    stub.gc = undefined;
    stub.from_v = &f64ToValue;
    stub.to_v = &f64FromValue;
    const cc = stub.asComputeCtx();
    try std.testing.expect(cc.ctx == @as(*anyopaque, @ptrCast(&stub)));
}
