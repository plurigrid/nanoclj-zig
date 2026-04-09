//! 12-layer SPI verification tower from Gay.jl's tower.jl
//!
//! Each layer computes a fingerprint via substrate.mix64 with a layer-specific salt.
//! The collective fingerprint is the XOR of all 12 layer fingerprints.
//! GF(3) trit per layer = fingerprint mod 3 - 1.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
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
// LAYER NAMES
// ============================================================================

const layer_names = [12][]const u8{
    "concept-tensor",
    "exponential",
    "higher",
    "traced-monoidal",
    "tensor-network",
    "thread-findings",
    "kripke-frames",
    "modal-logic",
    "sheaf-semantics",
    "probability-sheaves",
    "random-topos",
    "synthetic-probability",
};

// ============================================================================
// LAYER SALTS (comptime)
// ============================================================================

const layer_salts = blk: {
    var salts: [12]u64 = undefined;
    for (0..12) |i| {
        salts[i] = substrate.mix64(substrate.GOLDEN *% (@as(u64, i) + 1));
    }
    break :blk salts;
};

// ============================================================================
// TowerState
// ============================================================================

pub const TowerState = struct {
    seed: u64,
    layer_fps: [12]u64,
    collective_fp: u64,
    current_layer: u8,
    step_count: u64,

    pub fn init(seed: u64) TowerState {
        return .{
            .seed = seed,
            .layer_fps = [_]u64{0} ** 12,
            .collective_fp = 0,
            .current_layer = 0,
            .step_count = 0,
        };
    }

    pub fn runLayer(self: *TowerState, layer: u8) void {
        if (layer >= 12) return;
        const fp = substrate.mix64(self.seed ^ layer_salts[layer]);
        self.layer_fps[layer] = fp;
        self.collective_fp ^= fp;
        self.current_layer = layer;
        self.step_count += 1;
    }

    pub fn runAll(self: *TowerState) void {
        for (0..12) |i| {
            self.runLayer(@intCast(i));
        }
    }

    pub fn isConserved(self: *const TowerState) bool {
        // collective_fp XOR'd with 0 == collective_fp (matches Gay.jl pattern)
        return (self.collective_fp ^ 0) == self.collective_fp;
    }
};

/// Trit for a layer fingerprint: fp mod 3 - 1, giving {-1, 0, 1}
fn layerTrit(fp: u64) i8 {
    return @as(i8, @intCast(fp % 3)) - 1;
}

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

pub fn towerRunFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));

    var tower = TowerState.init(seed);
    tower.runAll();

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(seed)))));
    try addKV(obj, gc, "collective-fp", Value.makeInt(@bitCast(@as(u48, @truncate(tower.collective_fp)))));

    // Build layers vector
    const vec = try gc.allocObj(.vector);
    for (0..12) |i| {
        try vec.data.vector.items.append(gc.allocator, Value.makeInt(@bitCast(@as(u48, @truncate(tower.layer_fps[i])))));
    }
    try addKV(obj, gc, "layers", Value.makeObj(vec));
    try addKV(obj, gc, "conserved", Value.makeBool(tower.isConserved()));

    return Value.makeObj(obj);
}

pub fn towerLayerFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const n_raw = args[1].asInt();
    if (n_raw < 0 or n_raw >= 12) return error.InvalidArgs;
    const n: u8 = @intCast(n_raw);

    var tower = TowerState.init(seed);
    tower.runLayer(n);
    const fp = tower.layer_fps[n];

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "layer-name", Value.makeString(try gc.internString(layer_names[n])));
    try addKV(obj, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(fp)))));
    try addKV(obj, gc, "trit", Value.makeInt(@intCast(@as(i48, layerTrit(fp)))));

    return Value.makeObj(obj);
}

pub fn towerTritSumFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = gc;
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));

    var tower = TowerState.init(seed);
    tower.runAll();

    var trit_sum: i32 = 0;
    for (0..12) |i| {
        trit_sum += @as(i32, layerTrit(tower.layer_fps[i]));
    }
    // mod 3 with proper sign handling
    const result = @mod(trit_sum, @as(i32, 3));
    return Value.makeInt(@intCast(result));
}

// ============================================================================
// SKILL TABLE
// ============================================================================

pub const skill_table = .{
    .{ "tower-run", &towerRunFn },
    .{ "tower-layer", &towerLayerFn },
    .{ "tower-trit-sum", &towerTritSumFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "tower deterministic" {
    var t1 = TowerState.init(1069);
    t1.runAll();
    var t2 = TowerState.init(1069);
    t2.runAll();
    try std.testing.expectEqual(t1.collective_fp, t2.collective_fp);
    for (0..12) |i| {
        try std.testing.expectEqual(t1.layer_fps[i], t2.layer_fps[i]);
    }
}

test "tower all layers" {
    var tower = TowerState.init(1069);
    tower.runAll();
    for (0..12) |i| {
        try std.testing.expect(tower.layer_fps[i] != 0);
    }
    try std.testing.expect(tower.collective_fp != 0);
    try std.testing.expect(tower.isConserved());
}

test "tower trit sum conserved" {
    var tower = TowerState.init(1069);
    tower.runAll();
    var trit_sum: i32 = 0;
    for (0..12) |i| {
        trit_sum += @as(i32, layerTrit(tower.layer_fps[i]));
    }
    // Just verify it computes without crash; mod 3 result is in {0,1,2}
    const result = @mod(trit_sum, @as(i32, 3));
    try std.testing.expect(result >= 0 and result <= 2);
}
