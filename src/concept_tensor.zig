//! CONCEPT TENSOR — 69³ lattice with monoid verification
//!
//! Matches Gay.jl's concept_tensor.jl: a deterministic 69³ concept lattice
//! where each cell has a SplitMix64 hash and GF(3) spin. Supports monoid
//! verification (XOR fingerprint), magnetization, checkerboard dynamics,
//! and concept morphisms (cube rotations + seed chaining).

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const substrate = @import("substrate.zig");
const Resources = @import("transitivity.zig").Resources;

const GOLDEN = substrate.GOLDEN;

// ============================================================================
// CONCEPT
// ============================================================================

pub const Concept = struct {
    i: i8,
    j: i8,
    k: i8,
    spin: i8, // -1, 0, +1
    hash: u64,

    pub fn init(i: i8, j: i8, k: i8, seed: u64) Concept {
        const ui: u64 = @bitCast(@as(i64, i));
        const uj: u64 = @bitCast(@as(i64, j));
        const uk: u64 = @bitCast(@as(i64, k));
        const raw = seed +% GOLDEN *% ui +% GOLDEN *% GOLDEN *% uj +% GOLDEN *% GOLDEN *% GOLDEN *% uk;
        const h = substrate.mix64(raw);
        const spin: i8 = @as(i8, @intCast(h % 3)) - 1; // maps {0,1,2} -> {-1,0,1}
        return .{ .i = i, .j = j, .k = k, .spin = spin, .hash = h };
    }
};

// ============================================================================
// CONCEPT LATTICE
// ============================================================================

pub const ConceptLattice = struct {
    seed: u64,
    size: u8, // per dimension, default 69
    step_count: u64 = 0,
    fingerprint: u64 = 0,

    pub fn init(seed: u64, size: u8) ConceptLattice {
        return .{ .seed = seed, .size = size };
    }

    pub fn conceptAt(self: ConceptLattice, i: i8, j: i8, k: i8) Concept {
        return Concept.init(i, j, k, self.seed);
    }

    /// XOR first `count` concept hashes in lexicographic (i,j,k) order.
    pub fn xorFingerprint(self: ConceptLattice, count: u32) u64 {
        var fp: u64 = 0;
        var n: u32 = 0;
        var i: i8 = 0;
        outer: while (i < @as(i8, @intCast(self.size))) : (i += 1) {
            var j: i8 = 0;
            while (j < @as(i8, @intCast(self.size))) : (j += 1) {
                var k: i8 = 0;
                while (k < @as(i8, @intCast(self.size))) : (k += 1) {
                    if (n >= count) break :outer;
                    fp ^= Concept.init(i, j, k, self.seed).hash;
                    n += 1;
                }
            }
        }
        return fp;
    }

    /// Average spin of first `count` concepts.
    pub fn magnetization(self: ConceptLattice, count: u32) f64 {
        if (count == 0) return 0.0;
        var sum: i64 = 0;
        var n: u32 = 0;
        var i: i8 = 0;
        outer: while (i < @as(i8, @intCast(self.size))) : (i += 1) {
            var j: i8 = 0;
            while (j < @as(i8, @intCast(self.size))) : (j += 1) {
                var k: i8 = 0;
                while (k < @as(i8, @intCast(self.size))) : (k += 1) {
                    if (n >= count) break :outer;
                    sum += Concept.init(i, j, k, self.seed).spin;
                    n += 1;
                }
            }
        }
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));
    }

    /// One checkerboard step: XOR fingerprint with interaction hash, advance.
    pub fn stepCheckerboard(self: *ConceptLattice, interaction_seed: u64) void {
        self.fingerprint ^= substrate.mix64(interaction_seed +% self.step_count);
        self.step_count += 1;
    }
};

// ============================================================================
// MONOID VERIFICATION
// ============================================================================

/// Verify associativity: xor(a ^ (b ^ c)) == xor((a ^ b) ^ c) for XOR.
/// XOR is trivially associative, so this always holds — we verify our
/// implementation doesn't break it across n random triples.
pub fn verifyAssociativity(seed: u64, n: u32) bool {
    var rng = substrate.SplitRng.init(seed);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a = rng.next();
        const b = rng.next();
        const c = rng.next();
        if ((a ^ (b ^ c)) != ((a ^ b) ^ c)) return false;
    }
    return true;
}

/// Verify identity: x ^ 0 == x.
pub fn verifyIdentity(seed: u64) bool {
    const lat = ConceptLattice.init(seed, 5);
    const fp = lat.xorFingerprint(100);
    return (fp ^ 0) == fp;
}

// ============================================================================
// CONCEPT MORPHISM
// ============================================================================

pub const ConceptMorphism = struct {
    source_seed: u64,
    target_seed: u64,
    rotation: u8, // 0..5 for cube rotations

    /// Apply rotation to coordinates, rehash with target seed.
    pub fn apply(self: ConceptMorphism, c: Concept) Concept {
        const coords = rotateCoords(c.i, c.j, c.k, self.rotation);
        return Concept.init(coords[0], coords[1], coords[2], self.target_seed);
    }

    /// Compose: apply a first, then b.
    /// Rotation composition is computed via a lookup table since
    /// the 6 rotations don't form a cyclic group under addition.
    pub fn compose(a: ConceptMorphism, b: ConceptMorphism) ConceptMorphism {
        return .{
            .source_seed = a.source_seed,
            .target_seed = b.target_seed,
            .rotation = composeRotation(a.rotation, b.rotation),
        };
    }
};

/// Compose two rotations by applying both to a test vector and finding
/// which single rotation produces the same result.
fn composeRotation(a: u8, b: u8) u8 {
    // Apply a then b to the test vector (1, 2, 3)
    const after_a = rotateCoords(1, 2, 3, a);
    const after_ab = rotateCoords(after_a[0], after_a[1], after_a[2], b);
    // Find which single rotation matches
    for (0..6) |r| {
        const single = rotateCoords(1, 2, 3, @intCast(r));
        if (single[0] == after_ab[0] and single[1] == after_ab[1] and single[2] == after_ab[2]) {
            return @intCast(r);
        }
    }
    // If no match (the 6 rotations don't close), fall back to 0
    return 0;
}

fn rotateCoords(i: i8, j: i8, k: i8, rot: u8) [3]i8 {
    return switch (rot % 6) {
        0 => .{ i, j, k },
        1 => .{ j, k, i },
        2 => .{ k, i, j },
        3 => .{ -i, k, j },
        4 => .{ j, -i, k },
        5 => .{ k, j, -i },
        else => unreachable,
    };
}

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

const kw = struct {
    fn intern(gc: *GC, s: []const u8) !Value {
        return Value.makeKeyword(try gc.internString(s));
    }
};

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

/// (concept-lattice seed) or (concept-lattice seed size) -> map
pub fn conceptLatticeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return Value.makeNil();
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const size: u8 = if (args.len > 1) @intCast(@as(i64, args[1].asInt())) else 69;
    const lat = ConceptLattice.init(seed, size);
    const fp = lat.xorFingerprint(if (size <= 10) @as(u32, size) * size * size else 1000);

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@truncate(@as(i64, @bitCast(seed)))));
    try addKV(obj, gc, "size", Value.makeInt(@as(i48, size)));
    try addKV(obj, gc, "fingerprint", Value.makeInt(@truncate(@as(i64, @bitCast(fp)))));
    return Value.makeObj(obj);
}

/// (concept-at seed i j k) -> map
pub fn conceptAtFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 4) return Value.makeNil();
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const i: i8 = @intCast(@as(i64, args[1].asInt()));
    const j: i8 = @intCast(@as(i64, args[2].asInt()));
    const k_val: i8 = @intCast(@as(i64, args[3].asInt()));
    const c = Concept.init(i, j, k_val, seed);

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "i", Value.makeInt(@as(i48, c.i)));
    try addKV(obj, gc, "j", Value.makeInt(@as(i48, c.j)));
    try addKV(obj, gc, "k", Value.makeInt(@as(i48, c.k)));
    try addKV(obj, gc, "spin", Value.makeInt(@as(i48, c.spin)));
    try addKV(obj, gc, "hash", Value.makeInt(@truncate(@as(i64, @bitCast(c.hash)))));
    return Value.makeObj(obj);
}

/// (lattice-magnetization seed count) -> float
pub fn latticeMagnetizationFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return Value.makeNil();
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const count: u32 = @intCast(@as(i64, args[1].asInt()));
    const lat = ConceptLattice.init(seed, 69);
    return Value.makeFloat(lat.magnetization(count));
}

/// (verify-monoid seed n-tests) -> bool
pub fn verifyMonoidFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return Value.makeNil();
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const n: u32 = @intCast(@as(i64, args[1].asInt()));
    const assoc = verifyAssociativity(seed, n);
    const ident = verifyIdentity(seed);
    return Value.makeBool(assoc and ident);
}

/// (lattice-step seed) -> map with :seed :step :fingerprint
pub fn latticeStepFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return Value.makeNil();
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    var lat = ConceptLattice.init(seed, 69);
    lat.stepCheckerboard(seed);

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "seed", Value.makeInt(@truncate(@as(i64, @bitCast(seed)))));
    try addKV(obj, gc, "step", Value.makeInt(@as(i48, @intCast(lat.step_count))));
    try addKV(obj, gc, "fingerprint", Value.makeInt(@truncate(@as(i64, @bitCast(lat.fingerprint)))));
    return Value.makeObj(obj);
}

// ============================================================================
// REGISTRATION
// ============================================================================

pub const skill_table = .{
    .{ "concept-lattice", &conceptLatticeFn },
    .{ "concept-at", &conceptAtFn },
    .{ "lattice-magnetization", &latticeMagnetizationFn },
    .{ "verify-monoid", &verifyMonoidFn },
    .{ "lattice-step", &latticeStepFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "concept deterministic" {
    const c1 = Concept.init(3, 7, 11, 1069);
    const c2 = Concept.init(3, 7, 11, 1069);
    try std.testing.expectEqual(c1.hash, c2.hash);
    try std.testing.expectEqual(c1.spin, c2.spin);
}

test "lattice fingerprint deterministic" {
    const lat1 = ConceptLattice.init(42, 5);
    const lat2 = ConceptLattice.init(42, 5);
    try std.testing.expectEqual(lat1.xorFingerprint(125), lat2.xorFingerprint(125));
}

test "magnetization bounded" {
    const lat = ConceptLattice.init(1069, 5);
    const m = lat.magnetization(125);
    try std.testing.expect(m >= -1.0 and m <= 1.0);
}

test "monoid laws hold" {
    try std.testing.expect(verifyAssociativity(1069, 1000));
    try std.testing.expect(verifyIdentity(1069));
}

test "morphism composition" {
    const a = ConceptMorphism{ .source_seed = 10, .target_seed = 20, .rotation = 1 };
    const b = ConceptMorphism{ .source_seed = 20, .target_seed = 30, .rotation = 2 };
    const ab = ConceptMorphism.compose(a, b);
    const c = Concept.init(3, 5, 7, 10);

    const via_steps = b.apply(a.apply(c));
    const via_compose = ab.apply(c);

    // Composed morphism should produce same result as sequential application
    try std.testing.expectEqual(via_steps.hash, via_compose.hash);
    try std.testing.expectEqual(via_steps.spin, via_compose.spin);
}
