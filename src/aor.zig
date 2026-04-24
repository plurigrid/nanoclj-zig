//! agent-o-nanoclj — an agent-o-rama-inspired layer on nanoclj-zig.
//!
//! Top-level namespace; re-exports the rungs as they land. See
//! `.topos/agent-o-nanoclj.md` for the full architecture.
//!
//! Naming: `Aor` prefix everywhere so this doesn't collide with nanoclj's
//! existing Clojure `agent` (STM-style, in src/agent.zig + src/refs_agents.zig).

const std = @import("std");

pub const agent = @import("aor_agent.zig");

/// Rung 1 (this patch): Agent primitive.
/// Rung 2–7: see .topos/agent-o-nanoclj.md §2 — trace, topology, eval,
/// dataset, experiment, store, feedback.
pub const Agent = agent.Agent;
pub const AgentFn = agent.AgentFn;
pub const invokeStateless = agent.invokeStateless;

test {
    _ = agent;
}
