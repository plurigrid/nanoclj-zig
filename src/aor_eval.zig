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
const value = @import("value.zig");
const Value = value.Value;
const aor_trace = @import("aor_trace.zig");
const InvocationTrace = aor_trace.InvocationTrace;

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

/// Scalar result of an evaluator application. For comparative evaluators
/// we encode the preference as a float: -1.0 = b_better, 0.0 = tie,
/// +1.0 = a_better. This unifies downstream summaries.
pub const Verdict = struct {
    evaluator_name: []const u8,
    score: f32,
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
        .individual => |e| .{ .evaluator_name = e.name, .score = try e.f(output) },
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
    return .{ .evaluator_name = eval.name(), .score = s };
}

pub fn scoreMany(eval: Evaluator, outputs: []const Value) EvalError!Verdict {
    return switch (eval) {
        .summary => |e| .{ .evaluator_name = e.name, .score = try e.f(outputs) },
        else => error.EvalFailed,
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
    try std.testing.expectEqual(@as(f32, 7.0), v.score);
    try std.testing.expectEqualStrings("id", v.evaluator_name);
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
    try std.testing.expectEqual(@as(f32, 1.0), v_a.score);
    const v_t = try scorePair(e, Value.makeInt(5), Value.makeInt(5));
    try std.testing.expectEqual(@as(f32, 0.0), v_t.score);
    const v_b = try scorePair(e, Value.makeInt(3), Value.makeInt(8));
    try std.testing.expectEqual(@as(f32, -1.0), v_b.score);
}

test "scoreMany aggregates with summary evaluator" {
    const e = summary("mean", meanAgg);
    const xs = [_]Value{ Value.makeInt(2), Value.makeInt(4), Value.makeInt(6) };
    const v = try scoreMany(e, &xs);
    try std.testing.expectEqual(@as(f32, 4.0), v.score);
}

test "scoreMany on empty slice returns 0" {
    const e = summary("mean", meanAgg);
    const xs = [_]Value{};
    const v = try scoreMany(e, &xs);
    try std.testing.expectEqual(@as(f32, 0.0), v.score);
}

test "scoreInvocationSteps scores each completed step" {
    const aor_agent = @import("aor_agent.zig");
    const aor_topology = @import("aor_topology.zig");

    const body_struct = struct {
        fn inc(_: *aor_agent.Agent, in: Value) error{Invoke}!Value {
            return Value.makeInt(in.asInt() + 1);
        }
    };

    var topo = aor_topology.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = aor_trace.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("a", body_struct.inc);
    _ = try topo.newAgent("b", body_struct.inc);
    try topo.connect("a", "b");

    const r = try aor_topology.invoke(&topo, &trace_store, "a", Value.makeInt(10));
    _ = r;
    const tr = try trace_store.getInvocation(std.testing.allocator, 1);
    defer std.testing.allocator.free(tr.events);

    const e = individual("echo-score", lenScorer);
    const verdicts = try scoreInvocationSteps(std.testing.allocator, e, tr);
    defer std.testing.allocator.free(verdicts);
    // Two completed steps: a: 10→11, b: 11→12. Scores = [11, 12].
    try std.testing.expectEqual(@as(usize, 2), verdicts.len);
    try std.testing.expectEqual(@as(f32, 11.0), verdicts[0].score);
    try std.testing.expectEqual(@as(f32, 12.0), verdicts[1].score);
}
