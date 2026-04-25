//! Rung 7 of agent-o-nanoclj — the feedback-loop closure.
//!
//! This rung closes the world: invocation → trace → evaluator verdicts →
//! revise(agent state, verdicts) → next invocation. A single nanoclj process
//! is enough; no external orchestrator.
//!
//! The primitive:
//!
//!     ReviseFn = (prior_state: ?Value, verdicts: []const Verdict) → ?Value
//!
//! Given an Experiment (from Rung 5) and a `ReviseFn`, `cycleUntil` runs
//! iterations of (run → revise → loop) until either:
//!   - the `stop` predicate fires on the latest Report, or
//!   - `max_iters` iterations have run.
//!
//! The revised state is written onto the `Agent.state` of a caller-specified
//! agent name between iterations — so any agent body that reads `ctx.state`
//! gets the updated signal.
//!
//! Not a demo: this IS the production loop. Without this rung we only have
//! one-shot invocations; with it, the evaluator is wired back into the
//! agent's behavior.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;

const agent_lib = @import("agent.zig");
const eval_lib = @import("eval.zig");
const experiment_lib = @import("experiment.zig");

const Verdict = eval_lib.Verdict;
const Experiment = experiment_lib.Experiment;
const Report = experiment_lib.Report;

pub const FeedbackError = error{
    FeedbackFailed,
    TargetAgentMissing,
    OutOfMemory,
    ExperimentFailed,
    EvalFailed,
    AgentNotFound,
    DuplicateAgent,
    CycleDetected,
    Invoke,
};

/// User-supplied revision: take the current state and the full verdict list
/// from the last iteration's report; produce the new state (or null to
/// clear).
pub const ReviseFn = *const fn (prior: ?Value, verdicts: []const Verdict) ?Value;

/// Stop predicate: inspect a Report, return true to halt the cycle.
pub const StopFn = *const fn (report: *const Report) bool;

pub const CycleResult = struct {
    allocator: std.mem.Allocator,
    iterations: u32,
    reports: []Report,
    /// True iff the stop predicate fired on the last iteration (vs running
    /// out of `max_iters`).
    stopped_on_predicate: bool,

    pub fn deinit(self: *CycleResult) void {
        for (self.reports) |*r| r.deinit();
        self.allocator.free(self.reports);
    }

    pub fn last(self: *const CycleResult) *const Report {
        return &self.reports[self.reports.len - 1];
    }

    /// Pass-rate at each iteration. Caller owns returned slice.
    pub fn passRateTrajectory(self: *const CycleResult, allocator: std.mem.Allocator) ![]f32 {
        const out = try allocator.alloc(f32, self.reports.len);
        for (self.reports, 0..) |*r, i| out[i] = r.passRate();
        return out;
    }

    /// Change in pass rate from the previous iteration to the final.
    /// +ve = converging, 0 = flat, -ve = diverging. Returns 0 if <2 iters.
    pub fn lastDelta(self: *const CycleResult) f32 {
        if (self.reports.len < 2) return 0.0;
        const n = self.reports.len;
        return self.reports[n - 1].passRate() - self.reports[n - 2].passRate();
    }

    /// True iff pass rate strictly decreased across the last `window`
    /// iterations — an early signal to abort a non-converging loop.
    pub fn isDiverging(self: *const CycleResult, window: usize) bool {
        if (self.reports.len < window + 1) return false;
        const n = self.reports.len;
        var i: usize = n - window;
        while (i < n) : (i += 1) {
            if (self.reports[i].passRate() >= self.reports[i - 1].passRate()) return false;
        }
        return true;
    }
};

/// Run the feedback loop. `target_agent_name` is the agent whose `.state`
/// receives the revised value between iterations.
pub fn cycleUntil(
    allocator: std.mem.Allocator,
    experiment: *Experiment,
    target_agent_name: []const u8,
    revise: ReviseFn,
    stop: StopFn,
    max_iters: u32,
) FeedbackError!CycleResult {
    if (max_iters == 0) return error.FeedbackFailed;

    const target = experiment.topology.getAgent(target_agent_name) orelse return error.TargetAgentMissing;

    var reports: std.ArrayListUnmanaged(Report) = .empty;
    errdefer {
        for (reports.items) |*r| r.deinit();
        reports.deinit(allocator);
    }

    var stopped: bool = false;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        var report = experiment.run() catch |e| switch (e) {
            error.AgentNotFound => return error.AgentNotFound,
            error.DuplicateAgent => return error.DuplicateAgent,
            error.CycleDetected => return error.CycleDetected,
            error.ExperimentFailed => return error.ExperimentFailed,
            error.EvalFailed => return error.EvalFailed,
            error.Invoke => return error.Invoke,
            error.OutOfMemory => return error.OutOfMemory,
        };

        // Aggregate the verdicts across this iteration's examples so the
        // revise function sees the whole verdict set.
        var all_verdicts: std.ArrayListUnmanaged(Verdict) = .empty;
        defer all_verdicts.deinit(allocator);
        for (report.examples) |ex| {
            for (ex.verdicts) |v| {
                all_verdicts.append(allocator, v) catch |e| {
                    report.deinit();
                    return e;
                };
            }
        }

        if (stop(&report)) {
            stopped = true;
            try reports.append(allocator, report);
            break;
        }

        // Revise the target agent's state for the next iteration.
        target.state = revise(target.state, all_verdicts.items);
        try reports.append(allocator, report);
    }

    const iters = @as(u32, @intCast(reports.items.len));
    return CycleResult{
        .allocator = allocator,
        .iterations = iters,
        .reports = try reports.toOwnedSlice(allocator),
        .stopped_on_predicate = stopped,
    };
}

// ─────────────────────────────────────────────────────────────────────────
// Tests — the world runs; the feedback loop converges.
// ─────────────────────────────────────────────────────────────────────────

const trace_lib = @import("trace.zig");
const topology_lib = @import("topology.zig");
const dataset_lib = @import("dataset.zig");

/// Body that adds its own state (if set) to the input.
/// Uses @fieldParentPtr pattern — read the state from ctx.state.
fn biasedIncBody(ctx: *agent_lib.Agent, in: Value) error{Invoke}!Value {
    const bias: i48 = if (ctx.state) |s| s.asInt() else 0;
    return Value.makeInt(in.asInt() + 1 + bias);
}

fn identityScorer(v: Value) eval_lib.EvalError!f32 {
    return @floatFromInt(v.asInt());
}

/// Revise: if any verdict ≤ 0, nudge state up by 1 (so next iteration's
/// output is higher); otherwise keep.
fn nudgeUp(prior: ?Value, verdicts: []const Verdict) ?Value {
    var any_nonpos = false;
    for (verdicts) |v| if (v.primaryScore() <= 0.0) {
        any_nonpos = true;
        break;
    };
    if (!any_nonpos) return prior;
    const cur: i48 = if (prior) |p| p.asInt() else 0;
    return Value.makeInt(cur + 1);
}

/// Stop once all examples pass.
fn stopAllPass(report: *const Report) bool {
    return report.total > 0 and report.fail_count == 0;
}

test "cycleUntil: revises state until all examples pass" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    // Start state is null (bias=0). Worst example (-5) fails at iter 0
    // (output = -5 + 1 = -4). Revise nudges bias up by 1 each iter until
    // -5 + 1 + bias > 0 → bias > 4 → takes 5 revisions.
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "biased");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-5), null, "");
    try ds.addExample(Value.makeInt(-3), null, "");
    try ds.addExample(Value.makeInt(-1), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(
        std.testing.allocator,
        "loop",
        &topo,
        &trace_store,
        &ds,
        &evs,
        "biased_inc",
    );

    var result = try cycleUntil(std.testing.allocator, &exp, "biased_inc", nudgeUp, stopAllPass, 10);
    defer result.deinit();

    try std.testing.expect(result.stopped_on_predicate);
    try std.testing.expect(result.iterations >= 5);
    const last = result.last();
    try std.testing.expectEqual(@as(usize, 0), last.fail_count);
    try std.testing.expectEqual(@as(usize, 3), last.pass_count);
}

test "cycleUntil: max_iters caps iteration when stop never fires" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "never");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-1000), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(
        std.testing.allocator,
        "capped",
        &topo,
        &trace_store,
        &ds,
        &evs,
        "biased_inc",
    );

    var result = try cycleUntil(std.testing.allocator, &exp, "biased_inc", nudgeUp, stopAllPass, 3);
    defer result.deinit();
    try std.testing.expect(!result.stopped_on_predicate);
    try std.testing.expectEqual(@as(u32, 3), result.iterations);
}

test "cycleUntil: missing target agent errors cleanly" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "x");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(0), null, "");
    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "e", &topo, &trace_store, &ds, &evs, "biased_inc");

    try std.testing.expectError(
        FeedbackError.TargetAgentMissing,
        cycleUntil(std.testing.allocator, &exp, "missing", nudgeUp, stopAllPass, 5),
    );
}

test "passRateTrajectory traces convergence across iterations" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "traj");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-3), null, "");
    try ds.addExample(Value.makeInt(-1), null, "");
    try ds.addExample(Value.makeInt(1), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "t", &topo, &trace_store, &ds, &evs, "biased_inc");
    var result = try cycleUntil(std.testing.allocator, &exp, "biased_inc", nudgeUp, stopAllPass, 10);
    defer result.deinit();

    const traj = try result.passRateTrajectory(std.testing.allocator);
    defer std.testing.allocator.free(traj);
    try std.testing.expect(traj.len == result.iterations);
    // Pass rate should be monotonically non-decreasing for a converging loop.
    var i: usize = 1;
    while (i < traj.len) : (i += 1) {
        try std.testing.expect(traj[i] >= traj[i - 1]);
    }
    // Final iteration is all-pass.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), traj[traj.len - 1], 0.0001);
}

test "lastDelta reports final change; isDiverging false on converging run" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "c");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-5), null, "");
    try ds.addExample(Value.makeInt(0), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "c", &topo, &trace_store, &ds, &evs, "biased_inc");
    var result = try cycleUntil(std.testing.allocator, &exp, "biased_inc", nudgeUp, stopAllPass, 10);
    defer result.deinit();
    // Converging run is never diverging.
    try std.testing.expect(!result.isDiverging(1));
    try std.testing.expect(!result.isDiverging(3));
    // Final delta must be ≥ 0 on a converging run.
    try std.testing.expect(result.lastDelta() >= 0.0);
}

/// A named agent + its revise function. The world's ultimate feedback loop
/// takes many of these at once: each agent in the topology reads the shared
/// verdict set and rewrites its own state accordingly.
pub const TargetRevision = struct {
    agent_name: []const u8,
    revise: ReviseFn,
};

/// Compare two `?Value`s for bit-identical equality. Sufficient for
/// Nash-fixed-point detection where `revise(s, …) == s` is the stop sign.
fn valueEql(a: ?Value, b: ?Value) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.bits == b.?.bits;
}

/// Run the multi-target cycle until every target's revise returns its own
/// current state unchanged for one full iteration — i.e. the system is at
/// a Nash fixed point in the revision lattice. This is a stricter closure
/// than all-pass: the loop halts when no further adjustment is wanted, even
/// if some examples still fail.
///
/// Returns a CycleResult whose `stopped_on_predicate` is true iff a fixed
/// point was reached (vs max_iters).
pub fn cycleUntilFixedPoint(
    allocator: std.mem.Allocator,
    experiment: *Experiment,
    targets: []const TargetRevision,
    max_iters: u32,
) FeedbackError!CycleResult {
    if (max_iters == 0) return error.FeedbackFailed;

    var resolved: std.ArrayListUnmanaged(*agent_lib.Agent) = .empty;
    defer resolved.deinit(allocator);
    try resolved.ensureTotalCapacity(allocator, targets.len);
    for (targets) |t| {
        const a = experiment.topology.getAgent(t.agent_name) orelse return error.TargetAgentMissing;
        try resolved.append(allocator, a);
    }

    var reports: std.ArrayListUnmanaged(Report) = .empty;
    errdefer {
        for (reports.items) |*r| r.deinit();
        reports.deinit(allocator);
    }

    var fixed_point: bool = false;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        var report = experiment.run() catch |e| switch (e) {
            error.AgentNotFound => return error.AgentNotFound,
            error.DuplicateAgent => return error.DuplicateAgent,
            error.CycleDetected => return error.CycleDetected,
            error.ExperimentFailed => return error.ExperimentFailed,
            error.EvalFailed => return error.EvalFailed,
            error.Invoke => return error.Invoke,
            error.OutOfMemory => return error.OutOfMemory,
        };

        var all_verdicts: std.ArrayListUnmanaged(Verdict) = .empty;
        defer all_verdicts.deinit(allocator);
        for (report.examples) |ex| {
            for (ex.verdicts) |v| {
                all_verdicts.append(allocator, v) catch |e| {
                    report.deinit();
                    return e;
                };
            }
        }

        // Compute proposed revisions; if every single one is a no-op,
        // we've reached a Nash fixed point in the revision lattice.
        var any_changed = false;
        for (targets, 0..) |t, idx| {
            const cur = resolved.items[idx].state;
            const proposed = t.revise(cur, all_verdicts.items);
            if (!valueEql(cur, proposed)) {
                any_changed = true;
            }
        }

        if (!any_changed) {
            fixed_point = true;
            try reports.append(allocator, report);
            break;
        }

        // Apply the revisions we just computed.
        for (targets, 0..) |t, idx| {
            resolved.items[idx].state = t.revise(resolved.items[idx].state, all_verdicts.items);
        }
        try reports.append(allocator, report);
    }

    const iters = @as(u32, @intCast(reports.items.len));
    return CycleResult{
        .allocator = allocator,
        .iterations = iters,
        .reports = try reports.toOwnedSlice(allocator),
        .stopped_on_predicate = fixed_point,
    };
}

/// Like `cycleUntil` but multi-target: every iteration, all named agents
/// have their state revised from the same verdict set. Agents not listed
/// keep their state unchanged. This is the actual world-shape — one
/// verdict stream, many agents each adjusting in their own way.
pub fn cycleUntilMulti(
    allocator: std.mem.Allocator,
    experiment: *Experiment,
    targets: []const TargetRevision,
    stop: StopFn,
    max_iters: u32,
) FeedbackError!CycleResult {
    if (max_iters == 0) return error.FeedbackFailed;

    // Resolve each target name → agent pointer up front so we fail fast on
    // misnamed targets.
    var resolved: std.ArrayListUnmanaged(*agent_lib.Agent) = .empty;
    defer resolved.deinit(allocator);
    try resolved.ensureTotalCapacity(allocator, targets.len);
    for (targets) |t| {
        const a = experiment.topology.getAgent(t.agent_name) orelse return error.TargetAgentMissing;
        try resolved.append(allocator, a);
    }

    var reports: std.ArrayListUnmanaged(Report) = .empty;
    errdefer {
        for (reports.items) |*r| r.deinit();
        reports.deinit(allocator);
    }

    var stopped: bool = false;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        var report = experiment.run() catch |e| switch (e) {
            error.AgentNotFound => return error.AgentNotFound,
            error.DuplicateAgent => return error.DuplicateAgent,
            error.CycleDetected => return error.CycleDetected,
            error.ExperimentFailed => return error.ExperimentFailed,
            error.EvalFailed => return error.EvalFailed,
            error.Invoke => return error.Invoke,
            error.OutOfMemory => return error.OutOfMemory,
        };

        var all_verdicts: std.ArrayListUnmanaged(Verdict) = .empty;
        defer all_verdicts.deinit(allocator);
        for (report.examples) |ex| {
            for (ex.verdicts) |v| {
                all_verdicts.append(allocator, v) catch |e| {
                    report.deinit();
                    return e;
                };
            }
        }

        if (stop(&report)) {
            stopped = true;
            try reports.append(allocator, report);
            break;
        }

        // Apply every target's revise to the shared verdict set.
        for (targets, 0..) |t, idx| {
            resolved.items[idx].state = t.revise(resolved.items[idx].state, all_verdicts.items);
        }
        try reports.append(allocator, report);
    }

    const iters = @as(u32, @intCast(reports.items.len));
    return CycleResult{
        .allocator = allocator,
        .iterations = iters,
        .reports = try reports.toOwnedSlice(allocator),
        .stopped_on_predicate = stopped,
    };
}

// Multi-target feedback test helpers.

fn biasedDoubleBody(ctx: *agent_lib.Agent, in: Value) error{Invoke}!Value {
    const bias: i48 = if (ctx.state) |s| s.asInt() else 0;
    // Double then add bias, so a "negative" bias counter-acts the double.
    return Value.makeInt(in.asInt() * 2 + bias);
}

fn nudgeDown(prior: ?Value, verdicts: []const Verdict) ?Value {
    var any_nonpos = false;
    for (verdicts) |v| if (v.primaryScore() <= 0.0) {
        any_nonpos = true;
        break;
    };
    if (!any_nonpos) return prior;
    const cur: i48 = if (prior) |p| p.asInt() else 0;
    return Value.makeInt(cur - 1);
}

test "cycleUntilMulti: two targets with opposing revisions both converge" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);
    _ = try topo.newAgent("biased_dbl", biasedDoubleBody);
    try topo.connect("biased_inc", "biased_dbl");

    // Input -5 chained: (-5 + 1 + bias_inc) * 2 + bias_dbl.
    // With bias_inc = 0, bias_dbl = 0: output = -8 (fails, score ≤ 0).
    // nudgeUp raises bias_inc; nudgeDown lowers bias_dbl — both try to push
    // the chained output into positive. Converges.
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "multi");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-5), null, "");
    try ds.addExample(Value.makeInt(-2), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(
        std.testing.allocator,
        "multi",
        &topo,
        &trace_store,
        &ds,
        &evs,
        "biased_inc",
    );

    const targets = [_]TargetRevision{
        .{ .agent_name = "biased_inc", .revise = nudgeUp },
        .{ .agent_name = "biased_dbl", .revise = nudgeDown },
    };
    var result = try cycleUntilMulti(std.testing.allocator, &exp, &targets, stopAllPass, 50);
    defer result.deinit();
    try std.testing.expect(result.stopped_on_predicate);
    try std.testing.expectEqual(@as(usize, 0), result.last().fail_count);
}

test "cycleUntilMulti: unresolved target name errors at dispatch" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("real", biasedIncBody);
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "x");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(0), null, "");
    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "e", &topo, &trace_store, &ds, &evs, "real");

    const targets = [_]TargetRevision{
        .{ .agent_name = "real", .revise = nudgeUp },
        .{ .agent_name = "ghost", .revise = nudgeUp }, // not in topology
    };
    try std.testing.expectError(
        FeedbackError.TargetAgentMissing,
        cycleUntilMulti(std.testing.allocator, &exp, &targets, stopAllPass, 5),
    );
}

/// Revise that stops nudging once passRate is satisfied for this verdict
/// set (returns prior unchanged). Lets us test cycleUntilFixedPoint.
fn nudgeUpThenHold(prior: ?Value, verdicts: []const Verdict) ?Value {
    for (verdicts) |v| {
        if (v.primaryScore() <= 0.0) {
            const cur: i48 = if (prior) |p| p.asInt() else 0;
            return Value.makeInt(cur + 1);
        }
    }
    // No failing verdicts → no revision wanted → fixed point.
    return prior;
}

test "cycleUntilFixedPoint halts when no target wants to revise" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    // Dataset starts failing; after enough nudges, all pass; further nudges
    // would be no-ops because every verdict is positive. That's the fixed
    // point.
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "fp");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-4), null, "");
    try ds.addExample(Value.makeInt(-2), null, "");
    try ds.addExample(Value.makeInt(0), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "fp", &topo, &trace_store, &ds, &evs, "biased_inc");
    const targets = [_]TargetRevision{
        .{ .agent_name = "biased_inc", .revise = nudgeUpThenHold },
    };
    var result = try cycleUntilFixedPoint(std.testing.allocator, &exp, &targets, 20);
    defer result.deinit();

    try std.testing.expect(result.stopped_on_predicate); // reached fixed point
    try std.testing.expectEqual(@as(usize, 0), result.last().fail_count);
}

test "cycleUntilFixedPoint: never-converging revise hits max_iters" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "oscillate");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-1000), null, ""); // hard to fix

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "osc", &topo, &trace_store, &ds, &evs, "biased_inc");
    const targets = [_]TargetRevision{
        .{ .agent_name = "biased_inc", .revise = nudgeUp }, // never halts
    };
    var result = try cycleUntilFixedPoint(std.testing.allocator, &exp, &targets, 5);
    defer result.deinit();
    try std.testing.expect(!result.stopped_on_predicate);
    try std.testing.expectEqual(@as(u32, 5), result.iterations);
}

test "cycleUntil: max_iters=0 errors" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("biased_inc", biasedIncBody);
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "x");
    defer ds.deinit();
    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "e", &topo, &trace_store, &ds, &evs, "biased_inc");
    try std.testing.expectError(
        FeedbackError.FeedbackFailed,
        cycleUntil(std.testing.allocator, &exp, "biased_inc", nudgeUp, stopAllPass, 0),
    );
}
