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
    const excl_trit = @mod(excl + 300, 3) - 1; // map to {-1,0,1}
    const incl_trit = @mod(incl + 300, 3) - 1;

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
    return Value.makeObj(obj);
}
