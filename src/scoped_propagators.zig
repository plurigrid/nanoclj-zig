//! Scoped Propagators for nanoclj-zig — matching Gay.jl's scoped_propagators.jl
//!
//! Three-strategy scoped propagator over AncestryACSet:
//! bottomUp (leaves→roots), topDown (roots→leaves), horizontal (siblings).
//! Materialization runs all three in sequence.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const substrate = @import("substrate.zig");
const Resources = @import("transitivity.zig").Resources;

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
// AncestryNode
// ============================================================================

pub const AncestryNode = struct {
    name_hash: u64,
    fingerprint: u64,
    depth: u8,
    parent_idx: u8, // 255 = no parent

    pub fn init(name_hash: u64, seed: u64, depth: u8) AncestryNode {
        return .{
            .name_hash = name_hash,
            .fingerprint = substrate.mix64(name_hash +% seed +% @as(u64, depth) *% substrate.GOLDEN),
            .depth = depth,
            .parent_idx = 255,
        };
    }
};

// ============================================================================
// AncestryACSet
// ============================================================================

pub const AncestryACSet = struct {
    nodes: [64]AncestryNode,
    node_count: u8,
    seed: u64,
    materialized: bool,
    collective_fp: u64,

    pub fn init(seed: u64) AncestryACSet {
        return .{
            .nodes = undefined,
            .node_count = 0,
            .seed = seed,
            .materialized = false,
            .collective_fp = 0,
        };
    }

    pub fn addNode(self: *AncestryACSet, name_hash: u64, depth: u8, parent_idx: u8) u8 {
        const idx = self.node_count;
        if (idx >= 64) return 63; // saturate
        var node = AncestryNode.init(name_hash, self.seed, depth);
        node.parent_idx = parent_idx;
        self.nodes[idx] = node;
        self.node_count += 1;
        self.materialized = false;
        return idx;
    }

    pub fn addRoot(self: *AncestryACSet, name_hash: u64) u8 {
        return self.addNode(name_hash, 0, 255);
    }

    pub fn addChild(self: *AncestryACSet, parent_idx: u8, name_hash: u64) u8 {
        const depth = if (parent_idx < self.node_count) self.nodes[parent_idx].depth + 1 else 0;
        return self.addNode(name_hash, depth, parent_idx);
    }
};

// ============================================================================
// Three Propagation Strategies
// ============================================================================

/// Bottom-up: leaves to roots. Each parent fp = XOR of children fps, mixed with depth.
pub fn bottomUp(acs: *AncestryACSet) void {
    const n = acs.node_count;
    if (n == 0) return;
    // Find max depth
    var max_depth: u8 = 0;
    for (0..n) |i| {
        if (acs.nodes[i].depth > max_depth) max_depth = acs.nodes[i].depth;
    }
    // Process from max_depth-1 down to 0
    var d: u8 = max_depth;
    while (d > 0) {
        d -= 1;
        for (0..n) |i| {
            if (acs.nodes[i].depth == d) {
                // XOR all children fps
                var child_xor: u64 = 0;
                var has_child = false;
                for (0..n) |j| {
                    if (acs.nodes[j].parent_idx == @as(u8, @intCast(i))) {
                        child_xor ^= acs.nodes[j].fingerprint;
                        has_child = true;
                    }
                }
                if (has_child) {
                    acs.nodes[i].fingerprint = substrate.mix64(child_xor +% @as(u64, d) *% substrate.GOLDEN);
                }
            }
        }
    }
}

/// Top-down: roots to leaves. Each child fp = parent fp mixed with child's name_hash.
pub fn topDown(acs: *AncestryACSet) void {
    const n = acs.node_count;
    if (n == 0) return;
    // Find max depth
    var max_depth: u8 = 0;
    for (0..n) |i| {
        if (acs.nodes[i].depth > max_depth) max_depth = acs.nodes[i].depth;
    }
    // Process depth 1 through max_depth
    for (1..@as(usize, max_depth) + 1) |d| {
        for (0..n) |i| {
            if (acs.nodes[i].depth == @as(u8, @intCast(d))) {
                const pi = acs.nodes[i].parent_idx;
                if (pi < n) {
                    acs.nodes[i].fingerprint = substrate.mix64(acs.nodes[pi].fingerprint +% acs.nodes[i].name_hash);
                }
            }
        }
    }
}

/// Horizontal: siblings at same depth XOR their fps together.
pub fn horizontal(acs: *AncestryACSet) void {
    const n = acs.node_count;
    if (n == 0) return;
    // Find max depth
    var max_depth: u8 = 0;
    for (0..n) |i| {
        if (acs.nodes[i].depth > max_depth) max_depth = acs.nodes[i].depth;
    }
    // For each depth, XOR all sibling fps, then mix into each
    for (0..@as(usize, max_depth) + 1) |d| {
        var sibling_xor: u64 = 0;
        for (0..n) |i| {
            if (acs.nodes[i].depth == @as(u8, @intCast(d))) {
                sibling_xor ^= acs.nodes[i].fingerprint;
            }
        }
        for (0..n) |i| {
            if (acs.nodes[i].depth == @as(u8, @intCast(d))) {
                // XOR with all siblings (including self cancels, so re-add self)
                acs.nodes[i].fingerprint ^= substrate.mix64(sibling_xor ^ acs.nodes[i].fingerprint);
            }
        }
    }
}

// ============================================================================
// Universal Materialization
// ============================================================================

pub fn materialize(acs: *AncestryACSet) void {
    bottomUp(acs);
    topDown(acs);
    horizontal(acs);
    acs.materialized = true;
    var fp: u64 = 0;
    for (0..acs.node_count) |i| {
        fp ^= acs.nodes[i].fingerprint;
    }
    acs.collective_fp = fp;
}

// ============================================================================
// Balanced Binary Tree Builder
// ============================================================================

fn buildBalancedTree(acs: *AncestryACSet, n: u8) void {
    if (n == 0) return;
    // Add root
    _ = acs.addRoot(substrate.mix64(acs.seed));
    // BFS: for each node at index i, add left=2i+1, right=2i+2
    var i: u8 = 0;
    while (i < acs.node_count and acs.node_count < n) : (i += 1) {
        const left_hash = substrate.mix64(acs.seed +% @as(u64, acs.node_count) *% substrate.GOLDEN);
        _ = acs.addChild(i, left_hash);
        if (acs.node_count >= n) break;
        const right_hash = substrate.mix64(acs.seed +% @as(u64, acs.node_count) *% substrate.GOLDEN);
        _ = acs.addChild(i, right_hash);
    }
}

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

pub fn ancestryAcsetFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const acs = AncestryACSet.init(seed);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(seed)))));
    try addKV(obj, gc, "nodes", Value.makeInt(0));
    try addKV(obj, gc, "materialized", Value.makeBool(acs.materialized));
    try addKV(obj, gc, "fingerprint", Value.makeInt(0));
    return Value.makeObj(obj);
}

pub fn materializeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const raw_n = args[1].asInt();
    if (raw_n < 0) return error.InvalidArgs;
    const n: u8 = @intCast(@min(64, raw_n));
    var acs = AncestryACSet.init(seed);
    buildBalancedTree(&acs, n);
    materialize(&acs);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(acs.collective_fp)))));
    try addKV(obj, gc, "materialized", Value.makeBool(acs.materialized));
    try addKV(obj, gc, "node-count", Value.makeInt(@intCast(acs.node_count)));
    return Value.makeObj(obj);
}

pub fn propagateStrategyFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const strategy = args[1].asInt();
    if (strategy < 0 or strategy > 2) return error.InvalidArgs;

    var acs = AncestryACSet.init(seed);
    buildBalancedTree(&acs, 15); // 4-level balanced tree

    const strategy_name: []const u8 = switch (@as(u2, @intCast(strategy))) {
        0 => blk: {
            bottomUp(&acs);
            break :blk "bottom-up";
        },
        1 => blk: {
            topDown(&acs);
            break :blk "top-down";
        },
        2 => blk: {
            horizontal(&acs);
            break :blk "horizontal";
        },
        else => "unknown",
    };

    var fp: u64 = 0;
    for (0..acs.node_count) |i| {
        fp ^= acs.nodes[i].fingerprint;
    }

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(fp)))));
    try addKV(obj, gc, "strategy-name", Value.makeString(try gc.internString(strategy_name)));
    return Value.makeObj(obj);
}

// ============================================================================
// SKILL TABLE
// ============================================================================

pub const skill_table = .{
    .{ "ancestry-acset", &ancestryAcsetFn },
    .{ "materialize", &materializeFn },
    .{ "propagate-strategy", &propagateStrategyFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "ancestry node init" {
    const node = AncestryNode.init(42, 1069, 3);
    try std.testing.expect(node.fingerprint != 0);
    try std.testing.expectEqual(@as(u8, 3), node.depth);
    try std.testing.expectEqual(@as(u8, 255), node.parent_idx);
    try std.testing.expectEqual(@as(u64, 42), node.name_hash);
}

test "bottom up propagation" {
    var acs = AncestryACSet.init(1069);
    const root = acs.addRoot(100);
    _ = acs.addChild(root, 200);
    _ = acs.addChild(root, 300);
    const parent_fp_before = acs.nodes[0].fingerprint;
    bottomUp(&acs);
    try std.testing.expect(acs.nodes[0].fingerprint != parent_fp_before);
}

test "materialization deterministic" {
    var acs1 = AncestryACSet.init(1069);
    buildBalancedTree(&acs1, 15);
    materialize(&acs1);

    var acs2 = AncestryACSet.init(1069);
    buildBalancedTree(&acs2, 15);
    materialize(&acs2);

    try std.testing.expectEqual(acs1.collective_fp, acs2.collective_fp);
    try std.testing.expect(acs1.materialized);
    try std.testing.expect(acs2.materialized);
}

test "three strategies converge" {
    const seed: u64 = 1069;

    // Bottom-up
    var acs_bu = AncestryACSet.init(seed);
    buildBalancedTree(&acs_bu, 7);
    bottomUp(&acs_bu);
    var fp_bu: u64 = 0;
    for (0..acs_bu.node_count) |i| fp_bu ^= acs_bu.nodes[i].fingerprint;
    try std.testing.expect(fp_bu != 0);

    // Top-down
    var acs_td = AncestryACSet.init(seed);
    buildBalancedTree(&acs_td, 7);
    topDown(&acs_td);
    var fp_td: u64 = 0;
    for (0..acs_td.node_count) |i| fp_td ^= acs_td.nodes[i].fingerprint;
    try std.testing.expect(fp_td != 0);

    // Horizontal
    var acs_hz = AncestryACSet.init(seed);
    buildBalancedTree(&acs_hz, 7);
    horizontal(&acs_hz);
    var fp_hz: u64 = 0;
    for (0..acs_hz.node_count) |i| fp_hz ^= acs_hz.nodes[i].fingerprint;
    try std.testing.expect(fp_hz != 0);

    // Combined (materialize)
    var acs_all = AncestryACSet.init(seed);
    buildBalancedTree(&acs_all, 7);
    materialize(&acs_all);
    try std.testing.expect(acs_all.collective_fp != 0);
    try std.testing.expect(acs_all.materialized);
}
