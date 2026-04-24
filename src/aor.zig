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

// Rungs 3–7: see .topos/agent-o-nanoclj.md §2 — topology, eval, dataset,
// experiment, store, feedback.

test {
    _ = agent;
    _ = trace;
}
