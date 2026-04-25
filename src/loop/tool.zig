//! Rung 8 of agent-o-nanoclj — Tools and ToolRegistry.
//!
//! In agent-o-rama, "tools" are the function-calling primitives agents can
//! invoke (https://github.com/redplanetlabs/agent-o-rama/wiki/Tools). A tool
//! has a name, a description, and a callable body; agents pick a tool and
//! execute it during their invocation.
//!
//! This port keeps the shape minimal for the LLM-less case: a tool is a
//! named function from Value → Value, registered in a ToolRegistry. Agent
//! bodies look up tools by name from a registry handed to them, and the
//! registry is shared across a whole topology.
//!
//! Rationale for including this now: the feedback loop (Rung 7) closes
//! agent-state revision, but an agent body that can't call named operations
//! is too thin to express real work. With tools registered once and
//! dispatched by string, the same loop composes with any domain-specific
//! action.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;

pub const ToolError = error{
    ToolInvoke,
    ToolNotFound,
    DuplicateTool,
};

pub const ToolFn = *const fn (input: Value) ToolError!Value;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    invoke: ToolFn,
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMapUnmanaged(Tool) = .empty,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit(self.allocator);
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        if (self.tools.contains(tool.name)) return error.DuplicateTool;
        try self.tools.put(self.allocator, tool.name, tool);
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?Tool {
        return self.tools.get(name);
    }

    pub fn count(self: *const ToolRegistry) usize {
        return self.tools.count();
    }

    /// Convenience: lookup + invoke in one call.
    pub fn call(self: *const ToolRegistry, name: []const u8, input: Value) ToolError!Value {
        const t = self.get(name) orelse return error.ToolNotFound;
        return t.invoke(input);
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

fn addOne(in: Value) ToolError!Value {
    return Value.makeInt(in.asInt() + 1);
}

fn negate(in: Value) ToolError!Value {
    return Value.makeInt(-in.asInt());
}

fn boom(_: Value) ToolError!Value {
    return error.ToolInvoke;
}

test "ToolRegistry register + get + count + call" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.count());

    try reg.register(.{ .name = "add1", .description = "adds one", .invoke = addOne });
    try reg.register(.{ .name = "neg", .description = "negates", .invoke = negate });
    try std.testing.expectEqual(@as(usize, 2), reg.count());

    const t = reg.get("add1").?;
    try std.testing.expectEqualStrings("add1", t.name);
    try std.testing.expectEqualStrings("adds one", t.description);

    const r1 = try reg.call("add1", Value.makeInt(10));
    try std.testing.expectEqual(@as(i48, 11), r1.asInt());
    const r2 = try reg.call("neg", Value.makeInt(5));
    try std.testing.expectEqual(@as(i48, -5), r2.asInt());
}

test "ToolRegistry rejects duplicate names" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.register(.{ .name = "t", .description = "", .invoke = addOne });
    try std.testing.expectError(
        error.DuplicateTool,
        reg.register(.{ .name = "t", .description = "", .invoke = negate }),
    );
}

test "ToolRegistry.call on missing name returns ToolNotFound" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectError(error.ToolNotFound, reg.call("absent", Value.makeInt(0)));
}

test "ToolRegistry.call propagates the tool's error" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.register(.{ .name = "boom", .description = "always fails", .invoke = boom });
    try std.testing.expectError(error.ToolInvoke, reg.call("boom", Value.makeInt(0)));
}

test "ToolRegistry.get returns null for missing" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(?Tool, null), reg.get("nope"));
}
