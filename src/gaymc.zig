//! Gay Monte Carlo — colored MC module matching Gay.jl's gaymc.jl
//!
//! SplitMix64-colored Metropolis, replica exchange, temperature ladders.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const substrate = @import("substrate.zig");

// ============================================================================
// HELPERS
// ============================================================================

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

// ============================================================================
// MCContext
// ============================================================================

pub const MCContext = struct {
    seed: u64,
    sweep_count: u64,
    measure_count: u64,
    worker_id: u64,

    pub fn init(seed: u64, worker_id: u64) MCContext {
        return .{
            .seed = seed,
            .sweep_count = 0,
            .measure_count = 0,
            .worker_id = worker_id,
        };
    }

    pub fn sweep(self: *MCContext) struct { val: u64, color: substrate.Color } {
        const r = substrate.splitmix_next(self.seed);
        self.seed = r.next;
        self.sweep_count += 1;
        const c = substrate.Color{
            .r = @truncate(r.val >> 16),
            .g = @truncate(r.val >> 8),
            .b = @truncate(r.val),
        };
        return .{ .val = r.val, .color = c };
    }

    pub fn measure(self: *MCContext) struct { val: u64, color: substrate.Color } {
        const r = substrate.splitmix_next(self.seed);
        self.seed = r.next;
        self.measure_count += 1;
        const c = substrate.Color{
            .r = @truncate(r.val >> 16),
            .g = @truncate(r.val >> 8),
            .b = @truncate(r.val),
        };
        return .{ .val = r.val, .color = c };
    }
};

// ============================================================================
// Replica
// ============================================================================

pub const Replica = struct {
    ctx: MCContext,
    energy: f64,
    beta: f64,
    index: u8,
    swap_attempts: u32,
    swap_accepts: u32,

    pub fn init(seed: u64, beta: f64, index: u8) Replica {
        return .{
            .ctx = MCContext.init(seed, @as(u64, index)),
            .energy = 0.0,
            .beta = beta,
            .index = index,
            .swap_attempts = 0,
            .swap_accepts = 0,
        };
    }
};

// ============================================================================
// TemperatureLadder
// ============================================================================

pub const TemperatureLadder = struct {
    betas: [16]f64,
    count: u8,

    pub fn geometric(t_min: f64, t_max: f64, n: u8) TemperatureLadder {
        const count = if (n > 16) 16 else if (n == 0) 1 else n;
        var ladder = TemperatureLadder{ .betas = [_]f64{0} ** 16, .count = count };
        if (count == 1) {
            ladder.betas[0] = 1.0 / t_min;
            return ladder;
        }
        const ratio = std.math.pow(f64, t_max / t_min, 1.0 / @as(f64, @floatFromInt(count - 1)));
        for (0..count) |i| {
            const t = t_min * std.math.pow(f64, ratio, @as(f64, @floatFromInt(i)));
            ladder.betas[i] = 1.0 / t;
        }
        return ladder;
    }

    pub fn linear(t_min: f64, t_max: f64, n: u8) TemperatureLadder {
        const count = if (n > 16) 16 else if (n == 0) 1 else n;
        var ladder = TemperatureLadder{ .betas = [_]f64{0} ** 16, .count = count };
        if (count == 1) {
            ladder.betas[0] = 1.0 / t_min;
            return ladder;
        }
        const step = (t_max - t_min) / @as(f64, @floatFromInt(count - 1));
        for (0..count) |i| {
            const t = t_min + step * @as(f64, @floatFromInt(i));
            ladder.betas[i] = 1.0 / t;
        }
        return ladder;
    }
};

// ============================================================================
// Metropolis criterion
// ============================================================================

pub fn metropolis(delta_e: f64, beta: f64, rng_val: u64) bool {
    if (delta_e <= 0.0) return true;
    const u: f64 = @as(f64, @floatFromInt(rng_val)) / @as(f64, @floatFromInt(std.math.maxInt(u64)));
    const prob = std.math.exp(-beta * delta_e);
    return u < prob;
}

// ============================================================================
// Replica exchange
// ============================================================================

pub fn attemptSwap(r1: *Replica, r2: *Replica, rng_val: u64) bool {
    r1.swap_attempts += 1;
    r2.swap_attempts += 1;
    const delta_beta = r2.beta - r1.beta;
    const delta_energy = r2.energy - r1.energy;
    const accept = metropolis(-delta_beta * delta_energy, 1.0, rng_val);
    if (accept) {
        r1.swap_accepts += 1;
        r2.swap_accepts += 1;
        const tmp_beta = r1.beta;
        r1.beta = r2.beta;
        r2.beta = tmp_beta;
    }
    return accept;
}

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

pub fn mcContextFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or args.len > 2 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const worker_id: u64 = if (args.len == 2 and args[1].isInt())
        @bitCast(@as(i64, args[1].asInt()))
    else
        0;
    const ctx = MCContext.init(seed, worker_id);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(ctx.seed)))));
    try addKV(obj, gc, "worker-id", Value.makeInt(@bitCast(@as(u48, @truncate(ctx.worker_id)))));
    try addKV(obj, gc, "sweep-count", Value.makeInt(0));
    try addKV(obj, gc, "measure-count", Value.makeInt(0));
    return Value.makeObj(obj);
}

pub fn mcSweepFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    var ctx = MCContext.init(seed, 0);
    const result = ctx.sweep();
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(ctx.seed)))));
    try addKV(obj, gc, "sweep", Value.makeInt(@bitCast(@as(u48, @truncate(result.val)))));
    try addKV(obj, gc, "color", Value.makeInt(@bitCast(@as(u48, @truncate(@as(u64, result.color.r) << 16 | @as(u64, result.color.g) << 8 | @as(u64, result.color.b))))));
    return Value.makeObj(obj);
}

pub fn mcMetropolisFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = gc;
    if (args.len != 3) return error.ArityError;
    const delta_e: f64 = if (args[0].isFloat()) args[0].asFloat() else if (args[0].isInt()) @as(f64, @floatFromInt(args[0].asInt())) else return error.TypeError;
    const beta_v: f64 = if (args[1].isFloat()) args[1].asFloat() else if (args[1].isInt()) @as(f64, @floatFromInt(args[1].asInt())) else return error.TypeError;
    const rng: u64 = if (args[2].isInt()) @bitCast(@as(i64, args[2].asInt())) else return error.TypeError;
    return Value.makeBool(metropolis(delta_e, beta_v, rng));
}

pub fn mcLadderFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const t_min: f64 = if (args[0].isFloat()) args[0].asFloat() else if (args[0].isInt()) @as(f64, @floatFromInt(args[0].asInt())) else return error.TypeError;
    const t_max: f64 = if (args[1].isFloat()) args[1].asFloat() else if (args[1].isInt()) @as(f64, @floatFromInt(args[1].asInt())) else return error.TypeError;
    const n: u8 = if (args[2].isInt()) @truncate(@as(u64, @bitCast(@as(i64, args[2].asInt())))) else return error.TypeError;
    const ladder = TemperatureLadder.geometric(t_min, t_max, n);
    const vec = try gc.allocObj(.vector);
    for (0..ladder.count) |i| {
        try vec.data.vector.items.append(gc.allocator, Value.makeFloat(ladder.betas[i]));
    }
    return Value.makeObj(vec);
}

pub fn mcReplicaFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const seed: u64 = if (args[0].isInt()) @bitCast(@as(i64, args[0].asInt())) else return error.TypeError;
    const beta_v: f64 = if (args[1].isFloat()) args[1].asFloat() else if (args[1].isInt()) @as(f64, @floatFromInt(args[1].asInt())) else return error.TypeError;
    const index: u8 = if (args[2].isInt()) @truncate(@as(u64, @bitCast(@as(i64, args[2].asInt())))) else return error.TypeError;
    const replica = Replica.init(seed, beta_v, index);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(replica.ctx.seed)))));
    try addKV(obj, gc, "beta", Value.makeFloat(replica.beta));
    try addKV(obj, gc, "index", Value.makeInt(@as(i48, index)));
    try addKV(obj, gc, "energy", Value.makeFloat(replica.energy));
    try addKV(obj, gc, "swap-attempts", Value.makeInt(0));
    try addKV(obj, gc, "swap-accepts", Value.makeInt(0));
    return Value.makeObj(obj);
}

// ============================================================================
// SKILL TABLE
// ============================================================================

pub const skill_table = .{
    .{ "mc-context", &mcContextFn },
    .{ "mc-sweep", &mcSweepFn },
    .{ "mc-metropolis", &mcMetropolisFn },
    .{ "mc-ladder", &mcLadderFn },
    .{ "mc-replica", &mcReplicaFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "mc context init" {
    const ctx = MCContext.init(1069, 7);
    try std.testing.expectEqual(@as(u64, 1069), ctx.seed);
    try std.testing.expectEqual(@as(u64, 7), ctx.worker_id);
    try std.testing.expectEqual(@as(u64, 0), ctx.sweep_count);
    try std.testing.expectEqual(@as(u64, 0), ctx.measure_count);
}

test "mc sweep advances" {
    var ctx = MCContext.init(1069, 0);
    _ = ctx.sweep();
    try std.testing.expectEqual(@as(u64, 1), ctx.sweep_count);
    _ = ctx.sweep();
    try std.testing.expectEqual(@as(u64, 2), ctx.sweep_count);
    try std.testing.expect(ctx.seed != 1069);
}

test "metropolis always accepts negative" {
    try std.testing.expect(metropolis(-1.0, 1.0, 0));
    try std.testing.expect(metropolis(-1.0, 1.0, std.math.maxInt(u64)));
    try std.testing.expect(metropolis(-100.0, 100.0, 12345));
}

test "metropolis rejects large positive" {
    const result = metropolis(1000.0, 100.0, std.math.maxInt(u64));
    try std.testing.expect(!result);
}

test "temperature ladder geometric" {
    const ladder = TemperatureLadder.geometric(0.1, 10.0, 4);
    try std.testing.expectEqual(@as(u8, 4), ladder.count);
    // betas = 1/T, so as T increases, beta decreases → betas monotonically decreasing
    // i.e. betas[0] > betas[1] > betas[2] > betas[3]
    try std.testing.expect(ladder.betas[0] > ladder.betas[1]);
    try std.testing.expect(ladder.betas[1] > ladder.betas[2]);
    try std.testing.expect(ladder.betas[2] > ladder.betas[3]);
    // Check endpoints: beta[0] = 1/t_min = 10, beta[3] = 1/t_max = 0.1
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), ladder.betas[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), ladder.betas[3], 1e-10);
}
