//! §6.3 — unified cycle combinator (additive overlay).
//!
//! Step × Stop × Frontier → Trajectory.
//!
//! Existing `cycleUntil` / `cycleUntilMulti` / `cycleUntilFixedPoint`
//! (in feedback.zig) and `cycleByGradient` (in gradient.zig) keep their
//! current signatures and tests. This module adds a NEW entry point that
//! they will eventually reduce to as 3-line wrappers.
//!
//! SDF anchor: combinator with standardized interface (Sussman/Hanson
//! 2021, ch. 1). Step and Stop are orthogonal axes; new variants land
//! as new enum cases without touching existing call sites.
//!
//! Today's coverage:
//!   Step  — `.revise` (full)
//!         — `.gradient` / `.custom` (declared, body returns NotImplemented)
//!   Stop  — `.iters` / `.fixed_point` / `.pass_rate` / `.custom` (full)
//!   Frontier — 1 only; ≥2 reserved for ProTeGi-style beam-search.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;

const eval_lib = @import("eval.zig");
const experiment_lib = @import("experiment.zig");
const feedback_lib = @import("feedback.zig");
const agent_lib = @import("agent.zig");

const Verdict = eval_lib.Verdict;
const Experiment = experiment_lib.Experiment;
const Report = experiment_lib.Report;
const TargetRevision = feedback_lib.TargetRevision;
const ReviseFn = feedback_lib.ReviseFn;
const StopFn = feedback_lib.StopFn;

pub const CycleError = error{
    CycleFailed,
    OutOfMemory,
    AgentNotFound,
    DuplicateAgent,
    CycleDetected,
    EvalFailed,
    Invoke,
    ExperimentFailed,
    NotImplemented,
};

/// One axis of the combinator: how the topology mutates between iterations.
pub const Step = union(enum) {
    /// Apply per-target ReviseFn against the latest report's verdicts.
    /// Reproduces today's cycleUntilMulti / cycleUntilFixedPoint shape.
    revise: ReviseSpec,

    /// Reserved: gradient descent on agent integer states. Today's
    /// cycleByGradient owns this; the combinator returns NotImplemented
    /// until that function is folded in.
    gradient: GradientSpec,

    /// Caller-supplied step closure. Used by curricula that mutate state
    /// in non-revise / non-gradient ways (e.g., ProTeGi's `mutate-prompt`).
    custom: CustomSpec,

    pub const ReviseSpec = struct {
        targets: []const TargetRevision,
    };

    pub const GradientSpec = struct {
        target_names: []const []const u8,
        learning_rate: f32,
    };

    pub const CustomSpec = struct {
        body: *const fn (*Experiment, *const Report) anyerror!void,
    };
};

/// One axis of the combinator: when to halt.
pub const Stop = union(enum) {
    /// Halt after exactly `n` iterations. Always terminates.
    iters: u32,

    /// Halt when an iteration's revise step makes no changes
    /// (every target's revise returns its prior state). Reproduces
    /// `cycleUntilFixedPoint`. Only meaningful with `Step.revise`.
    fixed_point: void,

    /// Halt when last report's `passRate()` ≥ the threshold.
    pass_rate: f32,

    /// Halt via caller-supplied predicate over the latest Report.
    custom: StopFn,
};

/// Output: owned slice of per-iteration Reports plus a `stopped_on_predicate`
/// flag (true iff the stop axis fired vs running out of `max_iters`).
pub const Trajectory = struct {
    allocator: std.mem.Allocator,
    iterations: u32,
    reports: []Report,
    stopped_on_predicate: bool,

    pub fn deinit(self: *Trajectory) void {
        for (self.reports) |*r| r.deinit();
        self.allocator.free(self.reports);
    }

    pub fn last(self: *const Trajectory) *const Report {
        return &self.reports[self.reports.len - 1];
    }

    pub fn passRate(self: *const Trajectory) f32 {
        return self.last().passRate();
    }
};

/// Run `experiment`, apply `step` between iterations, halt when `stop`
/// fires or `max_iters` elapses. `frontier` reserved for ≥2 (beam-search);
/// today only `frontier == 1` is supported.
pub fn cycle(
    allocator: std.mem.Allocator,
    experiment: *Experiment,
    step: Step,
    stop: Stop,
    frontier: u32,
    max_iters: u32,
) CycleError!Trajectory {
    if (frontier != 1) return error.NotImplemented;
    if (max_iters == 0) return error.CycleFailed;

    var reports: std.ArrayListUnmanaged(Report) = .empty;
    errdefer {
        for (reports.items) |*r| r.deinit();
        reports.deinit(allocator);
    }

    var stopped: bool = false;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        var report = experiment.run() catch |e| return mapErr(e);

        // Test stop predicate against the fresh report (before any step).
        const halt: bool = switch (stop) {
            .iters => i + 1 >= max_iters,
            .fixed_point => false, // checked after apply
            .pass_rate => |t| report.passRate() >= t,
            .custom => |f| f(&report),
        };
        try reports.append(allocator, report);

        if (halt) {
            stopped = stop != .iters;
            break;
        }

        // Apply step. No mutation on the final allowable iteration since
        // we won't run another experiment after it.
        if (i + 1 < max_iters) {
            switch (step) {
                .revise => |spec| {
                    const last_idx = reports.items.len - 1;
                    const any_changed = try applyRevise(
                        experiment,
                        spec.targets,
                        &reports.items[last_idx],
                    );
                    if (stop == .fixed_point and !any_changed) {
                        stopped = true;
                        break;
                    }
                },
                .gradient => return error.NotImplemented,
                .custom => |spec| {
                    const last_idx = reports.items.len - 1;
                    spec.body(experiment, &reports.items[last_idx]) catch return error.CycleFailed;
                },
            }
        }
    }

    return Trajectory{
        .allocator = allocator,
        .iterations = @intCast(reports.items.len),
        .reports = try reports.toOwnedSlice(allocator),
        .stopped_on_predicate = stopped,
    };
}

fn applyRevise(
    experiment: *Experiment,
    targets: []const TargetRevision,
    report: *const Report,
) !bool {
    // Aggregate verdicts across all examples in the report.
    var verdicts: std.ArrayListUnmanaged(Verdict) = .empty;
    defer verdicts.deinit(experiment.allocator);
    for (report.examples) |er| {
        for (er.verdicts) |v| try verdicts.append(experiment.allocator, v);
    }

    var any_changed = false;
    for (targets) |t| {
        const a = experiment.topology.getAgent(t.agent_name) orelse return error.AgentNotFound;
        const new_state = t.revise(a.state, verdicts.items);
        if (!eqOptValue(a.state, new_state)) any_changed = true;
        a.state = new_state;
    }
    return any_changed;
}

fn eqOptValue(a: ?Value, b: ?Value) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.bits == b.?.bits;
}

fn mapErr(e: anyerror) CycleError {
    return switch (e) {
        error.AgentNotFound => CycleError.AgentNotFound,
        error.DuplicateAgent => CycleError.DuplicateAgent,
        error.CycleDetected => CycleError.CycleDetected,
        error.EvalFailed => CycleError.EvalFailed,
        error.Invoke => CycleError.Invoke,
        error.OutOfMemory => CycleError.OutOfMemory,
        error.ExperimentFailed => CycleError.ExperimentFailed,
        else => CycleError.CycleFailed,
    };
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

const dataset_lib = @import("dataset.zig");
const topology_lib = @import("topology.zig");
const trace_lib = @import("trace.zig");

fn biasedIncBody(ctx: *agent_lib.Agent, in: Value) error{Invoke}!Value {
    const bias: i48 = if (ctx.state) |s| s.asInt() else 0;
    return Value.makeInt(in.asInt() + 1 + bias);
}

fn identityScorer(v: Value) eval_lib.EvalError!f32 {
    return @floatFromInt(v.asInt());
}

fn nudgeUpRevise(prior: ?Value, _: []const Verdict) ?Value {
    const cur: i48 = if (prior) |p| p.asInt() else 0;
    return Value.makeInt(cur + 1);
}

fn neverChangeRevise(prior: ?Value, _: []const Verdict) ?Value {
    return prior;
}

test "cycle .iters runs exactly N iterations" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "iters");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(0), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "iters", &topo, &trace_store, &ds, &evs, "inc");

    const targets = [_]TargetRevision{
        .{ .agent_name = "inc", .revise = nudgeUpRevise },
    };

    var traj = try cycle(
        std.testing.allocator,
        &exp,
        .{ .revise = .{ .targets = &targets } },
        .{ .iters = 3 },
        1,
        3,
    );
    defer traj.deinit();
    try std.testing.expectEqual(@as(u32, 3), traj.iterations);
}

test "cycle .pass_rate halts when threshold reached" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "pass");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-1), null, "");
    try ds.addExample(Value.makeInt(0), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "pass", &topo, &trace_store, &ds, &evs, "inc");

    const targets = [_]TargetRevision{
        .{ .agent_name = "inc", .revise = nudgeUpRevise },
    };

    var traj = try cycle(
        std.testing.allocator,
        &exp,
        .{ .revise = .{ .targets = &targets } },
        .{ .pass_rate = 1.0 },
        1,
        50,
    );
    defer traj.deinit();
    try std.testing.expect(traj.stopped_on_predicate);
    try std.testing.expectEqual(@as(f32, 1.0), traj.passRate());
    // Bias starts at 0; -1+1+bias>0 needs bias≥1; 0+1+bias>0 needs bias≥0.
    // After 1 revise: bias=1; both inputs pass. So at most 2 iterations.
    try std.testing.expect(traj.iterations <= 3);
}

test "cycle .fixed_point halts when revise is a no-op" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", biasedIncBody);

    var ds = dataset_lib.Dataset.init(std.testing.allocator, "fp");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(5), null, "");

    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "fp", &topo, &trace_store, &ds, &evs, "inc");

    const targets = [_]TargetRevision{
        .{ .agent_name = "inc", .revise = neverChangeRevise },
    };

    var traj = try cycle(
        std.testing.allocator,
        &exp,
        .{ .revise = .{ .targets = &targets } },
        .{ .fixed_point = {} },
        1,
        10,
    );
    defer traj.deinit();
    try std.testing.expect(traj.stopped_on_predicate);
    // Initial state is null, neverChangeRevise returns null → no change on
    // first apply, halt triggered after iter 1.
    try std.testing.expect(traj.iterations <= 2);
}

test "cycle frontier > 1 is not implemented yet" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", biasedIncBody);
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "f");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(0), null, "");
    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "f", &topo, &trace_store, &ds, &evs, "inc");
    const targets = [_]TargetRevision{
        .{ .agent_name = "inc", .revise = nudgeUpRevise },
    };
    try std.testing.expectError(
        CycleError.NotImplemented,
        cycle(
            std.testing.allocator,
            &exp,
            .{ .revise = .{ .targets = &targets } },
            .{ .iters = 1 },
            2, // frontier=2 → not implemented
            5,
        ),
    );
}

test "cycle gradient step is not implemented yet" {
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", biasedIncBody);
    var ds = dataset_lib.Dataset.init(std.testing.allocator, "g");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(0), null, "");
    const evs = [_]eval_lib.Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "g", &topo, &trace_store, &ds, &evs, "inc");
    const names = [_][]const u8{"inc"};
    try std.testing.expectError(
        CycleError.NotImplemented,
        cycle(
            std.testing.allocator,
            &exp,
            .{ .gradient = .{ .target_names = &names, .learning_rate = 1.0 } },
            .{ .iters = 3 },
            1,
            5,
        ),
    );
}
