//! Rung 3 of agent-o-nanoclj — topology + invocation.
//!
//! Ports agent-o-rama's `AgentGraph` + `AgentTopology` + `AgentInvoke`
//! concepts (https://github.com/redplanetlabs/agent-o-rama/wiki) to the
//! nanoclj substrate.
//!
//! Per Nathan Marz's blog post (2025-11-03, blog.redplanetlabs.com), in
//! agent-o-rama each node is a plain function that "receives data, processes
//! it, and either passes it along to other nodes or returns a final result."
//! Nodes `emit` to named downstream nodes; executions fan out across the
//! DAG on virtual threads.
//!
//! This Zig port keeps the essential shape:
//!   - `Topology` holds a set of registered `Agent`s indexed by name.
//!   - `Edge{from, to}` encodes `from emits to to`. Multi-edges = fanout.
//!   - `invoke(topo, start_name, input)` runs the DAG synchronously
//!     depth-first: each agent's output becomes the input of its downstream
//!     agents. A single "final" result is returned from whichever path runs
//!     last. (Parallel / streaming semantics arrive in Rung 6.)
//!   - Every step is recorded to a `TraceStore` via Rung 2, keyed by the
//!     invocation id returned to the caller.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const aor_agent = @import("aor_agent.zig");
const aor_trace = @import("aor_trace.zig");
const Agent = aor_agent.Agent;
const AgentId = aor_agent.AgentId;
const TraceStore = aor_trace.TraceStore;
const InvokeId = aor_trace.InvokeId;

pub const TopologyError = error{
    AgentNotFound,
    DuplicateAgent,
    CycleDetected,
    Invoke,
    OutOfMemory,
};

/// Directed edge from one agent's output to another agent's input.
pub const Edge = struct {
    from: AgentId,
    to: AgentId,
};

/// A registered agent entry. Wraps the user's Agent plus bookkeeping.
pub const Node = struct {
    agent: Agent,
};

/// Agent topology: a mutable DAG of agents + edges.
pub const Topology = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    /// Name → index-into-nodes lookup for fast registration / resolution.
    name_index: std.StringHashMapUnmanaged(AgentId) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    next_id: AgentId = 1,

    pub fn init(allocator: std.mem.Allocator) Topology {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Topology) void {
        self.nodes.deinit(self.allocator);
        self.name_index.deinit(self.allocator);
        self.edges.deinit(self.allocator);
    }

    /// Register an agent. The agent's name becomes its handle; mutates
    /// agent.id to the newly-assigned numeric id.
    pub fn newAgent(self: *Topology, name: []const u8, body: aor_agent.AgentFn) !AgentId {
        if (self.name_index.get(name) != null) return TopologyError.DuplicateAgent;
        const id = self.next_id;
        self.next_id += 1;
        var a = Agent.init(name, body);
        a.id = id;
        try self.nodes.append(self.allocator, .{ .agent = a });
        try self.name_index.put(self.allocator, name, id);
        return id;
    }

    /// Connect `from` → `to`. Both must already be registered. No cycle
    /// check on insertion — cycles would surface at `invoke` time.
    pub fn connect(self: *Topology, from: []const u8, to: []const u8) !void {
        const from_id = self.name_index.get(from) orelse return TopologyError.AgentNotFound;
        const to_id = self.name_index.get(to) orelse return TopologyError.AgentNotFound;
        try self.edges.append(self.allocator, .{ .from = from_id, .to = to_id });
    }

    /// Find a registered agent by name. Returns null if not found.
    pub fn getAgent(self: *Topology, name: []const u8) ?*Agent {
        const id = self.name_index.get(name) orelse return null;
        return &self.nodes.items[@as(usize, id) - 1].agent;
    }

    fn downstream(self: *const Topology, from_id: AgentId, buf: *std.ArrayListUnmanaged(AgentId)) !void {
        buf.clearRetainingCapacity();
        for (self.edges.items) |e| {
            if (e.from == from_id) try buf.append(self.allocator, e.to);
        }
    }
};

/// Invoke result — the final output value + the invocation id that keyed the
/// trace. The caller can use `trace.getInvocation(invoke_id)` to replay.
pub const InvokeResult = struct {
    final: Value,
    invoke_id: InvokeId,
};

/// Execute a synchronous DFS through the topology starting from
/// `start_name`. Each step records to `trace`. Returns the output of the
/// last-visited agent plus the invocation id.
///
/// Cycle detection: a visit counter caps depth at 1024 — if the graph has
/// no outgoing edges a linear chain is fine; a cycle blows the cap.
pub fn invoke(
    topo: *Topology,
    trace: *TraceStore,
    start_name: []const u8,
    input: Value,
) TopologyError!InvokeResult {
    const invoke_id = trace.startInvocation();
    const start_agent = topo.getAgent(start_name) orelse return TopologyError.AgentNotFound;
    const final = try runStep(topo, trace, invoke_id, start_agent, input, 0);
    return .{ .final = final, .invoke_id = invoke_id };
}

fn runStep(
    topo: *Topology,
    trace: *TraceStore,
    invoke_id: InvokeId,
    agent: *Agent,
    input: Value,
    depth: u32,
) TopologyError!Value {
    if (depth > 1024) return TopologyError.CycleDetected;

    const step = trace.recordStep(invoke_id, agent, input, null, "") catch |e| switch (e) {
        error.OutOfMemory => return TopologyError.OutOfMemory,
    };

    const output = agent.invoke(input) catch return TopologyError.Invoke;

    trace.completeStep(invoke_id, step, output) catch |e| switch (e) {
        error.StepNotFound => return TopologyError.Invoke,
    };

    var next_ids: std.ArrayListUnmanaged(AgentId) = .empty;
    defer next_ids.deinit(topo.allocator);
    topo.downstream(agent.id, &next_ids) catch return TopologyError.OutOfMemory;

    if (next_ids.items.len == 0) return output;

    var last = output;
    for (next_ids.items) |next_id| {
        const next_agent = &topo.nodes.items[@as(usize, next_id) - 1].agent;
        last = try runStep(topo, trace, invoke_id, next_agent, output, depth + 1);
    }
    return last;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

fn echoBody(_: *Agent, input: Value) error{Invoke}!Value {
    return input;
}

fn incBody(_: *Agent, input: Value) error{Invoke}!Value {
    return Value.makeInt(input.asInt() + 1);
}

fn doubleBody(_: *Agent, input: Value) error{Invoke}!Value {
    return Value.makeInt(input.asInt() * 2);
}

test "Topology register + resolve by name" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    const id_a = try topo.newAgent("echo", echoBody);
    try std.testing.expectEqual(@as(AgentId, 1), id_a);
    try std.testing.expectEqual(@as(?AgentId, 1), topo.name_index.get("echo"));
    try std.testing.expect(topo.getAgent("echo") != null);
    try std.testing.expectEqual(@as(?*Agent, null), topo.getAgent("missing"));
}

test "Topology rejects duplicate agent names" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    _ = try topo.newAgent("once", echoBody);
    try std.testing.expectError(TopologyError.DuplicateAgent, topo.newAgent("once", echoBody));
}

test "Topology.connect requires both ends to exist" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    _ = try topo.newAgent("src", echoBody);
    try std.testing.expectError(TopologyError.AgentNotFound, topo.connect("src", "dst"));
    _ = try topo.newAgent("dst", echoBody);
    try topo.connect("src", "dst");
    try std.testing.expectEqual(@as(usize, 1), topo.edges.items.len);
}

test "invoke on a single node records one step and returns its output" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("inc", incBody);

    const r = try invoke(&topo, &trace, "inc", Value.makeInt(41));
    try std.testing.expectEqual(@as(i48, 42), r.final.asInt());

    const tr = try trace.getInvocation(std.testing.allocator, r.invoke_id);
    defer std.testing.allocator.free(tr.events);
    try std.testing.expectEqual(@as(usize, 1), tr.events.len);
    try std.testing.expectEqual(@as(i48, 41), tr.events[0].input.asInt());
    try std.testing.expectEqual(@as(i48, 42), tr.events[0].output.?.asInt());
    try std.testing.expect(tr.any_complete);
}

test "invoke on a chain records steps in order and threads output→input" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("inc", incBody);
    _ = try topo.newAgent("double", doubleBody);
    _ = try topo.newAgent("inc2", incBody);
    try topo.connect("inc", "double");
    try topo.connect("double", "inc2");

    // 1 -> inc -> 2 -> double -> 4 -> inc2 -> 5
    const r = try invoke(&topo, &trace, "inc", Value.makeInt(1));
    try std.testing.expectEqual(@as(i48, 5), r.final.asInt());

    const tr = try trace.getInvocation(std.testing.allocator, r.invoke_id);
    defer std.testing.allocator.free(tr.events);
    try std.testing.expectEqual(@as(usize, 3), tr.events.len);
    try std.testing.expectEqual(@as(i48, 1), tr.events[0].input.asInt());
    try std.testing.expectEqual(@as(i48, 2), tr.events[1].input.asInt());
    try std.testing.expectEqual(@as(i48, 4), tr.events[2].input.asInt());
    try std.testing.expectEqual(@as(i48, 5), tr.events[2].output.?.asInt());
}

test "invoke with fanout visits each downstream agent" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("src", echoBody);
    _ = try topo.newAgent("left", incBody);
    _ = try topo.newAgent("right", doubleBody);
    try topo.connect("src", "left");
    try topo.connect("src", "right");

    // src echoes 10 → both left (11) and right (20) run, each recorded.
    const r = try invoke(&topo, &trace, "src", Value.makeInt(10));
    _ = r;
    const tr = try trace.getInvocation(std.testing.allocator, 1);
    defer std.testing.allocator.free(tr.events);
    try std.testing.expectEqual(@as(usize, 3), tr.events.len); // src, left, right
}

test "invoke on missing start agent errors cleanly" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    try std.testing.expectError(
        TopologyError.AgentNotFound,
        invoke(&topo, &trace, "nope", Value.makeInt(0)),
    );
}

test "cycle detection caps at depth 1024" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("a", echoBody);
    _ = try topo.newAgent("b", echoBody);
    try topo.connect("a", "b");
    try topo.connect("b", "a");
    try std.testing.expectError(
        TopologyError.CycleDetected,
        invoke(&topo, &trace, "a", Value.makeInt(0)),
    );
}

test "invoke records multiple independent invocations with fresh ids" {
    var topo = Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace = TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    _ = try topo.newAgent("inc", incBody);
    const r1 = try invoke(&topo, &trace, "inc", Value.makeInt(1));
    const r2 = try invoke(&topo, &trace, "inc", Value.makeInt(100));
    try std.testing.expectEqual(@as(InvokeId, 1), r1.invoke_id);
    try std.testing.expectEqual(@as(InvokeId, 2), r2.invoke_id);
    try std.testing.expectEqual(@as(i48, 2), r1.final.asInt());
    try std.testing.expectEqual(@as(i48, 101), r2.final.asInt());
    try std.testing.expectEqual(@as(usize, 2), trace.eventCount());
}
