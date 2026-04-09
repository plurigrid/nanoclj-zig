//! PLURALISM: At least 3 maximally oppositional alternatives for every universal class.
//!
//! Each universal class in computation has one canonical implementation.
//! Pluralism demands at least 3 alternatives that are maximally different
//! from each other — not incremental variants but oppositional worldings
//! that generate fundamentally different computational realities.
//!
//! The alternatives are not ranked. Each is a complete worldview.
//! The user selects which world they inhabit via (with-world ...).
//!
//! Inspired by: Whitehead (process), Deleuze (difference), Latour (modes of existence),
//! Stengers (cosmopolitics), Haraway (staying with the trouble).

const std = @import("std");
const Value = @import("value.zig").Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

// ============================================================================
// 1. EQUALITY — How do we know two things are the same?
// ============================================================================

pub const EqualityMode = enum(u8) {
    /// Leibniz: structural identity. Two things are equal iff they have
    /// identical structure at every level. The view from nowhere.
    /// x = y ⟺ ∀P. P(x) ↔ P(y)
    leibniz,

    /// Homotopy: path-connected identity. Two things are equal iff there
    /// exists a continuous deformation between them. Topology over structure.
    /// x = y ⟺ ∃path: x ~> y in the ambient space
    homotopy,

    /// Wittgenstein: family resemblance. Two things are equal iff they
    /// share enough overlapping features. No single essence required.
    /// x = y ⟺ overlap(features(x), features(y)) > threshold
    wittgenstein,
};

pub fn pluralEqual(a: Value, b: Value, mode: EqualityMode, gc: *GC) bool {
    switch (mode) {
        .leibniz => {
            const transitivity = @import("transitivity.zig");
            return transitivity.structuralEq(a, b, gc);
        },
        .homotopy => {
            // Path-connected: same type and coercible
            if (a.eql(b)) return true;
            // Numbers: int and float of same value are path-connected
            if (a.isInt() and b.isFloat()) {
                return @as(f64, @floatFromInt(a.asInt())) == b.asFloat();
            }
            if (a.isFloat() and b.isInt()) {
                return a.asFloat() == @as(f64, @floatFromInt(b.asInt()));
            }
            // String and keyword of same name are path-connected
            if (a.isString() and b.isKeyword()) return a.asStringId() == b.asKeywordId();
            if (a.isKeyword() and b.isString()) return a.asKeywordId() == b.asStringId();
            // nil and empty collections are path-connected
            if (a.isNil()) {
                if (b.isObj()) {
                    const obj = b.asObj();
                    return switch (obj.kind) {
                        .list => obj.data.list.items.items.len == 0,
                        .vector => obj.data.vector.items.items.len == 0,
                        .map => obj.data.map.keys.items.len == 0,
                        else => false,
                    };
                }
            }
            if (b.isNil()) return pluralEqual(b, a, .homotopy, gc);
            return false;
        },
        .wittgenstein => {
            // Family resemblance: count shared features, threshold > 0
            if (a.eql(b)) return true;
            var shared: u32 = 0;
            var total: u32 = 0;
            // Feature: same tag (both int, both string, etc.)
            total += 1;
            const a_is_num = a.isInt() or a.isFloat();
            const b_is_num = b.isInt() or b.isFloat();
            const same_tag = (a.isNil() and b.isNil()) or
                (a.isBool() and b.isBool()) or
                (a_is_num and b_is_num) or
                (a.isString() and b.isString()) or
                (a.isKeyword() and b.isKeyword()) or
                (a.isSymbol() and b.isSymbol());
            if (same_tag) shared += 1;
            // Feature: same truthiness
            total += 1;
            if (a.isTruthy() == b.isTruthy()) shared += 1;
            // Feature: both numeric
            total += 1;
            if ((a.isInt() or a.isFloat()) and (b.isInt() or b.isFloat())) shared += 1;
            // Feature: same numeric value (if applicable)
            if ((a.isInt() or a.isFloat()) and (b.isInt() or b.isFloat())) {
                total += 1;
                const af: f64 = if (a.isFloat()) a.asFloat() else @floatFromInt(a.asInt());
                const bf: f64 = if (b.isFloat()) b.asFloat() else @floatFromInt(b.asInt());
                if (af == bf) shared += 1;
            }
            // Feature: same string content (if applicable)
            if (a.isString() and b.isString()) {
                total += 1;
                if (a.asStringId() == b.asStringId()) shared += 1;
            }
            // Threshold: > 50% features shared = resemblance
            return shared * 2 > total;
        },
    }
}

// ============================================================================
// 2. HASHING — How do we index the world?
// ============================================================================

pub const HashMode = enum(u8) {
    /// FNV-1a: deterministic, uniform, fast. The industrialist's hash.
    /// Every run produces the same value. Order matters absolutely.
    fnv1a,

    /// Zobrist: positional randomized hashing. Each element gets a
    /// random key, XOR'd together. Order-independent — a set hash.
    /// The anarchist's hash: every arrangement of the same elements
    /// produces the same hash.
    zobrist,

    /// Nilpotent: everything hashes to 0. The nihilist's hash.
    /// All distinctions are illusion. Every bucket overflows equally.
    /// Forces linear probing, exposing the violence of classification.
    nilpotent,
};

pub fn pluralHash(v: Value, mode: HashMode, gc: *GC) u32 {
    switch (mode) {
        .fnv1a => {
            var h: u32 = 2166136261;
            const bytes = valueToBytes(v, gc);
            for (bytes) |byte| {
                h ^= byte;
                h *%= 16777619;
            }
            return h;
        },
        .zobrist => {
            // XOR of per-element random keys (order-independent)
            var h: u32 = 0;
            const bytes = valueToBytes(v, gc);
            for (bytes, 0..) |byte, i| {
                h ^= zobristTable(byte, @truncate(i));
            }
            return h;
        },
        .nilpotent => return 0,
    }
}

fn zobristTable(byte: u8, pos: u8) u32 {
    // Deterministic pseudo-random from byte+position
    var x: u32 = @as(u32, byte) *% 2654435761 +% @as(u32, pos) *% 2246822519;
    x ^= x >> 16;
    x *%= 2246822519;
    x ^= x >> 13;
    return x;
}

fn valueToBytes(v: Value, gc: *GC) []const u8 {
    if (v.isInt()) {
        const i = v.asInt();
        return std.mem.asBytes(&i);
    }
    if (v.isString()) {
        return gc.getString(v.asStringId());
    }
    if (v.isSymbol()) {
        return gc.getString(v.asSymbolId());
    }
    return std.mem.asBytes(&v);
}

// ============================================================================
// 3. TRUTH — What counts as true?
// ============================================================================

pub const TruthMode = enum(u8) {
    /// Classical: bivalent. Everything is true or false. Excluded middle.
    /// The logic of empire: you're with us or against us.
    classical,

    /// Intuitionistic: constructive. True only if you have a proof/witness.
    /// 0 is false, nil is false, empty collections are false (no witness).
    /// Positive integers are true (they ARE witnesses). Negatives are false
    /// (debt is not evidence). Functions are true (they construct).
    intuitionistic,

    /// Paraconsistent: dialetheia permitted. Both true AND false simultaneously.
    /// Returns a trit: -1 (false), 0 (both/neither), +1 (true).
    /// nil = both (the void contains all possibilities).
    /// 0 = both (zero is the boundary). All else: +1.
    paraconsistent,
};

pub const Trit = enum(i8) {
    false_ = -1,
    both = 0,
    true_ = 1,

    pub fn and_(a: Trit, b: Trit) Trit {
        return @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b)));
    }

    pub fn or_(a: Trit, b: Trit) Trit {
        return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
    }

    pub fn not(a: Trit) Trit {
        return @enumFromInt(-@intFromEnum(a));
    }
};

pub fn pluralTruth(v: Value, mode: TruthMode) Trit {
    switch (mode) {
        .classical => {
            if (v.isNil()) return .false_;
            if (v.isBool() and !v.asBool()) return .false_;
            return .true_;
        },
        .intuitionistic => {
            // Only constructive witnesses are true
            if (v.isNil()) return .false_;
            if (v.isBool()) return if (v.asBool()) .true_ else .false_;
            if (v.isInt()) {
                const i = v.asInt();
                if (i > 0) return .true_; // positive = witness
                return .false_; // zero and negative = no witness
            }
            if (v.isFloat()) return if (v.asFloat() > 0) .true_ else .false_;
            if (v.isObj()) {
                const obj = v.asObj();
                return switch (obj.kind) {
                    .list => if (obj.data.list.items.items.len > 0) .true_ else .false_,
                    .vector => if (obj.data.vector.items.items.len > 0) .true_ else .false_,
                    .map => if (obj.data.map.keys.items.len > 0) .true_ else .false_,
                    .function, .macro_fn, .bc_closure, .partial_fn => .true_, // constructors are witnesses
                    else => .true_,
                };
            }
            return .true_;
        },
        .paraconsistent => {
            // Dialetheia: some things are both true and false
            if (v.isNil()) return .both; // void = all possibilities
            if (v.isBool()) return if (v.asBool()) .true_ else .false_;
            if (v.isInt()) {
                const i = v.asInt();
                if (i == 0) return .both; // boundary
                return if (i > 0) .true_ else .false_;
            }
            if (v.isFloat()) {
                const f = v.asFloat();
                if (f == 0.0 or f != f) return .both; // zero or NaN = both
                return if (f > 0) .true_ else .false_;
            }
            return .true_;
        },
    }
}

// ============================================================================
// 4. ORDERING — How do things compare?
// ============================================================================

pub const OrderMode = enum(u8) {
    /// Total: every pair is comparable. The world as a ladder.
    /// Numbers < strings < keywords < symbols < collections.
    total,

    /// Partial: some things are incomparable. The world as a forest.
    /// Only same-type values can be compared. Cross-type → incomparable.
    partial,

    /// Preorder: reflexive and transitive but not antisymmetric.
    /// Multiple things can occupy the same rank. The world as strata.
    /// Everything is compared by "weight" (count of sub-elements).
    preorder,
};

pub const Comparison = enum(i8) {
    less = -1,
    equal = 0,
    greater = 1,
    incomparable = 2, // only in partial order

    pub fn isLess(self: Comparison) bool {
        return self == .less;
    }

    pub fn isGreater(self: Comparison) bool {
        return self == .greater;
    }
};

pub fn pluralCompare(a: Value, b: Value, mode: OrderMode) Comparison {
    switch (mode) {
        .total => {
            // Type ordering: nil < bool < int < float < string < keyword < symbol < obj
            const ta = typeRank(a);
            const tb = typeRank(b);
            if (ta != tb) return if (ta < tb) .less else .greater;
            // Same type: compare values
            if (a.isInt() and b.isInt()) {
                const ai = a.asInt();
                const bi = b.asInt();
                return if (ai < bi) .less else if (ai > bi) .greater else .equal;
            }
            if (a.isFloat() and b.isFloat()) {
                const af = a.asFloat();
                const bf = b.asFloat();
                return if (af < bf) .less else if (af > bf) .greater else .equal;
            }
            return .equal;
        },
        .partial => {
            // Only same type (both int, both float, etc.)
            const same = (a.isInt() and b.isInt()) or
                (a.isFloat() and b.isFloat()) or
                (a.isString() and b.isString()) or
                (a.isNil() and b.isNil());
            if (!same) return .incomparable;
            if (a.isInt() and b.isInt()) {
                const ai = a.asInt();
                const bi = b.asInt();
                return if (ai < bi) .less else if (ai > bi) .greater else .equal;
            }
            return .incomparable;
        },
        .preorder => {
            // Compare by weight (element count)
            const wa = valueWeight(a);
            const wb = valueWeight(b);
            return if (wa < wb) .less else if (wa > wb) .greater else .equal;
        },
    }
}

fn typeRank(v: Value) u8 {
    if (v.isNil()) return 0;
    if (v.isBool()) return 1;
    if (v.isInt()) return 2;
    if (v.isFloat()) return 3;
    if (v.isString()) return 4;
    if (v.isKeyword()) return 5;
    if (v.isSymbol()) return 6;
    return 7;
}

fn valueWeight(v: Value) u32 {
    if (v.isNil()) return 0;
    if (v.isBool()) return 1;
    if (v.isInt()) return 1;
    if (v.isFloat()) return 1;
    if (v.isString()) return 1;
    if (v.isObj()) {
        const obj = v.asObj();
        return switch (obj.kind) {
            .list => @intCast(obj.data.list.items.items.len),
            .vector => @intCast(obj.data.vector.items.items.len),
            .map => @intCast(obj.data.map.keys.items.len),
            else => 1,
        };
    }
    return 1;
}

// ============================================================================
// 5. COLLECTION SEMANTICS — How do aggregates behave?
// ============================================================================

pub const CollectionMode = enum(u8) {
    /// Persistent: structural sharing, immutable by default.
    /// Okasaki's world: the past is always accessible.
    /// Time is a tree of versions.
    persistent,

    /// Ephemeral: mutable, no history. The performative world.
    /// Mutation is the only reality. Memory is finite.
    /// (Already supported via transients, but as first-class mode.)
    ephemeral,

    /// Confluent: merge-friendly, CRDT-like. The collaborative world.
    /// Any two versions can be merged. Conflict is generative.
    /// conj on two divergent copies produces their union.
    confluent,
};

// ============================================================================
// 6. EVALUATION STRATEGY — When do we compute?
// ============================================================================

pub const EvalStrategy = enum(u8) {
    /// Strict: evaluate arguments before calling. The eager world.
    /// What you see is what you get. No surprises. No laziness.
    strict,

    /// Lazy: evaluate only when needed. The procrastinator's world.
    /// Infinite structures are natural. Nothing happens until observed.
    lazy,

    /// Speculative: evaluate everything in parallel, discard unneeded.
    /// The optimist's world: assume everything will be needed.
    /// (On single thread: evaluate both branches of if, return correct one.)
    speculative,
};

// ============================================================================
// 7. NUMBER SYSTEM — What counts as a number?
// ============================================================================

pub const NumberMode = enum(u8) {
    /// IEEE 754: floating point. The engineer's world.
    /// Fast, imprecise, NaN exists. 0.1 + 0.2 != 0.3.
    ieee754,

    /// Exact rational: numerator/denominator pairs. The mathematician's world.
    /// 1/3 is exact. No rounding. Slow but correct.
    rational,

    /// p-adic: distance measured by divisibility. The number theorist's world.
    /// Numbers close together if their difference is divisible by large powers of p.
    /// 1 + 2 + 4 + 8 + ... = -1 (2-adically). Ultrametric topology.
    padic,
};

// ============================================================================
// 8. LOGIC CONNECTIVES — How do we combine propositions?
// ============================================================================

pub const LogicMode = enum(u8) {
    /// Boolean: AND/OR/NOT with short-circuit. Standard.
    boolean,

    /// Linear: every resource used exactly once. No copying, no discarding.
    /// (and a b) consumes both a and b. Can't use a again after.
    /// The ecologist's logic: nothing is free, everything has a cost.
    linear,

    /// Relevant: premises must be relevant to conclusions.
    /// (and a b) → a is valid only if b was actually needed.
    /// The pragmatist's logic: don't import what you don't use.
    relevant,
};

// ============================================================================
// 9. ERROR HANDLING — What happens when things go wrong?
// ============================================================================

pub const ErrorMode = enum(u8) {
    /// Exception: throw/catch, stack unwinding. The dramatist's errors.
    /// Failure is a crisis. Control flow jumps. Someone must catch it.
    exception,

    /// Result: Either/Maybe types. The bureaucrat's errors.
    /// Failure is a value. You must explicitly handle it or propagate.
    /// No surprises, no hidden control flow.
    result,

    /// Recovery: conditions and restarts (Common Lisp style).
    /// Failure is a negotiation. The handler can suggest a restart,
    /// the caller decides how to proceed. The diplomat's errors.
    recovery,
};

// ============================================================================
// 10. IDENTITY — What makes something the same thing over time?
// ============================================================================

pub const IdentityMode = enum(u8) {
    /// Referential: identity = memory address. Two pointers to the same
    /// object are identical. The physicalist's identity.
    referential,

    /// Narrative: identity = history of changes. Two things with the
    /// same change history are identical even if at different addresses.
    /// The historian's identity.
    narrative,

    /// Functional: identity = behavior under all inputs. Two things
    /// are identical iff they produce the same outputs for all inputs.
    /// The extensionalist's identity. (Undecidable in general.)
    functional,
};

// ============================================================================
// WORLD — The composite of all choices
// ============================================================================

pub const World = struct {
    equality: EqualityMode = .leibniz,
    hash: HashMode = .fnv1a,
    truth: TruthMode = .classical,
    order: OrderMode = .total,
    collection: CollectionMode = .persistent,
    eval_strategy: EvalStrategy = .strict,
    numbers: NumberMode = .ieee754,
    logic: LogicMode = .boolean,
    errors: ErrorMode = .exception,
    identity: IdentityMode = .referential,

    /// The default world: the canonical computational monoculture.
    pub const standard = World{};

    /// The constructivist world: intuitionistic logic, exact numbers,
    /// lazy evaluation, result-based errors, narrative identity.
    pub const constructivist = World{
        .equality = .homotopy,
        .truth = .intuitionistic,
        .eval_strategy = .lazy,
        .numbers = .rational,
        .errors = .result,
        .identity = .narrative,
    };

    /// The anarchist world: paraconsistent logic, nilpotent hash,
    /// confluent collections, Wittgenstein equality, preorder.
    pub const anarchist = World{
        .equality = .wittgenstein,
        .hash = .nilpotent,
        .truth = .paraconsistent,
        .order = .preorder,
        .collection = .confluent,
        .logic = .relevant,
        .errors = .recovery,
        .identity = .functional,
    };

    /// The speculative world: eager evaluation of all paths,
    /// zobrist hashing, linear logic (resource-aware).
    pub const speculative = World{
        .hash = .zobrist,
        .eval_strategy = .speculative,
        .logic = .linear,
        .numbers = .padic,
    };
};

// Current world (thread-local in future, global for now)
var current_world: World = World.standard;

pub fn getWorld() *const World {
    return &current_world;
}

pub fn setWorld(w: World) void {
    current_world = w;
}

// ============================================================================
// BUILTINS for Clojure interface
// ============================================================================

/// (set-world! :standard) or (set-world! :constructivist) etc.
pub fn setWorldFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isKeyword()) return error.TypeError;
    const name = gc.getString(args[0].asKeywordId());
    if (std.mem.eql(u8, name, "standard")) {
        current_world = World.standard;
    } else if (std.mem.eql(u8, name, "constructivist")) {
        current_world = World.constructivist;
    } else if (std.mem.eql(u8, name, "anarchist")) {
        current_world = World.anarchist;
    } else if (std.mem.eql(u8, name, "speculative")) {
        current_world = World.speculative;
    } else return error.TypeError;
    return Value.makeKeyword(args[0].asKeywordId());
}

/// (current-world) — returns keyword naming active world
pub fn currentWorldFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const w = &current_world;
    const name = if (std.meta.eql(w.*, World.standard))
        "standard"
    else if (std.meta.eql(w.*, World.constructivist))
        "constructivist"
    else if (std.meta.eql(w.*, World.anarchist))
        "anarchist"
    else if (std.meta.eql(w.*, World.speculative))
        "speculative"
    else
        "custom";
    return Value.makeKeyword(try gc.internString(name));
}

/// (plural-equal? a b) — compare using current world's equality mode
pub fn pluralEqualFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return Value.makeBool(pluralEqual(args[0], args[1], current_world.equality, gc));
}

/// (plural-compare a b) — compare using current world's ordering
pub fn pluralCompareFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const result = pluralCompare(args[0], args[1], current_world.order);
    return Value.makeInt(@intFromEnum(result));
}

/// (trit v) — evaluate truthiness using current world's logic
pub fn tritFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const t = pluralTruth(args[0], current_world.truth);
    return Value.makeInt(@intFromEnum(t));
}

/// (plural-hash v) — hash using current world's hash mode
pub fn pluralHashFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeInt(@intCast(pluralHash(args[0], current_world.hash, gc)));
}

// ============================================================================
// TESTS
// ============================================================================

test "pluralism: leibniz equality" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try std.testing.expect(pluralEqual(Value.makeInt(42), Value.makeInt(42), .leibniz, &gc));
    try std.testing.expect(!pluralEqual(Value.makeInt(42), Value.makeInt(43), .leibniz, &gc));
}

test "pluralism: homotopy equality (int/float path)" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try std.testing.expect(pluralEqual(Value.makeInt(42), Value.makeFloat(42.0), .homotopy, &gc));
    try std.testing.expect(!pluralEqual(Value.makeInt(42), Value.makeFloat(42.5), .homotopy, &gc));
}

test "pluralism: wittgenstein equality (family resemblance)" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    // Same int: all features match
    try std.testing.expect(pluralEqual(Value.makeInt(42), Value.makeInt(42), .wittgenstein, &gc));
    // Different ints: share type, truthiness, numeric-ness (3/4 features) → resemblance
    try std.testing.expect(pluralEqual(Value.makeInt(42), Value.makeInt(43), .wittgenstein, &gc));
    // Int vs nil: share nothing except both exist
    try std.testing.expect(!pluralEqual(Value.makeInt(42), Value.makeNil(), .wittgenstein, &gc));
}

test "pluralism: classical truth" {
    try std.testing.expectEqual(Trit.false_, pluralTruth(Value.makeNil(), .classical));
    try std.testing.expectEqual(Trit.true_, pluralTruth(Value.makeInt(0), .classical));
    try std.testing.expectEqual(Trit.true_, pluralTruth(Value.makeInt(42), .classical));
}

test "pluralism: intuitionistic truth" {
    try std.testing.expectEqual(Trit.false_, pluralTruth(Value.makeNil(), .intuitionistic));
    try std.testing.expectEqual(Trit.false_, pluralTruth(Value.makeInt(0), .intuitionistic));
    try std.testing.expectEqual(Trit.false_, pluralTruth(Value.makeInt(-1), .intuitionistic));
    try std.testing.expectEqual(Trit.true_, pluralTruth(Value.makeInt(1), .intuitionistic));
}

test "pluralism: paraconsistent truth" {
    try std.testing.expectEqual(Trit.both, pluralTruth(Value.makeNil(), .paraconsistent));
    try std.testing.expectEqual(Trit.both, pluralTruth(Value.makeInt(0), .paraconsistent));
    try std.testing.expectEqual(Trit.true_, pluralTruth(Value.makeInt(42), .paraconsistent));
    try std.testing.expectEqual(Trit.false_, pluralTruth(Value.makeInt(-1), .paraconsistent));
}

test "pluralism: trit algebra" {
    try std.testing.expectEqual(Trit.false_, Trit.and_(.true_, .false_));
    try std.testing.expectEqual(Trit.both, Trit.and_(.true_, .both));
    try std.testing.expectEqual(Trit.true_, Trit.or_(.false_, .true_));
    try std.testing.expectEqual(Trit.both, Trit.or_(.false_, .both));
    try std.testing.expectEqual(Trit.false_, Trit.not(.true_));
    try std.testing.expectEqual(Trit.both, Trit.not(.both));
}

test "pluralism: total order" {
    try std.testing.expectEqual(Comparison.less, pluralCompare(Value.makeInt(1), Value.makeInt(2), .total));
    try std.testing.expectEqual(Comparison.greater, pluralCompare(Value.makeInt(2), Value.makeInt(1), .total));
    try std.testing.expectEqual(Comparison.equal, pluralCompare(Value.makeInt(1), Value.makeInt(1), .total));
    // cross-type: int < string
    try std.testing.expectEqual(Comparison.less, pluralCompare(Value.makeInt(1), Value.makeString(0), .total));
}

test "pluralism: partial order — cross-type incomparable" {
    try std.testing.expectEqual(Comparison.incomparable, pluralCompare(Value.makeInt(1), Value.makeString(0), .partial));
}

test "pluralism: fnv1a hash deterministic" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    const h1 = pluralHash(Value.makeInt(42), .fnv1a, &gc);
    const h2 = pluralHash(Value.makeInt(42), .fnv1a, &gc);
    try std.testing.expectEqual(h1, h2);
}

test "pluralism: nilpotent hash always zero" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try std.testing.expectEqual(@as(u32, 0), pluralHash(Value.makeInt(42), .nilpotent, &gc));
    try std.testing.expectEqual(@as(u32, 0), pluralHash(Value.makeInt(99), .nilpotent, &gc));
}

test "pluralism: zobrist hash order-independent property" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    // Same value should produce same hash
    const h1 = pluralHash(Value.makeInt(42), .zobrist, &gc);
    const h2 = pluralHash(Value.makeInt(42), .zobrist, &gc);
    try std.testing.expectEqual(h1, h2);
}

test "pluralism: world presets" {
    try std.testing.expectEqual(EqualityMode.leibniz, World.standard.equality);
    try std.testing.expectEqual(EqualityMode.homotopy, World.constructivist.equality);
    try std.testing.expectEqual(EqualityMode.wittgenstein, World.anarchist.equality);
    try std.testing.expectEqual(TruthMode.classical, World.standard.truth);
    try std.testing.expectEqual(TruthMode.intuitionistic, World.constructivist.truth);
    try std.testing.expectEqual(TruthMode.paraconsistent, World.anarchist.truth);
}
