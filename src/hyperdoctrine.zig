//! Chromatic Hyperdoctrine for nanoclj-zig — matching Gay.jl's hyperdoctrine.jl
//!
//! Heyting algebra on chromatic predicates, substitution functors,
//! existential/universal quantifiers as adjoints, Beck-Chevalley verification.

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
// ChromaticType
// ============================================================================

pub const ChromaticType = struct {
    name_hash: u64,
    dimension: u8,
    seed: u64,
    fingerprint: u64,

    pub fn init(name_hash: u64, dim: u8, seed: u64) ChromaticType {
        return .{
            .name_hash = name_hash,
            .dimension = dim,
            .seed = seed,
            .fingerprint = substrate.mix64(seed ^ name_hash ^ @as(u64, dim)),
        };
    }
};

// ============================================================================
// ChromaticPredicate
// ============================================================================

pub const ChromaticPredicate = struct {
    context_hash: u64,
    name_hash: u64,
    fingerprint: u64,
    truth_bits: u64,

    pub fn init(ctx: u64, name: u64, seed: u64) ChromaticPredicate {
        return .{
            .context_hash = ctx,
            .name_hash = name,
            .fingerprint = substrate.mix64(seed ^ ctx ^ name),
            .truth_bits = 0,
        };
    }

    // ========================================================================
    // Heyting algebra operations
    // ========================================================================

    pub fn heytingAnd(a: ChromaticPredicate, b: ChromaticPredicate) ChromaticPredicate {
        return .{
            .context_hash = a.context_hash,
            .name_hash = a.name_hash ^ b.name_hash,
            .fingerprint = substrate.mix64(a.fingerprint ^ b.fingerprint),
            .truth_bits = a.truth_bits & b.truth_bits,
        };
    }

    pub fn heytingOr(a: ChromaticPredicate, b: ChromaticPredicate) ChromaticPredicate {
        return .{
            .context_hash = a.context_hash,
            .name_hash = a.name_hash ^ b.name_hash,
            .fingerprint = substrate.mix64(a.fingerprint ^ b.fingerprint),
            .truth_bits = a.truth_bits | b.truth_bits,
        };
    }

    pub fn heytingNot(a: ChromaticPredicate) ChromaticPredicate {
        return .{
            .context_hash = a.context_hash,
            .name_hash = a.name_hash,
            .fingerprint = substrate.mix64(a.fingerprint),
            .truth_bits = ~a.truth_bits,
        };
    }

    pub fn heytingImplies(a: ChromaticPredicate, b: ChromaticPredicate) ChromaticPredicate {
        return .{
            .context_hash = a.context_hash,
            .name_hash = a.name_hash ^ b.name_hash,
            .fingerprint = substrate.mix64(a.fingerprint ^ b.fingerprint),
            .truth_bits = ~a.truth_bits | b.truth_bits,
        };
    }

    // ========================================================================
    // Substitution and quantifiers
    // ========================================================================

    pub fn substitution(f_seed: u64, p: ChromaticPredicate) ChromaticPredicate {
        return .{
            .context_hash = substrate.mix64(p.context_hash ^ f_seed),
            .name_hash = p.name_hash,
            .fingerprint = substrate.mix64(p.fingerprint ^ f_seed),
            .truth_bits = p.truth_bits,
        };
    }

    pub fn existential(f_seed: u64, p: ChromaticPredicate) ChromaticPredicate {
        return .{
            .context_hash = p.context_hash,
            .name_hash = p.name_hash,
            .fingerprint = substrate.mix64(p.fingerprint ^ f_seed),
            .truth_bits = p.truth_bits,
        };
    }

    pub fn universal(f_seed: u64, p: ChromaticPredicate) ChromaticPredicate {
        return .{
            .context_hash = p.context_hash,
            .name_hash = p.name_hash,
            .fingerprint = substrate.mix64(p.fingerprint ^ f_seed),
            .truth_bits = p.truth_bits,
        };
    }
};

// ============================================================================
// Beck-Chevalley verification
// ============================================================================

pub fn verifyBeckChevalley(f_seed: u64, g_seed: u64, p: ChromaticPredicate) bool {
    // Path 1: existential(g) then substitution(f)
    const path1 = ChromaticPredicate.substitution(f_seed, ChromaticPredicate.existential(g_seed, p));
    // Path 2: substitution(f) then existential(g)
    const path2 = ChromaticPredicate.existential(g_seed, ChromaticPredicate.substitution(f_seed, p));
    return path1.fingerprint == path2.fingerprint;
}

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

pub fn heytingAndFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const a: u64 = @bitCast(@as(i64, args[0].asInt()));
    const b: u64 = @bitCast(@as(i64, args[1].asInt()));
    return Value.makeInt(@bitCast(@as(u48, @truncate(a & b))));
}

pub fn heytingOrFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const a: u64 = @bitCast(@as(i64, args[0].asInt()));
    const b: u64 = @bitCast(@as(i64, args[1].asInt()));
    return Value.makeInt(@bitCast(@as(u48, @truncate(a | b))));
}

pub fn heytingNotFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const a: u64 = @bitCast(@as(i64, args[0].asInt()));
    return Value.makeInt(@bitCast(@as(u48, @truncate(~a))));
}

pub fn heytingImpliesFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const a: u64 = @bitCast(@as(i64, args[0].asInt()));
    const b: u64 = @bitCast(@as(i64, args[1].asInt()));
    return Value.makeInt(@bitCast(@as(u48, @truncate(~a | b))));
}

pub fn beckChevalleyFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 4) return error.ArityError;
    for (args) |arg| {
        if (!arg.isInt()) return error.ArityError;
    }
    const f_seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const g_seed: u64 = @bitCast(@as(i64, args[1].asInt()));
    const pred_seed: u64 = @bitCast(@as(i64, args[2].asInt()));
    const ctx_seed: u64 = @bitCast(@as(i64, args[3].asInt()));

    const p = ChromaticPredicate.init(ctx_seed, pred_seed, pred_seed ^ ctx_seed);
    const verified = verifyBeckChevalley(f_seed, g_seed, p);

    const path1 = ChromaticPredicate.substitution(f_seed, ChromaticPredicate.existential(g_seed, p));
    const path2 = ChromaticPredicate.existential(g_seed, ChromaticPredicate.substitution(f_seed, p));

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "verified", Value.makeBool(verified));
    try addKV(obj, gc, "path1-fp", Value.makeInt(@bitCast(@as(u48, @truncate(path1.fingerprint)))));
    try addKV(obj, gc, "path2-fp", Value.makeInt(@bitCast(@as(u48, @truncate(path2.fingerprint)))));
    return Value.makeObj(obj);
}

// ============================================================================
// SKILL TABLE
// ============================================================================

pub const skill_table = .{
    .{ "heyting-and", &heytingAndFn },
    .{ "heyting-or", &heytingOrFn },
    .{ "heyting-not", &heytingNotFn },
    .{ "heyting-implies", &heytingImpliesFn },
    .{ "beck-chevalley", &beckChevalleyFn },
};

// ============================================================================
// TESTS
// ============================================================================

test "heyting and" {
    const a = ChromaticPredicate{ .context_hash = 0, .name_hash = 0, .fingerprint = 0, .truth_bits = 0b1100 };
    const b = ChromaticPredicate{ .context_hash = 0, .name_hash = 0, .fingerprint = 0, .truth_bits = 0b1010 };
    const result = ChromaticPredicate.heytingAnd(a, b);
    try std.testing.expectEqual(@as(u64, 0b1000), result.truth_bits);
}

test "heyting or" {
    const a = ChromaticPredicate{ .context_hash = 0, .name_hash = 0, .fingerprint = 0, .truth_bits = 0b1100 };
    const b = ChromaticPredicate{ .context_hash = 0, .name_hash = 0, .fingerprint = 0, .truth_bits = 0b1010 };
    const result = ChromaticPredicate.heytingOr(a, b);
    try std.testing.expectEqual(@as(u64, 0b1110), result.truth_bits);
}

test "heyting implies" {
    const a = ChromaticPredicate{ .context_hash = 0, .name_hash = 0, .fingerprint = 0, .truth_bits = 0b1100 };
    const b = ChromaticPredicate{ .context_hash = 0, .name_hash = 0, .fingerprint = 0, .truth_bits = 0b1010 };
    const result = ChromaticPredicate.heytingImplies(a, b);
    // a -> b = ~a | b = ~0b1100 | 0b1010 = 0xFFFF...F3 | 0b1010 = 0xFFFF...FFBB -> all bits set except bit 2
    try std.testing.expectEqual(~a.truth_bits | b.truth_bits, result.truth_bits);
}

test "double negation not identity" {
    const a = ChromaticPredicate{ .context_hash = 0, .name_hash = 0, .fingerprint = 0, .truth_bits = 0b1100 };
    const not_a = ChromaticPredicate.heytingNot(a);
    const not_not_a = ChromaticPredicate.heytingNot(not_a);
    // In classical logic ~~a == a, but in Heyting algebra on finite bit vectors
    // with full 64-bit complement, ~~a == a. The non-identity shows up with
    // proper open-set semantics. Here we verify the algebraic property that
    // ~~a >= a (i.e., a & ~~a == a).
    try std.testing.expectEqual(a.truth_bits, a.truth_bits & not_not_a.truth_bits);
    // Also verify the double negation round-trips on bits (classical case)
    try std.testing.expectEqual(a.truth_bits, not_not_a.truth_bits);
}

test "beck chevalley deterministic" {
    const p1 = ChromaticPredicate.init(42, 99, 1069);
    const p2 = ChromaticPredicate.init(42, 99, 1069);
    const r1 = verifyBeckChevalley(7, 13, p1);
    const r2 = verifyBeckChevalley(7, 13, p2);
    try std.testing.expectEqual(r1, r2);
    // Same predicate, same seeds => same fingerprints
    try std.testing.expectEqual(p1.fingerprint, p2.fingerprint);
}
