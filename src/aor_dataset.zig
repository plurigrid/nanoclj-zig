//! Rung 5 of agent-o-nanoclj — datasets.
//!
//! A Dataset is a collection of `Example`s, each carrying:
//!   - input:    Value to feed into a topology
//!   - expected: optional Value for reference-based eval
//!   - tags:     caller-owned string (comma-separated convention)
//!
//! The persistence side (EDN / JSON at rest) is deferred to Rung 6. For now
//! datasets are constructed in-memory by callers. This is sufficient to run
//! experiments at the REPL or in unit tests.
//!
//! Reference: agent-o-rama docs on datasets + experiments
//! (https://github.com/redplanetlabs/agent-o-rama/wiki/Evaluation).

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

pub const Example = struct {
    input: Value,
    expected: ?Value = null,
    tags: []const u8 = "",
};

pub const Dataset = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    examples: std.ArrayListUnmanaged(Example) = .empty,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Dataset {
        return .{ .allocator = allocator, .name = name };
    }

    pub fn deinit(self: *Dataset) void {
        self.examples.deinit(self.allocator);
    }

    pub fn addExample(self: *Dataset, input: Value, expected: ?Value, tags: []const u8) !void {
        try self.examples.append(self.allocator, .{ .input = input, .expected = expected, .tags = tags });
    }

    pub fn len(self: *const Dataset) usize {
        return self.examples.items.len;
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "Dataset.init + addExample + deinit" {
    var ds = Dataset.init(std.testing.allocator, "greet-set");
    defer ds.deinit();
    try std.testing.expectEqual(@as(usize, 0), ds.len());
    try ds.addExample(Value.makeInt(1), Value.makeInt(2), "easy");
    try ds.addExample(Value.makeInt(10), null, "no-expected");
    try std.testing.expectEqual(@as(usize, 2), ds.len());
    try std.testing.expectEqualStrings("greet-set", ds.name);
    try std.testing.expectEqualStrings("easy", ds.examples.items[0].tags);
    try std.testing.expect(ds.examples.items[1].expected == null);
}

test "Dataset name is caller-owned" {
    const nm: []const u8 = "longitudinal";
    var ds = Dataset.init(std.testing.allocator, nm);
    defer ds.deinit();
    try std.testing.expectEqualStrings(nm, ds.name);
}
