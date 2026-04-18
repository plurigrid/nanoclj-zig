//! Marsaglia-Bumpus SPI audit tests for nanoclj-zig
//! Ported from Gay.jl's marsaglia_bumpus_tests.jl
//!
//! Marsaglia: statistical quality tests (runs, birthday spacing)
//! Bumpus: compositional/structural tests (adhesion width, sheaf gluing)

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

const MAX_COUNT: u64 = 100_000;

fn clampCount(count: u64) u64 {
    return if (count > MAX_COUNT) MAX_COUNT else if (count == 0) 1 else count;
}

// ============================================================================
// SplitTree
// ============================================================================

pub const SplitTree = struct {
    seed: u64,
    depth: u8,
    fingerprint: u64,
    left_seed: u64,
    right_seed: u64,

    pub fn init(seed: u64, depth: u8) SplitTree {
        const left = substrate.mix64(seed);
        const right = substrate.mix64(seed ^ substrate.GOLDEN);
        return .{
            .seed = seed,
            .depth = depth,
            .fingerprint = left ^ right,
            .left_seed = left,
            .right_seed = right,
        };
    }

    pub fn split(self: SplitTree) struct { left: SplitTree, right: SplitTree } {
        return .{
            .left = SplitTree.init(self.left_seed, self.depth + 1),
            .right = SplitTree.init(self.right_seed, self.depth + 1),
        };
    }
};

// ============================================================================
// Marsaglia Tests
// ============================================================================

pub fn runsTest(seed: u64, count: u64) struct { pass: bool, stat: f64 } {
    const n = clampCount(count);
    if (n < 2) return .{ .pass = true, .stat = 0.0 };

    // Generate SplitMix sequence and count runs
    var runs: u64 = 1;
    var prev = substrate.mix64(seed +% substrate.GOLDEN);
    for (1..@as(usize, @intCast(n))) |i| {
        const curr = substrate.mix64(seed +% @as(u64, i) *% substrate.GOLDEN);
        // New run whenever direction changes
        const prev_up = prev < curr;
        const s2 = substrate.mix64(seed +% (@as(u64, i) -% 1) *% substrate.GOLDEN);
        _ = s2;
        if (i >= 2) {
            const prev2 = substrate.mix64(seed +% (@as(u64, i) - 1) *% substrate.GOLDEN);
            const was_up = substrate.mix64(seed +% (@as(u64, i) - 2) *% substrate.GOLDEN) < prev2;
            if (prev_up != was_up) runs += 1;
        }
        prev = curr;
    }

    // Expected runs ~ (2n - 1) / 3, variance ~ (16n - 29) / 90
    const nf: f64 = @floatFromInt(n);
    const expected = (2.0 * nf - 1.0) / 3.0;
    const variance = (16.0 * nf - 29.0) / 90.0;
    const runs_f: f64 = @floatFromInt(runs);
    const z = (runs_f - expected) / @sqrt(variance);
    const stat = z * z; // chi-square with 1 df

    return .{ .pass = stat < 6.635, .stat = stat }; // p < 0.01 threshold
}

pub fn birthdayTest(seed: u64, count: u64) struct { pass: bool, stat: f64 } {
    const n = clampCount(count);

    // Hash values into 360 bins (hue space)
    var bins = [_]u32{0} ** 360;
    for (0..@as(usize, @intCast(n))) |i| {
        const v = substrate.mix64(seed +% @as(u64, i) *% substrate.GOLDEN);
        const bin: usize = @intCast(v % 360);
        bins[bin] += 1;
    }

    // Count collisions (bins with > 1 entry)
    var collisions: u64 = 0;
    for (bins) |b| {
        if (b > 1) collisions += b - 1;
    }

    // Expected collisions under Poisson: lambda = n^2 / (2 * 360)
    const nf: f64 = @floatFromInt(n);
    const lambda = (nf * nf) / (2.0 * 360.0);
    const observed: f64 = @floatFromInt(collisions);
    // Normalized deviation
    const stat = if (lambda > 0) (observed - lambda) / @sqrt(lambda) else 0.0;

    return .{ .pass = @abs(stat) < 3.0, .stat = stat };
}

// ============================================================================
// Bumpus Compositional Tests
// ============================================================================

pub fn adhesionWidthTest(seed: u64, depth: u8) struct { pass: bool, width: u32 } {
    const clamped_depth: u8 = if (depth > 16) 16 else if (depth == 0) 1 else depth;
    var collisions: u32 = 0;

    // Check fingerprint collisions between siblings at each level
    const root = SplitTree.init(seed, 0);
    collisions += checkSiblingCollisions(root, clamped_depth);

    return .{ .pass = collisions == 0, .width = collisions };
}

fn checkSiblingCollisions(tree: SplitTree, remaining: u8) u32 {
    if (remaining == 0) return 0;
    const children = tree.split();
    var collisions: u32 = 0;
    if (children.left.fingerprint == children.right.fingerprint) collisions += 1;
    collisions += checkSiblingCollisions(children.left, remaining - 1);
    collisions += checkSiblingCollisions(children.right, remaining - 1);
    return collisions;
}

pub fn sheafGluingTest(seed: u64, depth: u8) struct { pass: bool, gluing_fp: u64 } {
    const clamped_depth: u8 = if (depth > 16) 16 else if (depth == 0) 1 else depth;
    const leaf_xor = collectLeafXor(SplitTree.init(seed, 0), clamped_depth);

    // Gluing is consistent if leaf XOR is deterministic (SPI property)
    return .{ .pass = leaf_xor != 0, .gluing_fp = leaf_xor };
}

fn collectLeafXor(tree: SplitTree, remaining: u8) u64 {
    if (remaining == 0) return tree.fingerprint;
    const children = tree.split();
    return collectLeafXor(children.left, remaining - 1) ^ collectLeafXor(children.right, remaining - 1);
}

// ============================================================================
// Full SPI Audit
// ============================================================================

pub fn fullSpiAudit(seed: u64) struct { runs: bool, birthday: bool, adhesion: bool, gluing: bool, all_pass: bool } {
    const r = runsTest(seed, 10000);
    const b = birthdayTest(seed, 10000);
    const a = adhesionWidthTest(seed, 8);
    const g = sheafGluingTest(seed, 8);
    return .{
        .runs = r.pass,
        .birthday = b.pass,
        .adhesion = a.pass,
        .gluing = g.pass,
        .all_pass = r.pass and b.pass and a.pass and g.pass,
    };
}

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

pub fn spiAuditFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const audit = fullSpiAudit(seed);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "runs", Value.makeBool(audit.runs));
    try addKV(obj, gc, "birthday", Value.makeBool(audit.birthday));
    try addKV(obj, gc, "adhesion", Value.makeBool(audit.adhesion));
    try addKV(obj, gc, "gluing", Value.makeBool(audit.gluing));
    try addKV(obj, gc, "all-pass", Value.makeBool(audit.all_pass));
    return Value.makeObj(obj);
}

pub fn runsTestFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const count: u64 = @bitCast(@as(i64, args[1].asInt()));
    const result = runsTest(seed, count);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "pass", Value.makeBool(result.pass));
    try addKV(obj, gc, "stat", Value.makeFloat(result.stat));
    return Value.makeObj(obj);
}

pub fn splitTreeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const depth: u8 = @intCast(@as(u64, @bitCast(@as(i64, args[1].asInt()))) & 0xFF);
    const tree = SplitTree.init(seed, depth);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(tree.seed)))));
    try addKV(obj, gc, "depth", Value.makeInt(@intCast(tree.depth)));
    try addKV(obj, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(tree.fingerprint)))));
    try addKV(obj, gc, "left", Value.makeInt(@bitCast(@as(u48, @truncate(tree.left_seed)))));
    try addKV(obj, gc, "right", Value.makeInt(@bitCast(@as(u48, @truncate(tree.right_seed)))));
    return Value.makeObj(obj);
}

// ============================================================================
// SKILL TABLE
// ============================================================================

pub const skill_table = .{
    .{ "spi-audit", &spiAuditFn },
    .{ "runs-test", &runsTestFn },
    .{ "split-tree", &splitTreeFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "split tree deterministic" {
    const t1 = SplitTree.init(1069, 0);
    const t2 = SplitTree.init(1069, 0);
    try std.testing.expectEqual(t1.fingerprint, t2.fingerprint);
    try std.testing.expectEqual(t1.left_seed, t2.left_seed);
    try std.testing.expectEqual(t1.right_seed, t2.right_seed);
    // Different seed → different fingerprint
    const t3 = SplitTree.init(42, 0);
    try std.testing.expect(t1.fingerprint != t3.fingerprint);
}

test "runs test passes" {
    const result = runsTest(1069, 10000);
    try std.testing.expect(result.pass);
}

test "adhesion width zero" {
    const result = adhesionWidthTest(1069, 8);
    try std.testing.expect(result.pass);
    try std.testing.expectEqual(@as(u32, 0), result.width);
}

test "sheaf gluing consistent" {
    // Gluing fingerprint is deterministic — same seed gives same result
    const result1 = sheafGluingTest(1069, 4);
    const result2 = sheafGluingTest(1069, 4);
    try std.testing.expectEqual(result1.gluing_fp, result2.gluing_fp);
    // Fingerprint is non-trivial
    try std.testing.expect(result1.gluing_fp != 0);
}
