//! Integration test — proves all 10 rungs of agent-o-nanoclj compose.
//!
//! Not a demo. An end-to-end assertion that the primitives don't just pass
//! their own unit tests but also compose cleanly through a single scenario:
//!
//!   1. Register two tools (Rung 8) in a ToolRegistry
//!   2. Build a 2-agent topology (Rung 3) whose bodies use those tools
//!   3. Create a dataset of inputs/expected pairs (Rung 5a)
//!   4. Wire an Experiment (Rung 5b) with an evaluator (Rung 4)
//!   5. Run cycleUntilFixedPoint (Rung 7) — the agents have state that
//!      evolves between iterations via ReviseFn
//!   6. For each completed invocation, run an Action (Rung 9) that feeds
//!      samples into a TelemetrySink (Rung 10)
//!   7. Assert: convergence, cycle metrics, telemetry aggregates, action
//!      log, and trace records all agree.
//!
//! If this passes, the world composes. If it fails, the regression is in
//! the interfaces between rungs — exactly the thing unit tests can miss.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const aor = @import("aor.zig");

// Shared tool registry + stateful scratch for the world.
var g_scale: i48 = 1;

fn scaleTool(in: Value) aor.ToolError!Value {
    return Value.makeInt(in.asInt() * g_scale);
}

fn incTool(in: Value) aor.ToolError!Value {
    return Value.makeInt(in.asInt() + 1);
}

// Agent bodies. Each uses a tool from the registry (shared in g_*)
// and consults its own .state as a per-agent offset.
var g_registry_ptr: ?*aor.ToolRegistry = null;

fn toolingInc(ctx: *aor.Agent, in: Value) error{Invoke}!Value {
    const reg = g_registry_ptr orelse return error.Invoke;
    const offset: i48 = if (ctx.state) |s| s.asInt() else 0;
    const scaled = reg.call("inc", in) catch return error.Invoke;
    return Value.makeInt(scaled.asInt() + offset);
}

fn toolingScale(ctx: *aor.Agent, in: Value) error{Invoke}!Value {
    const reg = g_registry_ptr orelse return error.Invoke;
    const offset: i48 = if (ctx.state) |s| s.asInt() else 0;
    const scaled = reg.call("scale", in) catch return error.Invoke;
    return Value.makeInt(scaled.asInt() + offset);
}

fn positiveScore(v: Value) aor.eval.EvalError!f32 {
    return @floatFromInt(v.asInt());
}

// Nudge state up on any non-positive verdict — classic "push out of failure".
fn nudgeUp(prior: ?Value, verdicts: []const aor.Verdict) ?Value {
    var any_nonpos = false;
    for (verdicts) |v| if (v.score <= 0.0) {
        any_nonpos = true;
        break;
    };
    if (!any_nonpos) return prior;
    const cur: i48 = if (prior) |p| p.asInt() else 0;
    return Value.makeInt(cur + 1);
}

// Telemetry action: record latency + step count + pass-rate proxy.
var g_sink_ptr: ?*aor.TelemetrySink = null;

fn telemetryAction(info: aor.action.RunInfo) aor.action.ActionError!aor.action.ActionResult {
    const sink = g_sink_ptr orelse return error.ActionFailed;
    sink.ingestRunInfo(info) catch return error.ActionFailed;
    sink.record("output.value", @as(f32, @floatFromInt(info.output.asInt())), "") catch return error.ActionFailed;
    return .{
        .action_name = "telemetry",
        .invoke_id = info.invoke_id,
        .data = info.output,
        .tags = "recorded",
    };
}

test "world composes: 10 rungs through one scenario" {
    // ─── Rung 8: tools ──────────────────────────────────────────────
    var registry = aor.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{ .name = "inc", .description = "+1", .invoke = incTool });
    try registry.register(.{ .name = "scale", .description = "*g_scale", .invoke = scaleTool });
    g_registry_ptr = &registry;
    g_scale = 2;

    // ─── Rungs 1, 3: topology ──────────────────────────────────────
    var topo = aor.Topology.init(std.testing.allocator);
    defer topo.deinit();
    _ = try topo.newAgent("a_inc", toolingInc);
    _ = try topo.newAgent("a_scale", toolingScale);
    try topo.connect("a_inc", "a_scale");

    // ─── Rung 2: trace store ────────────────────────────────────────
    var trace_store = aor.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();

    // ─── Rung 5a: dataset ──────────────────────────────────────────
    var ds = aor.Dataset.init(std.testing.allocator, "world");
    defer ds.deinit();
    try ds.addExample(Value.makeInt(-3), null, "neg");
    try ds.addExample(Value.makeInt(-1), null, "neg");
    try ds.addExample(Value.makeInt(0), null, "zero");

    // ─── Rung 4: evaluator ──────────────────────────────────────────
    const evs = [_]aor.Evaluator{aor.individualEvaluator("positive", positiveScore)};

    // ─── Rung 5b: experiment ───────────────────────────────────────
    var exp = aor.Experiment.init(
        std.testing.allocator,
        "world-e2e",
        &topo,
        &trace_store,
        &ds,
        &evs,
        "a_inc",
    );

    // ─── Rung 7: feedback cycle (fixed point) ───────────────────────
    const targets = [_]aor.TargetRevision{
        .{ .agent_name = "a_inc", .revise = nudgeUp },
        .{ .agent_name = "a_scale", .revise = nudgeUp },
    };
    var cycle_result = try aor.cycleUntilFixedPoint(std.testing.allocator, &exp, &targets, 30);
    defer cycle_result.deinit();

    // Must have stopped at a fixed point.
    try std.testing.expect(cycle_result.stopped_on_predicate);
    try std.testing.expect(cycle_result.iterations >= 1);

    // Convergence metrics are sensible.
    const traj = try cycle_result.passRateTrajectory(std.testing.allocator);
    defer std.testing.allocator.free(traj);
    try std.testing.expect(traj.len == cycle_result.iterations);
    // At fixed point, no target wants to revise — meaning all verdicts are
    // positive — so pass rate of the last iteration is 1.0.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), traj[traj.len - 1], 0.0001);

    // ─── Rungs 9, 10: actions + telemetry ───────────────────────────
    var action_log = aor.ActionLog.init(std.testing.allocator);
    defer action_log.deinit();
    var sink = aor.TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    g_sink_ptr = &sink;

    const actions = [_]aor.Action{
        .{ .name = "telemetry", .description = "emit run stats", .body = telemetryAction },
    };

    // For every invocation recorded during the cycle, run the telemetry action.
    const final_report = cycle_result.last();
    for (final_report.examples) |er| {
        const inv_trace = try trace_store.getInvocation(std.testing.allocator, er.invoke_id);
        defer std.testing.allocator.free(inv_trace.events);
        try aor.runActionsOnInvocation(&actions, inv_trace, &action_log);
    }
    // One log entry per example in the final iteration.
    try std.testing.expectEqual(final_report.examples.len, action_log.count());

    // Telemetry sink got latency + step-count + output.value series.
    const lat = sink.aggregateAll("latency.ns");
    const steps = sink.aggregateAll("step-count");
    const out_vals = sink.aggregateAll("output.value");
    try std.testing.expectEqual(final_report.examples.len, lat.count);
    try std.testing.expectEqual(final_report.examples.len, steps.count);
    try std.testing.expectEqual(final_report.examples.len, out_vals.count);
    // Chain is a → scale (two steps).
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), steps.mean(), 0.0001);
    // At fixed point, all outputs are positive.
    try std.testing.expect(out_vals.min > 0.0);

    // The trace store has at least one event per (iteration × example × 2 agents).
    try std.testing.expect(trace_store.eventCount() >= cycle_result.iterations * 3 * 2);

    g_registry_ptr = null;
    g_sink_ptr = null;
}
