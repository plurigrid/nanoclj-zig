//! agent-o-nanoclj — the feedback-loop core of nanoclj-zig.
//!
//! Top-level namespace; re-exports each rung as it lands. See
//! `.topos/agent-o-nanoclj.md` for the full architecture (10 rungs +
//! gradient extension).
//!
//! Layout: every loop primitive lives under `src/loop/` with a bare,
//! collision-free name (agent / topology / trace / eval / dataset /
//! experiment / feedback / tool / action / telemetry / checkpoint /
//! gradient / builtins). The umbrella file (this one) is what `core.zig`
//! and `build.zig` reference.
//!
//! Functorial framing (see "funcotriality in control"):
//!   F_play   : Topology → Trace               (invoke / Rung 3)
//!   F_witness: Trace    → Verdict / pass-rate (eval, experiment / Rungs 4–5)
//!   F_coplay : ∇(rate)  → Topology'           (gradient + revise / 7 + grad)
//! GF(3) closure: F_coplay ∘ F_witness ∘ F_play : Topology → Topology.

const std = @import("std");

pub const agent = @import("loop/agent.zig");
pub const trace = @import("loop/trace.zig");
pub const topology = @import("loop/topology.zig");
pub const eval = @import("loop/eval.zig");
pub const dataset = @import("loop/dataset.zig");
pub const experiment = @import("loop/experiment.zig");
pub const feedback = @import("loop/feedback.zig");
pub const tool = @import("loop/tool.zig");
pub const action = @import("loop/action.zig");
pub const telemetry = @import("loop/telemetry.zig");
pub const checkpoint = @import("loop/checkpoint.zig");
pub const gradient = @import("loop/gradient.zig");
pub const skill = @import("loop/skill.zig");
pub const builtins = @import("loop/builtins.zig");

/// Skill registry — SDF-style extension surface.
/// Extending: add to a submodule's `skills` slice; this fold picks it up.
pub const Skill = skill.Skill;
pub const SkillFn = skill.SkillFn;
pub const skillCombine = skill.combine;
pub const skillLookup = skill.lookup;
pub const skills: []const Skill = &builtins.skills; // future: ++ gradient.skills ++ ...

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

/// Rung 8: Tool + ToolRegistry.
pub const Tool = tool.Tool;
pub const ToolFn = tool.ToolFn;
pub const ToolRegistry = tool.ToolRegistry;
pub const ToolError = tool.ToolError;

/// Rung 9: Action + ActionLog.
pub const Action = action.Action;
pub const ActionFn = action.ActionFn;
pub const ActionResult = action.ActionResult;
pub const ActionLog = action.ActionLog;
pub const RunInfo = action.RunInfo;
pub const runAction = action.runAction;
pub const runActionsOnInvocation = action.runActionsOnInvocation;

/// Rung 10: Telemetry.
pub const Sample = telemetry.Sample;
pub const Series = telemetry.Series;
pub const Aggregate = telemetry.Aggregate;
pub const TelemetrySink = telemetry.TelemetrySink;

/// Rung 6+: unified checkpoint across trace + action + telemetry.
pub const Checkpoint = checkpoint.Checkpoint;
pub const CheckpointError = checkpoint.CheckpointError;

/// Gradient: F_coplay realized as finite-difference descent on agent state.
pub const Gradient = gradient.Gradient;
pub const GradientCycleResult = gradient.GradientCycleResult;
pub const GradientError = gradient.GradientError;
pub const traceGradient = gradient.traceGradient;
pub const cycleByGradient = gradient.cycleByGradient;

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
    _ = checkpoint;
    _ = gradient;
    _ = skill;
    _ = builtins;
    _ = @import("loop/world_test.zig");
}
