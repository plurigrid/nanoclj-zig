const std = @import("std");
const Value = @import("value.zig").Value;

/// Persistent vector using a 32-way trie (Bagwell HAMT).
/// Branching factor = 32, shift = 5 bits per level.
/// Structural sharing: modifications copy only the path from root to leaf.
const BITS = 5;
const WIDTH = 1 << BITS; // 32
const MASK = WIDTH - 1;

pub const Node = struct {
    children: [WIDTH]?*Node = [_]?*Node{null} ** WIDTH,
    values: [WIDTH]Value = [_]Value{Value.makeNil()} ** WIDTH,
    is_leaf: bool = false,
    ref_count: u32 = 1,
};

pub const PersistentVector = struct {
    root: ?*Node,
    tail: [WIDTH]Value,
    tail_len: u6, // 0..32
    count: u32,
    shift: u5, // depth * BITS (5, 10, 15, ...)
    allocator: std.mem.Allocator,

    pub fn empty(allocator: std.mem.Allocator) PersistentVector {
        return .{
            .root = null,
            .tail = [_]Value{Value.makeNil()} ** WIDTH,
            .tail_len = 0,
            .count = 0,
            .shift = BITS,
            .allocator = allocator,
        };
    }

    /// O(log32 n) — get value at index
    pub fn nth(self: *const PersistentVector, index: u32) ?Value {
        if (index >= self.count) return null;
        // Check if index is in the tail
        const tail_offset = self.tailOffset();
        if (index >= tail_offset) {
            return self.tail[index - tail_offset];
        }
        // Walk the trie
        var node = self.root orelse return null;
        var level = self.shift;
        while (level > BITS) {
            level -= BITS;
            const idx = (index >> @intCast(level)) & MASK;
            node = node.children[idx] orelse return null;
        }
        return node.values[index & MASK];
    }

    /// O(~1) amortized — append a value, returning a new vector
    pub fn conj(self: *const PersistentVector, val: Value) !PersistentVector {
        // If tail has room, just add to tail
        if (self.tail_len < WIDTH) {
            var new = self.*;
            new.tail[self.tail_len] = val;
            new.tail_len = self.tail_len + 1;
            new.count = self.count + 1;
            return new;
        }
        // Tail is full — push it into the trie and start a new tail
        const new_root = try self.pushTail(self.shift, self.root, self.tail[0..WIDTH]);
        var new = PersistentVector{
            .root = new_root.node,
            .tail = [_]Value{Value.makeNil()} ** WIDTH,
            .tail_len = 1,
            .count = self.count + 1,
            .shift = if (new_root.overflow) self.shift + BITS else self.shift,
            .allocator = self.allocator,
        };
        new.tail[0] = val;
        return new;
    }

    /// O(log32 n) — set value at index, returning a new vector
    pub fn assocN(self: *const PersistentVector, index: u32, val: Value) !PersistentVector {
        if (index >= self.count) return error.IndexOutOfBounds;
        var new = self.*;
        const tail_offset = self.tailOffset();
        if (index >= tail_offset) {
            new.tail[index - tail_offset] = val;
            return new;
        }
        // Path-copy through the trie
        new.root = try self.doAssoc(self.shift, self.root, index, val);
        return new;
    }

    /// O(~1) — remove last element, returning a new vector
    pub fn pop(self: *const PersistentVector) !PersistentVector {
        if (self.count == 0) return error.IndexOutOfBounds;
        if (self.count == 1) return empty(self.allocator);
        // If tail has more than one element, just shrink it
        if (self.tail_len > 1) {
            var new = self.*;
            new.tail_len = self.tail_len - 1;
            new.tail[new.tail_len] = Value.makeNil();
            new.count = self.count - 1;
            return new;
        }
        // Tail has one element — pull the last leaf from trie as new tail
        const tail_offset = self.tailOffset() - WIDTH;
        var new_tail: [WIDTH]Value = [_]Value{Value.makeNil()} ** WIDTH;
        // Read the last leaf from the trie
        if (self.root) |root| {
            var node = root;
            var level = self.shift;
            while (level > BITS) {
                level -= BITS;
                const idx = (tail_offset >> @intCast(level)) & MASK;
                node = node.children[idx] orelse break;
            }
            new_tail = node.values;
        }
        var new = PersistentVector{
            .root = try self.popTail(self.shift, self.root),
            .tail = new_tail,
            .tail_len = WIDTH,
            .count = self.count - 1,
            .shift = self.shift,
            .allocator = self.allocator,
        };
        // Shrink the root if needed
        if (new.root) |root| {
            if (!root.is_leaf and new.shift > BITS) {
                var non_null_count: u32 = 0;
                var only_child: ?*Node = null;
                for (root.children) |ch| {
                    if (ch != null) {
                        non_null_count += 1;
                        only_child = ch;
                    }
                }
                if (non_null_count == 1) {
                    new.root = only_child;
                    new.shift -= BITS;
                }
            }
        }
        return new;
    }

    fn tailOffset(self: *const PersistentVector) u32 {
        if (self.count < WIDTH) return 0;
        return ((self.count - 1) >> BITS) << BITS;
    }

    const PushResult = struct { node: *Node, overflow: bool };

    fn pushTail(self: *const PersistentVector, level: u5, parent: ?*Node, tail_vals: []const Value) !PushResult {
        const sub_idx = ((self.count - 1) >> @intCast(level)) & MASK;
        if (level == BITS) {
            // Create a leaf node with the tail values
            const new_leaf = try self.allocator.create(Node);
            new_leaf.* = .{ .is_leaf = true };
            for (tail_vals, 0..) |v, i| {
                new_leaf.values[i] = v;
            }
            if (parent) |p| {
                // Copy parent, set the new child
                const new_parent = try self.copyNode(p);
                new_parent.children[sub_idx] = new_leaf;
                return .{ .node = new_parent, .overflow = false };
            } else {
                const new_parent = try self.allocator.create(Node);
                new_parent.* = .{};
                new_parent.children[0] = new_leaf;
                return .{ .node = new_parent, .overflow = false };
            }
        }
        if (parent) |p| {
            const child = p.children[sub_idx];
            const result = try self.pushTail(level - BITS, child, tail_vals);
            const new_parent = try self.copyNode(p);
            if (result.overflow) {
                // Need a new slot in this node
                if (sub_idx + 1 < WIDTH) {
                    new_parent.children[sub_idx + 1] = result.node;
                    return .{ .node = new_parent, .overflow = false };
                } else {
                    // This level overflows too
                    const new_node = try self.allocator.create(Node);
                    new_node.* = .{};
                    new_node.children[0] = result.node;
                    return .{ .node = new_parent, .overflow = true };
                }
            } else {
                new_parent.children[sub_idx] = result.node;
                return .{ .node = new_parent, .overflow = false };
            }
        } else {
            // No parent at this level — need to create a path
            const result = try self.pushTail(level - BITS, null, tail_vals);
            const new_node = try self.allocator.create(Node);
            new_node.* = .{};
            new_node.children[0] = result.node;
            return .{ .node = new_node, .overflow = result.overflow };
        }
    }

    fn doAssoc(self: *const PersistentVector, level: u5, node: ?*Node, index: u32, val: Value) !*Node {
        const n = node orelse return error.IndexOutOfBounds;
        const new_node = try self.copyNode(n);
        if (level == 0) {
            new_node.values[index & MASK] = val;
        } else {
            const sub_idx = (index >> @intCast(level)) & MASK;
            new_node.children[sub_idx] = try self.doAssoc(level - BITS, n.children[sub_idx], index, val);
        }
        return new_node;
    }

    fn popTail(self: *const PersistentVector, level: u5, node: ?*Node) !?*Node {
        const n = node orelse return null;
        const sub_idx = ((self.count - 2) >> @intCast(level)) & MASK;
        if (level > BITS) {
            const new_child = try self.popTail(level - BITS, n.children[sub_idx]);
            if (new_child == null and sub_idx == 0) return null;
            const new_node = try self.copyNode(n);
            new_node.children[sub_idx] = new_child;
            return new_node;
        }
        if (sub_idx == 0) return null;
        const new_node = try self.copyNode(n);
        new_node.children[sub_idx] = null;
        return new_node;
    }

    fn copyNode(self: *const PersistentVector, n: *Node) !*Node {
        const new_node = try self.allocator.create(Node);
        new_node.* = n.*;
        new_node.ref_count = 1;
        return new_node;
    }

    /// Free all nodes (for owned cleanup only — not for shared structures)
    pub fn deinit(self: *PersistentVector) void {
        if (self.root) |root| {
            freeNode(self.allocator, root, self.shift);
        }
    }

    fn freeNode(allocator: std.mem.Allocator, node: *Node, level: u5) void {
        if (level > BITS) {
            for (node.children) |ch| {
                if (ch) |child| {
                    freeNode(allocator, child, level - BITS);
                }
            }
        }
        allocator.destroy(node);
    }

    /// Convert to a flat slice (for interop with existing code)
    pub fn toSlice(self: *const PersistentVector, allocator: std.mem.Allocator) ![]Value {
        const slice = try allocator.alloc(Value, self.count);
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            slice[i] = self.nth(i) orelse Value.makeNil();
        }
        return slice;
    }

    /// Create from a slice of values
    pub fn fromSlice(allocator: std.mem.Allocator, values: []const Value) !PersistentVector {
        var vec = empty(allocator);
        for (values) |v| {
            vec = try vec.conj(v);
        }
        return vec;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "persistent vector: basic conj and nth" {
    const alloc = std.testing.allocator;
    var v = PersistentVector.empty(alloc);
    // Build up 100 elements
    var i: u32 = 0;
    var nodes_to_free = std.ArrayList(*Node).init(alloc);
    defer nodes_to_free.deinit();
    while (i < 100) : (i += 1) {
        const old_root = v.root;
        v = try v.conj(Value.makeInt(@intCast(i)));
        // Track new root nodes for cleanup
        if (v.root != old_root) {
            if (v.root) |r| try nodes_to_free.append(r);
        }
    }
    defer {
        // Free all tracked nodes
        for (nodes_to_free.items) |n| {
            PersistentVector.freeNode(alloc, n, v.shift);
        }
    }
    try std.testing.expectEqual(@as(u32, 100), v.count);
    try std.testing.expectEqual(@as(i48, 0), v.nth(0).?.asInt());
    try std.testing.expectEqual(@as(i48, 99), v.nth(99).?.asInt());
    try std.testing.expectEqual(@as(i48, 50), v.nth(50).?.asInt());
    try std.testing.expect(v.nth(100) == null);
}

test "persistent vector: structural sharing" {
    const alloc = std.testing.allocator;
    var v1 = PersistentVector.empty(alloc);
    v1 = try v1.conj(Value.makeInt(1));
    v1 = try v1.conj(Value.makeInt(2));
    v1 = try v1.conj(Value.makeInt(3));
    // v2 shares structure with v1
    var v2 = try v1.conj(Value.makeInt(4));
    try std.testing.expectEqual(@as(u32, 3), v1.count);
    try std.testing.expectEqual(@as(u32, 4), v2.count);
    try std.testing.expectEqual(@as(i48, 3), v1.nth(2).?.asInt());
    try std.testing.expectEqual(@as(i48, 4), v2.nth(3).?.asInt());
    // v1 is unchanged
    try std.testing.expect(v1.nth(3) == null);
    _ = &v2;
}

test "persistent vector: assocN" {
    const alloc = std.testing.allocator;
    var v1 = PersistentVector.empty(alloc);
    v1 = try v1.conj(Value.makeInt(10));
    v1 = try v1.conj(Value.makeInt(20));
    v1 = try v1.conj(Value.makeInt(30));
    const v2 = try v1.assocN(1, Value.makeInt(99));
    try std.testing.expectEqual(@as(i48, 20), v1.nth(1).?.asInt()); // original unchanged
    try std.testing.expectEqual(@as(i48, 99), v2.nth(1).?.asInt()); // new version updated
}

test "persistent vector: fromSlice" {
    const alloc = std.testing.allocator;
    const vals = [_]Value{ Value.makeInt(1), Value.makeInt(2), Value.makeInt(3) };
    const v = try PersistentVector.fromSlice(alloc, &vals);
    try std.testing.expectEqual(@as(u32, 3), v.count);
    try std.testing.expectEqual(@as(i48, 2), v.nth(1).?.asInt());
}
