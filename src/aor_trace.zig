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

/// Callback invoked synchronously after an event is recorded. Subscribers
/// see events in insertion order. The store holds the subscriber slice by
/// reference; caller owns the lifetime. Multiple subscribers are supported.
pub const TraceSubscriber = *const fn (event: TraceEvent) void;

/// Append-only event log with monotonic invocation ids.
pub const TraceStore = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(TraceEvent) = .empty,
    next_invoke_id: InvokeId = 1,
    next_step_by_invoke: std.AutoHashMapUnmanaged(InvokeId, u32) = .empty,
    subscribers: std.ArrayListUnmanaged(TraceSubscriber) = .empty,

    pub fn init(allocator: std.mem.Allocator) TraceStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TraceStore) void {
        self.events.deinit(self.allocator);
        self.next_step_by_invoke.deinit(self.allocator);
        self.subscribers.deinit(self.allocator);
    }

    /// Register a callback that fires after every `recordStep` call. Order
    /// of subscribers matches registration order. No-op if the subscriber
    /// is already registered (pointer-equality dedup).
    pub fn subscribe(self: *TraceStore, sub: TraceSubscriber) !void {
        for (self.subscribers.items) |existing| {
            if (existing == sub) return;
        }
        try self.subscribers.append(self.allocator, sub);
    }

    /// Remove a previously registered subscriber. Returns true if a
    /// subscriber was removed, false otherwise.
    pub fn unsubscribe(self: *TraceStore, sub: TraceSubscriber) bool {
        for (self.subscribers.items, 0..) |existing, i| {
            if (existing == sub) {
                _ = self.subscribers.orderedRemove(i);
                return true;
            }
        }
        return false;
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

        const ev = TraceEvent{
            .invoke_id = invoke_id,
            .step = step,
            .agent_id = agent.id,
            .agent_name = agent.name,
            .input = input,
            .output = output,
            .ts_mono = monoNs(),
            .tags = tags,
        };
        try self.events.append(self.allocator, ev);
        // Notify live subscribers synchronously. They see the event exactly
        // once, in insertion order.
        for (self.subscribers.items) |sub| sub(ev);
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

    /// Rung 6 — serialize to a caller-provided ArrayList. Stable
    /// pipe-delimited format; appends one line per event. `scratch_alloc`
    /// is used for temporary escape buffers and freed per-event.
    pub fn writeJsonl(
        self: *const TraceStore,
        out: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        scratch_alloc: std.mem.Allocator,
    ) !void {
        return writeJsonlImpl(self, out, alloc, scratch_alloc);
    }

    /// Rung 6 — replace events from previously-written data. Strings (agent
    /// name, tags) are allocated from `intern_alloc` and live as long as
    /// the store; typically `intern_alloc == self.allocator`.
    pub fn loadJsonl(self: *TraceStore, data: []const u8, intern_alloc: std.mem.Allocator) !void {
        return loadJsonlImpl(self, data, intern_alloc);
    }
};

fn monoNs() u64 {
    // 0.16-native monotonic: std.c.clock_gettime (matches pattern used in
    // nrepl.zig, main.zig, core.zig, flow.zig, skill_inet.zig, etc.).
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Rung 6 — minimal persistence. A compact textual format so traces can
// survive process death and be replayed in another nanoclj session.
//
// Format: one line per event, pipe-separated fields:
//   invoke_id|step|agent_id|agent_name|input_bits|output_bits|ts_mono|tags
// output_bits is "-" when output is null, otherwise the u64 bit pattern.
// agent_name and tags are escaped: '\n' → '\\n', '|' → '\\|', '\\' → '\\\\'.

fn escapeField(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '|' => try out.appendSlice(allocator, "\\|"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn unescapeField(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const next = s[i + 1];
            switch (next) {
                '\\' => try out.append(allocator, '\\'),
                'n' => try out.append(allocator, '\n'),
                '|' => try out.append(allocator, '|'),
                else => try out.append(allocator, next),
            }
            i += 2;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn writeJsonlImpl(
    self: *const TraceStore,
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    scratch_alloc: std.mem.Allocator,
) !void {
    var tmp: [64]u8 = undefined;
    for (self.events.items) |ev| {
        const name_escaped = try escapeField(scratch_alloc, ev.agent_name);
        defer scratch_alloc.free(name_escaped);
        const tags_escaped = try escapeField(scratch_alloc, ev.tags);
        defer scratch_alloc.free(tags_escaped);

        try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{ev.invoke_id}));
        try out.append(alloc, '|');
        try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{ev.step}));
        try out.append(alloc, '|');
        try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{ev.agent_id}));
        try out.append(alloc, '|');
        try out.appendSlice(alloc, name_escaped);
        try out.append(alloc, '|');
        try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{ev.input.bits}));
        try out.append(alloc, '|');
        if (ev.output) |o| {
            try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{o.bits}));
        } else {
            try out.append(alloc, '-');
        }
        try out.append(alloc, '|');
        try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{ev.ts_mono}));
        try out.append(alloc, '|');
        try out.appendSlice(alloc, tags_escaped);
        try out.append(alloc, '\n');
    }
}

fn loadJsonlImpl(self: *TraceStore, data: []const u8, intern_alloc: std.mem.Allocator) !void {
    self.events.clearRetainingCapacity();
    self.next_step_by_invoke.clearRetainingCapacity();
    var max_invoke: InvokeId = 0;

    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        var parts: [8][]const u8 = undefined;
        var idx: usize = 0;
        var cursor: usize = 0;
        var field_start: usize = 0;
        while (cursor < line.len and idx < 8) : (cursor += 1) {
            if (line[cursor] == '\\' and cursor + 1 < line.len) {
                cursor += 1;
                continue;
            }
            if (line[cursor] == '|') {
                parts[idx] = line[field_start..cursor];
                idx += 1;
                field_start = cursor + 1;
            }
        }
        if (idx != 7) return error.ParseError;
        parts[7] = line[field_start..];

        const iid = try std.fmt.parseInt(InvokeId, parts[0], 10);
        const step = try std.fmt.parseInt(u32, parts[1], 10);
        const agent_id = try std.fmt.parseInt(u32, parts[2], 10);
        const name = try unescapeField(intern_alloc, parts[3]);
        const input_bits = try std.fmt.parseInt(u64, parts[4], 10);
        const output = if (std.mem.eql(u8, parts[5], "-"))
            @as(?Value, null)
        else blk: {
            const ob = try std.fmt.parseInt(u64, parts[5], 10);
            break :blk @as(?Value, Value{ .bits = ob });
        };
        const ts_mono = try std.fmt.parseInt(u64, parts[6], 10);
        const tags = try unescapeField(intern_alloc, parts[7]);

        try self.events.append(self.allocator, .{
            .invoke_id = iid,
            .step = step,
            .agent_id = agent_id,
            .agent_name = name,
            .input = Value{ .bits = input_bits },
            .output = output,
            .ts_mono = ts_mono,
            .tags = tags,
        });
        if (iid > max_invoke) max_invoke = iid;
        const gop = try self.next_step_by_invoke.getOrPut(self.allocator, iid);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        if (step + 1 > gop.value_ptr.*) gop.value_ptr.* = step + 1;
    }
    if (max_invoke >= self.next_invoke_id) self.next_invoke_id = max_invoke + 1;
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

var g_sub_count: u32 = 0;
var g_sub_last_input: i48 = 0;
fn testSub(ev: TraceEvent) void {
    g_sub_count += 1;
    g_sub_last_input = ev.input.asInt();
}

var g_sub2_count: u32 = 0;
fn testSub2(_: TraceEvent) void {
    g_sub2_count += 1;
}

test "subscribe: callback fires on each recordStep" {
    g_sub_count = 0;
    g_sub_last_input = 0;
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    try store.subscribe(testSub);

    var agent = aor_agent.Agent.init("sub", echoBody);
    const inv = store.startInvocation();
    _ = try store.recordStep(inv, &agent, Value.makeInt(11), null, "");
    _ = try store.recordStep(inv, &agent, Value.makeInt(22), null, "");
    _ = try store.recordStep(inv, &agent, Value.makeInt(33), null, "");

    try std.testing.expectEqual(@as(u32, 3), g_sub_count);
    try std.testing.expectEqual(@as(i48, 33), g_sub_last_input);
}

test "subscribe is idempotent (no dedup re-register)" {
    g_sub_count = 0;
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    try store.subscribe(testSub);
    try store.subscribe(testSub); // should not double-register

    var agent = aor_agent.Agent.init("s", echoBody);
    const inv = store.startInvocation();
    _ = try store.recordStep(inv, &agent, Value.makeInt(5), null, "");
    try std.testing.expectEqual(@as(u32, 1), g_sub_count);
}

test "unsubscribe removes callback" {
    g_sub_count = 0;
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    try store.subscribe(testSub);

    var agent = aor_agent.Agent.init("s", echoBody);
    const inv = store.startInvocation();
    _ = try store.recordStep(inv, &agent, Value.makeInt(5), null, "");
    try std.testing.expectEqual(@as(u32, 1), g_sub_count);

    const removed = store.unsubscribe(testSub);
    try std.testing.expect(removed);

    _ = try store.recordStep(inv, &agent, Value.makeInt(6), null, "");
    try std.testing.expectEqual(@as(u32, 1), g_sub_count); // no increment

    // Second unsubscribe is a no-op.
    try std.testing.expect(!store.unsubscribe(testSub));
}

test "multiple subscribers all fire, in registration order" {
    g_sub_count = 0;
    g_sub2_count = 0;
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    try store.subscribe(testSub);
    try store.subscribe(testSub2);

    var agent = aor_agent.Agent.init("s", echoBody);
    const inv = store.startInvocation();
    _ = try store.recordStep(inv, &agent, Value.makeInt(1), null, "");
    _ = try store.recordStep(inv, &agent, Value.makeInt(2), null, "");
    try std.testing.expectEqual(@as(u32, 2), g_sub_count);
    try std.testing.expectEqual(@as(u32, 2), g_sub2_count);
}

test "writeJsonl → loadJsonl roundtrips all event fields" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    var agent_a = aor_agent.Agent.init("alpha", echoBody);
    var agent_b = aor_agent.Agent.init("beta|with|pipes", echoBody);
    agent_a.id = 1;
    agent_b.id = 2;

    const inv = store.startInvocation();
    _ = try store.recordStep(inv, &agent_a, Value.makeInt(10), Value.makeInt(11), "plain");
    _ = try store.recordStep(inv, &agent_b, Value.makeInt(42), null, "retry,\\backslash,\nnewline");

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try store.writeJsonl(&buffer, std.testing.allocator, std.testing.allocator);

    // Rehydrate into a fresh store.
    var store2 = TraceStore.init(std.testing.allocator);
    defer {
        // Free owned strings before deinit.
        for (store2.events.items) |ev| {
            std.testing.allocator.free(ev.agent_name);
            std.testing.allocator.free(ev.tags);
        }
        store2.deinit();
    }
    try store2.loadJsonl(buffer.items, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), store2.eventCount());
    try std.testing.expectEqual(@as(InvokeId, inv), store2.events.items[0].invoke_id);
    try std.testing.expectEqual(@as(u32, 0), store2.events.items[0].step);
    try std.testing.expectEqualStrings("alpha", store2.events.items[0].agent_name);
    try std.testing.expectEqual(@as(i48, 10), store2.events.items[0].input.asInt());
    try std.testing.expectEqual(@as(i48, 11), store2.events.items[0].output.?.asInt());

    try std.testing.expectEqual(@as(u32, 1), store2.events.items[1].step);
    try std.testing.expectEqualStrings("beta|with|pipes", store2.events.items[1].agent_name);
    try std.testing.expect(store2.events.items[1].output == null);
    try std.testing.expectEqualStrings("retry,\\backslash,\nnewline", store2.events.items[1].tags);

    // next_invoke_id advanced past the restored max.
    try std.testing.expect(store2.next_invoke_id > inv);
}

test "loadJsonl on empty input produces empty store" {
    var store = TraceStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadJsonl("", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), store.eventCount());
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
