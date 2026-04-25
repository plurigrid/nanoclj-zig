//! Rung 5 of agent-o-nanoclj — experiments.
//!
//! An Experiment ties together:
//!   - a Topology (from Rung 3)
//!   - a Dataset (from this rung)
//!   - one or more Evaluators (from Rung 4)
//!
//! Running the experiment invokes the topology once per dataset example,
//! recording each invocation's trace, then applies each evaluator to the
//! final output. The returned `Report` aggregates per-example verdicts +
//! a pass/fail count (with a configurable predicate).
//!
//! This rung is the "e2e demo" milestone per .topos/agent-o-nanoclj.md §5 —
//! once landed, the equivalent of agent-o-rama's `e2e_test_agent.clj`
//! pattern is expressible on nanoclj-zig primitives.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;

const agent_lib = @import("agent.zig");
const trace_lib = @import("trace.zig");
const topology_lib = @import("topology.zig");
const eval_lib = @import("eval.zig");
const dataset_lib = @import("dataset.zig");

const Topology = topology_lib.Topology;
const TraceStore = trace_lib.TraceStore;
const InvokeId = trace_lib.InvokeId;
const Evaluator = eval_lib.Evaluator;
const Verdict = eval_lib.Verdict;
const Dataset = dataset_lib.Dataset;

pub const ExperimentError = error{
    ExperimentFailed,
    OutOfMemory,
    EvalFailed,
    AgentNotFound,
    DuplicateAgent,
    CycleDetected,
    Invoke,
};

/// A single example's outcome in a run.
pub const ExampleResult = struct {
    invoke_id: InvokeId,
    input: Value,
    output: Value,
    /// One verdict per evaluator in the evaluator list.
    verdicts: []const Verdict,
    pass: bool,
};

/// The aggregate report from running an experiment.
pub const Report = struct {
    allocator: std.mem.Allocator,
    experiment_name: []const u8,
    total: usize,
    pass_count: usize,
    fail_count: usize,
    /// Owned — caller must call `deinit` to release.
    examples: []ExampleResult,

    pub fn deinit(self: *Report) void {
        for (self.examples) |er| self.allocator.free(er.verdicts);
        self.allocator.free(self.examples);
    }

    pub fn passRate(self: *const Report) f32 {
        if (self.total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.pass_count)) / @as(f32, @floatFromInt(self.total));
    }
};

/// Pass predicate: given (expected, actual, verdicts), decide pass/fail.
/// Default: all verdict scores strictly positive (>0) → pass.
pub const PassFn = *const fn (expected: ?Value, actual: Value, verdicts: []const Verdict) bool;

fn defaultPass(_: ?Value, _: Value, verdicts: []const Verdict) bool {
    if (verdicts.len == 0) return true;
    for (verdicts) |v| {
        if (v.score <= 0.0) return false;
    }
    return true;
}

pub const Experiment = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    topology: *Topology,
    trace: *TraceStore,
    dataset: *const Dataset,
    evaluators: []const Evaluator,
    start_agent: []const u8,
    /// Pass predicate; defaults to `defaultPass`.
    pass_fn: PassFn = defaultPass,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        topology: *Topology,
        trace: *TraceStore,
        dataset: *const Dataset,
        evaluators: []const Evaluator,
        start_agent: []const u8,
    ) Experiment {
        return .{
            .allocator = allocator,
            .name = name,
            .topology = topology,
            .trace = trace,
            .dataset = dataset,
            .evaluators = evaluators,
            .start_agent = start_agent,
        };
    }

    pub fn run(self: *Experiment) ExperimentError!Report {
        var results: std.ArrayListUnmanaged(ExampleResult) = .empty;
        errdefer {
            for (results.items) |er| self.allocator.free(er.verdicts);
            results.deinit(self.allocator);
        }

        var pass_n: usize = 0;
        var fail_n: usize = 0;

        for (self.dataset.examples.items) |ex| {
            const invoke_res = topology_lib.invoke(
                self.topology,
                self.trace,
                self.start_agent,
                ex.input,
            ) catch |e| switch (e) {
                error.AgentNotFound => return ExperimentError.AgentNotFound,
                error.DuplicateAgent => return ExperimentError.DuplicateAgent,
                error.CycleDetected => return ExperimentError.CycleDetected,
                error.Invoke => return ExperimentError.Invoke,
                error.OutOfMemory => return ExperimentError.OutOfMemory,
            };

            var verdict_list: std.ArrayListUnmanaged(Verdict) = .empty;
            errdefer verdict_list.deinit(self.allocator);

            for (self.evaluators) |eval| {
                const v = switch (eval.kind()) {
                    .individual => eval_lib.scoreOne(eval, invoke_res.final) catch return ExperimentError.EvalFailed,
                    .comparative => blk: {
                        const exp_val = ex.expected orelse break :blk Verdict{ .evaluator_name = eval.name(), .score = 0.0 };
                        break :blk eval_lib.scorePair(eval, invoke_res.final, exp_val) catch return ExperimentError.EvalFailed;
                    },
                    .summary => blk: {
                        const xs = [_]Value{invoke_res.final};
                        break :blk eval_lib.scoreMany(eval, &xs) catch return ExperimentError.EvalFailed;
                    },
                };
                try verdict_list.append(self.allocator, v);
            }

            const verdicts_slice = try verdict_list.toOwnedSlice(self.allocator);
            const passed = self.pass_fn(ex.expected, invoke_res.final, verdicts_slice);
            if (passed) pass_n += 1 else fail_n += 1;

            try results.append(self.allocator, .{
                .invoke_id = invoke_res.invoke_id,
                .input = ex.input,
                .output = invoke_res.final,
                .verdicts = verdicts_slice,
                .pass = passed,
            });
        }

        return Report{
            .allocator = self.allocator,
            .experiment_name = self.name,
            .total = self.dataset.len(),
            .pass_count = pass_n,
            .fail_count = fail_n,
            .examples = try results.toOwnedSlice(self.allocator),
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests — this is the success-criterion e2e from .topos/agent-o-nanoclj.md §5
// ─────────────────────────────────────────────────────────────────────────

fn incBody(_: *agent_lib.Agent, in: Value) error{Invoke}!Value {
    return Value.makeInt(in.asInt() + 1);
}

fn doubleBody(_: *agent_lib.Agent, in: Value) error{Invoke}!Value {
    return Value.makeInt(in.asInt() * 2);
}

fn identityScorer(v: Value) eval_lib.EvalError!f32 {
    // Pass iff positive (matches defaultPass: score > 0).
    return @floatFromInt(v.asInt());
}

test "Experiment.run: single-agent with individual evaluator" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("inc", incBody);

    var ds = Dataset.init(std.testing.allocator, "inc-set");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(10), null, "");
    try ds.addExample(Value.makeInt(-5), null, "");
    try ds.addExample(Value.makeInt(0), null, "");

    const evaluators = [_]Evaluator{eval_lib.individual("score", identityScorer)};
    var exp = Experiment.init(
        std.testing.allocator,
        "inc-experiment",
        &topo,
        &trace,
        &ds,
        &evaluators,
        "inc",
    );

    var report = try exp.run();
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 3), report.total);
    // 11 > 0 (pass), -4 < 0 (fail), 1 > 0 (pass)
    try std.testing.expectEqual(@as(usize, 2), report.pass_count);
    try std.testing.expectEqual(@as(usize, 1), report.fail_count);
    try std.testing.expectEqualStrings("inc-experiment", report.experiment_name);
    try std.testing.expectEqual(@as(usize, 1), report.examples[0].verdicts.len);
    try std.testing.expect(report.examples[0].pass);
    try std.testing.expect(!report.examples[1].pass);
    try std.testing.expect(report.examples[2].pass);
}

test "Experiment.run: chain topology with dataset + verdicts" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("inc", incBody);
    _ = try topo.newAgent("double", doubleBody);
    try topo.connect("inc", "double");

    var ds = Dataset.init(std.testing.allocator, "chain-set");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(3), null, ""); // (3+1)*2 = 8 → pass
    try ds.addExample(Value.makeInt(-3), null, ""); // (-3+1)*2 = -4 → fail

    const evaluators = [_]Evaluator{eval_lib.individual("score", identityScorer)};
    var exp = Experiment.init(
        std.testing.allocator,
        "chain-exp",
        &topo,
        &trace,
        &ds,
        &evaluators,
        "inc",
    );
    var report = try exp.run();
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.total);
    try std.testing.expectEqual(@as(usize, 1), report.pass_count);
    try std.testing.expectEqual(@as(usize, 1), report.fail_count);
    try std.testing.expectEqual(@as(i48, 8), report.examples[0].output.asInt());
    try std.testing.expectEqual(@as(i48, -4), report.examples[1].output.asInt());
}

test "Report.passRate reflects counts" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("inc", incBody);

    var ds = Dataset.init(std.testing.allocator, "pr");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(1), null, ""); // pass
    try ds.addExample(Value.makeInt(1), null, ""); // pass
    try ds.addExample(Value.makeInt(1), null, ""); // pass
    try ds.addExample(Value.makeInt(-10), null, ""); // fail

    const evaluators = [_]Evaluator{eval_lib.individual("score", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "pr", &topo, &trace, &ds, &evaluators, "inc");
    var report = try exp.run();
    defer report.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 0.75), report.passRate(), 0.0001);
}

test "Experiment with empty dataset → 0 total, rate 0" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("inc", incBody);

    var ds = Dataset.init(std.testing.allocator, "empty");
    defer ds.deinit();

    const evaluators = [_]Evaluator{eval_lib.individual("s", identityScorer)};
    var exp = Experiment.init(std.testing.allocator, "empty-exp", &topo, &trace, &ds, &evaluators, "inc");
    var report = try exp.run();
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.total);
    try std.testing.expectEqual(@as(f32, 0.0), report.passRate());
}
