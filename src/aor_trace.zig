//! Rung 2 of agent-o-nanoclj — per-invocation trace store.
//!
//! An append-only event log for agent invocations. Each `TraceEvent` records
//! one step of an invocation (which agent ran, on what input, producing what
//! output, when). Events are grouped by `invoke_id`, so replaying or
//! inspecting an invocation is O(k) where k is the number of events in it.
//!
//! Design:
//!   - `TraceStore` owns a monotonically-growing `invoke_id` counter and a
//!     flat list of events. Each event carries its `invoke_id`, so grouping
//!     is just a filter — no per-invoke heap allocation needed on hot path.
//!   - `startInvocation` issues a fresh id; `recordStep` appends; `finish`
//!     is optional book-keeping. No ring-buffer yet — persistence/eviction
//!     arrives in Rung 6.
//!   - Values are held as raw `Value` bits. Lifetimes follow the GC; callers
//!     must keep values alive across the trace's lifetime if they want to
//!     deref them later.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const aor_agent = @import("aor_agent.zig");
const AgentId = aor_agent.AgentId;

pub const InvokeId = u64;

/// Single step in an invocation.
pub const TraceEvent = struct {
    invoke_id: InvokeId,
    step: u32,
    agent_id: AgentId,
    agent_name: []const u8,
    input: Value,
    /// null until the step completes — lets us distinguish "running" from "done".
    output: ?Value,
    /// Monotonic ns since an arbitrary epoch; useful for ordering + dur diffs.
    ts_mono: u64,
    /// Optional comma-separated tags — owner is caller's string-intern table
    /// (typically the GC). Empty string means "no tags".
    tags: []const u8,
};

/// Snapshot of a single invocation extracted from a store.
pub const InvocationTrace = struct {
    invoke_id: InvokeId,
    events: []const TraceEvent,
    /// True iff at least one event is complete; informational.
    any_complete: bool,
};

/// Append-only event log with monotonic invocation ids.
pub const TraceStore = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(TraceEvent) = .empty,
    next_invoke_id: InvokeId = 1,
    next_step_by_invoke: std.AutoHashMapUnmanaged(InvokeId, u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) TraceStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TraceStore) void {
        self.events.deinit(self.allocator);
        self.next_step_by_invoke.deinit(self.allocator);
    }

    /// Allocate a fresh invocation id. Does not append an event.
    pub fn startInvocation(self: *TraceStore) InvokeId {
        const id = self.next_invoke_id;
        self.next_invoke_id += 1;
        return id;
    }

    /// Append a step entry for `invoke_id`. The step number is auto-incremented
    /// per invocation. Output is `null` for a "started" step; use
    /// `completeStep` to fill it in, or pass output directly for a synchronous
    /// one-shot step.
    pub fn recordStep(
        self: *TraceStore,
        invoke_id: InvokeId,
        agent: *const aor_agent.Agent,
        input: Value,
        output: ?Value,
        tags: []const u8,
    ) !u32 {
        const next_ptr = try self.next_step_by_invoke.getOrPut(self.allocator, invoke_id);
        if (!next_ptr.found_existing) next_ptr.value_ptr.* = 0;
        const step = next_ptr.value_ptr.*;
        next_ptr.value_ptr.* = step + 1;

        try self.events.append(self.allocator, .{
            .invoke_id = invoke_id,
            .step = step,
            .agent_id = agent.id,
            .agent_name = agent.name,
            .input = input,
            .output = output,
            .ts_mono = monoNs(),
            .tags = tags,
        });
        return step;
    }

    /// Retroactively set the output on a previously-appended step.
    pub fn completeStep(self: *TraceStore, invoke_id: InvokeId, step: u32, output: Value) !void {
        for (self.events.items) |*ev| {
            if (ev.invoke_id == invoke_id and ev.step == step) {
                ev.output = output;
                return;
            }
        }
        return error.StepNotFound;
    }

    /// Extract all events for a given invocation id, in append order.
    /// Caller must free the returned slice with `allocator.free`.
    pub fn getInvocation(self: *const TraceStore, allocator: std.mem.Allocator, invoke_id: InvokeId) !InvocationTrace {
        var collected: std.ArrayListUnmanaged(TraceEvent) = .empty;
        errdefer collected.deinit(allocator);
        var any_complete = false;
        for (self.events.items) |ev| {
            if (ev.invoke_id == invoke_id) {
                if (ev.output != null) any_complete = true;
                try collected.append(allocator, ev);
            }
        }
        return .{
            .invoke_id = invoke_id,
            .events = try collected.toOwnedSlice(allocator),
            .any_complete = any_complete,
        };
    }

    /// Total event count across all invocations (for introspection/tests).
    pub fn eventCount(self: *const TraceStore) usize {
        return self.events.items.len;
    }
};

fn monoNs() u64 {
    // 0.16-native monotonic: std.c.clock_gettime (matches pattern used in
    // nrepl.zig, main.zig, core.zig, flow.zig, skill_inet.zig, etc.).
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

fn echoBody(_: *aor_agent.Agent, input: Value) error{Invoke}!Value {
    return input;
}

test "TraceStore.init + deinit is clean" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.eventCount());
    try std.testing.expectEqual(@as(InvokeId, 1), store.next_invoke_id);
}

test "startInvocation issues monotonic ids" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    const a = store.startInvocation();
    const b = store.startInvocation();
    const c = store.startInvocation();
    try std.testing.expectEqual(@as(InvokeId, 1), a);
    try std.testing.expectEqual(@as(InvokeId, 2), b);
    try std.testing.expectEqual(@as(InvokeId, 3), c);
}

test "recordStep appends with auto step numbering per invocation" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    var agent = aor_agent.Agent.init("echo", echoBody);

    const inv = store.startInvocation();
    const s0 = try store.recordStep(inv, &agent, Value.makeInt(10), null, "");
    const s1 = try store.recordStep(inv, &agent, Value.makeInt(20), null, "");
    const s2 = try store.recordStep(inv, &agent, Value.makeInt(30), Value.makeInt(31), "tag-a");

    try std.testing.expectEqual(@as(u32, 0), s0);
    try std.testing.expectEqual(@as(u32, 1), s1);
    try std.testing.expectEqual(@as(u32, 2), s2);
    try std.testing.expectEqual(@as(usize, 3), store.eventCount());
}

test "recordStep per-invocation step numbering is independent" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    var agent = aor_agent.Agent.init("echo", echoBody);

    const inv_a = store.startInvocation();
    const inv_b = store.startInvocation();
    _ = try store.recordStep(inv_a, &agent, Value.makeInt(1), null, "");
    _ = try store.recordStep(inv_b, &agent, Value.makeInt(100), null, "");
    _ = try store.recordStep(inv_a, &agent, Value.makeInt(2), null, "");
    const b1 = try store.recordStep(inv_b, &agent, Value.makeInt(200), null, "");
    try std.testing.expectEqual(@as(u32, 1), b1); // b's second step
}

test "completeStep backfills output on the right event" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    var agent = aor_agent.Agent.init("echo", echoBody);
    const inv = store.startInvocation();
    _ = try store.recordStep(inv, &agent, Value.makeInt(5), null, "");
    try store.completeStep(inv, 0, Value.makeInt(42));
    const trace = try store.getInvocation(std.testing.allocator, inv);
    defer std.testing.allocator.free(trace.events);
    try std.testing.expectEqual(@as(usize, 1), trace.events.len);
    try std.testing.expect(trace.events[0].output != null);
    try std.testing.expectEqual(@as(i48, 42), trace.events[0].output.?.asInt());
    try std.testing.expect(trace.any_complete);
}

test "completeStep on missing step errors" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.StepNotFound, store.completeStep(99, 0, Value.makeInt(0)));
}

test "getInvocation isolates events by invoke_id" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    var agent = aor_agent.Agent.init("echo", echoBody);
    const inv_a = store.startInvocation();
    const inv_b = store.startInvocation();
    _ = try store.recordStep(inv_a, &agent, Value.makeInt(1), null, "");
    _ = try store.recordStep(inv_b, &agent, Value.makeInt(10), null, "");
    _ = try store.recordStep(inv_a, &agent, Value.makeInt(2), null, "");
    _ = try store.recordStep(inv_b, &agent, Value.makeInt(20), null, "");
    _ = try store.recordStep(inv_a, &agent, Value.makeInt(3), null, "");

    const trace_a = try store.getInvocation(std.testing.allocator, inv_a);
    defer std.testing.allocator.free(trace_a.events);
    const trace_b = try store.getInvocation(std.testing.allocator, inv_b);
    defer std.testing.allocator.free(trace_b.events);

    try std.testing.expectEqual(@as(usize, 3), trace_a.events.len);
    try std.testing.expectEqual(@as(usize, 2), trace_b.events.len);
    try std.testing.expectEqual(@as(i48, 1), trace_a.events[0].input.asInt());
    try std.testing.expectEqual(@as(i48, 10), trace_b.events[0].input.asInt());
}

test "tags pass through to events" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    var agent = aor_agent.Agent.init("echo", echoBody);
    const inv = store.startInvocation();
    _ = try store.recordStep(inv, &agent, Value.makeInt(0), null, "retry,llm,cached");
    const trace = try store.getInvocation(std.testing.allocator, inv);
    defer std.testing.allocator.free(trace.events);
    try std.testing.expectEqualStrings("retry,llm,cached", trace.events[0].tags);
}
