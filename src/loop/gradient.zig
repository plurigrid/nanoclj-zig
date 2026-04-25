//! Gradient tracing for the agent-o-nanoclj feedback loop.
//!
//! This is the numerical complement to `cycleUntil*` — instead of revising
//! agent state via a hand-coded `ReviseFn`, we estimate the per-agent
//! partial derivative of pass rate w.r.t. each agent's integer state and
//! descend along that gradient.
//!
//! Functorial framing (per "funcotriality in control"):
//!   F_play  : Topology → Trace
//!   F_witness : Trace → Verdict / pass-rate
//!   F_coplay : ∇(pass-rate) → Topology'      ← THIS RUNG
//!
//! The gradient IS the formal F_coplay when revise is autoderived rather
//! than supplied. Composition is gradient descent on the world.
//!
//! Method: 1-sided finite difference over a unit perturbation (δ = 1).
//! For agent state `s : ?Value` interpreted as i48:
//!   ∂L/∂s ≈ (L(s + 1) − L(s)) / 1
//! Non-integer / null state contributes ∂L/∂s = 0 (no signal).

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;

const agent_lib = @import("agent.zig");
const topology_lib = @import("topology.zig");
const eval_lib = @import("eval.zig");
const experiment_lib = @import("experiment.zig");
const feedback = @import("feedback.zig");
const trace_lib = @import("trace.zig");

const Topology = topology_lib.Topology;
const TraceStore = trace_lib.TraceStore;
const Experiment = experiment_lib.Experiment;
const Report = experiment_lib.Report;
const TargetRevision = feedback.TargetRevision;

pub const GradientError = error{
    GradientFailed,
    OutOfMemory,
    AgentNotFound,
    DuplicateAgent,
    CycleDetected,
    EvalFailed,
    Invoke,
};

/// One agent's contribution to the loss landscape: partial derivative of
/// pass rate w.r.t. that agent's state at the current point. Sign is the
/// descent direction toward higher pass rate (∇L > 0 → increase state).
pub const Gradient = struct {
    agent_name: []const u8,
    partial: f32,
};

/// Compute ∂pass_rate/∂state for each named agent in `targets` by 1-sided
/// finite difference (δ = +1). Each call costs `1 + |targets|` runs of the
/// experiment. The experiment's TraceStore accumulates events from every
/// probe — caller can filter by invoke_id later if they want only the
/// "real" runs.
pub fn traceGradient(
    allocator: std.mem.Allocator,
    experiment: *Experiment,
    targets: []const []const u8,
) GradientError![]Gradient {
    // Baseline.
    var baseline = experiment.run() catch |e| return mapErr(e);
    defer baseline.deinit();
    const base_rate = baseline.passRate();

    var out: std.ArrayListUnmanaged(Gradient) = .empty;
    errdefer out.deinit(allocator);

    for (targets) |name| {
        const agent = experiment.topology.getAgent(name) orelse return error.AgentNotFound;
        const saved = agent.state;

        // Perturb by +1 (or 1 if state is null).
        const cur: i48 = if (saved) |s| s.asInt() else 0;
        agent.state = Value.makeInt(cur + 1);

        var perturbed = experiment.run() catch |e| {
            agent.state = saved;
            return mapErr(e);
        };
        const perturbed_rate = perturbed.passRate();
        perturbed.deinit();

        agent.state = saved; // restore

        const partial = perturbed_rate - base_rate; // δ = 1, so ∂ = Δ
        try out.append(allocator, .{ .agent_name = name, .partial = partial });
    }
    return out.toOwnedSlice(allocator);
}

/// Result of one full gradient-descent run.
pub const GradientCycleResult = struct {
    allocator: std.mem.Allocator,
    iterations: u32,
    reports: []Report,
    /// Final gradient at the stopping point — useful to confirm we actually
    /// reached a local optimum (norm small).
    final_gradient: []Gradient,

    pub fn deinit(self: *GradientCycleResult) void {
        for (self.reports) |*r| r.deinit();
        self.allocator.free(self.reports);
        self.allocator.free(self.final_gradient);
    }

    /// L1 norm of the gradient. Near zero means converged to a local optimum.
    pub fn gradientNorm(self: *const GradientCycleResult) f32 {
        var s: f32 = 0;
        for (self.final_gradient) |g| s += @abs(g.partial);
        return s;
    }
};

/// Descend along the estimated gradient: each iteration computes
/// ∇pass_rate, takes a step state += round(learning_rate * partial),
/// records the resulting report. Stops on (a) gradient norm below tol,
/// or (b) max_iters.
pub fn cycleByGradient(
    allocator: std.mem.Allocator,
    experiment: *Experiment,
    targets: []const []const u8,
    learning_rate: f32,
    norm_tol: f32,
    max_iters: u32,
) GradientError!GradientCycleResult {
    if (max_iters == 0) return error.GradientFailed;

    // Resolve agents up front for fast state mutation.
    var resolved: std.ArrayListUnmanaged(*agent_lib.Agent) = .empty;
    defer resolved.deinit(allocator);
    try resolved.ensureTotalCapacity(allocator, targets.len);
    for (targets) |name| {
        const a = experiment.topology.getAgent(name) orelse return error.AgentNotFound;
        try resolved.append(allocator, a);
    }

    var reports: std.ArrayListUnmanaged(Report) = .empty;
    errdefer {
        for (reports.items) |*r| r.deinit();
        reports.deinit(allocator);
    }

    var last_grad: []Gradient = &.{};
    errdefer if (last_grad.len > 0) allocator.free(last_grad);

    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        // Free the previous iteration's gradient before allocating a new one.
        if (last_grad.len > 0) allocator.free(last_grad);
        last_grad = try traceGradient(allocator, experiment, targets);

        // Norm check — if gradient is flat, we're done.
        var l1: f32 = 0;
        for (last_grad) |g| l1 += @abs(g.partial);
        if (l1 < norm_tol) {
            // Record one final report at the converged point.
            const final = experiment.run() catch |e| return mapErr(e);
            try reports.append(allocator, final);
            break;
        }

        // Apply gradient step to each target's state.
        for (last_grad, 0..) |g, idx| {
            const agent = resolved.items[idx];
            const cur: i48 = if (agent.state) |s| s.asInt() else 0;
            const step = @as(i48, @intFromFloat(@round(learning_rate * g.partial)));
            // Always make progress in the right direction even if rounding kills it.
            const eff_step: i48 = if (step != 0) step else if (g.partial > 0) 1 else if (g.partial < 0) -1 else 0;
            agent.state = Value.makeInt(cur + eff_step);
        }

        const report = experiment.run() catch |e| return mapErr(e);
        try reports.append(allocator, report);
    }

    return GradientCycleResult{
        .allocator = allocator,
        .iterations = @intCast(reports.items.len),
        .reports = try reports.toOwnedSlice(allocator),
        .final_gradient = last_grad,
    };
}

fn mapErr(e: anyerror) GradientError {
    return switch (e) {
        error.AgentNotFound => GradientError.AgentNotFound,
        error.DuplicateAgent => GradientError.DuplicateAgent,
        error.CycleDetected => GradientError.CycleDetected,
        error.EvalFailed => GradientError.EvalFailed,
        error.Invoke => GradientError.Invoke,
        error.OutOfMemory => GradientError.OutOfMemory,
        else => GradientError.GradientFailed,
    };
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

const dataset_lib = @import("dataset.zig");

fn biasedIncBody(ctx: *agent_lib.Agent, in: Value) error{Invoke}!Value {
    const bias: i48 = if (ctx.state) |s| s.asInt() else 0;
    return Value.makeInt(in.asInt() + 1 + bias);
}

fn identityScorer(v: Value) eval_lib.EvalError!f32 {
    return @floatFromInt(v.asInt());
}

test "traceGradient: positive partial when increasing state improves pass rate" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    // Negative inputs initially fail (output ≤ 0). Increasing state by +1
    // tips one of them positive → pass rate strictly increases.
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "g");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-2), null, "");
    try ds.addExample(Value.makeInt(-1), null, "");
    try ds.addExample(Value.makeInt(0), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "g", &topo, &trace_store, &ds, &evs, "biased_inc");

    const targets = [_][]const u8{"biased_inc"};
    const grads = try traceGradient(std.testing.allocator, &exp, &targets);
    defer std.testing.allocator.free(grads);

    try std.testing.expectEqual(@as(usize, 1), grads.len);
    try std.testing.expectEqualStrings("biased_inc", grads[0].agent_name);
    try std.testing.expect(grads[0].partial > 0); // +1 to state strictly improves
}

test "traceGradient: zero partial when state already saturates pass rate" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    const id = try topo.newAgent("biased_inc", biasedIncBody);
    const agent = &topo.nodes.items[@as(usize, id) - 1].agent;
    agent.state = Value.makeInt(100); // already huge, all examples pass

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "saturated");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-2), null, "");
    try ds.addExample(Value.makeInt(0), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "sat", &topo, &trace_store, &ds, &evs, "biased_inc");

    const grads = try traceGradient(std.testing.allocator, &exp, &.{"biased_inc"});
    defer std.testing.allocator.free(grads);
    try std.testing.expectEqual(@as(f32, 0.0), grads[0].partial);
}

test "cycleByGradient: descends to all-pass on a winnable problem" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "descend");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-3), null, "");
    try ds.addExample(Value.makeInt(-1), null, "");
    try ds.addExample(Value.makeInt(0), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "descend", &topo, &trace_store, &ds, &evs, "biased_inc");

    const targets = [_][]const u8{"biased_inc"};
    var result = try cycleByGradient(std.testing.allocator, &exp, &targets, 5.0, 0.01, 30);
    defer result.deinit();

    try std.testing.expect(result.iterations >= 1);
    // Final iteration should be all-pass.
    const final = &result.reports[result.reports.len - 1];
    try std.testing.expectEqual(@as(usize, 0), final.fail_count);
    // Gradient at the optimum is small (pass rate is 1.0, perturbing up
    // can't improve further → ∇ ≤ 0).
    try std.testing.expect(result.gradientNorm() <= 0.34); // ≤ 1/3 (one example flipping)
}

test "cycleByGradient: errors on unknown target" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("real", biasedIncBody);
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "x");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(0), null, "");
    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "x", &topo, &trace_store, &ds, &evs, "real");

    try std.testing.expectError(
        GradientError.AgentNotFound,
        cycleByGradient(std.testing.allocator, &exp, &.{"missing"}, 1.0, 0.01, 5),
    );
}
