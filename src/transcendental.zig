//! TRANSCENDENTAL IDEALISM: Kantian categories as monad transformers
//!
//! The three trans- layers (transclusion, transduction, transitivity) are
//! nanoclj-zig's transcendental apparatus — the conditions for the possibility
//! of computational experience. No value reaches the REPL without passing
//! through all three.
//!
//!   transclusion  = Space (domain structure, ⟦·⟧ meaning function)
//!   transduction  = Time  (fuel-bounded operational steps, causation)
//!   transitivity  = Identity (structural equality, GF(3) conservation)
//!
//! Kant's Table of Categories maps to monad transformers over Domain:
//!
//!   ┌───────────┬─────────────────────┬──────────────────────────────┐
//!   │ Category  │ Triad               │ Monad transformer            │
//!   ├───────────┼─────────────────────┼──────────────────────────────┤
//!   │ Quantity  │ Unity/Plural/Total  │ ListT (cons/first/rest)      │
//!   │ Quality   │ Real/Negat/Limit    │ Domain (value/⊥/error)       │
//!   │ Relation  │ Subst/Cause/Commun  │ StateT (env/fuel/inet)       │
//!   │ Modality  │ Possib/Actual/Neces │ SubstrateT (tree/bc/inet)    │
//!   └───────────┴─────────────────────┴──────────────────────────────┘
//!
//! The Schematism (CPR A137/B176): categories apply to intuitions only
//! through time-determinations. In nanoclj-zig, the schematism IS the
//! trit-tick — every fuel tick carries GF(3) phase, bridging the pure
//! categories (type-level) to the sensible manifold (runtime values).
//!
//! Antinomies arise where substrates disagree on intensional properties:
//!   1st: Finite/infinite → fuel-bounded vs unbounded (halting problem)
//!   2nd: Simple/composite → atom vs list (value decomposition)
//!   3rd: Freedom/determinism → interaction net choice vs sequential
//!   4th: Necessary being → fixed points (Y combinator, def recursion)
//!
//! The Copernican turn: it's not that values conform to substrates,
//! but that substrates conform to values. The Domain monad is the
//! transcendental unity of apperception — ALL computational experience
//! must pass through Domain.bind to reach consciousness (the REPL).

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const compat = @import("compat.zig");
const transclusion = @import("transclusion.zig");
const Domain = transclusion.Domain;
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;

// ============================================================================
// KANTIAN CATEGORIES AS COMPUTATIONAL OPERATIONS
// ============================================================================

/// The four category groups, each a triad (thesis/antithesis/synthesis).
/// GF(3) is not accidental — Kant's triadic structure IS GF(3).
pub const CategoryGroup = enum(u2) {
    quantity, // 0: how many (ListT)
    quality, // 1: what kind (Domain)
    relation, // 2: how connected (StateT)
    // modality is implicit: it's the CHOICE of substrate
};

/// Quantity: Unity(1) / Plurality(many) / Totality(all)
/// The list monad — cons builds plurality, count measures totality.
pub const Quantity = enum(u2) {
    unity, // a single value (atom)
    plurality, // a collection (list/vector)
    totality, // a measured whole (count, reduce)
};

/// Quality: Reality(+1) / Negation(-1) / Limitation(0)
/// Maps directly to GF(3) trit values.
pub const Quality = enum(i2) {
    reality = 1, // value present, affirmative
    negation = -1, // ⊥, absence, nil
    limitation = 0, // error, bounded failure
};

/// Relation: Substance / Causation / Community
/// Substance = persistent bindings (def/env)
/// Causation = sequential eval steps (fuel ticks)
/// Community = parallel interaction (inet wires)
pub const Relation = enum(u2) {
    substance, // env bindings, atoms, state
    causation, // sequential steps, let-chains, do-blocks
    community, // interaction net parallel reduction
};

// ============================================================================
// JUDGMENT: The synthetic a priori
// ============================================================================

/// A transcendental judgment: the result of applying categories to intuition.
/// This is what the REPL actually prints — not the noumenon (raw bits),
/// but the phenomenon (categorized, schematized, unified value).
pub const Judgment = struct {
    /// The phenomenon (what appears)
    domain: Domain,
    /// Which quantity structure was involved
    quantity: Quantity,
    /// GF(3) quality (reality/negation/limitation)
    quality: Quality,
    /// Which relational mode produced it
    relation: Relation,
    /// Fuel cost (the temporal schematism — time-determination)
    fuel_spent: u64,
    /// Trit balance (conservation check across the judgment)
    trit_balance: i8,

    /// The transcendental unity of apperception:
    /// "The I think must be able to accompany all my representations" (B131)
    /// In nanoclj-zig: every judgment carries its full categorical signature.
    pub fn apperceive(domain: Domain, res: *const Resources) Judgment {
        const qual: Quality = switch (domain) {
            .value => |v| if (v.isNil()) .negation else .reality,
            .bottom => .negation,
            .err => .limitation,
        };
        const quant: Quantity = switch (domain) {
            .value => |v| blk: {
                if (v.isObj()) {
                    const o = v.asObj();
                    if (o.kind == .list or o.kind == .vector or o.kind == .set) {
                        break :blk .plurality;
                    }
                    if (o.kind == .map) break :blk .plurality;
                }
                break :blk .unity;
            },
            .bottom, .err => .unity,
        };
        return .{
            .domain = domain,
            .quantity = quant,
            .quality = qual,
            .relation = if (res.depth > 0) .causation else .substance,
            .fuel_spent = res.steps_taken,
            .trit_balance = res.trit_balance,
        };
    }

    /// Is this judgment's trit balance conserved? (GF(3) = 0 mod 3)
    /// Conservation = the judgment is "transcendentally valid" —
    /// it didn't create or destroy computational charge.
    pub fn isConserved(self: *const Judgment) bool {
        return self.trit_balance == 0;
    }

    /// The antinomy detector: does this judgment contain a contradiction
    /// between its categorical determinations?
    /// E.g., quality=reality but domain=bottom (fuel said yes, resource said no)
    pub fn hasAntinomy(self: *const Judgment) bool {
        return switch (self.quality) {
            .reality => self.domain == .bottom or self.domain == .err,
            .negation => switch (self.domain) {
                .value => |v| !v.isNil(),
                else => false,
            },
            .limitation => self.domain == .value,
        };
    }
};

// ============================================================================
// ANTINOMIES: Where substrates disagree
// ============================================================================

/// The four Kantian antinomies, computationally instantiated.
pub const Antinomy = enum(u2) {
    /// 1st: Is the computational world finite or infinite?
    /// Thesis: fuel-bounded eval always terminates (finite)
    /// Antithesis: Turing completeness means some programs diverge (infinite)
    /// Resolution: the distinction is transcendental, not empirical.
    /// We can't decide from INSIDE which programs halt.
    finitude,

    /// 2nd: Is there a simplest computational element?
    /// Thesis: atoms (int, nil, bool) are simple, irreducible
    /// Antithesis: every value is a 64-bit NaN-boxed encoding (composite)
    /// Resolution: simplicity is relative to the level of description
    simplicity,

    /// 3rd: Is there freedom (non-determinism) in computation?
    /// Thesis: interaction nets have inherent parallelism (choice of reduction)
    /// Antithesis: all three substrates compute the same function (determinism)
    /// Resolution: intensional freedom is real even when extensional behavior is determined
    freedom,

    /// 4th: Is there a necessary computational being?
    /// Thesis: fixed points exist (Y combinator, recursive def)
    /// Antithesis: every computation is contingent on fuel
    /// Resolution: necessity is structural (type-level), contingency is operational
    necessity,
};

/// Detect which antinomy is active for a given computation.
pub fn detectAntinomy(domain: Domain, res: *const Resources) ?Antinomy {
    // 1st antinomy: fuel exhausted but result was partial
    if (domain == .bottom and res.fuel == 0) return .finitude;

    // 4th antinomy: recursive depth hit limit (fixed point attempt)
    if (domain == .bottom) {
        if (res.max_depth_seen >= res.limits.max_depth) return .necessity;
    }

    // 3rd antinomy: trit balance non-zero (substrate destroyed information)
    if (!res.isConserved()) return .freedom;

    // 2nd antinomy: value is both atomic and composite (NaN-boxed int)
    switch (domain) {
        .value => |v| {
            if (v.isInt() or v.isFloat()) return .simplicity; // always active for numbers
        },
        else => {},
    }

    return null;
}

// ============================================================================
// MONAD TRANSFORMERS: Stacking the categories
// ============================================================================

/// ListT over Domain: the Quantity monad transformer.
/// (list-bind xs f) = (concat (map f xs))
/// This is how Quantity structures experience: one → many → measured whole.
pub fn listBind(xs: Value, f: *const fn (Value) Domain, gc: *GC) Domain {
    if (xs.isNil()) return Domain.pure(Value.makeNil());
    if (!xs.isObj()) return f(xs); // unity: just apply

    const obj = xs.asObj();
    if (obj.kind != .list and obj.kind != .vector) return f(xs);

    const items = if (obj.kind == .list) obj.data.list.items else obj.data.vector.items;
    const result_obj = gc.allocObj(.list) catch return .{ .err = .{ .kind = .overflow } };

    for (items.items) |item| {
        const d = f(item);
        switch (d) {
            .value => |v| {
                result_obj.data.list.items.append(gc.allocator, v) catch
                    return .{ .err = .{ .kind = .collection_too_large } };
            },
            .bottom => return d, // short-circuit on ⊥
            .err => return d, // short-circuit on error
        }
    }
    return Domain.pure(Value.makeObj(result_obj));
}

/// StateT over Domain: the Relation monad transformer.
/// Threads env (substance) and resources (causation) through computation.
pub const StateT = struct {
    env: *Env,
    res: *Resources,

    /// run: unwrap the state, apply f, return (result, new_state)
    pub fn run(self: *StateT, f: *const fn (Value, *Env, *Resources) Domain, v: Value) Domain {
        return f(v, self.env, self.res);
    }
};

// ============================================================================
// SCHEMATISM: Categories → Intuitions via trit-tick time
// ============================================================================

/// The schema of a category: how it applies to the temporal manifold.
/// "The schema is nothing but the pure synthesis, determined by a rule
/// of unity according to concepts" (A142/B181)
pub const Schema = struct {
    category: CategoryGroup,
    /// Time-determination: how many trit-ticks this schema consumed
    ticks: u64,
    /// GF(3) phase at application: the temporal signature
    phase: u2, // 0, 1, or 2

    pub fn fromResources(cat: CategoryGroup, res: *const Resources) Schema {
        return .{
            .category = cat,
            .ticks = res.steps_taken,
            .phase = @intCast(@mod(res.steps_taken, 3)),
        };
    }
};

// ============================================================================
// REPL BUILTINS
// ============================================================================

/// (judge expr) → map with categorical analysis
/// Returns: {:domain <val> :quantity <q> :quality <q> :relation <r>
///           :fuel <n> :trit <n> :conserved <bool> :antinomy <a|nil>}
pub fn judgeFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const eval_mod = @import("eval.zig");
    var res = Resources.initDefault();

    // Evaluate the expression through the transcendental apparatus
    const result = eval_mod.eval(args[0], env, gc) catch Value.makeNil();
    const domain = Domain.pure(result);
    const judgment = Judgment.apperceive(domain, &res);

    // Build result map
    const obj = try gc.allocObj(.map);
    const alloc = gc.allocator;

    // :quality
    try obj.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("quality")));
    const qual_name = switch (judgment.quality) {
        .reality => "reality",
        .negation => "negation",
        .limitation => "limitation",
    };
    try obj.data.map.vals.append(alloc, Value.makeKeyword(try gc.internString(qual_name)));

    // :quantity
    try obj.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("quantity")));
    const quant_name = switch (judgment.quantity) {
        .unity => "unity",
        .plurality => "plurality",
        .totality => "totality",
    };
    try obj.data.map.vals.append(alloc, Value.makeKeyword(try gc.internString(quant_name)));

    // :relation
    try obj.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("relation")));
    const rel_name = switch (judgment.relation) {
        .substance => "substance",
        .causation => "causation",
        .community => "community",
    };
    try obj.data.map.vals.append(alloc, Value.makeKeyword(try gc.internString(rel_name)));

    // :trit
    try obj.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("trit")));
    try obj.data.map.vals.append(alloc, Value.makeInt(@intCast(judgment.trit_balance)));

    // :conserved
    try obj.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("conserved")));
    try obj.data.map.vals.append(alloc, Value.makeBool(judgment.isConserved()));

    // :antinomy
    try obj.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("antinomy")));
    const anti = detectAntinomy(domain, &res);
    if (anti) |a| {
        const anti_name = switch (a) {
            .finitude => "finitude",
            .simplicity => "simplicity",
            .freedom => "freedom",
            .necessity => "necessity",
        };
        try obj.data.map.vals.append(alloc, Value.makeKeyword(try gc.internString(anti_name)));
    } else {
        try obj.data.map.vals.append(alloc, Value.makeNil());
    }

    // :value
    try obj.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("value")));
    try obj.data.map.vals.append(alloc, result);

    return Value.makeObj(obj);
}

/// (categories) → list of all category names
pub fn categoriesFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.list);
    const alloc = gc.allocator;
    const names = [_][]const u8{
        "quantity",  "quality",   "relation",  "modality",
        "unity",     "plurality", "totality",
        "reality",   "negation",  "limitation",
        "substance", "causation", "community",
        "possible",  "actual",    "necessary",
    };
    for (names) |n| {
        try obj.data.list.items.append(alloc, Value.makeKeyword(try gc.internString(n)));
    }
    return Value.makeObj(obj);
}

/// (antinomy n) → keyword describing nth antinomy
pub fn antinomyFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or !args[0].isInt()) return error.TypeError;
    const n = args[0].asInt();
    const name = switch (n) {
        1 => "finitude: Is computation finite or infinite? (halting problem)",
        2 => "simplicity: Is there an atomic computational element? (NaN-boxing)",
        3 => "freedom: Is there non-determinism? (inet parallelism vs extensional determinism)",
        4 => "necessity: Do fixed points exist necessarily? (Y combinator vs fuel contingency)",
        else => return Value.makeNil(),
    };
    return Value.makeString(try gc.internString(name));
}

/// (phenomenon val) → the value as it appears (identity — we never see noumena)
/// This is not a no-op philosophically: it marks the boundary.
/// "Thoughts without content are empty, intuitions without concepts are blind" (A51/B75)
pub fn phenomenonFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    // The phenomenon IS the value. The noumenon is the bits we can't introspect.
    // This function's existence marks the transcendental boundary.
    return args[0];
}

/// (noumenon val) → nil (we cannot access things-in-themselves)
/// "We can have no knowledge of any object as thing in itself,
/// but only insofar as it is an object of sensible intuition" (Bxxvi)
pub fn noumenonFn(_: []Value, _: *GC, _: *Env) anyerror!Value {
    return Value.makeNil(); // always nil — the noumenon is inaccessible
}

// ============================================================================
// TESTS
// ============================================================================

test "transcendental: judgment apperception" {
    const judgment = Judgment.apperceive(
        Domain.pure(Value.makeInt(42)),
        &Resources.initDefault(),
    );
    try std.testing.expectEqual(Quality.reality, judgment.quality);
    try std.testing.expectEqual(Quantity.unity, judgment.quantity);
    try std.testing.expect(judgment.isConserved());
    try std.testing.expect(!judgment.hasAntinomy());
}

test "transcendental: nil is negation" {
    const judgment = Judgment.apperceive(
        Domain.pure(Value.makeNil()),
        &Resources.initDefault(),
    );
    try std.testing.expectEqual(Quality.negation, judgment.quality);
}

test "transcendental: bottom detects finitude antinomy" {
    var res = Resources.initDefault();
    res.fuel = 0;
    const anti = detectAntinomy(.{ .bottom = .fuel_exhausted }, &res);
    try std.testing.expectEqual(Antinomy.finitude, anti.?);
}

test "transcendental: number always has simplicity antinomy" {
    const res = Resources.initDefault();
    const anti = detectAntinomy(Domain.pure(Value.makeInt(7)), &res);
    try std.testing.expectEqual(Antinomy.simplicity, anti.?);
}

test "transcendental: schema GF(3) phase" {
    var res = Resources.initDefault();
    res.steps_taken = 7; // 7 mod 3 = 1
    const s = Schema.fromResources(.quantity, &res);
    try std.testing.expectEqual(@as(u2, 1), s.phase);
}
