//! Rung 4 of agent-o-nanoclj — evaluators.
//!
//! Ports agent-o-rama's evaluator trio:
//!   - Individual evaluator:   Value → f32 score
//!   - Comparative evaluator:  (Value, Value) → {a-better, tie, b-better}
//!   - Summary evaluator:      []Value → f32 aggregate
//!
//! Reference:
//!   https://redplanetlabs.com/aor/clojuredoc/com.rpl.agent-o-rama.html
//!   (declare-evaluator-builder / declare-comparative-evaluator-builder /
//!    declare-summary-evaluator-builder)
//!
//! An evaluator is declared once (name + function) and can then run against
//! any `InvocationTrace` event's output — or the entire invocation's output
//! slice. Evaluators are side-effect-free by contract; their only product
//! is a `Verdict`.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const trace_lib = @import("trace.zig");
const InvocationTrace = trace_lib.InvocationTrace;

pub const EvalError = error{
    EvalFailed,
};

pub const IndividualFn = *const fn (output: Value) EvalError!f32;
pub const ComparativeFn = *const fn (a: Value, b: Value) EvalError!Preference;
pub const SummaryFn = *const fn (outputs: []const Value) EvalError!f32;

pub const Preference = enum { a_better, tie, b_better };

pub const EvalKind = enum { individual, comparative, summary };

pub const Evaluator = union(EvalKind) {
    individual: struct { name: []const u8, f: IndividualFn },
    comparative: struct { name: []const u8, f: ComparativeFn },
    summary: struct { name: []const u8, f: SummaryFn },

    pub fn name(self: Evaluator) []const u8 {
        return switch (self) {
            .individual => |e| e.name,
            .comparative => |e| e.name,
            .summary => |e| e.name,
        };
    }

    pub fn kind(self: Evaluator) EvalKind {
        return @as(EvalKind, self);
    }
};

/// Result of an evaluator application. SDF-style tagged union — every
/// variant carries the evaluator's name plus a payload shaped to its kind.
///
/// Variants and their downstream consumers:
///   `.scalar`   — Rung 4 (today): a single f32. Default shape, used by
///                 individual / comparative / summary evaluators in this
///                 file. For comparatives, score encodes preference:
///                 -1.0 = b_better, 0.0 = tie, +1.0 = a_better.
///   `.trit`     — Rung 5: GF(3) gate verdict (-1 / 0 / +1). Lets a
///                 cycle stop predicate read trit balance directly.
///   `.vector`   — Rung 6 (MAGICORE PRM): step-wise scorer; one f32 per
///                 reasoning step. Caller owns the slice.
///   `.record`   — Rung 5+ (Evaluator-Optimizer): scalar score plus a
///                 free-form feedback string. Caller owns `feedback`.
///   `.semantic` — Rung 8 (ProTeGi): natural-language gradient instead
///                 of a scalar. Caller owns `gradient`.
///
/// Read via the dispatching methods (`name`, `primaryScore`, `passes`)
/// rather than by direct field access — that's the SDF generic-dispatch
/// surface, and it's what lets new variants land without breaking
/// existing call sites.
pub const Verdict = union(enum) {
    scalar: ScalarVerdict,
    trit: TritVerdict,
    vector: VectorVerdict,
    record: RecordVerdict,
    semantic: SemanticVerdict,

    pub const ScalarVerdict = struct { evaluator_name: []const u8, score: f32 };
    pub const TritVerdict = struct { evaluator_name: []const u8, trit: i2 };
    pub const VectorVerdict = struct { evaluator_name: []const u8, steps: []const f32 };
    pub const RecordVerdict = struct {
        evaluator_name: []const u8,
        score: f32,
        feedback: []const u8,
    };
    pub const SemanticVerdict = struct {
        evaluator_name: []const u8,
        gradient: []const u8,
    };

    /// Convenience constructor for the scalar (Rung 4) shape.
    pub fn makeScalar(eval_name: []const u8, score: f32) Verdict {
        return .{ .scalar = .{ .evaluator_name = eval_name, .score = score } };
    }

    pub fn name(self: Verdict) []const u8 {
        return switch (self) {
            inline else => |v| v.evaluator_name,
        };
    }

    /// Project any variant down to a single f32 for legacy passFn /
    /// passRate consumers. Defined explicitly per variant rather than
    /// hidden in a `default`, so a future Rung that demands a different
    /// projection is forced to think about it.
    pub fn primaryScore(self: Verdict) f32 {
        return switch (self) {
            .scalar => |v| v.score,
            .trit => |v| @floatFromInt(@as(i32, v.trit)),
            .vector => |v| if (v.steps.len == 0) 0.0 else blk: {
                var s: f32 = 0;
                for (v.steps) |x| s += x;
                break :blk s / @as(f32, @floatFromInt(v.steps.len));
            },
            .record => |v| v.score,
            .semantic => 0.0, // no scalar interpretation — gate via passes()
        };
    }

    /// Pass predicate. Semantic verdicts pass unconditionally (the
    /// natural-language gradient itself decides revision direction);
    /// every other variant compares `primaryScore() > threshold`.
    pub fn passes(self: Verdict, threshold: f32) bool {
        return switch (self) {
            .semantic => true,
            else => self.primaryScore() > threshold,
        };
    }
};

// Builders ────────────────────────────────────────────────────────────────
pub fn individual(name: []const u8, f: IndividualFn) Evaluator {
    return .{ .individual = .{ .name = name, .f = f } };
}
pub fn comparative(name: []const u8, f: ComparativeFn) Evaluator {
    return .{ .comparative = .{ .name = name, .f = f } };
}
pub fn summary(name: []const u8, f: SummaryFn) Evaluator {
    return .{ .summary = .{ .name = name, .f = f } };
}

// Runners ─────────────────────────────────────────────────────────────────
pub fn scoreOne(eval: Evaluator, output: Value) EvalError!Verdict {
    return switch (eval) {
        .individual => |e| Verdict.makeScalar(e.name, try e.f(output)),
        .comparative => error.EvalFailed, // needs pair; use scorePair
        .summary => error.EvalFailed, // needs slice; use scoreMany
    };
}

pub fn scorePair(eval: Evaluator, a: Value, b: Value) EvalError!Verdict {
    const pref = switch (eval) {
        .comparative => |e| try e.f(a, b),
        else => return error.EvalFailed,
    };
    const s: f32 = switch (pref) {
        .a_better => 1.0,
        .tie => 0.0,
        .b_better => -1.0,
    };
    return Verdict.makeScalar(eval.name(), s);
}

pub fn scoreMany(eval: Evaluator, outputs: []const Value) EvalError!Verdict {
    return switch (eval) {
        .summary => |e| Verdict.makeScalar(e.name, try e.f(outputs)),
        else => error.EvalFailed,
    };
}

// agent-o-rama-named convenience aliases for ad-hoc evaluator testing.
// Upstream exposes these as try-evaluator / try-comparative-evaluator /
// try-summary-evaluator on their Clojure API; mirror the naming so ported
// code reads the same way.
pub const tryEvaluator = scoreOne;
pub const tryComparative = scorePair;
pub const trySummary = scoreMany;

/// Kind-dispatching try: pick the right call by the evaluator's own kind.
/// Input shapes:
///   individual  → pass the single Value as `a`; `b`/`xs` ignored
///   comparative → pass `a` and `b`; `xs` ignored
///   summary     → pass `xs`; `a`/`b` ignored
pub fn tryAny(eval: Evaluator, a: Value, b: Value, xs: []const Value) EvalError!Verdict {
    return switch (eval.kind()) {
        .individual => scoreOne(eval, a),
        .comparative => scorePair(eval, a, b),
        .summary => scoreMany(eval, xs),
    };
}

/// Apply an individual evaluator to each completed event of an invocation
/// and return a slice of verdicts (one per completed step). Caller owns the
/// returned slice.
pub fn scoreInvocationSteps(
    allocator: std.mem.Allocator,
    eval: Evaluator,
    trace: InvocationTrace,
) ![]Verdict {
    if (eval.kind() != .individual) return error.EvalFailed;
    var out: std.ArrayListUnmanaged(Verdict) = .empty;
    errdefer out.deinit(allocator);
    for (trace.events) |ev| {
        if (ev.output) |o| {
            const v = try scoreOne(eval, o);
            try out.append(allocator, v);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

fn lenScorer(v: Value) EvalError!f32 {
    // Degenerate scorer that just returns the int value as f32.
    if (!v.isInt()) return error.EvalFailed;
    return @floatFromInt(v.asInt());
}

fn biggerIsBetter(a: Value, b: Value) EvalError!Preference {
    const av = a.asInt();
    const bv = b.asInt();
    if (av > bv) return .a_better;
    if (av < bv) return .b_better;
    return .tie;
}

fn meanAgg(vs: []const Value) EvalError!f32 {
    if (vs.len == 0) return 0.0;
    var sum: f32 = 0;
    for (vs) |v| sum += @as(f32, @floatFromInt(v.asInt()));
    return sum / @as(f32, @floatFromInt(vs.len));
}

test "Evaluator kind introspection" {
    const a = individual("len", lenScorer);
    const b = comparative("cmp", biggerIsBetter);
    const c = summary("mean", meanAgg);
    try std.testing.expectEqual(EvalKind.individual, a.kind());
    try std.testing.expectEqual(EvalKind.comparative, b.kind());
    try std.testing.expectEqual(EvalKind.summary, c.kind());
    try std.testing.expectEqualStrings("len", a.name());
    try std.testing.expectEqualStrings("cmp", b.name());
    try std.testing.expectEqualStrings("mean", c.name());
}

test "scoreOne on individual" {
    const e = individual("id", lenScorer);
    const v = try scoreOne(e, Value.makeInt(7));
    try std.testing.expectEqual(@as(f32, 7.0), v.primaryScore());
    try std.testing.expectEqualStrings("id", v.name());
}

test "scoreOne rejects non-individual" {
    const c = comparative("cmp", biggerIsBetter);
    try std.testing.expectError(error.EvalFailed, scoreOne(c, Value.makeInt(0)));
    const s = summary("sum", meanAgg);
    try std.testing.expectError(error.EvalFailed, scoreOne(s, Value.makeInt(0)));
}

test "scorePair encodes preference as {-1,0,+1}" {
    const e = comparative("cmp", biggerIsBetter);
    const v_a = try scorePair(e, Value.makeInt(10), Value.makeInt(5));
    try std.testing.expectEqual(@as(f32, 1.0), v_a.primaryScore());
    const v_t = try scorePair(e, Value.makeInt(5), Value.makeInt(5));
    try std.testing.expectEqual(@as(f32, 0.0), v_t.primaryScore());
    const v_b = try scorePair(e, Value.makeInt(3), Value.makeInt(8));
    try std.testing.expectEqual(@as(f32, -1.0), v_b.primaryScore());
}

test "scoreMany aggregates with summary evaluator" {
    const e = summary("mean", meanAgg);
    const xs = [_]Value{ Value.makeInt(2), Value.makeInt(4), Value.makeInt(6) };
    const v = try scoreMany(e, &xs);
    try std.testing.expectEqual(@as(f32, 4.0), v.primaryScore());
}

test "scoreMany on empty slice returns 0" {
    const e = summary("mean", meanAgg);
    const xs = [_]Value{};
    const v = try scoreMany(e, &xs);
    try std.testing.expectEqual(@as(f32, 0.0), v.primaryScore());
}

test "tryEvaluator / tryComparative / trySummary are aliases" {
    const ei = individual("id", lenScorer);
    const v1 = try tryEvaluator(ei, Value.makeInt(7));
    try std.testing.expectEqual(@as(f32, 7.0), v1.primaryScore());

    const ec = comparative("cmp", biggerIsBetter);
    const v2 = try tryComparative(ec, Value.makeInt(10), Value.makeInt(5));
    try std.testing.expectEqual(@as(f32, 1.0), v2.primaryScore());

    const es = summary("mean", meanAgg);
    const xs = [_]Value{ Value.makeInt(2), Value.makeInt(4) };
    const v3 = try trySummary(es, &xs);
    try std.testing.expectEqual(@as(f32, 3.0), v3.primaryScore());
}

test "tryAny dispatches by evaluator kind" {
    const e_ind = individual("s", lenScorer);
    const v_ind = try tryAny(e_ind, Value.makeInt(42), Value.makeInt(0), &.{});
    try std.testing.expectEqual(@as(f32, 42.0), v_ind.primaryScore());

    const e_cmp = comparative("c", biggerIsBetter);
    const v_cmp = try tryAny(e_cmp, Value.makeInt(2), Value.makeInt(5), &.{});
    try std.testing.expectEqual(@as(f32, -1.0), v_cmp.primaryScore());

    const e_sum = summary("m", meanAgg);
    const xs = [_]Value{ Value.makeInt(10), Value.makeInt(20), Value.makeInt(30) };
    const v_sum = try tryAny(e_sum, Value.makeInt(0), Value.makeInt(0), &xs);
    try std.testing.expectEqual(@as(f32, 20.0), v_sum.primaryScore());
}

test "scoreInvocationSteps scores each completed step" {
    const agent_lib = @import("agent.zig");
    const topology_lib = @import("topology.zig");

    const body_struct = struct {
        fn inc(_: *agent_lib.Agent, in: Value) error{Invoke}!Value {
            return Value.makeInt(in.asInt() + 1);
        }
    };

    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("a", body_struct.inc);
    _ = try topo.newAgent("b", body_struct.inc);
    try topo.connect("a", "b");

    const r = try topology_lib.invoke(&topo, &trace_store, "a", Value.makeInt(10));
    _ = r;
    const tr = try trace_store.getInvocation(std.testing.allocator, 1);
    defer std.testing.allocator.free(tr.events);

    const e = individual("echo-score", lenScorer);
    const verdicts = try scoreInvocationSteps(std.testing.allocator, e, tr);
    defer std.testing.allocator.free(verdicts);
    // Two completed steps: a: 10→11, b: 11→12. Scores = [11, 12].
    try std.testing.expectEqual(@as(usize, 2), verdicts.len);
    try std.testing.expectEqual(@as(f32, 11.0), verdicts[0].primaryScore());
    try std.testing.expectEqual(@as(f32, 12.0), verdicts[1].primaryScore());
}

// ─────────────────────────────────────────────────────────────────────────
// Verdict tagged-union — staged variants (Rungs 5/6/8)
// ─────────────────────────────────────────────────────────────────────────

test "Verdict.trit projects to f32 trit value and respects passes()" {
    const v = Verdict{ .trit = .{ .evaluator_name = "gf3", .trit = 1 } };
    try std.testing.expectEqualStrings("gf3", v.name());
    try std.testing.expectEqual(@as(f32, 1.0), v.primaryScore());
    try std.testing.expect(v.passes(0.0));
    try std.testing.expect(!v.passes(1.5));
}

test "Verdict.trit negative trit gives negative primaryScore" {
    const v = Verdict{ .trit = .{ .evaluator_name = "gf3", .trit = -1 } };
    try std.testing.expectEqual(@as(f32, -1.0), v.primaryScore());
    try std.testing.expect(!v.passes(0.0));
}

test "Verdict.vector projects to mean of step scores (MAGICORE PRM)" {
    const steps = [_]f32{ 0.2, 0.4, 0.6 };
    const v = Verdict{ .vector = .{ .evaluator_name = "prm", .steps = &steps } };
    try std.testing.expectEqualStrings("prm", v.name());
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), v.primaryScore(), 1e-6);
}

test "Verdict.vector empty slice projects to zero" {
    const v = Verdict{ .vector = .{ .evaluator_name = "empty", .steps = &.{} } };
    try std.testing.expectEqual(@as(f32, 0.0), v.primaryScore());
}

test "Verdict.record carries score + feedback (Evaluator-Optimizer)" {
    const v = Verdict{ .record = .{
        .evaluator_name = "judge",
        .score = 0.85,
        .feedback = "raise the prompt's specificity",
    } };
    try std.testing.expectEqualStrings("judge", v.name());
    try std.testing.expectEqual(@as(f32, 0.85), v.primaryScore());
    try std.testing.expect(v.passes(0.5));
}

test "Verdict.semantic always passes — gradient is the revision direction" {
    const v = Verdict{ .semantic = .{
        .evaluator_name = "protegi",
        .gradient = "outputs were too verbose; tighten",
    } };
    try std.testing.expectEqualStrings("protegi", v.name());
    try std.testing.expectEqual(@as(f32, 0.0), v.primaryScore());
    try std.testing.expect(v.passes(0.0));
    try std.testing.expect(v.passes(99.0)); // semantic bypasses the threshold
}

test "Verdict.makeScalar round-trips through dispatch methods" {
    const v = Verdict.makeScalar("acc", 0.91);
    try std.testing.expectEqualStrings("acc", v.name());
    try std.testing.expectEqual(@as(f32, 0.91), v.primaryScore());
}
