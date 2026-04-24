//! Rung 1 of agent-o-nanoclj — the Agent record.
//!
//! Port of agent-o-rama's `new-agent` primitive. An Agent is a named unit of
//! computation that:
//!   - has a stable identifier (name + numeric id for trace lookup)
//!   - wraps a call (`AgentFn`) mapping input Value → output Value
//!   - carries opaque state (a `*Value` pointer; typically a nanoclj atom/ref)
//!   - records its invocations into a trace buffer (filled by Rung 2)
//!
//! This rung is intentionally state-minimal: no topology, no scheduler, no
//! persistence. Those arrive in subsequent rungs. The point is to fix the
//! shape of an Agent so later rungs can compose them unambiguously.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

/// Callable signature for an agent body. `ctx` lets an Agent consult its own
/// state / trace / env when invoked without threading them through args.
pub const AgentFn = *const fn (ctx: *Agent, input: Value) error{Invoke}!Value;

/// Monotonic agent id, assigned at registration time by the topology (later
/// rungs). For unattached agents, 0 means "not-yet-registered".
pub const AgentId = u32;

/// An agent-o-nanoclj agent. Names are caller-owned slices (no duplication);
/// callers typically intern them in the GC's string table.
pub const Agent = struct {
    id: AgentId = 0,
    name: []const u8,
    body: AgentFn,
    /// Opaque per-agent state. Usually a `*Obj` tagged as `atom`/`ref`/`agent`
    /// from refs_agents.zig; stored as `?Value` so a stateless agent is expressible.
    state: ?Value = null,
    /// Reserved for Rung 2: pointer into the trace store. `null` until an
    /// invocation is started under a topology.
    trace_slot: ?*usize = null,

    pub fn init(name: []const u8, body: AgentFn) Agent {
        return .{ .name = name, .body = body };
    }

    pub fn withState(self: Agent, initial: Value) Agent {
        var out = self;
        out.state = initial;
        return out;
    }

    /// Direct invocation path for single-agent testing. Production code will
    /// go through topology invocation (Rung 3) which records traces.
    pub fn invoke(self: *Agent, input: Value) error{Invoke}!Value {
        return self.body(self, input);
    }
};

/// Helper for callers that have an AgentFn but don't yet want to allocate an
/// Agent struct — useful during unit tests of agent bodies.
pub fn invokeStateless(body: AgentFn, name: []const u8, input: Value) error{Invoke}!Value {
    var agent = Agent.init(name, body);
    return agent.invoke(input);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

fn echoBody(_: *Agent, input: Value) error{Invoke}!Value {
    return input;
}

fn nameTagBody(ctx: *Agent, input: Value) error{Invoke}!Value {
    // Silly body that returns something derived from the agent's name and the
    // input, to show ctx is reachable. We just return the input unchanged in
    // the no-GC test context; checking ctx.name.len is what exercises ctx.
    if (ctx.name.len == 0) return error.Invoke;
    return input;
}

test "Agent.init captures name and body" {
    const a = Agent.init("echo", echoBody);
    try std.testing.expectEqualStrings("echo", a.name);
    try std.testing.expectEqual(@as(AgentId, 0), a.id);
    try std.testing.expectEqual(@as(?Value, null), a.state);
    try std.testing.expectEqual(@as(?*usize, null), a.trace_slot);
}

test "Agent.withState returns a new Agent with state set" {
    const a = Agent.init("stash", echoBody);
    const b = a.withState(Value.makeInt(42));
    try std.testing.expectEqual(@as(?Value, null), a.state); // original unchanged
    try std.testing.expect(b.state != null);
    try std.testing.expectEqual(@as(i48, 42), b.state.?.asInt());
}

test "Agent.invoke calls body with input" {
    var a = Agent.init("echo", echoBody);
    const out = try a.invoke(Value.makeInt(7));
    try std.testing.expectEqual(@as(i48, 7), out.asInt());
}

test "Agent body receives its ctx (can see its own name)" {
    var a = Agent.init("nameful", nameTagBody);
    const out = try a.invoke(Value.makeInt(1));
    try std.testing.expectEqual(@as(i48, 1), out.asInt());
}

test "invokeStateless: body runs without caller managing the Agent struct" {
    const out = try invokeStateless(echoBody, "ephemeral", Value.makeInt(99));
    try std.testing.expectEqual(@as(i48, 99), out.asInt());
}

test "Agent.invoke on an empty-name agent (via body that checks name) errors" {
    var a = Agent.init("", nameTagBody);
    try std.testing.expectError(error.Invoke, a.invoke(Value.makeInt(0)));
}
