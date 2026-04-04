//! COMPUTABLE SETS, REDUCTIONS, AND GUIDELINE AUDITOR
//!
//! Extends church_turing.zig with:
//!   1. Computable sets as first-class objects (characteristic functions)
//!   2. Many-one reductions A ≤_m B with verification
//!   3. Weihrauch degrees (fine structure of non-computability)
//!   4. Guideline auditor: any "open" or "permanent" guideline is tested
//!      against the decidability hierarchy. Claims that require solving
//!      HALT-hard problems are flagged as dishonest.
//!
//! Recent results implemented:
//!   - Quantum channel capacity undecidability (2601.22471)
//!   - AI alignment undecidability via Rice (Nature Sci Rep 2025)
//!   - Computable bases / Galois connection (Brattka-Rauzy 2510.09850)
//!   - Weihrauch lattice (Dagstuhl 25131)

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const substrate = @import("substrate.zig");

// ============================================================================
// COMPUTABLE SETS
// ============================================================================

/// A computable set over i48, defined by its characteristic function.
/// χ_S(n) always halts and returns true/false.
pub const ComputableSetKind = enum(u8) {
    evens,
    odds,
    primes,
    squares,
    multiples, // parametric: multiples of k
    complement,
    union_set,
    intersection_set,
    symmetric_diff,
    custom, // user-defined via nanoclj predicate
};

/// Built-in characteristic functions — total, always halt.
fn isEven(n: i48) bool {
    return @mod(n, 2) == 0;
}

fn isOdd(n: i48) bool {
    return @mod(n, 2) != 0;
}

fn isPrime(n: i48) bool {
    if (n < 2) return false;
    if (n < 4) return true;
    if (@mod(n, 2) == 0) return false;
    var i: i48 = 3;
    while (i * i <= n) : (i += 2) {
        if (@mod(n, i) == 0) return false;
    }
    return true;
}

fn isSquare(n: i48) bool {
    if (n < 0) return false;
    const s = @as(i48, @intFromFloat(@sqrt(@as(f64, @floatFromInt(n)))));
    return s * s == n;
}

fn isMultipleOf(n: i48, k: i48) bool {
    if (k == 0) return n == 0;
    return @mod(n, k) == 0;
}

/// Enumerate members of a computable set up to bound.
fn enumerateSet(kind: ComputableSetKind, param: i48, bound: i48, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(i48) {
    var result: std.ArrayListUnmanaged(i48) = compat.emptyList(i48);
    var n: i48 = 0;
    while (n < bound) : (n += 1) {
        const member = switch (kind) {
            .evens => isEven(n),
            .odds => isOdd(n),
            .primes => isPrime(n),
            .squares => isSquare(n),
            .multiples => isMultipleOf(n, param),
            else => false,
        };
        if (member) try result.append(allocator, n);
    }
    return result;
}

/// Natural density approximation: |S ∩ [0,n)| / n
fn density(kind: ComputableSetKind, param: i48, n: i48) f64 {
    if (n <= 0) return 0.0;
    var count: i48 = 0;
    var i: i48 = 0;
    while (i < n) : (i += 1) {
        const member = switch (kind) {
            .evens => isEven(i),
            .odds => isOdd(i),
            .primes => isPrime(i),
            .squares => isSquare(i),
            .multiples => isMultipleOf(i, param),
            else => false,
        };
        if (member) count += 1;
    }
    return @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(n));
}

// ============================================================================
// MANY-ONE REDUCTIONS  A ≤_m B
// ============================================================================

/// A reduction is a computable function f such that x ∈ A ⟺ f(x) ∈ B.
pub const ReductionKind = enum(u8) {
    /// Map yes→0, no→1 (reduces any decidable set to evens)
    to_evens,
    /// Map yes→0, no→3 (reduces any decidable set to squares)
    to_squares,
    /// Identity (A ≤_m A, trivial)
    identity,
    /// Composition of two reductions (transitivity)
    composed,
};

/// Verify a reduction: for all x in [0, bound), x ∈ source ⟺ f(x) ∈ target.
fn verifyReduction(
    source_kind: ComputableSetKind,
    source_param: i48,
    target_kind: ComputableSetKind,
    target_param: i48,
    reduction: ReductionKind,
    bound: i48,
) bool {
    var x: i48 = 0;
    while (x < bound) : (x += 1) {
        const in_source = switch (source_kind) {
            .evens => isEven(x),
            .odds => isOdd(x),
            .primes => isPrime(x),
            .squares => isSquare(x),
            .multiples => isMultipleOf(x, source_param),
            else => false,
        };
        const fx = switch (reduction) {
            .to_evens => if (in_source) @as(i48, 0) else @as(i48, 1),
            .to_squares => if (in_source) @as(i48, 0) else @as(i48, 3),
            .identity => x,
            .composed => if (in_source) @as(i48, 0) else @as(i48, 1),
        };
        const in_target = switch (target_kind) {
            .evens => isEven(fx),
            .odds => isOdd(fx),
            .primes => isPrime(fx),
            .squares => isSquare(fx),
            .multiples => isMultipleOf(fx, target_param),
            else => false,
        };
        if (in_source != in_target) return false;
    }
    return true;
}

// ============================================================================
// WEIHRAUCH DEGREES
// ============================================================================

/// Position in the Weihrauch lattice — fine-grained non-computability.
pub const WeihrauchDegree = enum(u8) {
    computable,     // id: always solvable
    lpo,            // Limited Principle of Omniscience
    llpo,           // Lesser LPO
    ivt,            // Intermediate Value Theorem
    wkl,            // Weak König's Lemma
    bwt,            // Bolzano-Weierstrass
    halt,           // Halting problem
    beyond_halt,    // Σ⁰₂ and above

    pub fn description(self: WeihrauchDegree) []const u8 {
        return switch (self) {
            .computable => "computable: always solvable, no oracle needed",
            .lpo => "LPO: is this infinite sequence all zeros?",
            .llpo => "LLPO: which of two sequences has a 1 first?",
            .ivt => "IVT-hard: needs bisection/binary search oracle",
            .wkl => "WKL-hard: needs infinite backtracking oracle",
            .bwt => "BWT-hard: needs accumulation point oracle",
            .halt => "HALT-hard: genuinely impossible (diagonal argument)",
            .beyond_halt => "Beyond HALT: Σ⁰₂+ (iterated halting oracle needed)",
        };
    }

    pub fn isDecidable(self: WeihrauchDegree) bool {
        return self == .computable;
    }

    pub fn requiresOracle(self: WeihrauchDegree) bool {
        return @intFromEnum(self) >= @intFromEnum(WeihrauchDegree.lpo);
    }

    pub fn isImpossible(self: WeihrauchDegree) bool {
        return @intFromEnum(self) >= @intFromEnum(WeihrauchDegree.halt);
    }
};

// ============================================================================
// GUIDELINE AUDITOR
//
// Any guideline that claims to be "open" or "permanent" makes implicit
// computability claims. This auditor classifies those claims against
// the Weihrauch lattice and flags the dishonest ones.
//
// From the four frontiers:
//   - Rice: "verify all programs satisfy property P" → HALT-hard
//   - Quantum capacity: "compute optimal channel use" → beyond HALT
//   - Alignment: "ensure AI is aligned" → HALT-hard (Rice)
//   - Spectral gap: "determine if system is gapped" → HALT-hard
//
// A guideline claiming to solve any of these "permanently" is lying.
// An honest guideline states its Weihrauch degree and what oracle it assumes.
// ============================================================================

pub const GuidelineClaim = enum(u8) {
    /// "All implementations will satisfy property P"
    universal_semantic_property,
    /// "This standard is permanent and complete"
    permanent_completeness,
    /// "Compliance can always be verified"
    universal_compliance_check,
    /// "This covers all edge cases"
    total_coverage,
    /// "Membership in this category is always decidable"
    decidable_membership,
    /// "This process will always terminate"
    guaranteed_termination,
    /// "This approximation converges"
    convergence_claim,
    /// "This is open for extension"
    open_extension,
};

pub const AuditResult = struct {
    claim: GuidelineClaim,
    weihrauch_degree: WeihrauchDegree,
    honest: bool,
    fix: []const u8,
    theorem: []const u8,
};

/// Audit a guideline claim against the decidability hierarchy.
pub fn auditClaim(claim: GuidelineClaim) AuditResult {
    return switch (claim) {
        .universal_semantic_property => .{
            .claim = claim,
            .weihrauch_degree = .halt,
            .honest = false,
            .fix = "restrict to syntactic properties or provably-halting programs (alignment paper fix)",
            .theorem = "Rice's theorem: all nontrivial semantic properties are undecidable",
        },
        .permanent_completeness => .{
            .claim = claim,
            .weihrauch_degree = .beyond_halt,
            .honest = false,
            .fix = "version the guideline; state what oracle/approximation scheme is assumed",
            .theorem = "Godel's incompleteness: no consistent system is complete",
        },
        .universal_compliance_check => .{
            .claim = claim,
            .weihrauch_degree = .halt,
            .honest = false,
            .fix = "restrict compliance to decidable (syntactic) checks; flag semantic checks as approximate",
            .theorem = "Rice's theorem + spectral gap undecidability (Cubitt et al.)",
        },
        .total_coverage => .{
            .claim = claim,
            .weihrauch_degree = .beyond_halt,
            .honest = false,
            .fix = "enumerate covered cases explicitly; state the coverage is c.e., not computable",
            .theorem = "halting problem: can't decide all cases; channel capacity undecidability (Bhattacharyya et al.)",
        },
        .decidable_membership => .{
            .claim = claim,
            .weihrauch_degree = .computable,
            .honest = true,
            .fix = "already honest — provide the characteristic function",
            .theorem = "definition of computable set: chi_S is total",
        },
        .guaranteed_termination => .{
            .claim = claim,
            .weihrauch_degree = .halt,
            .honest = false,
            .fix = "use primitive recursive bounds or fuel limits; state the bound explicitly",
            .theorem = "halting problem (diagonal argument)",
        },
        .convergence_claim => .{
            .claim = claim,
            .weihrauch_degree = .ivt,
            .honest = true, // if they provide the modulus of convergence
            .fix = "state the modulus of convergence; IVT-hard problems need bisection oracle",
            .theorem = "Brattka-Rauzy: admissible iff Galois connection has fixed point",
        },
        .open_extension => .{
            .claim = claim,
            .weihrauch_degree = .wkl,
            .honest = true, // if they acknowledge the search is c.e.
            .fix = "openness = c.e. extension; you can add but can't decide what's missing (Post's theorem)",
            .theorem = "Post's theorem: computable = c.e. ∩ co-c.e.; openness without closure = semi-decidable",
        },
    };
}

// ============================================================================
// NANOCLJ BUILTINS
// ============================================================================

/// (computable-set kind) → enumerate members up to 100
/// kind: "evens" | "odds" | "primes" | "squares" | "mult-of-N"
pub fn computableSetFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const name = gc.getString(args[0].asStringId());
    const bound: i48 = if (args.len > 1 and args[1].isInt()) args[1].asInt() else 100;

    var kind: ComputableSetKind = .evens;
    var param: i48 = 0;

    if (std.mem.eql(u8, name, "evens")) {
        kind = .evens;
    } else if (std.mem.eql(u8, name, "odds")) {
        kind = .odds;
    } else if (std.mem.eql(u8, name, "primes")) {
        kind = .primes;
    } else if (std.mem.eql(u8, name, "squares")) {
        kind = .squares;
    } else if (std.mem.startsWith(u8, name, "mult-of-")) {
        kind = .multiples;
        param = std.fmt.parseInt(i48, name[8..], 10) catch 2;
    } else {
        return error.TypeError;
    }

    var members = try enumerateSet(kind, param, bound, gc.allocator);
    defer members.deinit(gc.allocator);

    // Return as vector
    const obj = try gc.allocObj(.vector);
    for (members.items) |m| {
        try obj.data.vector.items.append(gc.allocator, Value.makeInt(m));
    }
    return Value.makeObj(obj);
}

/// (set-density kind n) → float density approximation
pub fn setDensityFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    if (!args[1].isInt()) return error.TypeError;

    const name = gc.getString(args[0].asStringId());
    const n = args[1].asInt();

    var kind: ComputableSetKind = .evens;
    var param: i48 = 0;

    if (std.mem.eql(u8, name, "evens")) {
        kind = .evens;
    } else if (std.mem.eql(u8, name, "odds")) {
        kind = .odds;
    } else if (std.mem.eql(u8, name, "primes")) {
        kind = .primes;
    } else if (std.mem.eql(u8, name, "squares")) {
        kind = .squares;
    } else if (std.mem.startsWith(u8, name, "mult-of-")) {
        kind = .multiples;
        param = std.fmt.parseInt(i48, name[8..], 10) catch 2;
    }

    return Value.makeFloat(density(kind, param, n));
}

/// (reduce-verify source target bound) → bool
/// Verify that source ≤_m target via canonical reduction, for all x < bound.
pub fn reduceVerifyFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isString() or !args[2].isInt())
        return error.TypeError;

    const source_name = gc.getString(args[0].asStringId());
    const target_name = gc.getString(args[1].asStringId());
    const bound = args[2].asInt();

    const source_kind: ComputableSetKind = if (std.mem.eql(u8, source_name, "evens")) .evens
        else if (std.mem.eql(u8, source_name, "primes")) .primes
        else if (std.mem.eql(u8, source_name, "squares")) .squares
        else .odds;

    const target_kind: ComputableSetKind = if (std.mem.eql(u8, target_name, "evens")) .evens
        else if (std.mem.eql(u8, target_name, "squares")) .squares
        else .odds;

    const reduction: ReductionKind = if (target_kind == .evens) .to_evens
        else if (target_kind == .squares) .to_squares
        else .identity;

    return Value.makeBool(verifyReduction(source_kind, 0, target_kind, 0, reduction, bound));
}

/// (weihrauch-degree problem) → map with degree info
/// problem: "ivt" | "halting" | "spectral-gap" | "channel-capacity" | "alignment" | "tiling"
pub fn weihrauchDegreeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const name = gc.getString(args[0].asStringId());

    const degree: WeihrauchDegree = if (std.mem.eql(u8, name, "even-membership")) .computable
        else if (std.mem.eql(u8, name, "prime-membership")) .computable
        else if (std.mem.eql(u8, name, "ivt")) .ivt
        else if (std.mem.eql(u8, name, "wkl")) .wkl
        else if (std.mem.eql(u8, name, "halting")) .halt
        else if (std.mem.eql(u8, name, "spectral-gap")) .halt
        else if (std.mem.eql(u8, name, "alignment")) .halt
        else if (std.mem.eql(u8, name, "tiling")) .halt
        else if (std.mem.eql(u8, name, "channel-capacity")) .halt
        else .computable;

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "problem"));
    try obj.data.map.vals.append(gc.allocator, args[0]);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "degree"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intFromEnum(degree)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "decidable?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(degree.isDecidable()));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "impossible?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(degree.isImpossible()));

    const desc_id = try gc.internString(degree.description());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "description"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(desc_id));

    return Value.makeObj(obj);
}

/// (audit-guideline claim) → map with audit result
/// claim: "universal-semantic" | "permanent" | "compliance" | "coverage" |
///        "membership" | "termination" | "convergence" | "open"
pub fn auditGuidelineFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const name = gc.getString(args[0].asStringId());

    const claim: GuidelineClaim = if (std.mem.eql(u8, name, "universal-semantic")) .universal_semantic_property
        else if (std.mem.eql(u8, name, "permanent")) .permanent_completeness
        else if (std.mem.eql(u8, name, "compliance")) .universal_compliance_check
        else if (std.mem.eql(u8, name, "coverage")) .total_coverage
        else if (std.mem.eql(u8, name, "membership")) .decidable_membership
        else if (std.mem.eql(u8, name, "termination")) .guaranteed_termination
        else if (std.mem.eql(u8, name, "convergence")) .convergence_claim
        else if (std.mem.eql(u8, name, "open")) .open_extension
        else return error.TypeError;

    const result = auditClaim(claim);

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "claim"));
    try obj.data.map.vals.append(gc.allocator, args[0]);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "degree"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intFromEnum(result.weihrauch_degree)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "honest?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(result.honest));

    const fix_id = try gc.internString(result.fix);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "fix"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(fix_id));

    const thm_id = try gc.internString(result.theorem);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "theorem"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(thm_id));

    const deg_desc = try gc.internString(result.weihrauch_degree.description());
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "degree-description"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(deg_desc));

    return Value.makeObj(obj);
}

/// (audit-all-guidelines) → vector of all audit results
/// Audits every claim type. The meta-guideline: a guideline about guidelines.
pub fn auditAllGuidelinesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const obj = try gc.allocObj(.vector);
    const claims = [_]GuidelineClaim{
        .universal_semantic_property,
        .permanent_completeness,
        .universal_compliance_check,
        .total_coverage,
        .decidable_membership,
        .guaranteed_termination,
        .convergence_claim,
        .open_extension,
    };
    const claim_names = [_][]const u8{
        "universal-semantic",
        "permanent",
        "compliance",
        "coverage",
        "membership",
        "termination",
        "convergence",
        "open",
    };

    for (claims, 0..) |claim, i| {
        const result = auditClaim(claim);
        const entry = try gc.allocObj(.map);
        const kw = struct {
            fn intern(g: *GC, s: []const u8) !Value {
                return Value.makeKeyword(try g.internString(s));
            }
        };

        const name_id = try gc.internString(claim_names[i]);
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "claim"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(name_id));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "honest?"));
        try entry.data.map.vals.append(gc.allocator, Value.makeBool(result.honest));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "degree"));
        try entry.data.map.vals.append(gc.allocator, Value.makeInt(@intFromEnum(result.weihrauch_degree)));

        const fix_id = try gc.internString(result.fix);
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "fix"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(fix_id));

        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }
    return Value.makeObj(obj);
}

// ============================================================================
// ARITHMETICAL HIERARCHY BUILTINS
// ============================================================================

const HierarchyLevel = struct {
    class: enum(u8) { sigma, pi, delta },
    n: u8,

    fn trit(self: @This()) i8 {
        return switch (self.class) {
            .sigma => 1,
            .pi => -1,
            .delta => 0,
        };
    }

    fn label(self: @This()) []const u8 {
        if (self.class == .delta and self.n <= 1) return "decidable";
        if (self.class == .sigma and self.n == 1) return "c.e. (semidecidable)";
        if (self.class == .pi and self.n == 1) return "co-c.e.";
        if (self.class == .sigma and self.n == 2) return "limit-computable";
        if (self.class == .pi and self.n == 2) return "co-limit-computable";
        return "higher";
    }
};

const DELTA_1 = HierarchyLevel{ .class = .delta, .n = 1 };
const SIGMA_1 = HierarchyLevel{ .class = .sigma, .n = 1 };
const PI_1 = HierarchyLevel{ .class = .pi, .n = 1 };
const SIGMA_2 = HierarchyLevel{ .class = .sigma, .n = 2 };
const PI_2 = HierarchyLevel{ .class = .pi, .n = 2 };

const ProblemEntry = struct { name: []const u8, level: HierarchyLevel, reduces_from: ?[]const u8 };

const problem_table = [_]ProblemEntry{
    .{ .name = "even-membership", .level = DELTA_1, .reduces_from = null },
    .{ .name = "prime-membership", .level = DELTA_1, .reduces_from = null },
    .{ .name = "regex-match", .level = DELTA_1, .reduces_from = null },
    .{ .name = "halting", .level = SIGMA_1, .reduces_from = null },
    .{ .name = "provability", .level = SIGMA_1, .reduces_from = "halting" },
    .{ .name = "diophantine", .level = SIGMA_1, .reduces_from = "halting" },
    .{ .name = "wang-tiling", .level = SIGMA_1, .reduces_from = "halting" },
    .{ .name = "channel-capacity", .level = SIGMA_1, .reduces_from = "wang-tiling" },
    .{ .name = "alignment", .level = SIGMA_1, .reduces_from = "halting" },
    .{ .name = "spectral-gap", .level = SIGMA_1, .reduces_from = "halting" },
    .{ .name = "totality", .level = PI_1, .reduces_from = null },
    .{ .name = "goldbach", .level = PI_1, .reduces_from = null },
    .{ .name = "infinity", .level = SIGMA_2, .reduces_from = "halting" },
    .{ .name = "completeness", .level = SIGMA_2, .reduces_from = null },
    .{ .name = "cofinality", .level = PI_2, .reduces_from = null },
};

fn findProblem(name: []const u8) ?ProblemEntry {
    for (&problem_table) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p.*;
    }
    return null;
}

/// (classify-problem name) → {:class "sigma" :n 1 :trit +1 :label "c.e."}
pub fn classifyProblemFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const name = gc.getString(args[0].asStringId());
    const p = findProblem(name) orelse return error.TypeError;

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    const class_str: []const u8 = switch (p.level.class) {
        .sigma => "sigma",
        .pi => "pi",
        .delta => "delta",
    };
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "class"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(class_str)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "n"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(p.level.n)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, p.level.trit()))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "label"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(p.level.label())));
    if (p.reduces_from) |rf| {
        try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "reduces-from"));
        try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(rf)));
    }
    return Value.makeObj(obj);
}

/// (detect-morphism source target) → {:kind "embedding" :source-trit +1 :target-trit -1 :trit-sum 0}
pub fn detectMorphismFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2 or !args[0].isString() or !args[1].isString()) return error.ArityError;
    const src_name = gc.getString(args[0].asStringId());
    const tgt_name = gc.getString(args[1].asStringId());
    const src = findProblem(src_name) orelse return error.TypeError;
    const tgt = findProblem(tgt_name) orelse return error.TypeError;

    const same_level = src.level.class == tgt.level.class and src.level.n == tgt.level.n;

    // Check reduction witness
    var has_reduction = false;
    if (src.reduces_from) |rf| {
        if (std.mem.eql(u8, rf, tgt_name)) has_reduction = true;
    }
    if (tgt.reduces_from) |rf| {
        if (std.mem.eql(u8, rf, src_name)) has_reduction = true;
    }

    const kind: []const u8 = if (same_level and has_reduction)
        "isomorphism"
    else if (same_level)
        "gf3-bridge"
    else if (src.level.n <= tgt.level.n)
        "embedding"
    else
        "collapse";

    const trit_sum = @mod(@as(i8, src.level.trit()) + tgt.level.trit() + 3, 3);

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "kind"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(kind)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "source-trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, src.level.trit()))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "target-trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, tgt.level.trit()))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit-sum"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, trit_sum))));
    if (has_reduction) {
        try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "reduction-witness"));
        try obj.data.map.vals.append(gc.allocator, Value.makeBool(true));
    }
    return Value.makeObj(obj);
}

/// (list-problems) → vector of all classified problem names
pub fn listProblemsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const obj = try gc.allocObj(.vector);
    for (&problem_table) |*p| {
        try obj.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(p.name)));
    }
    return Value.makeObj(obj);
}

// ============================================================================
// MÖBIUS INVERSION & REALIZABILITY
// ============================================================================

fn isPrimeImpl(n: i48) bool {
    if (n < 2) return false;
    if (n < 4) return true;
    if (@mod(n, 2) == 0 or @mod(n, 3) == 0) return false;
    var d: i48 = 5;
    while (d * d <= n) : (d += 2) {
        if (@mod(n, d) == 0) return false;
        d += 1;
        if (d * d <= n and @mod(n, d) == 0) return false;
    }
    return true;
}

fn mobiusFn_impl(n: i48) i48 {
    if (n <= 0) return 0;
    if (n == 1) return 1;
    var val: u32 = @intCast(n);
    var num_factors: u8 = 0;
    var d: u32 = 2;
    while (d * d <= val) : (d += 1) {
        if (val % d == 0) {
            val /= d;
            if (val % d == 0) return 0;
            num_factors += 1;
        }
    }
    if (val > 1) num_factors += 1;
    return if (num_factors % 2 == 0) @as(i48, 1) else @as(i48, -1);
}

fn mertens_impl(n: i48) i48 {
    var sum: i48 = 0;
    var k: i48 = 1;
    while (k <= n) : (k += 1) {
        sum += mobiusFn_impl(k);
    }
    return sum;
}

fn mertensTritImpl(n: i48) i48 {
    const m = mertens_impl(n);
    const r = @mod(m + 300, 3);
    return if (r == 2) @as(i48, -1) else r;
}

/// (mobius n) → μ(n) ∈ {-1, 0, 1}
pub fn mobiusBuiltinFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    return Value.makeInt(mobiusFn_impl(args[0].asInt()));
}

/// (mertens n) → M(n) = Σ_{k=1}^{n} μ(k)
pub fn mertensBuiltinFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    return Value.makeInt(mertens_impl(args[0].asInt()));
}

/// (moebius-boundary) → {:exclusive-mertens M(1068) :inclusive-mertens M(1069) :flips? true}
pub fn moebiusBoundaryFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const seed: i48 = @intCast(substrate.CANONICAL_SEED);
    const excl = mertens_impl(seed - 1);
    const incl = mertens_impl(seed);
    // Map mod 3 to GF(3): {0→0, 1→+1, 2→-1}
    const excl_r = @mod(excl + 300, 3);
    const excl_trit: i48 = if (excl_r == 2) -1 else excl_r;
    const incl_r = @mod(incl + 300, 3);
    const incl_trit: i48 = if (incl_r == 2) -1 else incl_r;

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "seed"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(seed));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "exclusive-mertens"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(excl));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inclusive-mertens"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(incl));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "exclusive-trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(excl_trit));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "inclusive-trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(incl_trit));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "flips?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(excl_trit != incl_trit));

    // Flip index: count primes p ≤ seed where Mertens trit flips Π→Σ
    var flip_count: i48 = 0;
    var flip_index: i48 = -1;
    var p: i48 = 2;
    while (p <= seed) : (p += 1) {
        if (!isPrimeImpl(p)) continue;
        const pt = mertensTritImpl(p - 1);
        const qt = mertensTritImpl(p);
        if (pt == -1 and qt == 1) {
            if (p == seed) flip_index = flip_count;
            flip_count += 1;
        }
    }
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "flip-index"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(if (flip_index >= 0) flip_index else flip_count));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "total-flip-primes"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(flip_count));
    return Value.makeObj(obj);
}

/// (flip-primes n) → vector of primes p ≤ n where Mertens trit flips Π→Σ
pub fn flipPrimesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or !args[0].isInt()) return error.ArityError;
    const bound = args[0].asInt();
    if (bound < 2) return Value.makeNil();
    const obj = try gc.allocObj(.vector);
    var p: i48 = 2;
    while (p <= bound) : (p += 1) {
        if (!isPrimeImpl(p)) continue;
        if (mertensTritImpl(p - 1) == -1 and mertensTritImpl(p) == 1) {
            try obj.data.vector.items.append(gc.allocator, Value.makeInt(p));
        }
    }
    return Value.makeObj(obj);
}

/// (morphism-graph) → vector of {:source s :target t :kind k :trit-sum n} for all problem pairs
pub fn morphismGraphFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const obj = try gc.allocObj(.vector);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    for (&problem_table, 0..) |*src, i| {
        for (&problem_table, 0..) |*tgt, j| {
            if (i == j) continue;
            const same_level = src.level.class == tgt.level.class and src.level.n == tgt.level.n;
            var has_reduction = false;
            if (src.reduces_from) |rf| {
                if (std.mem.eql(u8, rf, tgt.name)) has_reduction = true;
            }
            if (tgt.reduces_from) |rf| {
                if (std.mem.eql(u8, rf, src.name)) has_reduction = true;
            }
            // Only emit edges with a witness or same-level bridge
            if (!has_reduction and !same_level) continue;
            const kind: []const u8 = if (same_level and has_reduction)
                "isomorphism"
            else if (same_level)
                "gf3-bridge"
            else if (src.level.n <= tgt.level.n)
                "embedding"
            else
                "collapse";
            const trit_sum: i48 = @mod(@as(i48, src.level.trit()) + @as(i48, tgt.level.trit()) + 3, 3);
            const edge = try gc.allocObj(.map);
            try edge.data.map.keys.append(gc.allocator, try kw.intern(gc, "source"));
            try edge.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(src.name)));
            try edge.data.map.keys.append(gc.allocator, try kw.intern(gc, "target"));
            try edge.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(tgt.name)));
            try edge.data.map.keys.append(gc.allocator, try kw.intern(gc, "kind"));
            try edge.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(kind)));
            try edge.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit-sum"));
            try edge.data.map.vals.append(gc.allocator, Value.makeInt(trit_sum));
            try obj.data.vector.items.append(gc.allocator, Value.makeObj(edge));
        }
    }
    return Value.makeObj(obj);
}

// ============================================================================
// GORARD ORDINAL TOWER
// ============================================================================

const GorardEntry = struct { index: u8, ordinal: []const u8, system: []const u8, causal: []const u8, trit: i48 };

const gorard_tower = [_]GorardEntry{
    .{ .index = 0, .ordinal = "omega", .system = "RCA_0", .causal = "finite causal diamond", .trit = 1 },
    .{ .index = 1, .ordinal = "omega^omega", .system = "RCA_0", .causal = "primitive recursive causal depth", .trit = -1 },
    .{ .index = 2, .ordinal = "omega^omega^omega", .system = "WKL_0", .causal = "compactness (infinite branch accumulation)", .trit = 1 },
    .{ .index = 3, .ordinal = "epsilon_0", .system = "ACA_0", .causal = "Peano-complete causal invariance (Gentzen)", .trit = -1 },
    .{ .index = 4, .ordinal = "Gamma_0", .system = "ATR_0", .causal = "predicative transfinite induction along causal WO", .trit = 1 },
    .{ .index = 5, .ordinal = "psi(Omega_omega)", .system = "Pi11-CA_0", .causal = "impredicative causal graph minor theorem", .trit = -1 },
    .{ .index = 6, .ordinal = "theta(Omega^omega*omega)", .system = "beyond", .causal = "TREE-scale causal branching (Friedman)", .trit = 0 },
};

/// (gorard-tower) → vector of {:index n :ordinal str :system str :causal str :trit n}
pub fn gorardTowerFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    const obj = try gc.allocObj(.vector);
    for (&gorard_tower) |*level| {
        const entry = try gc.allocObj(.map);
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "index"));
        try entry.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(level.index)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "ordinal"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(level.ordinal)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "system"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(level.system)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "causal"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(level.causal)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
        try entry.data.map.vals.append(gc.allocator, Value.makeInt(level.trit));
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }
    return Value.makeObj(obj);
}

/// (gorard-trit-sum) → GF(3) conservation check of the tower
pub fn gorardTritSumFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    _ = args;
    var sum: i48 = 0;
    for (&gorard_tower) |*level| {
        sum += level.trit;
    }
    return Value.makeInt(@mod(sum + 300, 3));
}

// ============================================================================
// DIOPHANTINE EQUATIONS
// ============================================================================

fn isqrt(n: u64) u64 {
    if (n == 0) return 0;
    var x = std.math.sqrt(n);
    while (x * x > n) x -= 1;
    while ((x + 1) * (x + 1) <= n) x += 1;
    return x;
}

/// (pythagorean-triples bound) → vector of [a b c] triples with a≤b, c≤bound
pub fn pythagoreanTriplesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return Value.makeNil();
    const bound_val = if (args[0].isInt()) args[0].asInt() else return Value.makeNil();
    if (bound_val <= 0) return Value.makeNil();
    const bound: u32 = @intCast(@min(bound_val, 10000));

    const obj = try gc.allocObj(.vector);
    var m: u32 = 2;
    while (m * m < bound) : (m += 1) {
        var n: u32 = 1;
        while (n < m) : (n += 1) {
            if ((m - n) % 2 == 1 and std.math.gcd(m, n) == 1) {
                const a = m * m - n * n;
                const b = 2 * m * n;
                const c = m * m + n * n;
                if (c <= bound) {
                    const triple = try gc.allocObj(.vector);
                    const a_min = @min(a, b);
                    const b_max = @max(a, b);
                    try triple.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(a_min)));
                    try triple.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(b_max)));
                    try triple.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(c)));
                    try obj.data.vector.items.append(gc.allocator, Value.makeObj(triple));
                }
            }
        }
    }
    return Value.makeObj(obj);
}

/// (pell-solve D) → {:x n :y m} fundamental solution of x²-Dy²=1, or nil
pub fn pellSolveFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return Value.makeNil();
    const d_val = if (args[0].isInt()) args[0].asInt() else return Value.makeNil();
    if (d_val < 2) return Value.makeNil();
    const D: u64 = @intCast(d_val);

    const sqrt_D = isqrt(D);
    if (sqrt_D * sqrt_D == D) return Value.makeNil(); // perfect square

    // Continued fraction expansion of √D
    var m: u64 = 0;
    var d: u64 = 1;
    var a: u64 = sqrt_D;
    const a0 = a;
    var p_prev: u64 = 1;
    var p_curr: u64 = a;
    var q_prev: u64 = 0;
    var q_curr: u64 = 1;

    for (0..2000) |_| {
        m = d * a - m;
        d = (D - m * m) / d;
        if (d == 0) return Value.makeNil();
        a = (a0 + m) / d;

        const p_next = a * p_curr + p_prev;
        const q_next = a * q_curr + q_prev;
        p_prev = p_curr;
        p_curr = p_next;
        q_prev = q_curr;
        q_curr = q_next;

        if (p_curr * p_curr == D * q_curr * q_curr + 1) {
            const obj = try gc.allocObj(.map);
            const kw = struct {
                fn intern(g: *GC, s: []const u8) !Value {
                    return Value.makeKeyword(try g.internString(s));
                }
            };
            try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "x"));
            try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(p_curr)));
            try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "y"));
            try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(q_curr)));
            try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "D"));
            try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(D)));
            try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "verify"));
            const verify: i48 = @intCast(p_curr * p_curr - D * q_curr * q_curr);
            try obj.data.map.vals.append(gc.allocator, Value.makeInt(verify));
            return Value.makeObj(obj);
        }
    }
    return Value.makeNil();
}

/// (markov-triples bound) → vector of [a b c] with a²+b²+c²=3abc, a≤b≤c≤bound
pub fn markovTriplesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return Value.makeNil();
    const bound_val = if (args[0].isInt()) args[0].asInt() else return Value.makeNil();
    if (bound_val <= 0) return Value.makeNil();
    const bound: u32 = @intCast(@min(bound_val, 500));

    const obj = try gc.allocObj(.vector);
    var a: u64 = 1;
    while (a <= bound) : (a += 1) {
        var b: u64 = a;
        while (b <= bound) : (b += 1) {
            var c: u64 = b;
            while (c <= bound) : (c += 1) {
                const lhs = a * a + b * b + c * c;
                const rhs = 3 * a * b * c;
                if (lhs == rhs) {
                    const triple = try gc.allocObj(.vector);
                    try triple.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(a)));
                    try triple.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(b)));
                    try triple.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(c)));
                    try obj.data.vector.items.append(gc.allocator, Value.makeObj(triple));
                }
            }
        }
    }
    return Value.makeObj(obj);
}

/// (rh-check bound) → vector of {:x n :pi π(n) :li Li(n) :error |π-Li| :bound C√n·ln(n) :ok? bool}
pub fn rhCheckFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return Value.makeNil();
    const bound_val = if (args[0].isInt()) args[0].asInt() else return Value.makeNil();
    if (bound_val < 10) return Value.makeNil();
    const bound: u32 = @intCast(@min(bound_val, 1000000));

    // Sieve primes
    const sieve = try gc.allocator.alloc(bool, bound + 1);
    defer gc.allocator.free(sieve);
    @memset(sieve, true);
    sieve[0] = false;
    if (bound >= 1) sieve[1] = false;
    var i: u32 = 2;
    while (i * i <= bound) : (i += 1) {
        if (sieve[i]) {
            var j = i * i;
            while (j <= bound) : (j += i) sieve[j] = false;
        }
    }

    // Count primes up to each checkpoint
    const checkpoints = [_]u32{ 100, 1000, 5000, 10000, 50000, 100000, 500000, 1000000 };
    const obj = try gc.allocObj(.vector);

    var pi_count: u32 = 0;
    var cp_idx: usize = 0;
    var n: u32 = 2;
    while (n <= bound and cp_idx < checkpoints.len) : (n += 1) {
        if (sieve[n]) pi_count += 1;
        if (n == checkpoints[cp_idx]) {
            if (checkpoints[cp_idx] <= bound) {
                // Li(x) ≈ x/ln(x) * (1 + 1/ln(x)) — simple approximation
                const x_f: f64 = @floatFromInt(n);
                const ln_x = @log(x_f);
                const li_approx = x_f / ln_x * (1.0 + 1.0 / ln_x);
                const pi_f: f64 = @floatFromInt(pi_count);
                const err = @abs(pi_f - li_approx);
                const rh_bound = @sqrt(x_f) * ln_x;

                const entry = try gc.allocObj(.map);
                const kw = struct {
                    fn intern(g: *GC, s: []const u8) !Value {
                        return Value.makeKeyword(try g.internString(s));
                    }
                };
                try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "x"));
                try entry.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(n)));
                try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "pi"));
                try entry.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(pi_count)));
                try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "error"));
                try entry.data.map.vals.append(gc.allocator, Value.makeFloat(err));
                try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "rh-bound"));
                try entry.data.map.vals.append(gc.allocator, Value.makeFloat(rh_bound));
                try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "ok?"));
                try entry.data.map.vals.append(gc.allocator, Value.makeBool(err < rh_bound));
                try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry));
            }
            cp_idx += 1;
        }
    }
    return Value.makeObj(obj);
}

// ============================================================================
// STOPTHROWINGROCKS BLOG — expressed in nanoclj-zig
//
// Six posts → six computational concepts:
//   1. Escaping the Simulation — simulation detection via computational bounds
//   2. Matrix Derivation — 𝔻(A) = D·A - A·D, tr=0 conservation
//   3. Random Fields — Gromov product distance matrices on metric spaces
//   4. Color Sort — GF(3) water sort puzzle, decidable (Δ⁰₁)
//   5. Teraformr — turn-based state machine (discrete dynamics)
//   6. We Move As One — clone synchronization (consensus problem)
// ============================================================================

// --- 1. ESCAPING THE SIMULATION ---
// Core idea: if we live in a simulation, the simulator has finite compute.
// Detectable via: fuel exhaustion = hitting the simulator's resource bound.
// In nanoclj-zig, our fuel-bounded eval IS the simulation boundary.
// The REPL's fuel limit (semantics.Resources) is literally the simulation wall.

/// (simulation-fuel) → current fuel limit of the evaluator
pub fn simulationFuelFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    _ = args;
    // The default fuel from semantics.Resources.initDefault()
    // This IS the simulation boundary — computation beyond this diverges
    return Value.makeInt(1_000_000);
}

/// (simulation-escape? expr-cost) → true if expression cost exceeds simulator fuel
/// The philosophical point: you can't escape, but you CAN detect the wall.
pub fn simulationEscapeFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or !args[0].isInt()) return error.ArityError;
    const cost = args[0].asInt();
    const fuel: i48 = 1_000_000; // simulator's budget
    // Can we escape? Only if cost > fuel. But we can never RUN cost > fuel.
    // This is the diagonal argument: the simulation can always detect escape attempts.
    return Value.makeBool(cost > fuel);
}

// --- 2. MATRIX DERIVATION ---
// 𝔻(A) = D·A - A·D (commutator / Lie bracket)
// Properties: tr(𝔻(A)) = 0 always, product rule holds

/// (matrix-derivation D A) → 𝔻(A) = D·A - A·D for 2×2 matrices
/// Each matrix is [[a b] [c d]]
pub fn matrixDerivationFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const d = parse2x2(args[0], gc) orelse return error.TypeError;
    const a = parse2x2(args[1], gc) orelse return error.TypeError;
    const da = mul2x2(d, a);
    const ad = mul2x2(a, d);
    const result = [4]i48{ da[0] - ad[0], da[1] - ad[1], da[2] - ad[2], da[3] - ad[3] };
    return make2x2(result, gc);
}

/// (matrix-derivation-trace D A) → tr(𝔻(A)), always 0
pub fn matrixDerivationTraceFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const d = parse2x2(args[0], gc) orelse return error.TypeError;
    const a = parse2x2(args[1], gc) orelse return error.TypeError;
    const da = mul2x2(d, a);
    const ad = mul2x2(a, d);
    return Value.makeInt((da[0] - ad[0]) + (da[3] - ad[3]));
}

fn parse2x2(v: Value, gc: *GC) ?[4]i48 {
    _ = gc;
    if (!v.isObj()) return null;
    const obj = v.asObj();
    if (obj.kind != .vector) return null;
    if (obj.data.vector.items.items.len != 2) return null;
    const r0v = obj.data.vector.items.items[0];
    const r1v = obj.data.vector.items.items[1];
    if (!r0v.isObj() or !r1v.isObj()) return null;
    const r0o = r0v.asObj();
    const r1o = r1v.asObj();
    if (r0o.kind != .vector or r1o.kind != .vector) return null;
    const r0 = r0o.data.vector.items.items;
    const r1 = r1o.data.vector.items.items;
    if (r0.len != 2 or r1.len != 2) return null;
    if (!r0[0].isInt() or !r0[1].isInt() or !r1[0].isInt() or !r1[1].isInt()) return null;
    return [4]i48{ r0[0].asInt(), r0[1].asInt(), r1[0].asInt(), r1[1].asInt() };
}

fn mul2x2(a: [4]i48, b: [4]i48) [4]i48 {
    return [4]i48{
        a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
    };
}

fn make2x2(m: [4]i48, gc: *GC) !Value {
    const row0 = try gc.allocObj(.vector);
    try row0.data.vector.items.append(gc.allocator, Value.makeInt(m[0]));
    try row0.data.vector.items.append(gc.allocator, Value.makeInt(m[1]));
    const row1 = try gc.allocObj(.vector);
    try row1.data.vector.items.append(gc.allocator, Value.makeInt(m[2]));
    try row1.data.vector.items.append(gc.allocator, Value.makeInt(m[3]));
    const result = try gc.allocObj(.vector);
    try result.data.vector.items.append(gc.allocator, Value.makeObj(row0));
    try result.data.vector.items.append(gc.allocator, Value.makeObj(row1));
    return Value.makeObj(result);
}

// --- 3. RANDOM FIELDS / GROMOV PRODUCT ---
// For 3 points on a metric space, the Gromov product (x₁|x₂)_{x₀} =
// (d(x₀,x₁) + d(x₀,x₂) - d(x₁,x₂)) / 2
// Positive iff the metric is of negative type (trees are always negative type).

/// (gromov-matrix [d01 d02 d12]) → {:d01 .. :gromov-product-2x .. :trit .. :negative-type? ..}
pub fn gromovMatrixFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const dists_obj = args[0].asObj();
    if (dists_obj.kind != .vector) return error.TypeError;
    const items = dists_obj.data.vector.items.items;
    if (items.len != 3) return error.ArityError;
    if (!items[0].isInt() or !items[1].isInt() or !items[2].isInt()) return error.TypeError;
    const d01 = items[0].asInt();
    const d02 = items[1].asInt();
    const d12 = items[2].asInt();
    const gromov_2 = d01 + d02 - d12; // 2× Gromov product
    const gp_r = @mod(gromov_2 + 300, 3);
    const gp_trit: i48 = if (gp_r == 2) -1 else gp_r;

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "d01"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(d01));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "d02"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(d02));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "d12"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(d12));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "gromov-product-2x"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(gromov_2));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(gp_trit));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "negative-type?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(gromov_2 >= 0));
    return Value.makeObj(obj);
}

// --- 4. COLOR SORT ---
// Water Sort puzzle: tubes of colored segments, pour same-color tops.
// GF(3) trit sum conserved under pours.

/// (color-sort-trit-sum [[0 1 2] [1 0 2] []]) → GF(3) sum of all tube contents
pub fn colorSortTritSumFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const tubes_obj = args[0].asObj();
    if (tubes_obj.kind != .vector) return error.TypeError;
    var sum: i48 = 0;
    for (tubes_obj.data.vector.items.items) |tube_val| {
        if (!tube_val.isObj()) continue;
        const tube_obj = tube_val.asObj();
        if (tube_obj.kind != .vector) continue;
        for (tube_obj.data.vector.items.items) |c| {
            if (c.isInt()) sum += c.asInt();
        }
    }
    return Value.makeInt(@mod(sum + 300, 3));
}

// --- 5. TERAFORMR (turn-based state machine) ---
// Discrete dynamics: state × action → state. Undo = history stack.
// This is a deterministic pushdown automaton (Δ⁰₁, decidable).

/// (turn-state moves) → {:steps n :reversible true :hierarchy "delta-1"}
pub fn turnStateFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or !args[0].isInt()) return error.ArityError;
    const moves = args[0].asInt();
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "steps"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(moves));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "reversible"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(true));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "hierarchy"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString("delta-1")));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(0)); // Δ = 0
    return Value.makeObj(obj);
}

// --- 6. WE MOVE AS ONE (consensus/clone synchronization) ---
// n clones must synchronize actions. This is the consensus problem:
// - With reliable channels: decidable (Δ⁰₁)
// - With crash failures: Σ⁰₁ (FLP impossibility: no deterministic solution)
// - Byzantine: Π⁰₁ (must verify all honest nodes agree)

/// (consensus-classify n failures) → {:n n :failures f :hierarchy str :trit n}
pub fn consensusClassifyFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    const n = args[0].asInt();
    const f = args[1].asInt();
    const hierarchy: []const u8 = if (f == 0) "delta-1" else if (f * 3 < n) "sigma-1" else "pi-1";
    const trit: i48 = if (f == 0) 0 else if (f * 3 < n) 1 else -1;

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "n"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(n));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "failures"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(f));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "hierarchy"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(hierarchy)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(trit));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "note"));
    const note: []const u8 = if (f == 0) "reliable: all clones move as one" else if (f * 3 < n) "FLP: probabilistic consensus possible" else "Byzantine: need >2/3 honest";
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(note)));
    return Value.makeObj(obj);
}

// ============================================================================
// STACKS PROJECT CONNECTION
//
// The Stacks Project (stacks.math.columbia.edu) is the canonical reference
// for algebraic geometry. Key tags connecting to our realizability topos:
//
//   00VH — Site: category + covering families (3 axioms)
//           Our classified problems form a site under Turing reductions
//   00VL — Sheaf: presheaf satisfying gluing (equalizer of double arrows)
//           Ω_eff ≅ Σ⁰₁ truth values = subobject classifier of effective topos
//   03N1 — Étale cohomology: topology on schemes via étale morphisms
//           Over Spec(GF(3)), étale = separable = trit-valued
//   026K — Algebraic stacks: higher categorical descent
//           Gorard tower levels form a stack of proof-theoretic depths
//   0238 — Descent: effective descent = gluing data → object
//           Realizability: a realizer witnesses descent (effective = computable)
//
// The arithmetical hierarchy IS the filtration of the effective topos:
//   Δ⁰₁ = decidable sheaves (classical, trit 0)
//   Σ⁰₁ = c.e. sheaves (witnessed, trit +1)
//   Π⁰₁ = co-c.e. sheaves (validated, trit -1)
// ============================================================================

const StacksTag = struct {
    tag: []const u8,
    name: []const u8,
    chapter: []const u8,
    connection: []const u8,
    trit: i48,
};

const stacks_tags = [_]StacksTag{
    .{ .tag = "00VH", .name = "Site", .chapter = "7.6",
       .connection = "classified problems as a site under Turing reductions",
       .trit = 0 },
    .{ .tag = "00VL", .name = "Sheaf on a Site", .chapter = "7.7",
       .connection = "Omega_eff = Sigma^0_1 truth values (subobject classifier)",
       .trit = 1 },
    .{ .tag = "03N1", .name = "Etale Cohomology", .chapter = "59",
       .connection = "over Spec(GF(3)), etale sheaves are trit-valued",
       .trit = -1 },
    .{ .tag = "026K", .name = "Algebraic Stacks", .chapter = "94",
       .connection = "Gorard tower as stack of proof-theoretic depths",
       .trit = 0 },
    .{ .tag = "0238", .name = "Descent", .chapter = "35",
       .connection = "effective descent = realizer witnesses gluing",
       .trit = 1 },
    .{ .tag = "00ZU", .name = "Homological Algebra", .chapter = "12",
       .connection = "derived functors = iterated Sigma/Pi quantifier alternation",
       .trit = -1 },
};

/// (stacks-tags) → vector of {:tag "00VH" :name "Site" :connection str :trit n}
pub fn stacksTagsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    const obj = try gc.allocObj(.vector);
    for (&stacks_tags) |*t| {
        const entry = try gc.allocObj(.map);
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "tag"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(t.tag)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "name"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(t.name)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "chapter"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(t.chapter)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "connection"));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(t.connection)));
        try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
        try entry.data.map.vals.append(gc.allocator, Value.makeInt(t.trit));
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }
    return Value.makeObj(obj);
}

/// (stacks-trit-sum) → GF(3) conservation across Stacks Project connections
pub fn stacksTritSumFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    _ = args;
    var sum: i48 = 0;
    for (&stacks_tags) |*t| sum += t.trit;
    return Value.makeInt(@mod(sum + 300, 3));
}

/// (stacks-lookup tag-string) → tag entry or nil
pub fn stacksLookupFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const needle = gc.getString(args[0].asStringId());
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };
    for (&stacks_tags) |*t| {
        if (std.mem.eql(u8, t.tag, needle)) {
            const entry = try gc.allocObj(.map);
            try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "tag"));
            try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(t.tag)));
            try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "name"));
            try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(t.name)));
            try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "connection"));
            try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(t.connection)));
            try entry.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
            try entry.data.map.vals.append(gc.allocator, Value.makeInt(t.trit));
            return Value.makeObj(entry);
        }
    }
    return Value.makeNil();
}
