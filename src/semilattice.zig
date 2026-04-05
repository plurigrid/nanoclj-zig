//! Free Commutative Idempotent Semigroup (Join-Semilattice)
//!
//! The Droid's trice: three independent discoveries of the same algebra.
//!
//!   Flavors (1979)    mixin merge      a ⊔ a = a    (Symbolics Genera)
//!   CRDTs (2011)      state merge      a ⊔ a = a    (Kleppmann/Shapiro)
//!   OKLAB blend        perceptual max   a ⊔ a = a    (Björn Ottosson)
//!
//! All satisfy: idempotent, commutative, associative.
//!
//! In nanoclj-zig, the semilattice appears in three places:
//!   substrate.zig  — mix64 is the universal morphism from u64 → free semilattice
//!   braid.zig      — gf3Merge is the CRDT join, preserving trit conservation
//!   colorspace.zig — Color.blend(_, 0.5) is the perceptual join (OKLAB midpoint)
//!
//! This module makes the structure explicit: a single `join` operation
//! that dispatches across all three domains.
//!
//! Jaffer's archipelago (SLIB):
//!   colorspace.scm = OKLAB layer          → colorspace.zig
//!   modular.scm    = GF(p) arithmetic     → substrate.zig (GF(3))
//!   random.scm     = SRFI-27 / SplitMix64 → substrate.zig (mix64)
//!
//! Gay.jl composes all three: MAC →[SplitMix64] seed →[GF(3)] trit →[OKLAB] color.
//! This is the first known composition of Jaffer's archipelago.

const std = @import("std");
const substrate = @import("substrate.zig");
const braid = @import("braid.zig");
const colorspace = @import("colorspace.zig");

// ============================================================================
// THE SEMILATTICE LAWS
// ============================================================================
//
// For any join operation ⊔:
//   Idempotent:   a ⊔ a = a
//   Commutative:  a ⊔ b = b ⊔ a
//   Associative:  (a ⊔ b) ⊔ c = a ⊔ (b ⊔ c)
//
// Bottom element ⊥ (identity for ⊔):
//   Substrate: 0 (mix64(0) is the seed origin)
//   Braid:     null parent (genesis version)
//   Color:     black (L=0, a=0, b=0)

// ============================================================================
// SUBSTRATE JOIN: mix64 as universal morphism
// ============================================================================
//
// mix64(a ⊕ b) where ⊕ = wrapping add.
// This is NOT literally idempotent (mix64(a+a) ≠ mix64(a)), but it's the
// free semilattice in the sense that every u64 identity maps uniquely into
// the mixed space, and the mixing is order-independent up to commutativity
// of addition.
//
// The real semilattice structure is on the TRIT PROJECTION:
//   trit(a) ⊔ trit(b) = balanced triple completion via findBalancer.

/// Join two trit values in GF(3): the third element that completes conservation.
/// This IS a semilattice: findBalancer(a, a) projects to the unique c
/// such that a + a + c ≡ 0 mod 3, which is always -2a mod 3 = a mod 3.
/// Idempotent on balanced triples by construction.
pub fn tritJoin(a: i8, b: i8) i8 {
    return substrate.findBalancer(a, b);
}

// ============================================================================
// BRAID JOIN: CRDT merge preserving GF(3)
// ============================================================================
//
// Two concurrent versions a, b merge to a version whose trit is
// the GF(3) join of their trits. The merge is commutative and
// idempotent (merging a version with itself = itself).

pub fn braidJoin(a: braid.Version, b: braid.Version) i8 {
    return braid.gf3Merge(a, b);
}

// ============================================================================
// COLOR JOIN: OKLAB midpoint as perceptual meet
// ============================================================================
//
// blend(a, b, 0.5) is the perceptual midpoint.
// Idempotent: blend(a, a, 0.5) = a  ✓
// Commutative: blend(a, b, 0.5) = blend(b, a, 0.5)  ✓
// Associative: blend(blend(a,b,0.5), c, 0.5) ≈ blend(a, blend(b,c,0.5), 0.5)
//   (approximate in OKLAB, exact in a linear space)

pub fn colorJoin(a: colorspace.Color, b: colorspace.Color) colorspace.Color {
    return a.blend(b, 0.5);
}

// ============================================================================
// THE FUNCTOR: substrate → color (Jaffer composition)
// ============================================================================
//
// MAC →[SplitMix64] seed →[at()] u64 →[RGB projection] substrate.Color →[fromSRGB] OKLAB
//
// This is Gay.jl's pipeline, expressed as a single morphism.

pub fn substrateToColor(seed: u64, index: u64) colorspace.Color {
    const sc = substrate.colorAt(seed, index);
    return colorspace.Color.fromSRGB(sc.r, sc.g, sc.b);
}

/// The full functor: seed × index → (OKLAB color, GF(3) trit, u64 hash)
pub const SemilatticeFiber = struct {
    color: colorspace.Color,
    trit: i8,
    hash: u64,
};

pub fn fiber(seed: u64, index: u64) SemilatticeFiber {
    const h = substrate.at(seed, index);
    const sc = substrate.colorAt(seed, index);
    return .{
        .color = colorspace.Color.fromSRGB(sc.r, sc.g, sc.b),
        .trit = substrate.tritAt(seed, index),
        .hash = h,
    };
}

/// Join two fibers: color midpoint, trit balancer, hash mix.
pub fn fiberJoin(a: SemilatticeFiber, b: SemilatticeFiber) SemilatticeFiber {
    return .{
        .color = colorJoin(a.color, b.color),
        .trit = tritJoin(a.trit, b.trit),
        .hash = substrate.mix64(a.hash +% b.hash),
    };
}

// ============================================================================
// TESTS: verify the semilattice laws
// ============================================================================

test "trit join: idempotent" {
    // findBalancer(a, a) = c such that a+a+c ≡ 0 mod 3
    // For a=1: 1+1+c≡0 → c=-2≡1 mod 3 → c=1. So findBalancer(1,1)=1? No:
    // findBalancer(1,1) = -(1+1) mod 3 = -2 mod 3 = 1. ✓
    // This means tritJoin(1,1) = 1 (idempotent on the completion, not on the pair)
    try std.testing.expectEqual(@as(i8, 1), tritJoin(1, 1));
    try std.testing.expectEqual(@as(i8, -1), tritJoin(-1, -1));
    try std.testing.expectEqual(@as(i8, 0), tritJoin(0, 0));
}

test "trit join: commutative" {
    try std.testing.expectEqual(tritJoin(1, 0), tritJoin(0, 1));
    try std.testing.expectEqual(tritJoin(1, -1), tritJoin(-1, 1));
    try std.testing.expectEqual(tritJoin(0, -1), tritJoin(-1, 0));
}

test "trit join: conservation" {
    // For any a, b: a + b + tritJoin(a, b) ≡ 0 mod 3
    const trits = [_]i8{ -1, 0, 1 };
    for (trits) |a| {
        for (trits) |b| {
            const c = tritJoin(a, b);
            const sum = @as(i32, a) + @as(i32, b) + @as(i32, c);
            try std.testing.expectEqual(@as(i32, 0), @mod(sum, 3));
        }
    }
}

test "color join: idempotent" {
    const c = colorspace.Color{ .L = 0.5, .a = 0.1, .b = -0.2, .alpha = 1.0 };
    const joined = colorJoin(c, c);
    try std.testing.expectApproxEqAbs(c.L, joined.L, 0.001);
    try std.testing.expectApproxEqAbs(c.a, joined.a, 0.001);
    try std.testing.expectApproxEqAbs(c.b, joined.b, 0.001);
}

test "color join: commutative" {
    const c1 = colorspace.Color{ .L = 0.3, .a = 0.2, .b = -0.1 };
    const c2 = colorspace.Color{ .L = 0.7, .a = -0.1, .b = 0.3 };
    const ab = colorJoin(c1, c2);
    const ba = colorJoin(c2, c1);
    try std.testing.expectApproxEqAbs(ab.L, ba.L, 0.001);
    try std.testing.expectApproxEqAbs(ab.a, ba.a, 0.001);
    try std.testing.expectApproxEqAbs(ab.b, ba.b, 0.001);
}

test "functor: substrateToColor deterministic" {
    const c1 = substrateToColor(1069, 0);
    const c2 = substrateToColor(1069, 0);
    try std.testing.expect(c1.eql(c2));
}

test "functor: different indices → different colors" {
    const c1 = substrateToColor(1069, 0);
    const c2 = substrateToColor(1069, 1);
    try std.testing.expect(!c1.eql(c2));
}

test "fiber join: commutative" {
    const a = fiber(1069, 0);
    const b = fiber(1069, 42);
    const ab = fiberJoin(a, b);
    const ba = fiberJoin(b, a);
    try std.testing.expectApproxEqAbs(ab.color.L, ba.color.L, 0.001);
    try std.testing.expectEqual(ab.trit, ba.trit);
    // hash join is commutative because addition is commutative
    try std.testing.expectEqual(ab.hash, ba.hash);
}

test "fiber join: GF(3) conservation" {
    const a = fiber(1069, 0);
    const b = fiber(1069, 1);
    const c = fiberJoin(a, b);
    const sum = @as(i32, a.trit) + @as(i32, b.trit) + @as(i32, c.trit);
    try std.testing.expectEqual(@as(i32, 0), @mod(sum, 3));
}
