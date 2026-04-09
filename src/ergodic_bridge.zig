//! Ergodic Bridge for nanoclj-zig — matching Gay.jl's ergodic_bridge.jl
//!
//! Measures ergodic properties of SplitMix64 color sequences:
//! wall-clock bridge (XOR fingerprint + Shannon entropy),
//! per-channel color bandwidth, ergodic mixing time, obstruction detection.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const substrate = @import("substrate.zig");
const gay_skills = @import("gay_skills.zig");

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

const MAX_COUNT: u64 = 100_000;

fn clampCount(count: u64) u64 {
    return if (count > MAX_COUNT) MAX_COUNT else if (count == 0) 1 else count;
}

fn extractSeedCount(args: []Value) !struct { seed: u64, count: u64 } {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    return .{
        .seed = @bitCast(@as(i64, args[0].asInt())),
        .count = clampCount(@bitCast(@as(i64, args[1].asInt()))),
    };
}

// ============================================================================
// WallClockBridge
// ============================================================================

pub const WallClockBridge = struct {
    seed: u64,
    color_count: u64,
    fingerprint: u64,
    entropy: f64,
    order_independent: bool,

    pub fn create(seed: u64, count: u64) WallClockBridge {
        const n = clampCount(count);
        var fingerprint: u64 = 0;
        var r_hist = [_]u32{0} ** 256;
        var g_hist = [_]u32{0} ** 256;
        var b_hist = [_]u32{0} ** 256;

        for (0..n) |i| {
            const c = substrate.colorAt(seed, @as(u64, i));
            // XOR-fold: order-independent fingerprint
            fingerprint ^= substrate.mix64(@as(u64, c.r) << 16 | @as(u64, c.g) << 8 | @as(u64, c.b));
            r_hist[c.r] += 1;
            g_hist[c.g] += 1;
            b_hist[c.b] += 1;
        }

        // Shannon entropy over combined RGB histogram (768 bins)
        const total: f64 = @floatFromInt(n * 3);
        var entropy: f64 = 0;
        inline for (.{ &r_hist, &g_hist, &b_hist }) |hist| {
            for (hist) |bin| {
                if (bin > 0) {
                    const p: f64 = @as(f64, @floatFromInt(bin)) / total;
                    entropy -= p * @log(p) / @log(2.0);
                }
            }
        }

        return .{
            .seed = seed,
            .color_count = n,
            .fingerprint = fingerprint,
            .entropy = entropy,
            .order_independent = true,
        };
    }

    pub fn verify(self: *const WallClockBridge) bool {
        const recomputed = create(self.seed, self.color_count);
        return recomputed.fingerprint == self.fingerprint;
    }
};

// ============================================================================
// ColorBandwidth
// ============================================================================

pub const ColorBandwidth = struct {
    r_entropy: f64,
    g_entropy: f64,
    b_entropy: f64,
    total_entropy: f64,
    gamut_coverage: f64,

    fn channelEntropy(hist: *const [256]u32, n: u64) f64 {
        const total: f64 = @floatFromInt(n);
        var ent: f64 = 0;
        for (hist) |bin| {
            if (bin > 0) {
                const p: f64 = @as(f64, @floatFromInt(bin)) / total;
                ent -= p * @log(p) / @log(2.0);
            }
        }
        return ent / 8.0; // normalize by log2(256)=8
    }

    pub fn measure(seed: u64, count: u64) ColorBandwidth {
        const n = clampCount(count);
        var r_hist = [_]u32{0} ** 256;
        var g_hist = [_]u32{0} ** 256;
        var b_hist = [_]u32{0} ** 256;

        // Track unique colors via a simple hash set approach:
        // use XOR fingerprint accumulation for unique count approximation
        var unique_count: u64 = 0;
        // Use a bit array for tracking (limited but fast)
        // For exact count, hash (r,g,b) and count collisions
        // Approximate: count unique 16-bit hashes
        var seen = [_]u8{0} ** 8192; // 65536 bits

        for (0..n) |i| {
            const c = substrate.colorAt(seed, @as(u64, i));
            r_hist[c.r] += 1;
            g_hist[c.g] += 1;
            b_hist[c.b] += 1;
            // hash to 16 bits for uniqueness tracking
            const h: u16 = @truncate(substrate.mix64(@as(u64, c.r) << 16 | @as(u64, c.g) << 8 | @as(u64, c.b)));
            const byte_idx = h >> 3;
            const bit_idx: u3 = @truncate(h);
            const mask: u8 = @as(u8, 1) << bit_idx;
            if (seen[byte_idx] & mask == 0) {
                seen[byte_idx] |= mask;
                unique_count += 1;
            }
        }

        const re = channelEntropy(&r_hist, n);
        const ge = channelEntropy(&g_hist, n);
        const be = channelEntropy(&b_hist, n);

        return .{
            .r_entropy = re,
            .g_entropy = ge,
            .b_entropy = be,
            .total_entropy = (re + ge + be) / 3.0,
            .gamut_coverage = @as(f64, @floatFromInt(unique_count)) / @as(f64, @floatFromInt(n)),
        };
    }
};

// ============================================================================
// ErgodicMeasure
// ============================================================================

pub const ErgodicMeasure = struct {
    mixing_time: u64,
    visited_fraction: f64,
    ergodicity_score: f64,
    is_ergodic: bool,

    pub fn measure(seed: u64, count: u64) ErgodicMeasure {
        const n = clampCount(count);
        var hue_bins = [_]bool{false} ** 360;
        var bins_hit: u64 = 0;
        var mixing_time: u64 = n; // default: never reached
        const threshold: u64 = 324; // 90% of 360

        for (0..n) |i| {
            const c = substrate.colorAt(seed, @as(u64, i));
            const hue = gay_skills.rgbToHue(c.r, c.g, c.b);
            const bin: usize = @min(359, @as(usize, @intFromFloat(hue)));
            if (!hue_bins[bin]) {
                hue_bins[bin] = true;
                bins_hit += 1;
                if (bins_hit >= threshold and mixing_time == n) {
                    mixing_time = i + 1;
                }
            }
        }

        const visited: f64 = @as(f64, @floatFromInt(bins_hit)) / 360.0;
        return .{
            .mixing_time = mixing_time,
            .visited_fraction = visited,
            .ergodicity_score = visited,
            .is_ergodic = visited > 0.9,
        };
    }
};

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

pub fn wallClockBridgeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const sc = try extractSeedCount(args);
    const bridge = WallClockBridge.create(sc.seed, sc.count);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(bridge.seed)))));
    try addKV(obj, gc, "color-count", Value.makeInt(@bitCast(@as(u48, @truncate(bridge.color_count)))));
    try addKV(obj, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(bridge.fingerprint)))));
    try addKV(obj, gc, "entropy", Value.makeFloat(bridge.entropy));
    try addKV(obj, gc, "order-independent", Value.makeBool(bridge.order_independent));
    try addKV(obj, gc, "verified", Value.makeBool(bridge.verify()));
    return Value.makeObj(obj);
}

pub fn colorBandwidthFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const sc = try extractSeedCount(args);
    const bw = ColorBandwidth.measure(sc.seed, sc.count);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "r-entropy", Value.makeFloat(bw.r_entropy));
    try addKV(obj, gc, "g-entropy", Value.makeFloat(bw.g_entropy));
    try addKV(obj, gc, "b-entropy", Value.makeFloat(bw.b_entropy));
    try addKV(obj, gc, "total-entropy", Value.makeFloat(bw.total_entropy));
    try addKV(obj, gc, "gamut-coverage", Value.makeFloat(bw.gamut_coverage));
    return Value.makeObj(obj);
}

pub fn ergodicMeasureFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const sc = try extractSeedCount(args);
    const em = ErgodicMeasure.measure(sc.seed, sc.count);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "mixing-time", Value.makeInt(@bitCast(@as(u48, @truncate(em.mixing_time)))));
    try addKV(obj, gc, "visited-fraction", Value.makeFloat(em.visited_fraction));
    try addKV(obj, gc, "ergodicity-score", Value.makeFloat(em.ergodicity_score));
    try addKV(obj, gc, "is-ergodic", Value.makeBool(em.is_ergodic));
    return Value.makeObj(obj);
}

pub fn detectObstructionsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const sc = try extractSeedCount(args);
    const bridge = WallClockBridge.create(sc.seed, sc.count);
    const bw = ColorBandwidth.measure(sc.seed, sc.count);
    const em = ErgodicMeasure.measure(sc.seed, sc.count);

    const vec = try gc.allocObj(.vector);

    if (!bridge.verify()) {
        try vec.data.vector.items.append(gc.allocator, try kw(gc, "fingerprint-mismatch"));
    }
    if (bw.total_entropy < 0.5) {
        try vec.data.vector.items.append(gc.allocator, try kw(gc, "low-bandwidth"));
    }
    if (!em.is_ergodic) {
        try vec.data.vector.items.append(gc.allocator, try kw(gc, "non-ergodic"));
    }
    if (bw.gamut_coverage < 0.5) {
        try vec.data.vector.items.append(gc.allocator, try kw(gc, "low-gamut"));
    }
    if (bridge.entropy < 1.0) {
        try vec.data.vector.items.append(gc.allocator, try kw(gc, "low-entropy"));
    }

    return Value.makeObj(vec);
}

// ============================================================================
// SKILL TABLE
// ============================================================================

pub const skill_table = .{
    .{ "wall-clock-bridge", &wallClockBridgeFn },
    .{ "color-bandwidth", &colorBandwidthFn },
    .{ "ergodic-measure", &ergodicMeasureFn },
    .{ "detect-obstructions", &detectObstructionsFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "wall clock bridge deterministic" {
    const b1 = WallClockBridge.create(1069, 1000);
    const b2 = WallClockBridge.create(1069, 1000);
    try std.testing.expectEqual(b1.fingerprint, b2.fingerprint);
    try std.testing.expectEqual(b1.entropy, b2.entropy);
    try std.testing.expect(b1.verify());
}

test "color bandwidth reasonable" {
    const bw = ColorBandwidth.measure(1069, 10000);
    try std.testing.expect(bw.total_entropy > 0.5);
    try std.testing.expect(bw.r_entropy > 0.5);
    try std.testing.expect(bw.g_entropy > 0.5);
    try std.testing.expect(bw.b_entropy > 0.5);
}

test "ergodic measure converges" {
    const em = ErgodicMeasure.measure(1069, 10000);
    try std.testing.expect(em.is_ergodic);
    try std.testing.expect(em.visited_fraction > 0.9);
    try std.testing.expect(em.mixing_time < 10000);
}

test "obstructions empty for good seed" {
    // We test the structs directly since builtin fns need GC/Env
    const bridge = WallClockBridge.create(1069, 10000);
    const bw = ColorBandwidth.measure(1069, 10000);
    const em = ErgodicMeasure.measure(1069, 10000);

    try std.testing.expect(bridge.verify());
    try std.testing.expect(bw.total_entropy >= 0.5);
    try std.testing.expect(em.is_ergodic);
    try std.testing.expect(bw.gamut_coverage >= 0.5);
    try std.testing.expect(bridge.entropy >= 1.0);
}
