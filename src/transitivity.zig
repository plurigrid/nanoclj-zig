//! TRANSITIVITY: Equivalence closure, resource bounding, soundness
//!
//! The "when to stop" and "are they the same?" layer.
//! Mirrors bisimulation's Paige-Tarjan partition refinement:
//!   structural equality = finest partition where equivalent states
//!   cannot be distinguished by any observation sequence.
//!
//! Also houses resource limits (the immune system) and GF(3) trit semantics.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

// ============================================================================
// PSEUDO-OPERATIONAL: Resource Limits (the immune system)
// ============================================================================

/// Resource limits for adversarial defense.
/// These bound ALL execution: parsing, evaluation, GC.
pub const Limits = struct {
    /// Maximum eval recursion depth (prevents stack overflow)
    max_depth: u32 = 1024,
    /// Maximum reader nesting depth (prevents parser stack overflow)
    max_read_depth: u32 = 256,
    /// Fuel: total eval steps before forced termination
    max_fuel: u64 = 10_000_000_000,
    /// Maximum string length in bytes
    max_string_len: u32 = 1024 * 1024, // 1MB
    /// Maximum collection size (items in one list/vector/map)
    max_collection_size: u32 = 100_000,
    /// Maximum interned strings (prevents string table exhaustion)
    max_interned_strings: u32 = 100_000,
    /// Maximum live objects before forced GC
    max_live_objects: u32 = 1_000_000,
    /// Maximum environment chain depth
    max_env_depth: u32 = 512,
};

/// Runtime resource tracker (threaded through eval)
pub const Resources = struct {
    fuel: u64,
    depth: u32 = 0,
    read_depth: u32 = 0,
    steps_taken: u64 = 0,
    max_depth_seen: u32 = 0,
    limits: Limits,
    /// GF(3) balance accumulator for conservation checks
    trit_balance: i8 = 0,

    pub fn init(limits: Limits) Resources {
        return .{
            .fuel = limits.max_fuel,
            .limits = limits,
        };
    }

    pub fn initDefault() Resources {
        return init(.{});
    }

    /// Consume fuel based on color-game depth cost.
    /// Inlined LUT path for depths < 512 (hot path avoids function call).
    pub inline fn tick(self: *Resources) !void {
        if (self.fuel == 0) return error.FuelExhausted;
        const gay_skills = @import("gay_skills.zig");
        // Inline LUT access — avoids function call overhead for common depths
        const cost = if (self.depth < gay_skills.DEPTH_FUEL_LUT_SIZE)
            gay_skills.depth_fuel_lut[self.depth]
        else
            gay_skills.depthFuelCost(self.depth);
        if (self.fuel < cost) {
            self.fuel = 0;
            return error.FuelExhausted;
        }
        self.fuel -= cost;
        self.steps_taken += 1;
    }

    /// Enter a deeper eval frame
    pub fn descend(self: *Resources) !void {
        self.depth += 1;
        if (self.depth > self.max_depth_seen) self.max_depth_seen = self.depth;
        if (self.depth > self.limits.max_depth) return error.DepthExceeded;
    }

    /// Leave an eval frame
    pub fn ascend(self: *Resources) void {
        self.depth -|= 1;
    }

    /// Enter a deeper read frame
    pub fn descendRead(self: *Resources) !void {
        self.read_depth += 1;
        if (self.read_depth > self.limits.max_read_depth) return error.ReadDepthExceeded;
    }

    /// Leave a read frame
    pub fn ascendRead(self: *Resources) void {
        self.read_depth -|= 1;
    }

    /// Accumulate GF(3) balance from a trit
    pub fn accumulateTrit(self: *Resources, trit: i8) void {
        self.trit_balance = @intCast(@mod(@as(i16, self.trit_balance) + @as(i16, trit) + 3, 3));
    }

    /// Check GF(3) conservation (balance should be 0)
    pub fn isConserved(self: *const Resources) bool {
        return self.trit_balance == 0;
    }

    pub fn fuelRemaining(self: *const Resources) u64 {
        return self.fuel;
    }

    /// Fork: split resources into n independent children for parallel eval.
    /// Fuel is divided equally (adiabatic — no overhead).
    /// Each child inherits depth/limits but gets independent trit_balance.
    pub fn fork(self: *Resources, n: usize) [64]Resources {
        var children: [64]Resources = undefined;
        if (n == 0) return children;
        const fuel_each = self.fuel / @max(n, 1);
        for (0..@min(n, 64)) |i| {
            children[i] = .{
                .fuel = fuel_each,
                .depth = self.depth,
                .read_depth = self.read_depth,
                .steps_taken = 0,
                .max_depth_seen = self.depth,
                .limits = self.limits,
                .trit_balance = 0,
            };
        }
        // Remainder fuel stays with parent (Landauer: join will cost kT·ln(n))
        self.fuel -= fuel_each * @min(n, 64);
        return children;
    }

    /// Join: merge n child resources back into parent.
    /// Accumulates steps, trit_balance, tracks max_depth.
    /// Join cost = 1 fuel unit per child (approximates kT·ln(n)).
    pub fn join(self: *Resources, children: []Resources, n: usize) void {
        for (0..@min(n, 64)) |i| {
            self.steps_taken += children[i].steps_taken;
            self.fuel += children[i].fuel; // return unused fuel
            if (children[i].max_depth_seen > self.max_depth_seen) {
                self.max_depth_seen = children[i].max_depth_seen;
            }
            // Accumulate trit balance from each child
            self.accumulateTrit(children[i].trit_balance);
        }
        // Join overhead: 1 fuel per child merged (measurement cost)
        const join_cost = @min(n, self.fuel);
        self.fuel -= join_cost;
    }
};

// ============================================================================
// TRIT-TICK: Post-float integer time quantum with GF(3) phase
// ============================================================================
//
// Flick (Meta): 1/705,600,000 sec — LCM of all media frame/sample rates.
// Post-float insight: represent time as integers, never floats.
//
// Trit-tick: 1/2,116,800,000 sec — Flick × 3.
// Every tick carries an intrinsic GF(3) phase: tick mod 3 ∈ {0,1,2} maps to
// Signal(+1) / Mechanism(0) / Act(-1), the 333 SMA triad.
//
// Glimpse: 1/1069 of a trit-tick — the cognitive jerk quantum.
// 1069 is prime: intentionally incommensurate with the trit-tick grid.
// This creates a Moiré beat pattern against the phase cycle:
//   glimpse_phase = (glimpse_count * 1069) mod 3
// Because gcd(1069, 3) = 1 (1069 ≡ 2 mod 3), the glimpse phase
// rotates through all three states but at a rate that DRIFTS against
// the trit-tick phase. This drift IS cognitive jerk — the felt
// acceleration/deceleration of subjective time.
//
// Jerk = d³x/dt³. In discrete time:
//   position = tick count (objective)
//   velocity = glimpses per tick (attention rate, variable)
//   acceleration = d(velocity)/dt (engagement change)
//   jerk = d(acceleration)/dt (the "snap" of phase lock/unlock)
//
// When glimpse phase aligns with trit-tick phase: flow state (time vanishes)
// When they anti-align: friction (time drags)
// The 1069-prime spacing ensures alignment is rare and aperiodic.
//
// Hierarchy:
//   1 second = 2,116,800,000 trit-ticks
//   1 trit-tick = 1069 glimpses (cognitive microstructure)
//   1 trit-cycle = 3 trit-ticks = 3207 glimpses
//   1 flick = 3 trit-ticks (by construction)
//
// Divisibility (inherits from flick, all exact):
//   24 fps:  88,200,000 trit-ticks/frame
//   25 fps:  84,672,000 trit-ticks/frame
//   30 fps:  70,560,000 trit-ticks/frame
//   48 fps:  44,100,000 trit-ticks/frame
//   60 fps:  35,280,000 trit-ticks/frame
//   120 fps: 17,640,000 trit-ticks/frame
//   44100 Hz:    48,000 trit-ticks/sample
//   48000 Hz:    44,100 trit-ticks/sample
//   96000 Hz:    22,050 trit-ticks/sample
//   All divisible by 3 ✓ (phase-aligned at every boundary)

pub const FLICK: u64 = 705_600_000;
pub const TRIT_TICK: u64 = FLICK * 3; // 2,116,800,000
pub const GLIMPSES_PER_TRIT_TICK: u64 = 1069; // prime — cognitive jerk quantum
pub const TRIT_TICKS_PER_SEC: u64 = TRIT_TICK;
pub const GLIMPSES_PER_SEC: u64 = TRIT_TICKS_PER_SEC * GLIMPSES_PER_TRIT_TICK;

/// GF(3) phase of a trit-tick count: Signal(+1) / Mechanism(0) / Act(-1)
pub fn tritPhase(tick_count: u64) i8 {
    const m = tick_count % 3;
    if (m == 0) return 0; // Mechanism (neutral)
    if (m == 1) return 1; // Signal (positive)
    return -1; // Act (negative)
}

/// Convert frame count at a given fps to trit-ticks
pub fn framesToTritTicks(frames: u64, fps: u32) u64 {
    return frames * (TRIT_TICKS_PER_SEC / @as(u64, fps));
}

/// Convert audio sample count at a given rate to trit-ticks
pub fn samplesToTritTicks(samples: u64, sample_rate: u32) u64 {
    return samples * (TRIT_TICKS_PER_SEC / @as(u64, sample_rate));
}

/// Trit-tick duration struct for accumulating post-float time
pub const TritTime = struct {
    ticks: u64 = 0,
    glimpses: u64 = 0, // sub-tick cognitive microstructure

    pub fn addTicks(self: *TritTime, n: u64) void {
        self.ticks += n;
    }

    pub fn addGlimpses(self: *TritTime, n: u64) void {
        self.glimpses += n;
        // Carry: 1069 glimpses = 1 trit-tick
        const carry = self.glimpses / GLIMPSES_PER_TRIT_TICK;
        self.glimpses %= GLIMPSES_PER_TRIT_TICK;
        self.ticks += carry;
    }

    pub fn phase(self: *const TritTime) i8 {
        return tritPhase(self.ticks);
    }

    /// Glimpse phase — drifts against tick phase because 1069 ≡ 2 mod 3
    pub fn glimpsePhase(self: *const TritTime) i8 {
        return tritPhase(self.glimpses);
    }

    /// Cognitive jerk indicator: alignment between tick phase and glimpse phase
    /// 0 = aligned (flow), 1 = leading (anticipation), -1 = lagging (drag)
    pub fn jerk(self: *const TritTime) i8 {
        const tp = self.phase();
        const gp = self.glimpsePhase();
        const diff = @as(i16, tp) - @as(i16, gp);
        const m = @mod(diff + 3, 3);
        if (m == 0) return 0; // flow
        if (m == 1) return 1; // anticipation
        return -1; // drag
    }

    /// Which trit-cycle are we in? (0-indexed)
    pub fn cycle(self: *const TritTime) u64 {
        return self.ticks / 3;
    }

    /// How many flicks have elapsed?
    pub fn asFlicks(self: *const TritTime) u64 {
        return self.ticks / 3;
    }

    /// Total glimpses (ticks × 1069 + sub-tick glimpses)
    pub fn totalGlimpses(self: *const TritTime) u64 {
        return self.ticks * GLIMPSES_PER_TRIT_TICK + self.glimpses;
    }

    /// Seconds as integer + remainder trit-ticks
    pub fn asSeconds(self: *const TritTime) struct { secs: u64, remainder: u64 } {
        return .{
            .secs = self.ticks / TRIT_TICKS_PER_SEC,
            .remainder = self.ticks % TRIT_TICKS_PER_SEC,
        };
    }

    /// Phase-congruent: same phase but possibly different tick count
    pub fn phaseCongruent(a: TritTime, b: TritTime) bool {
        return a.ticks % 3 == b.ticks % 3;
    }
};

// ============================================================================
// P-ADIC VALUATION: Ultrametric depth for multi-prime time lenses
// ============================================================================
//
// v_p(n) = highest power of prime p dividing n.
// Each prime gives a different "time lens" — a different notion of which
// ticks are "close" in the ultrametric topology.
//
// The flick factorization 2⁹ × 3² × 5⁵ × 7² reveals four natural lenses:
//   v₂: binary depth (even/odd, power-of-2 landmarks at 2,4,8,16,...)
//   v₃: trit depth (the GF(3) layer, landmarks at 9,27,81,243,...)
//   v₅: quint depth (decimal/pentatonic landmarks at 25,125,625,...)
//   v₇: sept depth (weekly/harmonic landmarks at 49,343,...)
//
// The 1069-adic valuation is special: since 1069 is prime and coprime to
// all media rates, v₁₀₆₉(n) = 0 for all n < 1069. The first 1069-adic
// landmark IS the glimpse boundary. No tick before it resonates in the
// cognitive prime — this is why flow state requires accumulation.
//
// Multi-p-adic "depth vector" d(n) = (v₂(n), v₃(n), v₅(n), v₇(n), v₁₀₆₉(n))
// gives a 5-dimensional ultrametric fingerprint of each moment in time.
// Moments with matching depth vectors are "p-adically congruent" — they
// feel the same across all time lenses simultaneously.

/// p-adic valuation: highest power of p dividing n
pub fn padicVal(p: u64, n: u64) u32 {
    if (n == 0 or p < 2) return 0;
    var v: u32 = 0;
    var m = n;
    while (m % p == 0) : (v += 1) {
        m /= p;
    }
    return v;
}

/// The canonical primes for the trit-tick ultrametric tower
pub const TOWER_PRIMES = [_]u64{ 2, 3, 5, 7, 1069 };

/// Multi-p-adic depth vector: (v2, v3, v5, v7, v1069)
pub const PadicDepth = struct {
    v: [5]u32 = .{ 0, 0, 0, 0, 0 },

    pub fn of(n: u64) PadicDepth {
        var d: PadicDepth = .{};
        for (TOWER_PRIMES, 0..) |p, i| {
            d.v[i] = padicVal(p, n);
        }
        return d;
    }

    /// Total depth = sum of all valuations (crude "importance" measure)
    pub fn total(self: *const PadicDepth) u32 {
        var s: u32 = 0;
        for (self.v) |vi| s += vi;
        return s;
    }

    /// Two moments are ultrametrically congruent if all valuations match
    pub fn congruent(a: PadicDepth, b: PadicDepth) bool {
        return std.mem.eql(u32, &a.v, &b.v);
    }

    /// Ultrametric distance: max prime where valuations differ
    /// Returns the index into TOWER_PRIMES, or 5 if identical
    pub fn distance(a: PadicDepth, b: PadicDepth) u32 {
        var max_diff: u32 = 5; // identical
        for (a.v, b.v, 0..) |va, vb, i| {
            if (va != vb) max_diff = @intCast(i);
        }
        return max_diff;
    }
};

// ============================================================================
// INFORMATION SPACETIME: Spacelike/Timelike on Graph Structures
// ============================================================================
//
// Matter ↔ information density (nodes per subgraph volume)
// Energy ↔ exchange rate (edges traversed per trit-tick)
// c ↔ information speed limit (max causal reach per tick)
//
// A graph node pair (u, v) is:
//   TIMELIKE:  reachable within k ticks (inside light cone, causal)
//   SPACELIKE: unreachable within k ticks (outside light cone, simultaneous)
//   LIGHTLIKE: exactly at the boundary (k = distance(u, v))
//
// The p-adic tower gives multiple "speeds of light":
//   c₂ = binary branching rate (2^d nodes reachable at depth d)
//   c₃ = trit phase propagation (3^d, GF(3) wavefront)
//   c₅ = pentatonic spread, c₇ = harmonic spread
//   c₁₀₆₉ = glimpse-scale propagation (cognitive wavefront)
//
// Conservation: density × rate = constant (information E=mc²)
// GF(3) sum = 0 already enforces this at the trit level.

/// Separation type between two points in information spacetime
pub const Separation = enum(i8) {
    timelike = 1, // causal: path exists within budget
    lightlike = 0, // boundary: path length = budget exactly
    spacelike = -1, // acausal: no path within budget

    /// GF(3) trit value of the separation
    pub fn trit(self: Separation) i8 {
        return @intFromEnum(self);
    }
};

/// Classify separation: is (distance) within (budget) trit-ticks?
pub fn classify(distance: u64, budget: u64) Separation {
    if (distance < budget) return .timelike;
    if (distance == budget) return .lightlike;
    return .spacelike;
}

/// Information light cone: how many nodes reachable at branching factor b in k steps
/// Volume of the cone = (b^(k+1) - 1) / (b - 1) for b > 1
pub fn coneVolume(branching: u64, depth: u64) u64 {
    if (branching <= 1) return depth + 1;
    var vol: u64 = 0;
    var layer: u64 = 1;
    for (0..depth + 1) |_| {
        vol +|= layer;
        layer *|= branching;
    }
    return vol;
}

/// Information density: nodes / cone volume
/// Returns fixed-point (density × 1000) to avoid float
pub fn infoDensity(nodes: u64, volume: u64) u64 {
    if (volume == 0) return 0;
    return (nodes * 1000) / volume;
}

/// Exchange rate: edges traversed per trit-tick
/// For a k-regular graph with n nodes, max rate = k * n / 2 edges per tick
pub fn exchangeRate(edges_per_tick: u64, trit_ticks: u64) u64 {
    if (trit_ticks == 0) return 0;
    return edges_per_tick / trit_ticks;
}

/// Information c: the speed limit relating density and rate
/// c² = rate / density (analog of E = mc²)
/// Returns fixed-point × 1000
pub fn infoC(rate: u64, density_fp: u64) u64 {
    if (density_fp == 0) return 0;
    return (rate * 1000) / density_fp;
}

/// Multi-scale light cone using p-adic tower
/// Returns cone volumes at each prime's branching rate
pub fn padicCones(depth: u64) [5]u64 {
    var cones: [5]u64 = undefined;
    for (TOWER_PRIMES, 0..) |p, i| {
        cones[i] = coneVolume(p, depth);
    }
    return cones;
}

/// Causal depth: given a cone volume, what depth achieves it at branching b?
/// Inverse of coneVolume — how many ticks to reach volume v
pub fn causalDepth(branching: u64, target_volume: u64) u64 {
    if (branching <= 1) return target_volume -| 1;
    var vol: u64 = 0;
    var layer: u64 = 1;
    var d: u64 = 0;
    while (vol < target_volume) : (d += 1) {
        vol +|= layer;
        layer *|= branching;
        if (layer == 0) break; // overflow
    }
    return d -| 1;
}

// ============================================================================
// STRUCTURAL EQUALITY (denotational requirement)
// ============================================================================

/// Deep structural equality — the denotational semantics REQUIRES this.
/// Bitwise equality (Value.eql) is the operational approximation.
/// This function is the ground truth.
///
///   ⟦(= a b)⟧ = structuralEq(a, b)
///
/// Satisfies:
///   reflexive:  eq(v, v) = true
///   symmetric:  eq(a, b) = eq(b, a)
///   transitive: eq(a, b) ∧ eq(b, c) → eq(a, c)
///   structural: eq([1 2], [1 2]) = true (NOT pointer equality)
pub fn structuralEq(a: Value, b: Value, gc: *GC) bool {
    if (a.eql(b)) return true;
    if (a.isNil() and b.isNil()) return true;
    if (a.isBool() and b.isBool()) return a.asBool() == b.asBool();
    if (a.isInt() and b.isInt()) return a.asInt() == b.asInt();
    if (a.isFloat() and b.isFloat()) return a.asFloat() == b.asFloat();
    if ((a.isInt() and b.isFloat()) or (a.isFloat() and b.isInt())) return false;
    if (a.isString() and b.isString()) {
        return std.mem.eql(u8, gc.getString(a.asStringId()), gc.getString(b.asStringId()));
    }
    if (a.isKeyword() and b.isKeyword()) {
        return std.mem.eql(u8, gc.getString(a.asKeywordId()), gc.getString(b.asKeywordId()));
    }
    if (a.isSymbol() and b.isSymbol()) {
        return std.mem.eql(u8, gc.getString(a.asSymbolId()), gc.getString(b.asSymbolId()));
    }
    if (a.isObj() and b.isObj()) {
        return structuralEqObj(a.asObj(), b.asObj(), gc);
    }
    return false;
}

fn structuralEqObj(a: *Obj, b: *Obj, gc: *GC) bool {
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .list => structuralEqSeq(a.data.list.items.items, b.data.list.items.items, gc),
        .vector => structuralEqSeq(a.data.vector.items.items, b.data.vector.items.items, gc),
        .map => structuralEqMap(a, b, gc),
        .set => structuralEqSeq(a.data.set.items.items, b.data.set.items.items, gc),
        .rational => a.data.rational.numerator == b.data.rational.numerator and a.data.rational.denominator == b.data.rational.denominator,
        .function, .macro_fn, .bc_closure, .builtin_ref, .lazy_seq, .partial_fn, .multimethod, .protocol, .dense_f64, .trace => false,
        .atom => structuralEq(a.data.atom.val, b.data.atom.val, gc),
    };
}

fn structuralEqSeq(as: []Value, bs: []Value, gc: *GC) bool {
    if (as.len != bs.len) return false;
    for (as, bs) |a, b| {
        if (!structuralEq(a, b, gc)) return false;
    }
    return true;
}

fn structuralEqMap(a: *Obj, b: *Obj, gc: *GC) bool {
    const a_keys = a.data.map.keys.items;
    const b_keys = b.data.map.keys.items;
    if (a_keys.len != b_keys.len) return false;
    for (a_keys, 0..) |ak, ai| {
        var found = false;
        for (b_keys, 0..) |bk, bi| {
            if (structuralEq(ak, bk, gc)) {
                if (!structuralEq(a.data.map.vals.items[ai], b.data.map.vals.items[bi], gc))
                    return false;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ============================================================================
// GF(3) TRIT SEMANTICS
// ============================================================================

/// Every value carries an implicit trit (its "charge")
pub fn valueTrit(val: Value) i8 {
    if (val.isNil()) return 0;
    if (val.isBool()) return if (val.asBool()) @as(i8, 1) else @as(i8, -1);
    if (val.isInt()) {
        const i = val.asInt();
        if (i > 0) return 1;
        if (i < 0) return -1;
        return 0;
    }
    if (val.isObj()) {
        const addr = @intFromPtr(val.asObj());
        return switch (@as(u2, @intCast(addr % 3))) {
            0 => @as(i8, 0),
            1 => @as(i8, 1),
            2 => @as(i8, -1),
            else => unreachable,
        };
    }
    return 0;
}

// ============================================================================
// SOUNDNESS CHECK: Denotational ≡ Operational
// ============================================================================

/// Check that denotational and operational semantics agree on a value.
pub fn checkSoundness(val: Value, env: *Env, gc: *GC, fuel: u64) bool {
    const transclusion = @import("transclusion.zig");
    const transduction = @import("transduction.zig");

    var res_d = Resources.init(.{ .max_fuel = fuel });
    var res_o = Resources.init(.{ .max_fuel = fuel });

    const d = transclusion.denote(val, env, gc, &res_d);
    const o = transduction.evalBounded(val, env, gc, &res_o);

    return switch (d) {
        .value => |dv| switch (o) {
            .value => |ov| structuralEq(dv, ov, gc),
            else => false,
        },
        .bottom => |dr| switch (o) {
            .bottom => |or_| dr == or_,
            else => false,
        },
        .err => |de| switch (o) {
            .err => |oe| de.kind == oe.kind,
            else => false,
        },
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "structural equality: vectors" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const v1 = try gc.allocObj(.vector);
    try v1.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try v1.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const v2 = try gc.allocObj(.vector);
    try v2.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try v2.data.vector.items.append(gc.allocator, Value.makeInt(2));

    try std.testing.expect(structuralEq(Value.makeObj(v1), Value.makeObj(v2), &gc));
}

test "structural equality: maps order-independent" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const m1 = try gc.allocObj(.map);
    const ka = try gc.internString("a");
    const kb = try gc.internString("b");
    try m1.data.map.keys.append(gc.allocator, Value.makeKeyword(ka));
    try m1.data.map.vals.append(gc.allocator, Value.makeInt(1));
    try m1.data.map.keys.append(gc.allocator, Value.makeKeyword(kb));
    try m1.data.map.vals.append(gc.allocator, Value.makeInt(2));

    const m2 = try gc.allocObj(.map);
    try m2.data.map.keys.append(gc.allocator, Value.makeKeyword(kb));
    try m2.data.map.vals.append(gc.allocator, Value.makeInt(2));
    try m2.data.map.keys.append(gc.allocator, Value.makeKeyword(ka));
    try m2.data.map.vals.append(gc.allocator, Value.makeInt(1));

    try std.testing.expect(structuralEq(Value.makeObj(m1), Value.makeObj(m2), &gc));
}

test "structural equality: nested" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const inner1 = try gc.allocObj(.vector);
    try inner1.data.vector.items.append(gc.allocator, Value.makeInt(1));
    const inner2 = try gc.allocObj(.vector);
    try inner2.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const outer1 = try gc.allocObj(.vector);
    try outer1.data.vector.items.append(gc.allocator, Value.makeObj(inner1));
    try outer1.data.vector.items.append(gc.allocator, Value.makeObj(inner2));

    const inner3 = try gc.allocObj(.vector);
    try inner3.data.vector.items.append(gc.allocator, Value.makeInt(1));
    const inner4 = try gc.allocObj(.vector);
    try inner4.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const outer2 = try gc.allocObj(.vector);
    try outer2.data.vector.items.append(gc.allocator, Value.makeObj(inner3));
    try outer2.data.vector.items.append(gc.allocator, Value.makeObj(inner4));

    try std.testing.expect(structuralEq(Value.makeObj(outer1), Value.makeObj(outer2), &gc));
}

test "resource limits: fuel exhaustion" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var res = Resources.init(.{ .max_fuel = 5 });
    for (0..5) |_| try res.tick();
    try std.testing.expectError(error.FuelExhausted, res.tick());
}

test "resource limits: depth exceeded" {
    var res = Resources.init(.{ .max_depth = 3 });
    try res.descend();
    try res.descend();
    try res.descend();
    try std.testing.expectError(error.DepthExceeded, res.descend());
    res.ascend();
    res.ascend();
    try res.descend();
}

test "GF(3) conservation" {
    var res = Resources.initDefault();
    res.accumulateTrit(1);
    res.accumulateTrit(1);
    res.accumulateTrit(1);
    try std.testing.expect(res.isConserved());

    res.trit_balance = 0;
    res.accumulateTrit(1);
    res.accumulateTrit(-1);
    try std.testing.expect(res.isConserved());

    res.trit_balance = 0;
    res.accumulateTrit(1);
    try std.testing.expect(!res.isConserved());
}

test "value trit assignment" {
    try std.testing.expectEqual(@as(i8, 0), valueTrit(Value.makeNil()));
    try std.testing.expectEqual(@as(i8, 1), valueTrit(Value.makeBool(true)));
    try std.testing.expectEqual(@as(i8, -1), valueTrit(Value.makeBool(false)));
    try std.testing.expectEqual(@as(i8, 0), valueTrit(Value.makeInt(0)));
    try std.testing.expectEqual(@as(i8, 1), valueTrit(Value.makeInt(42)));
    try std.testing.expectEqual(@as(i8, -1), valueTrit(Value.makeInt(-7)));
}

test "fork/join: fuel conservation" {
    var res = Resources.init(.{ .max_fuel = 1000 });
    const initial_fuel = res.fuel;

    var children = res.fork(4);
    // Each child gets 250 fuel
    try std.testing.expectEqual(@as(u64, 250), children[0].fuel);
    try std.testing.expectEqual(@as(u64, 250), children[1].fuel);

    // Simulate work: child 0 uses 100, child 1 uses 50
    children[0].fuel -= 100;
    children[0].steps_taken = 10;
    children[1].fuel -= 50;
    children[1].steps_taken = 5;

    res.join(&children, 4);
    // Total fuel used = 100 + 50 = 150, plus join cost of 4
    // Returned fuel = (250-100) + (250-50) + 250 + 250 = 850
    // Parent fuel after join = remaining + 850 - 4 (join cost)
    try std.testing.expectEqual(@as(u64, 15), res.steps_taken);
    // Conservation: no fuel created from nothing
    try std.testing.expect(res.fuel <= initial_fuel);
}

test "fork/join: trit conservation" {
    var res = Resources.init(.{ .max_fuel = 1000 });
    var children = res.fork(3);

    // Each child accumulates trits
    children[0].trit_balance = 1;
    children[1].trit_balance = 1;
    children[2].trit_balance = 1;

    res.join(&children, 3);
    // 1 + 1 + 1 = 3 ≡ 0 (mod 3) → conserved
    try std.testing.expect(res.isConserved());
}

test "soundness: literal" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    try std.testing.expect(checkSoundness(Value.makeInt(42), &env, &gc, 1000));
    try std.testing.expect(checkSoundness(Value.makeNil(), &env, &gc, 1000));
    try std.testing.expect(checkSoundness(Value.makeBool(true), &env, &gc, 1000));
}
