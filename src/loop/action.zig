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
const value = @import("../value.zig");
const Value = value.Value;

const trace_lib = @import("trace.zig");
const InvokeId = trace_lib.InvokeId;
const InvocationTrace = trace_lib.InvocationTrace;

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

    /// Rung 6 — append one line per ActionResult:
    ///   invoke_id|action_name|data_bits|tags
    /// data_bits is "-" for null. action_name and tags escape '\|\n\\'.
    pub fn writeJsonl(
        self: *const ActionLog,
        out: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        scratch_alloc: std.mem.Allocator,
    ) !void {
        var tmp: [64]u8 = undefined;
        for (self.results.items) |r| {
            const name_esc = try escapeField(scratch_alloc, r.action_name);
            defer scratch_alloc.free(name_esc);
            const tags_esc = try escapeField(scratch_alloc, r.tags);
            defer scratch_alloc.free(tags_esc);

            try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{r.invoke_id}));
            try out.append(alloc, '|');
            try out.appendSlice(alloc, name_esc);
            try out.append(alloc, '|');
            if (r.data) |d| {
                try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{d.bits}));
            } else {
                try out.append(alloc, '-');
            }
            try out.append(alloc, '|');
            try out.appendSlice(alloc, tags_esc);
            try out.append(alloc, '\n');
        }
    }

    pub fn loadJsonl(self: *ActionLog, data: []const u8, intern_alloc: std.mem.Allocator) !void {
        self.results.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var parts: [4][]const u8 = undefined;
            var idx: usize = 0;
            var cursor: usize = 0;
            var field_start: usize = 0;
            while (cursor < line.len and idx < 4) : (cursor += 1) {
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
            if (idx != 3) return error.ParseError;
            parts[3] = line[field_start..];

            const iid = try std.fmt.parseInt(InvokeId, parts[0], 10);
            const name = try unescapeField(intern_alloc, parts[1]);
            const data_opt = if (std.mem.eql(u8, parts[2], "-"))
                @as(?Value, null)
            else blk: {
                const bits = try std.fmt.parseInt(u64, parts[2], 10);
                break :blk @as(?Value, Value{ .bits = bits });
            };
            const tags = try unescapeField(intern_alloc, parts[3]);

            try self.results.append(self.allocator, .{
                .invoke_id = iid,
                .action_name = name,
                .data = data_opt,
                .tags = tags,
            });
        }
    }
};

// Escape helpers shared between write/load. Identical grammar to
// trace.zig so a single codec covers trace + action logs.
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
            switch (s[i + 1]) {
                '\\' => try out.append(allocator, '\\'),
                'n' => try out.append(allocator, '\n'),
                '|' => try out.append(allocator, '|'),
                else => try out.append(allocator, s[i + 1]),
            }
            i += 2;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

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

const agent_lib = @import("agent.zig");
const topology_lib = @import("topology.zig");

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

fn incBody(_: *agent_lib.Agent, in: Value) error{Invoke}!Value {
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
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", incBody);

    const r = try topology_lib.invoke(&topo, &trace_store, "inc", Value.makeInt(100));
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
    var topo = topology_lib.Topology.init(std.testing.allocator);
    defer topo.deinit();
    var trace_store = trace_lib.TraceStore.init(std.testing.allocator);
    defer trace_store.deinit();
    _ = try topo.newAgent("inc", incBody);
    const r = try topology_lib.invoke(&topo, &trace_store, "inc", Value.makeInt(7));
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

test "ActionLog writeJsonl → loadJsonl roundtrip" {
    var log = ActionLog.init(std.testing.allocator);
    defer log.deinit();
    try log.results.append(log.allocator, .{
        .invoke_id = 7,
        .action_name = "alpha",
        .data = Value.makeInt(99),
        .tags = "ok",
    });
    try log.results.append(log.allocator, .{
        .invoke_id = 8,
        .action_name = "b|eta",
        .data = null,
        .tags = "fail\nweird",
    });

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try log.writeJsonl(&buf, std.testing.allocator, std.testing.allocator);

    var log2 = ActionLog.init(std.testing.allocator);
    defer {
        for (log2.results.items) |r| {
            std.testing.allocator.free(r.action_name);
            std.testing.allocator.free(r.tags);
        }
        log2.deinit();
    }
    try log2.loadJsonl(buf.items, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), log2.count());
    try std.testing.expectEqual(@as(InvokeId, 7), log2.results.items[0].invoke_id);
    try std.testing.expectEqualStrings("alpha", log2.results.items[0].action_name);
    try std.testing.expectEqual(@as(i48, 99), log2.results.items[0].data.?.asInt());
    try std.testing.expectEqualStrings("ok", log2.results.items[0].tags);
    try std.testing.expectEqualStrings("b|eta", log2.results.items[1].action_name);
    try std.testing.expect(log2.results.items[1].data == null);
    try std.testing.expectEqualStrings("fail\nweird", log2.results.items[1].tags);
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
