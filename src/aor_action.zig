//! Rung 9 of agent-o-nanoclj — Actions and ActionLog.
//!
//! Ports agent-o-rama's Actions system
//! (https://github.com/redplanetlabs/agent-o-rama/wiki/Actions,-rules,-and-telemetry):
//!
//!   "Actions are hooks that execute on a sampled subset of live agent runs
//!    for online evaluation, dataset capture, webhook triggers, or custom
//!    logic. Actions return a map with string keys recorded in the action
//!    log."
//!
//! Evaluators are the READ side (observe + score). Actions are the
//! WRITE/SIDE-EFFECT side (observe + do). Both consume an invocation's
//! inputs + outputs; neither modifies the agent's body. Actions produce
//! `ActionResult`s that are persisted to an `ActionLog` for telemetry.
//!
//! This rung is intentionally narrow: no filtering DSL, no sample-rate
//! sampling, no async execution. Run-all-actions-on-all-invocations is
//! sufficient to express the primitive; sampling/filtering are caller
//! concerns until Rung 6 (persistence) makes the ActionLog durable.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

const aor_trace = @import("aor_trace.zig");
const InvokeId = aor_trace.InvokeId;
const InvocationTrace = aor_trace.InvocationTrace;

pub const ActionError = error{
    ActionFailed,
    OutOfMemory,
};

/// Runtime context handed to an action's body.
pub const RunInfo = struct {
    invoke_id: InvokeId,
    /// Input to the first agent in the chain (the invoker-provided value).
    input: Value,
    /// Output of the last agent in the chain (the final value).
    output: Value,
    /// Wall-clock duration in nanoseconds from first step's ts to last
    /// step's ts. Computed by the caller from the trace.
    latency_ns: u64,
    /// Number of events in the invocation's trace.
    step_count: u32,
};

/// Product of a single action run. `data` is optional structured
/// information (e.g. a score, a payload to webhook); `tags` is a
/// comma-separated string the action wants attached to telemetry.
pub const ActionResult = struct {
    action_name: []const u8,
    invoke_id: InvokeId,
    data: ?Value = null,
    tags: []const u8 = "",
};

pub const ActionFn = *const fn (info: RunInfo) ActionError!ActionResult;

pub const Action = struct {
    name: []const u8,
    description: []const u8,
    body: ActionFn,
};

/// Append-only log of action results. Paired with `TraceStore` from Rung 2 —
/// traces record what an agent did; ActionLog records what actions did in
/// response. Both are introspectable without persistence (Rung 6).
pub const ActionLog = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayListUnmanaged(ActionResult) = .empty,

    pub fn init(allocator: std.mem.Allocator) ActionLog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ActionLog) void {
        self.results.deinit(self.allocator);
    }

    pub fn count(self: *const ActionLog) usize {
        return self.results.items.len;
    }

    /// All results for a single invocation, in insertion order.
    /// Caller must free returned slice with `allocator.free`.
    pub fn forInvocation(
        self: *const ActionLog,
        allocator: std.mem.Allocator,
        invoke_id: InvokeId,
    ) ![]ActionResult {
        var out: std.ArrayListUnmanaged(ActionResult) = .empty;
        errdefer out.deinit(allocator);
        for (self.results.items) |r| {
            if (r.invoke_id == invoke_id) try out.append(allocator, r);
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Compute `RunInfo` from a completed invocation trace.
pub fn runInfoFromTrace(trace: InvocationTrace) RunInfo {
    std.debug.assert(trace.events.len > 0);
    const first = trace.events[0];
    const last = trace.events[trace.events.len - 1];
    return .{
        .invoke_id = trace.invoke_id,
        .input = first.input,
        .output = last.output orelse last.input,
        .latency_ns = if (last.ts_mono >= first.ts_mono) last.ts_mono - first.ts_mono else 0,
        .step_count = @intCast(trace.events.len),
    };
}

/// Run one action, append its result to the log.
pub fn runAction(action: Action, info: RunInfo, log: *ActionLog) ActionError!void {
    const result = try action.body(info);
    log.results.append(log.allocator, result) catch return error.OutOfMemory;
}

/// Run every action against a completed invocation. Continues on individual
/// action failures (logs them as empty results); returns `ActionFailed` only
/// if allocation fails.
pub fn runActionsOnInvocation(
    actions: []const Action,
    trace: InvocationTrace,
    log: *ActionLog,
) ActionError!void {
    if (trace.events.len == 0) return;
    const info = runInfoFromTrace(trace);
    for (actions) |a| {
        _ = runAction(a, info, log) catch |e| switch (e) {
            error.ActionFailed => {
                // Failed actions still produce a log entry so users can see
                // which actions ran and which didn't.
                log.results.append(log.allocator, .{
                    .action_name = a.name,
                    .invoke_id = info.invoke_id,
                    .data = null,
                    .tags = "failed",
                }) catch return error.OutOfMemory;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

const aor_agent = @import("aor_agent.zig");
const aor_topology = @import("aor_topology.zig");

fn recordBody(info: RunInfo) ActionError!ActionResult {
    return .{
        .action_name = "record",
        .invoke_id = info.invoke_id,
        .data = info.output,
        .tags = "telemetry",
    };
}

fn countTag(info: RunInfo) ActionError!ActionResult {
    // Produce a tag including step count so we can assert below.
    return .{
        .action_name = "count",
        .invoke_id = info.invoke_id,
        .data = Value.makeInt(@as(i48, @intCast(info.step_count))),
        .tags = "step-count",
    };
}

fn failBody(_: RunInfo) ActionError!ActionResult {
    return error.ActionFailed;
}

fn incBody(_: *aor_agent.Agent, in: Value) error{Invoke}!Value {
    return Value.makeInt(in.asInt() + 1);
}

test "ActionLog.init + count + deinit" {
    var log = ActionLog.init(std.testing.allocator);
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 0), log.count());
}

test "runAction appends a result" {
    var log = ActionLog.init(std.testing.allocator);
    defer log.deinit();
    const info = RunInfo{
        .invoke_id = 42,
        .input = Value.makeInt(1),
        .output = Value.makeInt(2),
        .latency_ns = 1000,
        .step_count = 1,
    };
    try runAction(.{ .name = "record", .description = "", .body = recordBody }, info, &log);
    try std.testing.expectEqual(@as(usize, 1), log.count());
    try std.testing.expectEqual(@as(InvokeId, 42), log.results.items[0].invoke_id);
    try std.testing.expectEqualStrings("telemetry", log.results.items[0].tags);
    try std.testing.expect(log.results.items[0].data != null);
    try std.testing.expectEqual(@as(i48, 2), log.results.items[0].data.?.asInt());
}

test "runActionsOnInvocation runs all actions + produces one log entry each" {
    var topo = aor_topology.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = aor_trace.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", incBody);

    const r = try aor_topology.invoke(&topo, &trace_store, "inc", Value.makeInt(100));
    const tr = try trace_store.getInvocation(std.testing.allocator, r.invoke_id);
    defer std.testing.allocator.free(tr.events);

    var log = ActionLog.init(std.testing.allocator);
    defer log.deinit();

    const actions = [_]Action{
        .{ .name = "record", .description = "", .body = recordBody },
        .{ .name = "count", .description = "", .body = countTag },
    };
    try runActionsOnInvocation(&actions, tr, &log);
    try std.testing.expectEqual(@as(usize, 2), log.count());

    // The count action must have seen 1 step (single-node invoke).
    for (log.results.items) |res| {
        if (std.mem.eql(u8, res.action_name, "count")) {
            try std.testing.expectEqual(@as(i48, 1), res.data.?.asInt());
        }
    }
}

test "failing action still produces a 'failed' log entry (no silent drop)" {
    var topo = aor_topology.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = aor_trace.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", incBody);
    const r = try aor_topology.invoke(&topo, &trace_store, "inc", Value.makeInt(7));
    const tr = try trace_store.getInvocation(std.testing.allocator, r.invoke_id);
    defer std.testing.allocator.free(tr.events);

    var log = ActionLog.init(std.testing.allocator);
    defer log.deinit();

    const actions = [_]Action{
        .{ .name = "ok", .description = "", .body = recordBody },
        .{ .name = "bad", .description = "", .body = failBody },
    };
    try runActionsOnInvocation(&actions, tr, &log);
    try std.testing.expectEqual(@as(usize, 2), log.count());
    try std.testing.expectEqualStrings("failed", log.results.items[1].tags);
    try std.testing.expect(log.results.items[1].data == null);
}

test "forInvocation filters results by invoke_id" {
    var log = ActionLog.init(std.testing.allocator);
    defer log.deinit();
    const info_a = RunInfo{ .invoke_id = 1, .input = Value.makeInt(0), .output = Value.makeInt(0), .latency_ns = 0, .step_count = 0 };
    const info_b = RunInfo{ .invoke_id = 2, .input = Value.makeInt(0), .output = Value.makeInt(0), .latency_ns = 0, .step_count = 0 };
    try runAction(.{ .name = "r", .description = "", .body = recordBody }, info_a, &log);
    try runAction(.{ .name = "r", .description = "", .body = recordBody }, info_b, &log);
    try runAction(.{ .name = "r", .description = "", .body = recordBody }, info_a, &log);

    const for_a = try log.forInvocation(std.testing.allocator, 1);
    defer std.testing.allocator.free(for_a);
    try std.testing.expectEqual(@as(usize, 2), for_a.len);

    const for_b = try log.forInvocation(std.testing.allocator, 2);
    defer std.testing.allocator.free(for_b);
    try std.testing.expectEqual(@as(usize, 1), for_b.len);
}
