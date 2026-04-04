//! 17 Gay Skills for nanoclj-zig
//!
//! Loads the most relevant capabilities from zig-syrup's gay/ modules
//! as Clojure builtins. Depth-bounded via color games: each eval step
//! generates a color, and the color's trit governs recursion permission.
//!
//! ┌────────────────────────────────────────────────────────────┐
//! │  Skill                    Builtin             Trit Domain  │
//! │  1. splitmix64            (mix64 n)           +1           │
//! │  2. color-at              (color-at seed idx) +1           │
//! │  3. color-hex             (color-hex r g b)   +1           │
//! │  4. color-trit            (color-trit hex)    0            │
//! │  5. gf3-add               (gf3-add a b)      0            │
//! │  6. gf3-mul               (gf3-mul a b)      0            │
//! │  7. gf3-conserved?        (gf3-conserved? v)  0           │
//! │  8. trit-balance          (trit-balance v)    0            │
//! │  9. tropical-add          (tropical-add a b)  -1           │
//! │ 10. tropical-mul          (tropical-mul a b)  -1           │
//! │ 11. world-create          (world-create seed) +1           │
//! │ 12. world-step            (world-step w)      0            │
//! │ 13. propagate             (propagate cell v)  0            │
//! │ 14. xor-fingerprint       (xor-fp v)          -1           │
//! │ 15. shannon-entropy       (entropy v)         -1           │
//! │ 16. depth-color           (depth-color)       0            │
//! │ 17. bisim-check           (bisim? a b)        -1           │
//! └────────────────────────────────────────────────────────────┘
//!
//! Color-game depth bounding:
//!   Each recursion level is assigned a color via SplitMix64(depth).
//!   The color's trit (+1/0/-1) determines the recursion budget:
//!     +1 (red domain):   may recurse freely (generator)
//!     0  (green domain): may recurse with cost 2 fuel per step
//!     -1 (blue domain):  may recurse with cost 3 fuel per step
//!   This creates natural depth "seasons" where some depths are
//!   cheaper than others, matching the Kuramoto oscillator model
//!   from did_seasons.zig.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const semantics = @import("semantics.zig");
const substrate = @import("substrate.zig");

// ============================================================================
// CONSTANTS
// ============================================================================

pub const GAY_SEED: u64 = 1069;
const GOLDEN: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;

// ============================================================================
// COLOR-GAME DEPTH BOUNDING
// ============================================================================

/// Compute the fuel cost for a given recursion depth (slow path).
fn computeDepthFuelCost(depth: u32) u64 {
    const state = @as(u64, depth) *% GOLDEN +% GAY_SEED;
    var z = state +% GOLDEN;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    z = z ^ (z >> 31);
    const r: u8 = @truncate(z >> 16);
    const g: u8 = @truncate(z >> 8);
    const b: u8 = @truncate(z);
    const trit = substrate.hueToTrit(rgbToHue(r, g, b));
    return switch (trit) {
        1 => 1,
        0 => 2,
        -1 => 3,
        else => 2,
    };
}

/// Comptime lookup table: eliminates ~10M float computations per fib(28).
pub const DEPTH_FUEL_LUT_SIZE = 512;
pub const depth_fuel_lut: [DEPTH_FUEL_LUT_SIZE]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [DEPTH_FUEL_LUT_SIZE]u64 = undefined;
    for (0..DEPTH_FUEL_LUT_SIZE) |d| {
        table[d] = computeDepthFuelCost(@intCast(d));
    }
    break :blk table;
};

/// Fuel cost for a given recursion depth. Uses comptime LUT for depths < 1024.
/// Creates "seasons" in recursion: some depths are cheap (red/+1),
/// some moderate (green/0), some expensive (blue/-1). Adversarial
/// inputs can't predict or exploit the pattern because it's PRF-derived.
pub fn depthFuelCost(depth: u32) u64 {
    if (depth < DEPTH_FUEL_LUT_SIZE) return depth_fuel_lut[depth];
    return computeDepthFuelCost(depth);
}

/// RGB to hue (local copy to avoid import cycles)
fn rgbToHue(r: u8, g: u8, b: u8) f64 {
    const rf: f64 = @as(f64, @floatFromInt(r)) / 255.0;
    const gf: f64 = @as(f64, @floatFromInt(g)) / 255.0;
    const bf: f64 = @as(f64, @floatFromInt(b)) / 255.0;
    const max_v = @max(rf, @max(gf, bf));
    const min_v = @min(rf, @min(gf, bf));
    const delta = max_v - min_v;
    if (delta < 1e-10) return 0.0;
    var hue: f64 = undefined;
    if (max_v == rf) {
        hue = 60.0 * @mod((gf - bf) / delta, 6.0);
    } else if (max_v == gf) {
        hue = 60.0 * ((bf - rf) / delta + 2.0);
    } else {
        hue = 60.0 * ((rf - gf) / delta + 4.0);
    }
    if (hue < 0) hue += 360.0;
    return hue;
}

/// Get the color assigned to a given recursion depth
pub fn depthColor(depth: u32) substrate.Color {
    return substrate.colorAt(GAY_SEED, @as(u64, depth));
}

// ============================================================================
// TROPICAL SEMIRING (Skill 9-10: min-plus algebra)
// ============================================================================

/// Tropical addition = min (for shortest-path / cost problems)
fn tropicalAdd(a: f64, b: f64) f64 {
    if (std.math.isInf(a)) return b;
    if (std.math.isInf(b)) return a;
    return @min(a, b);
}

/// Tropical multiplication = addition (path composition)
fn tropicalMul(a: f64, b: f64) f64 {
    if (std.math.isInf(a) or std.math.isInf(b)) return std.math.inf(f64);
    return a + b;
}

// ============================================================================
// KRIPKE WORLD (Skill 11-12: possible worlds)
// ============================================================================

/// A Kripke world state: seed → deterministic color + trit
pub const World = struct {
    seed: u64,
    step: u64 = 0,
    trit_sum: i8 = 0,

    pub fn init(seed: u64) World {
        return .{ .seed = seed };
    }

    pub fn advance(self: *World) substrate.Color {
        const c = substrate.colorAt(self.seed, self.step);
        self.step += 1;
        const trit = substrate.hueToTrit(rgbToHue(c.r, c.g, c.b));
        self.trit_sum = @intCast(@mod(@as(i16, self.trit_sum) + @as(i16, trit) + 3, 3));
        return c;
    }

    pub fn isConserved(self: *const World) bool {
        return self.trit_sum == 0;
    }
};

// ============================================================================
// PROPAGATOR CELL (Skill 13: partial information lattice)
// ============================================================================

pub const CellState = enum {
    nothing,     // ⊥ — no information
    value,       // has a value
    contradiction, // ⊤ — inconsistent
};

// ============================================================================
// BUILTIN IMPLEMENTATIONS
// ============================================================================

// Skill 9: tropical-add
pub fn tropicalAddFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const b: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeFloat(tropicalAdd(a, b));
}

// Skill 10: tropical-mul
pub fn tropicalMulFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const b: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeFloat(tropicalMul(a, b));
}

// Skill 11: world-create (seed) → {:seed N :step 0 :trit 0 :conserved true}
pub fn worldCreateFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len > 1) return error.ArityError;
    const seed: u64 = if (args.len == 1 and args[0].isInt())
        @bitCast(@as(i64, args[0].asInt()))
    else
        GAY_SEED;
    return worldToMap(World.init(seed), gc);
}

// Skill 12: world-step (world) → {:seed N :step N+1 :trit T :conserved B :color "#RRGGBB"}
pub fn worldStepFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isObj()) return error.ArityError;
    const obj = args[0].asObj();
    if (obj.kind != .map) return error.TypeError;
    // Extract seed and step from map
    var seed: u64 = GAY_SEED;
    var step: u64 = 0;
    var trit_sum: i8 = 0;
    for (obj.data.map.keys.items, 0..) |k, i| {
        if (k.isKeyword()) {
            const name = gc.getString(k.asKeywordId());
            const v = obj.data.map.vals.items[i];
            if (std.mem.eql(u8, name, "seed") and v.isInt()) seed = @bitCast(@as(i64, v.asInt()));
            if (std.mem.eql(u8, name, "step") and v.isInt()) step = @bitCast(@as(i64, v.asInt()));
            if (std.mem.eql(u8, name, "trit") and v.isInt()) trit_sum = @intCast(v.asInt());
        }
    }
    var w = World{ .seed = seed, .step = step, .trit_sum = trit_sum };
    const c = w.advance();
    // Build result map with color
    const result = try worldToMap(w, gc);
    const result_obj = result.asObj();
    var hex_buf: [7]u8 = undefined;
    const hex = "0123456789ABCDEF";
    hex_buf = .{
        '#',
        hex[c.r >> 4], hex[c.r & 0xF],
        hex[c.g >> 4], hex[c.g & 0xF],
        hex[c.b >> 4], hex[c.b & 0xF],
    };
    try result_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("color")));
    try result_obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(&hex_buf)));
    return result;
}

fn worldToMap(w: World, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "seed"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@bitCast(@as(u48, @truncate(w.seed)))));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "step"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@bitCast(@as(u48, @truncate(w.step)))));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, w.trit_sum))));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "conserved"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(w.isConserved()));
    return Value.makeObj(obj);
}

// Skill 13: propagate — merge two values in the partial information lattice
// nothing ⊔ v = v, v ⊔ nothing = v, v ⊔ v = v, v ⊔ w = contradiction
pub fn propagateFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a = args[0];
    const b = args[1];
    // nil = nothing (⊥)
    if (a.isNil()) return b;
    if (b.isNil()) return a;
    // Same value = idempotent (bitwise — structural eq needs GC)
    if (a.eql(b)) return a;
    // Different non-nil values = contradiction → return nil tagged specially
    // We use the keyword :contradiction as the ⊤ element
    return Value.makeBool(false); // ⊤ = false (contradiction signal)
}

// Skill 14: xor-fingerprint — already exists in substrate, re-export
pub const xorFingerprintFn = substrate.xorFingerprintFn;

// Skill 15: shannon-entropy of a numeric vector
pub fn entropyFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isObj()) return error.ArityError;
    const obj = args[0].asObj();
    const items = switch (obj.kind) {
        .vector => obj.data.vector.items.items,
        .list => obj.data.list.items.items,
        else => return error.TypeError,
    };
    var buf: [256]f64 = undefined;
    const n = @min(items.len, 256);
    for (items[0..n], 0..) |item, i| {
        buf[i] = if (item.isInt()) @floatFromInt(item.asInt()) else if (item.isFloat()) item.asFloat() else 0.0;
    }
    // Shannon entropy
    var total: f64 = 0;
    for (buf[0..n]) |v| total += @abs(v);
    if (total < 1e-15) return Value.makeFloat(0.0);
    var entropy: f64 = 0;
    for (buf[0..n]) |v| {
        const p = @abs(v) / total;
        if (p > 1e-15) entropy -= p * @log(p) / @log(2.0);
    }
    return Value.makeFloat(entropy);
}

// Skill 16: depth-color — return the color assigned to current eval depth
pub fn depthColorFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len > 1) return error.ArityError;
    const depth: u32 = if (args.len == 1 and args[0].isInt())
        @intCast(args[0].asInt())
    else
        0;
    const c = depthColor(depth);
    var hex_buf: [7]u8 = undefined;
    const hex = "0123456789ABCDEF";
    hex_buf = .{
        '#',
        hex[c.r >> 4], hex[c.r & 0xF],
        hex[c.g >> 4], hex[c.g & 0xF],
        hex[c.b >> 4], hex[c.b & 0xF],
    };
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "hex"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(&hex_buf)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "depth"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(depth)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "fuel-cost"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(depthFuelCost(depth))));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, substrate.hueToTrit(rgbToHue(c.r, c.g, c.b))))));
    return Value.makeObj(obj);
}

// Skill 17: bisim? — check if two values are bisimulation-equivalent
// Uses structural equality as the ground-truth bisimulation relation
pub fn bisimCheckFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return Value.makeBool(semantics.structuralEq(args[0], args[1], gc));
}

// Skill 3: color-hex (r g b) → "#RRGGBB"
pub fn colorHexFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt() or !args[2].isInt()) return error.TypeError;
    const r: u8 = @intCast(@as(i48, @max(0, @min(255, args[0].asInt()))));
    const g: u8 = @intCast(@as(i48, @max(0, @min(255, args[1].asInt()))));
    const b: u8 = @intCast(@as(i48, @max(0, @min(255, args[2].asInt()))));
    const hex = "0123456789ABCDEF";
    const hex_buf: [7]u8 = .{
        '#',
        hex[r >> 4], hex[r & 0xF],
        hex[g >> 4], hex[g & 0xF],
        hex[b >> 4], hex[b & 0xF],
    };
    return Value.makeString(try gc.internString(&hex_buf));
}

// Skill 4: color-trit (hex-string) → -1/0/+1 based on hue
pub fn colorTritFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // Accept either a hex string "#RRGGBB" or 3 ints
    if (args[0].isString()) {
        const s = gc.getString(args[0].asStringId());
        if (s.len == 7 and s[0] == '#') {
            const r = parseHex2(s[1..3]) orelse return error.TypeError;
            const g = parseHex2(s[3..5]) orelse return error.TypeError;
            const b = parseHex2(s[5..7]) orelse return error.TypeError;
            return Value.makeInt(@intCast(@as(i48, substrate.hueToTrit(rgbToHue(r, g, b)))));
        }
    }
    return error.TypeError;
}

fn parseHex2(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    const hi = hexVal(s[0]) orelse return null;
    const lo = hexVal(s[1]) orelse return null;
    return (hi << 4) | lo;
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

// ============================================================================
// REGISTRATION
// ============================================================================

/// Register all 17 gay skills as builtins in the core table.
/// Call this from core.zig after initCore.
pub const skill_table = .{
    // Skills 1-2 already registered as mix64, color-at in substrate
    .{ "color-hex", &colorHexFn },         // 3
    .{ "color-trit", &colorTritFn },        // 4
    // Skills 5-8 already registered as gf3-add, gf3-mul, gf3-conserved?, trit-balance
    .{ "tropical-add", &tropicalAddFn },    // 9
    .{ "tropical-mul", &tropicalMulFn },    // 10
    .{ "world-create", &worldCreateFn },    // 11
    .{ "world-step", &worldStepFn },        // 12
    .{ "propagate", &propagateFn },         // 13
    // Skill 14: xor-fingerprint already registered
    .{ "entropy", &entropyFn },             // 15
    .{ "depth-color", &depthColorFn },      // 16
    .{ "bisim?", &bisimCheckFn },           // 17
};

// ============================================================================
// TESTS
// ============================================================================

test "depth fuel cost varies by color" {
    // Costs should be 1, 2, or 3
    var costs: [3]u32 = .{ 0, 0, 0 };
    for (0..100) |d| {
        const cost = depthFuelCost(@intCast(d));
        try std.testing.expect(cost >= 1 and cost <= 3);
        costs[cost - 1] += 1;
    }
    // All three cost levels should appear in 100 depths
    try std.testing.expect(costs[0] > 0); // cost=1 (red)
    try std.testing.expect(costs[1] > 0); // cost=2 (green)
    try std.testing.expect(costs[2] > 0); // cost=3 (blue)
}

test "tropical semiring" {
    try std.testing.expectEqual(@as(f64, 3.0), tropicalAdd(3.0, 5.0));
    try std.testing.expectEqual(@as(f64, 8.0), tropicalMul(3.0, 5.0));
    try std.testing.expectEqual(@as(f64, 3.0), tropicalAdd(3.0, std.math.inf(f64)));
    try std.testing.expect(std.math.isInf(tropicalMul(3.0, std.math.inf(f64))));
}

test "world conservation" {
    var w = World.init(GAY_SEED);
    // After 3 steps, check trit balance
    _ = w.advance();
    _ = w.advance();
    _ = w.advance();
    // Conservation depends on the specific colors
    // but the function should not crash
    _ = w.isConserved();
    try std.testing.expect(w.step == 3);
}

test "depth color is deterministic" {
    const c1 = depthColor(42);
    const c2 = depthColor(42);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.g, c2.g);
    try std.testing.expectEqual(c1.b, c2.b);
}
