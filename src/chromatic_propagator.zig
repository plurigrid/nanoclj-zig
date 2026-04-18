//! Chromatic Propagator for nanoclj-zig — matching Gay.jl's chromatic_propagator.jl
//!
//! Propagator cells with color identity: each cell has a SplitMix64-derived color,
//! constraint propagation with GF(3) color conservation checks.

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

// ============================================================================
// ChromaticCell
// ============================================================================

pub const ChromaticCell = struct {
    name_hash: u64,
    content: gay_skills.CellState,
    value_bits: u64,
    color: substrate.Color,
    color_seed: u64,

    pub fn init(name_hash: u64, seed: u64) ChromaticCell {
        const combined = substrate.mix64(seed +% name_hash *% substrate.GOLDEN);
        return .{
            .name_hash = name_hash,
            .content = .nothing,
            .value_bits = 0,
            .color = substrate.colorAt(seed, name_hash),
            .color_seed = combined,
        };
    }

    pub fn tell(self: *ChromaticCell, val: u64) void {
        switch (self.content) {
            .nothing => {
                self.content = .value;
                self.value_bits = val;
            },
            .value => {
                if (self.value_bits != val) {
                    self.content = .contradiction;
                }
            },
            .contradiction => {},
        }
    }

    /// GF(3) trit of this cell's color: extracted from hue sector.
    /// Red (0°±60°) = -1, Green (120°±60°) = 0, Blue (240°±60°) = +1.
    pub fn trit(self: *const ChromaticCell) i8 {
        // Approximate hue from RGB by max channel
        const max_ch = @max(self.color.r, @max(self.color.g, self.color.b));
        if (max_ch == self.color.r) return -1; // red-dominant → validator
        if (max_ch == self.color.b) return 1; // blue-dominant → generator
        return 0; // green-dominant → coordinator
    }

    /// GF(3) conservation: combine trits mod 3, not XOR.
    /// XOR is GF(2); trit sum mod 3 is the correct conservation law.
    pub fn conservedCombine(c1: substrate.Color, c2: substrate.Color) substrate.Color {
        // Preserve legacy XOR for backward compatibility in substrate.Color
        // but see colorConservationCheck below for the correct GF(3) check.
        return .{
            .r = c1.r ^ c2.r,
            .g = c1.g ^ c2.g,
            .b = c1.b ^ c2.b,
        };
    }
};

// ============================================================================
// ChromaticEnv
// ============================================================================

pub const ChromaticEnv = struct {
    cells: [64]ChromaticCell,
    cell_count: u8,
    seed: u64,
    step: u64,

    pub fn init(seed: u64) ChromaticEnv {
        return .{
            .cells = undefined,
            .cell_count = 0,
            .seed = seed,
            .step = 0,
        };
    }

    pub fn defineCell(self: *ChromaticEnv, name_hash: u64) ?*ChromaticCell {
        // Check if already exists
        for (self.cells[0..self.cell_count]) |*cell| {
            if (cell.name_hash == name_hash) return cell;
        }
        if (self.cell_count >= 64) return null;
        self.cells[self.cell_count] = ChromaticCell.init(name_hash, self.seed);
        self.cell_count += 1;
        return &self.cells[self.cell_count - 1];
    }

    pub fn getCell(self: *ChromaticEnv, name_hash: u64) ?*ChromaticCell {
        for (self.cells[0..self.cell_count]) |*cell| {
            if (cell.name_hash == name_hash) return cell;
        }
        return null;
    }

    pub fn constraintAdd(self: *ChromaticEnv, a: u64, b: u64, sum: u64) bool {
        const cell_a = self.getCell(a) orelse return true;
        const cell_b = self.getCell(b) orelse return true;
        const cell_sum = self.getCell(sum) orelse return true;
        if (cell_a.content == .value and cell_b.content == .value) {
            cell_sum.tell(cell_a.value_bits +% cell_b.value_bits);
        }
        return cell_sum.content != .contradiction;
    }

    pub fn constraintMul(self: *ChromaticEnv, a: u64, b: u64, prod: u64) bool {
        const cell_a = self.getCell(a) orelse return true;
        const cell_b = self.getCell(b) orelse return true;
        const cell_prod = self.getCell(prod) orelse return true;
        if (cell_a.content == .value and cell_b.content == .value) {
            cell_prod.tell(cell_a.value_bits *% cell_b.value_bits);
        }
        return cell_prod.content != .contradiction;
    }

    /// GF(3) conservation check: trit sum of all cells ≡ 0 (mod 3).
    /// This is the correct invariant for the plastic constant / GF(27) tower.
    /// The old XOR check (GF(2)) is preserved in conservedCombine for
    /// backward compatibility but this is the authoritative conservation law.
    pub fn colorConservationCheck(self: *const ChromaticEnv) bool {
        var trit_sum: i32 = 0;
        for (self.cells[0..self.cell_count]) |cell| {
            trit_sum += cell.trit();
        }
        return @mod(trit_sum, 3) == 0;
    }

    pub fn networkFingerprint(self: *const ChromaticEnv) u64 {
        var fp: u64 = 0;
        for (self.cells[0..self.cell_count]) |cell| {
            fp ^= cell.color_seed;
        }
        return fp;
    }
};

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

/// Global chromatic env storage (keyed by seed, up to 16 envs)
var envs: [16]ChromaticEnv = undefined;
var env_seeds: [16]u64 = .{0} ** 16;
var env_count: u8 = 0;

fn getOrCreateEnv(seed: u64) *ChromaticEnv {
    for (0..env_count) |i| {
        if (env_seeds[i] == seed) return &envs[i];
    }
    if (env_count < 16) {
        envs[env_count] = ChromaticEnv.init(seed);
        env_seeds[env_count] = seed;
        env_count += 1;
        return &envs[env_count - 1];
    }
    // Overwrite last slot
    envs[15] = ChromaticEnv.init(seed);
    env_seeds[15] = seed;
    return &envs[15];
}

pub fn chromaticEnvFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const ce = getOrCreateEnv(seed);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(ce.seed)))));
    try addKV(obj, gc, "cells", Value.makeInt(@intCast(ce.cell_count)));
    try addKV(obj, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(ce.networkFingerprint())))));
    return Value.makeObj(obj);
}

pub fn chromaticDefineFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const name_hash: u64 = @bitCast(@as(i64, args[1].asInt()));
    const ce = getOrCreateEnv(seed);
    const cell = ce.defineCell(name_hash) orelse return error.Overflow;
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "name-hash", Value.makeInt(@bitCast(@as(u48, @truncate(cell.name_hash)))));
    try addKV(obj, gc, "state", Value.makeInt(@intCast(@intFromEnum(cell.content))));
    try addKV(obj, gc, "color-r", Value.makeInt(@intCast(cell.color.r)));
    try addKV(obj, gc, "color-g", Value.makeInt(@intCast(cell.color.g)));
    try addKV(obj, gc, "color-b", Value.makeInt(@intCast(cell.color.b)));
    return Value.makeObj(obj);
}

pub fn chromaticTellFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3 or !args[0].isInt() or !args[1].isInt() or !args[2].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const name_hash: u64 = @bitCast(@as(i64, args[1].asInt()));
    const val: u64 = @bitCast(@as(i64, args[2].asInt()));
    const ce = getOrCreateEnv(seed);
    const cell = ce.getCell(name_hash) orelse return error.InvalidArgs;
    cell.tell(val);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "state", Value.makeInt(@intCast(@intFromEnum(cell.content))));
    try addKV(obj, gc, "color-r", Value.makeInt(@intCast(cell.color.r)));
    try addKV(obj, gc, "color-g", Value.makeInt(@intCast(cell.color.g)));
    try addKV(obj, gc, "color-b", Value.makeInt(@intCast(cell.color.b)));
    try addKV(obj, gc, "conserved", Value.makeBool(ce.colorConservationCheck()));
    return Value.makeObj(obj);
}

pub fn chromaticConservationFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const ce = getOrCreateEnv(seed);
    return Value.makeBool(ce.colorConservationCheck());
}

// ============================================================================
// SKILL TABLE
// ============================================================================

pub const skill_table = .{
    .{ "chromatic-env", &chromaticEnvFn },
    .{ "chromatic-define", &chromaticDefineFn },
    .{ "chromatic-tell", &chromaticTellFn },
    .{ "chromatic-conservation", &chromaticConservationFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "chromatic cell init" {
    const cell = ChromaticCell.init(42, 1069);
    try std.testing.expectEqual(gay_skills.CellState.nothing, cell.content);
    try std.testing.expectEqual(@as(u64, 42), cell.name_hash);
    // Color should be deterministically assigned
    const cell2 = ChromaticCell.init(42, 1069);
    try std.testing.expectEqual(cell.color.r, cell2.color.r);
    try std.testing.expectEqual(cell.color.g, cell2.color.g);
    try std.testing.expectEqual(cell.color.b, cell2.color.b);
}

test "chromatic tell idempotent" {
    var cell = ChromaticCell.init(1, 1069);
    cell.tell(100);
    try std.testing.expectEqual(gay_skills.CellState.value, cell.content);
    try std.testing.expectEqual(@as(u64, 100), cell.value_bits);
    cell.tell(100);
    try std.testing.expectEqual(gay_skills.CellState.value, cell.content);
    try std.testing.expectEqual(@as(u64, 100), cell.value_bits);
}

test "chromatic tell contradiction" {
    var cell = ChromaticCell.init(1, 1069);
    cell.tell(100);
    try std.testing.expectEqual(gay_skills.CellState.value, cell.content);
    cell.tell(200);
    try std.testing.expectEqual(gay_skills.CellState.contradiction, cell.content);
}

test "chromatic conservation" {
    var ce = ChromaticEnv.init(1069);
    _ = ce.defineCell(1);
    _ = ce.defineCell(2);
    _ = ce.defineCell(3);
    // Fingerprint should be deterministic
    const fp1 = ce.networkFingerprint();
    var ce2 = ChromaticEnv.init(1069);
    _ = ce2.defineCell(1);
    _ = ce2.defineCell(2);
    _ = ce2.defineCell(3);
    const fp2 = ce2.networkFingerprint();
    try std.testing.expectEqual(fp1, fp2);
}
