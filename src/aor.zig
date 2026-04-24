//! agent-o-nanoclj — an agent-o-rama-inspired layer on nanoclj-zig.
//!
//! Top-level namespace; re-exports the rungs as they land. See
//! `.topos/agent-o-nanoclj.md` for the full architecture.
//!
//! Naming: `Aor` prefix everywhere so this doesn't collide with nanoclj's
//! existing Clojure `agent` (STM-style, in src/agent.zig + src/refs_agents.zig).

const std = @import("std");

pub const agent = @import("aor_agent.zig");
pub const trace = @import("aor_trace.zig");
pub const topology = @import("aor_topology.zig");
pub const eval = @import("aor_eval.zig");
pub const dataset = @import("aor_dataset.zig");
pub const experiment = @import("aor_experiment.zig");
pub const feedback = @import("aor_feedback.zig");
pub const tool = @import("aor_tool.zig");
pub const action = @import("aor_action.zig");
pub const telemetry = @import("aor_telemetry.zig");

/// Rung 1: Agent primitive.
pub const Agent = agent.Agent;
pub const AgentFn = agent.AgentFn;
pub const AgentId = agent.AgentId;
pub const invokeStateless = agent.invokeStateless;

/// Rung 2: Trace store.
pub const InvokeId = trace.InvokeId;
pub const TraceEvent = trace.TraceEvent;
pub const TraceStore = trace.TraceStore;
pub const InvocationTrace = trace.InvocationTrace;

/// Rung 3: Topology + invocation.
pub const Topology = topology.Topology;
pub const Edge = topology.Edge;
pub const InvokeResult = topology.InvokeResult;
pub const TopologyError = topology.TopologyError;
pub const invoke = topology.invoke;

/// Rung 4: Evaluator.
pub const Evaluator = eval.Evaluator;
pub const EvalKind = eval.EvalKind;
pub const Preference = eval.Preference;
pub const Verdict = eval.Verdict;
pub const individualEvaluator = eval.individual;
pub const comparativeEvaluator = eval.comparative;
pub const summaryEvaluator = eval.summary;
pub const tryEvaluator = eval.tryEvaluator;
pub const tryComparative = eval.tryComparative;
pub const trySummary = eval.trySummary;
pub const tryAny = eval.tryAny;

/// Rung 5: Dataset + Experiment.
pub const Example = dataset.Example;
pub const Dataset = dataset.Dataset;
pub const Experiment = experiment.Experiment;
pub const ExampleResult = experiment.ExampleResult;
pub const Report = experiment.Report;
pub const PassFn = experiment.PassFn;

/// Rung 7: Feedback-loop closure (invocation → verdict → revise → invocation).
pub const CycleResult = feedback.CycleResult;
pub const ReviseFn = feedback.ReviseFn;
pub const StopFn = feedback.StopFn;
pub const TargetRevision = feedback.TargetRevision;
pub const cycleUntil = feedback.cycleUntil;
pub const cycleUntilMulti = feedback.cycleUntilMulti;
pub const cycleUntilFixedPoint = feedback.cycleUntilFixedPoint;

/// Rung 8: Tool + ToolRegistry (agent-o-rama's function-calling primitive).
pub const Tool = tool.Tool;
pub const ToolFn = tool.ToolFn;
pub const ToolRegistry = tool.ToolRegistry;
pub const ToolError = tool.ToolError;

/// Rung 9: Action + ActionLog (the side-effect side of the invocation hook).
pub const Action = action.Action;
pub const ActionFn = action.ActionFn;
pub const ActionResult = action.ActionResult;
pub const ActionLog = action.ActionLog;
pub const RunInfo = action.RunInfo;
pub const runAction = action.runAction;
pub const runActionsOnInvocation = action.runActionsOnInvocation;

/// Rung 10: Telemetry aggregator (outer monitor over the inner loop).
pub const Sample = telemetry.Sample;
pub const Series = telemetry.Series;
pub const Aggregate = telemetry.Aggregate;
pub const TelemetrySink = telemetry.TelemetrySink;

// Rung 6 (persistence + streaming) remains as follow-up; the feedback loop
// does not require it — intermediate state lives in-process on Agent.state.

test {
    _ = agent;
    _ = trace;
    _ = topology;
    _ = eval;
    _ = dataset;
    _ = experiment;
    _ = feedback;
    _ = tool;
    _ = action;
    _ = telemetry;
    _ = @import("aor_world_test.zig");
}
