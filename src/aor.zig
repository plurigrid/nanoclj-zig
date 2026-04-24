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

// Rungs 5–7: see .topos/agent-o-nanoclj.md §2 — dataset, experiment, store,
// feedback.

test {
    _ = agent;
    _ = trace;
    _ = topology;
    _ = eval;
}
