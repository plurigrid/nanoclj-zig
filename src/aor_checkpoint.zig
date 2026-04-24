//! Unified save/restore for the agent-o-nanoclj world.
//!
//! Individual rungs have their own JSONL dump/load methods. This module
//! offers a single primitive that captures all three log types together
//! with a simple framing so a caller can "save the whole world" and
//! "reload the whole world" in one call.
//!
//! Format (pipe/newline-escaped at the per-log level per the rung's own
//! encoder):
//!
//!     # aor-checkpoint v1
//!     # trace
//!     <trace lines...>
//!     # action
//!     <action lines...>
//!     # telemetry
//!     <telemetry lines...>
//!
//! The `#` lines are section markers. They don't appear inside log content
//! because TraceStore/ActionLog/TelemetrySink all use pipe-delimited lines
//! starting with a digit or a printable character — no line in a rung's
//! output starts with `#`. (If that invariant ever breaks, the version
//! header catches the mismatch.)

const std = @import("std");
const aor_trace = @import("aor_trace.zig");
const aor_action = @import("aor_action.zig");
const aor_telemetry = @import("aor_telemetry.zig");

pub const CheckpointError = error{
    ParseError,
    OutOfMemory,
    MissingSection,
    VersionMismatch,
};

/// Handles to the three log types. Any can be null to opt out.
pub const Checkpoint = struct {
    trace: ?*aor_trace.TraceStore = null,
    action_log: ?*aor_action.ActionLog = null,
    telemetry: ?*aor_telemetry.TelemetrySink = null,

    /// Serialize all participating logs into a single buffer.
    pub fn write(
        self: *const Checkpoint,
        out: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        scratch_alloc: std.mem.Allocator,
    ) !void {
        try out.appendSlice(alloc, "# aor-checkpoint v1\n");
        try out.appendSlice(alloc, "# trace\n");
        if (self.trace) |t| try t.writeJsonl(out, alloc, scratch_alloc);
        try out.appendSlice(alloc, "# action\n");
        if (self.action_log) |l| try l.writeJsonl(out, alloc, scratch_alloc);
        try out.appendSlice(alloc, "# telemetry\n");
        if (self.telemetry) |ts| try ts.writeJsonl(out, alloc, scratch_alloc);
    }

    /// Load from a buffer previously produced by `write`. Sections not
    /// present in the checkpoint are left unchanged in their log.
    pub fn load(self: *Checkpoint, data: []const u8, intern_alloc: std.mem.Allocator) !void {
        var section: Section = .header;
        var section_start: usize = 0;
        var saw_version = false;

        var it = std.mem.splitScalar(u8, data, '\n');
        var pos: usize = 0;
        while (it.next()) |line| : (pos += line.len + 1) {
            const is_marker = line.len > 0 and line[0] == '#';
            if (is_marker) {
                // Flush the previous section's buffer.
                if (section != .header) {
                    const buf = data[section_start..pos];
                    try self.dispatchSection(section, buf, intern_alloc);
                }
                if (std.mem.startsWith(u8, line, "# aor-checkpoint v1")) {
                    saw_version = true;
                    section = .header;
                } else if (std.mem.eql(u8, line, "# trace")) {
                    section = .trace;
                } else if (std.mem.eql(u8, line, "# action")) {
                    section = .action;
                } else if (std.mem.eql(u8, line, "# telemetry")) {
                    section = .telemetry;
                } else {
                    return error.ParseError;
                }
                section_start = pos + line.len + 1;
            }
        }
        // Flush the final section.
        if (section != .header and section_start < data.len) {
            try self.dispatchSection(section, data[section_start..], intern_alloc);
        }
        if (!saw_version) return error.VersionMismatch;
    }

    const Section = enum { header, trace, action, telemetry };

    fn dispatchSection(
        self: *Checkpoint,
        section: Section,
        buf: []const u8,
        intern_alloc: std.mem.Allocator,
    ) !void {
        switch (section) {
            .header => {},
            .trace => if (self.trace) |t| try t.loadJsonl(buf, intern_alloc),
            .action => if (self.action_log) |l| try l.loadJsonl(buf, intern_alloc),
            .telemetry => if (self.telemetry) |ts| try ts.loadJsonl(buf),
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

const value = @import("value.zig");
const Value = value.Value;
const aor_agent = @import("aor_agent.zig");

fn echoBody(_: *aor_agent.Agent, in: Value) error{Invoke}!Value {
    return in;
}

test "Checkpoint write → load preserves all three logs" {
    // Populate three logs.
    var trace = aor_trace.TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    var action = aor_action.ActionLog.init(std.testing.allocator);
    defer action.deinit();
    var telem = aor_telemetry.TelemetrySink.init(std.testing.allocator);
    defer telem.deinit();

    var agent = aor_agent.Agent.init("e", echoBody);
    agent.id = 1;
    const inv = trace.startInvocation();
    _ = try trace.recordStep(inv, &agent, Value.makeInt(10), Value.makeInt(10), "");
    _ = try trace.recordStep(inv, &agent, Value.makeInt(20), null, "tag");

    try action.results.append(action.allocator, .{
        .invoke_id = inv,
        .action_name = "log",
        .data = Value.makeInt(42),
        .tags = "metric",
    });
    try telem.record("latency.ns", 1_000_000.0, "");
    try telem.record("eval.score", 0.7, "");
    try telem.record("eval.score", 0.9, "");

    const cp_out = Checkpoint{ .trace = &trace, .action_log = &action, .telemetry = &telem };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try cp_out.write(&buf, std.testing.allocator, std.testing.allocator);

    // Fresh world; load.
    var trace2 = aor_trace.TraceStore.init(std.testing.allocator);
    defer {
        for (trace2.events.items) |ev| {
            std.testing.allocator.free(ev.agent_name);
            std.testing.allocator.free(ev.tags);
        }
        trace2.deinit();
    }
    var action2 = aor_action.ActionLog.init(std.testing.allocator);
    defer {
        for (action2.results.items) |r| {
            std.testing.allocator.free(r.action_name);
            std.testing.allocator.free(r.tags);
        }
        action2.deinit();
    }
    var telem2 = aor_telemetry.TelemetrySink.init(std.testing.allocator);
    defer telem2.deinit();
    var cp_in = Checkpoint{ .trace = &trace2, .action_log = &action2, .telemetry = &telem2 };
    try cp_in.load(buf.items, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), trace2.eventCount());
    try std.testing.expectEqual(@as(usize, 1), action2.count());
    try std.testing.expectEqual(@as(usize, 2), telem2.aggregateAll("eval.score").count);
    try std.testing.expectEqual(@as(usize, 1), telem2.aggregateAll("latency.ns").count);
}

test "Checkpoint.load rejects bad version header" {
    var trace = aor_trace.TraceStore.init(std.testing.allocator);
    defer trace.deinit();
    var cp = Checkpoint{ .trace = &trace };
    try std.testing.expectError(
        error.VersionMismatch,
        cp.load("# trace\n", std.testing.allocator),
    );
}

test "Checkpoint with all fields null: write produces framing only" {
    var cp = Checkpoint{};
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try cp.write(&buf, std.testing.allocator, std.testing.allocator);
    // Just three markers + version header.
    const expected =
        "# aor-checkpoint v1\n" ++
        "# trace\n" ++
        "# action\n" ++
        "# telemetry\n";
    try std.testing.expectEqualStrings(expected, buf.items);
}
