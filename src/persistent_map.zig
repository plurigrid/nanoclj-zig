const std = @import("std");
const Value = @import("value.zig").Value;
const semantics = @import("semantics.zig");
const GC = @import("gc.zig").GC;
const compat = @import("compat.zig");

/// Persistent hash map using a Hash Array Mapped Trie (HAMT).
/// Branching factor = 32, uses a bitmap to indicate which slots are populated.
/// Structural sharing: modifications copy only the path from root to the changed entry.
const BITS = 5;
const WIDTH = 1 << BITS; // 32
const MASK = WIDTH - 1;

fn hashValue(v: Value, gc: *GC) u32 {
    if (v.isKeyword()) {
        const s = gc.getString(v.asKeywordId());
        return @truncate(std.hash.Wyhash.hash(0, s));
    }
    if (v.isSymbol()) {
        const s = gc.getString(v.asSymbolId());
        return @truncate(std.hash.Wyhash.hash(1, s));
    }
    if (v.isInt()) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, v.asInt(), .little);
        return @truncate(std.hash.Wyhash.hash(2, &buf));
    }
    if (v.isString()) {
        const s = gc.getString(v.asStringId());
        return @truncate(std.hash.Wyhash.hash(3, s));
    }
    if (v.isObj()) {
        const obj = v.asObj();
        if (obj.kind == .color) {
            const c = obj.data.color;
            var buf: [16]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], @bitCast(c.L), .little);
            std.mem.writeInt(u32, buf[4..8], @bitCast(c.a), .little);
            std.mem.writeInt(u32, buf[8..12], @bitCast(c.b), .little);
            std.mem.writeInt(u32, buf[12..16], @bitCast(c.alpha), .little);
            return @truncate(std.hash.Wyhash.hash(4, &buf));
        }
    }
    // fallback: treat as zero hash
    return 0;
}

pub const Entry = struct {
    key: Value,
    val: Value,
};

pub const HamtNode = union(enum) {
    branch: BranchNode,
    leaf: Entry,
    collision: CollisionNode,
};

pub const BranchNode = struct {
    bitmap: u32 = 0,
    children: std.ArrayListUnmanaged(*HamtNode),

    fn compressedIndex(self: *const BranchNode, bit: u32) u32 {
        return @popCount(self.bitmap & (bit - 1));
    }
};

pub const CollisionNode = struct {
    entries: std.ArrayListUnmanaged(Entry),
    hash: u32,
};

pub const PersistentMap = struct {
    root: ?*HamtNode,
    count: u32,
    allocator: std.mem.Allocator,

    pub fn empty(allocator: std.mem.Allocator) PersistentMap {
        return .{ .root = null, .count = 0, .allocator = allocator };
    }

    /// O(log32 n) — lookup a key
    pub fn get(self: *const PersistentMap, key: Value, gc: *GC) ?Value {
        const root = self.root orelse return null;
        const hash = hashValue(key, gc);
        return getNode(root, key, hash, 0, gc);
    }

    /// O(log32 n) — insert or update, returns a new map
    pub fn assoc(self: *const PersistentMap, key: Value, val: Value, gc: *GC) !PersistentMap {
        const hash = hashValue(key, gc);
        var added = false;
        const new_root = try assocNode(self.allocator, self.root, key, val, hash, 0, gc, &added);
        return .{
            .root = new_root,
            .count = if (added) self.count + 1 else self.count,
            .allocator = self.allocator,
        };
    }

    /// O(log32 n) — remove a key, returns a new map
    pub fn dissoc(self: *const PersistentMap, key: Value, gc: *GC) !PersistentMap {
        if (self.root == null) return self.*;
        const hash = hashValue(key, gc);
        var removed = false;
        const new_root = try dissocNode(self.allocator, self.root.?, key, hash, 0, gc, &removed);
        return .{
            .root = new_root,
            .count = if (removed and self.count > 0) self.count - 1 else self.count,
            .allocator = self.allocator,
        };
    }

    pub fn containsKey(self: *const PersistentMap, key: Value, gc: *GC) bool {
        return self.get(key, gc) != null;
    }

    /// Convert to flat key/value slices for interop
    pub fn toEntries(self: *const PersistentMap, allocator: std.mem.Allocator) !struct { keys: []Value, vals: []Value } {
        var keys = std.ArrayList(Value).init(allocator);
        var vals = std.ArrayList(Value).init(allocator);
        if (self.root) |root| {
            try collectEntries(root, &keys, &vals);
        }
        return .{ .keys = try keys.toOwnedSlice(), .vals = try vals.toOwnedSlice() };
    }

    fn collectEntries(node: *HamtNode, keys: *std.ArrayList(Value), vals: *std.ArrayList(Value)) !void {
        switch (node.*) {
            .leaf => |entry| {
                try keys.append(entry.key);
                try vals.append(entry.val);
            },
            .branch => |branch| {
                for (branch.children.items) |child| {
                    try collectEntries(child, keys, vals);
                }
            },
            .collision => |coll| {
                for (coll.entries.items) |entry| {
                    try keys.append(entry.key);
                    try vals.append(entry.val);
                }
            },
        }
    }

    /// Create from key/value slices
    pub fn fromEntries(allocator: std.mem.Allocator, keys: []const Value, vals: []const Value, gc: *GC) !PersistentMap {
        var m = empty(allocator);
        for (keys, vals) |k, v| {
            m = try m.assoc(k, v, gc);
        }
        return m;
    }
};

fn getNode(node: *HamtNode, key: Value, hash: u32, shift: u5, gc: *GC) ?Value {
    switch (node.*) {
        .leaf => |entry| {
            if (semantics.structuralEq(entry.key, key, gc)) return entry.val;
            return null;
        },
        .branch => |branch| {
            const bit: u32 = @as(u32, 1) << @intCast((hash >> shift) & MASK);
            if (branch.bitmap & bit == 0) return null;
            const idx = branch.compressedIndex(bit);
            if (idx >= branch.children.items.len) return null;
            return getNode(branch.children.items[idx], key, hash, shift +| BITS, gc);
        },
        .collision => |coll| {
            for (coll.entries.items) |entry| {
                if (semantics.structuralEq(entry.key, key, gc)) return entry.val;
            }
            return null;
        },
    }
}

fn assocNode(allocator: std.mem.Allocator, node: ?*HamtNode, key: Value, val: Value, hash: u32, shift: u5, gc: *GC, added: *bool) !*HamtNode {
    if (node == null) {
        const new_node = try allocator.create(HamtNode);
        new_node.* = .{ .leaf = .{ .key = key, .val = val } };
        added.* = true;
        return new_node;
    }
    const n = node.?;
    switch (n.*) {
        .leaf => |entry| {
            if (semantics.structuralEq(entry.key, key, gc)) {
                // Update existing key
                const new_node = try allocator.create(HamtNode);
                new_node.* = .{ .leaf = .{ .key = key, .val = val } };
                return new_node;
            }
            // Hash collision at this level?
            const existing_hash = hashValue(entry.key, gc);
            if (existing_hash == hash) {
                // True collision — create collision node
                const new_node = try allocator.create(HamtNode);
                var entries = compat.emptyList(Entry);
                try entries.append(allocator, entry);
                try entries.append(allocator, .{ .key = key, .val = val });
                new_node.* = .{ .collision = .{ .entries = entries, .hash = hash } };
                added.* = true;
                return new_node;
            }
            // Different hashes — create a branch
            const new_branch = try allocator.create(HamtNode);
            var children = compat.emptyList(*HamtNode);
            const bit1: u32 = @as(u32, 1) << @intCast((existing_hash >> shift) & MASK);
            const bit2: u32 = @as(u32, 1) << @intCast((hash >> shift) & MASK);
            if (bit1 == bit2) {
                // Same slot — recurse deeper
                const child = try assocNode(allocator, n, key, val, hash, shift +| BITS, gc, added);
                try children.append(allocator, child);
                new_branch.* = .{ .branch = .{ .bitmap = bit1, .children = children } };
            } else {
                // Different slots
                const leaf1 = try allocator.create(HamtNode);
                leaf1.* = .{ .leaf = entry };
                const leaf2 = try allocator.create(HamtNode);
                leaf2.* = .{ .leaf = .{ .key = key, .val = val } };
                if (bit1 < bit2) {
                    try children.append(allocator, leaf1);
                    try children.append(allocator, leaf2);
                } else {
                    try children.append(allocator, leaf2);
                    try children.append(allocator, leaf1);
                }
                new_branch.* = .{ .branch = .{ .bitmap = bit1 | bit2, .children = children } };
                added.* = true;
            }
            return new_branch;
        },
        .branch => |branch| {
            const bit: u32 = @as(u32, 1) << @intCast((hash >> shift) & MASK);
            const idx = branch.compressedIndex(bit);
            const new_node = try allocator.create(HamtNode);
            var new_children = compat.emptyList(*HamtNode);
            try new_children.appendSlice(allocator, branch.children.items);
            if (branch.bitmap & bit != 0) {
                // Existing slot — recurse
                new_children.items[idx] = try assocNode(allocator, branch.children.items[idx], key, val, hash, shift +| BITS, gc, added);
                new_node.* = .{ .branch = .{ .bitmap = branch.bitmap, .children = new_children } };
            } else {
                // New slot — insert
                const leaf = try allocator.create(HamtNode);
                leaf.* = .{ .leaf = .{ .key = key, .val = val } };
                try new_children.insert(allocator, idx, leaf);
                new_node.* = .{ .branch = .{ .bitmap = branch.bitmap | bit, .children = new_children } };
                added.* = true;
            }
            return new_node;
        },
        .collision => |coll| {
            if (coll.hash == hash) {
                const new_node = try allocator.create(HamtNode);
                var entries = compat.emptyList(Entry);
                try entries.appendSlice(allocator, coll.entries.items);
                // Check for existing key
                for (entries.items, 0..) |entry, i| {
                    if (semantics.structuralEq(entry.key, key, gc)) {
                        entries.items[i] = .{ .key = key, .val = val };
                        new_node.* = .{ .collision = .{ .entries = entries, .hash = hash } };
                        return new_node;
                    }
                }
                try entries.append(allocator, .{ .key = key, .val = val });
                new_node.* = .{ .collision = .{ .entries = entries, .hash = hash } };
                added.* = true;
                return new_node;
            }
            // Different hash — upgrade to branch
            return assocNode(allocator, null, key, val, hash, shift, gc, added);
        },
    }
}

fn dissocNode(allocator: std.mem.Allocator, node: *HamtNode, key: Value, hash: u32, shift: u5, gc: *GC, removed: *bool) !?*HamtNode {
    switch (node.*) {
        .leaf => |entry| {
            if (semantics.structuralEq(entry.key, key, gc)) {
                removed.* = true;
                return null;
            }
            return node; // key not found
        },
        .branch => |branch| {
            const bit: u32 = @as(u32, 1) << @intCast((hash >> shift) & MASK);
            if (branch.bitmap & bit == 0) return node; // key not in this branch
            const idx = branch.compressedIndex(bit);
            const new_child = try dissocNode(allocator, branch.children.items[idx], key, hash, shift +| BITS, gc, removed);
            if (!removed.*) return node;
            if (new_child == null) {
                // Remove this slot
                const new_bitmap = branch.bitmap & ~bit;
                if (new_bitmap == 0) return null;
                if (@popCount(new_bitmap) == 1) {
                    // Collapse: only one child left — return it directly
                    for (branch.children.items, 0..) |child, i| {
                        if (i != idx) return child;
                    }
                }
                const new_node = try allocator.create(HamtNode);
                var new_children = compat.emptyList(*HamtNode);
                for (branch.children.items, 0..) |child, i| {
                    if (i != idx) try new_children.append(allocator, child);
                }
                new_node.* = .{ .branch = .{ .bitmap = new_bitmap, .children = new_children } };
                return new_node;
            } else {
                const new_node = try allocator.create(HamtNode);
                var new_children = compat.emptyList(*HamtNode);
                try new_children.appendSlice(allocator, branch.children.items);
                new_children.items[idx] = new_child.?;
                new_node.* = .{ .branch = .{ .bitmap = branch.bitmap, .children = new_children } };
                return new_node;
            }
        },
        .collision => |coll| {
            const new_node = try allocator.create(HamtNode);
            var entries = compat.emptyList(Entry);
            for (coll.entries.items) |entry| {
                if (!semantics.structuralEq(entry.key, key, gc)) {
                    try entries.append(allocator, entry);
                } else {
                    removed.* = true;
                }
            }
            if (entries.items.len == 0) return null;
            if (entries.items.len == 1) {
                new_node.* = .{ .leaf = entries.items[0] };
            } else {
                new_node.* = .{ .collision = .{ .entries = entries, .hash = coll.hash } };
            }
            return new_node;
        },
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "persistent map: basic assoc and get" {
    // page_allocator: structural sharing means intermediate nodes can't be individually freed
    const alloc = std.heap.page_allocator;
    const gc_mod = @import("gc.zig");
    var gc = gc_mod.GC.init(alloc);
    defer gc.deinit();

    var m = PersistentMap.empty(alloc);
    const k1 = Value.makeKeyword(try gc.internString("a"));
    const k2 = Value.makeKeyword(try gc.internString("b"));
    m = try m.assoc(k1, Value.makeInt(1), &gc);
    m = try m.assoc(k2, Value.makeInt(2), &gc);

    try std.testing.expectEqual(@as(u32, 2), m.count);
    try std.testing.expectEqual(@as(i48, 1), m.get(k1, &gc).?.asInt());
    try std.testing.expectEqual(@as(i48, 2), m.get(k2, &gc).?.asInt());
}

test "persistent map: structural sharing" {
    const alloc = std.heap.page_allocator;
    const gc_mod = @import("gc.zig");
    var gc = gc_mod.GC.init(alloc);
    defer gc.deinit();

    var m1 = PersistentMap.empty(alloc);
    const ka = Value.makeKeyword(try gc.internString("a"));
    const kb = Value.makeKeyword(try gc.internString("b"));
    const kc = Value.makeKeyword(try gc.internString("c"));
    m1 = try m1.assoc(ka, Value.makeInt(1), &gc);
    m1 = try m1.assoc(kb, Value.makeInt(2), &gc);

    const m2 = try m1.assoc(kc, Value.makeInt(3), &gc);
    try std.testing.expectEqual(@as(u32, 2), m1.count);
    try std.testing.expectEqual(@as(u32, 3), m2.count);
    try std.testing.expect(m1.get(kc, &gc) == null);
    try std.testing.expectEqual(@as(i48, 3), m2.get(kc, &gc).?.asInt());
}

test "persistent map: dissoc" {
    const alloc = std.heap.page_allocator;
    const gc_mod = @import("gc.zig");
    var gc = gc_mod.GC.init(alloc);
    defer gc.deinit();

    var m1 = PersistentMap.empty(alloc);
    const ka = Value.makeKeyword(try gc.internString("x"));
    const kb = Value.makeKeyword(try gc.internString("y"));
    m1 = try m1.assoc(ka, Value.makeInt(10), &gc);
    m1 = try m1.assoc(kb, Value.makeInt(20), &gc);

    const m2 = try m1.dissoc(ka, &gc);
    try std.testing.expectEqual(@as(u32, 2), m1.count);
    try std.testing.expectEqual(@as(u32, 1), m2.count);
    try std.testing.expect(m2.get(ka, &gc) == null);
    try std.testing.expectEqual(@as(i48, 20), m2.get(kb, &gc).?.asInt());
}

fn freeHamtNode(allocator: std.mem.Allocator, node: *HamtNode) void {
    switch (node.*) {
        .branch => |*branch| {
            for (branch.children.items) |child| {
                freeHamtNode(allocator, child);
            }
            branch.children.deinit(allocator);
        },
        .collision => |*coll| {
            coll.entries.deinit(allocator);
        },
        .leaf => {},
    }
    allocator.destroy(node);
}
