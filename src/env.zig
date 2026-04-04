const std = @import("std");
const Value = @import("value.zig").Value;

pub const Env = struct {
    parent: ?*Env,
    bindings: std.StringHashMap(Value),
    id_bindings: std.AutoHashMapUnmanaged(u48, Value) = .{},
    allocator: std.mem.Allocator,
    marked: bool = false,
    is_root: bool = false, // true for the global env (not GC-tracked)
    // Small-env fast path: array-backed bindings for ≤8 params (no heap alloc)
    small_ids: [8]u48 = undefined,
    small_vals: [8]Value = undefined,
    small_len: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) Env {
        return .{
            .parent = parent,
            .bindings = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .marked = false,
            .is_root = false,
        };
    }

    /// Lightweight init: no hash maps allocated, only small arrays used.
    /// Call deinitSmall() instead of deinit() when done.
    pub fn initSmall(parent: ?*Env) Env {
        // Use undefined allocator — hash maps won't be touched
        return .{
            .parent = parent,
            .bindings = std.StringHashMap(Value).init(std.heap.page_allocator),
            .allocator = std.heap.page_allocator,
            .marked = false,
            .is_root = false,
        };
    }

    pub fn deinit(self: *Env) void {
        self.bindings.deinit();
        self.id_bindings.deinit(self.allocator);
    }

    /// Lightweight deinit for small-env mode (no hash maps to free)
    pub fn deinitSmall(self: *Env) void {
        _ = self;
        // Nothing to free — small arrays are stack-allocated
    }

    pub fn set(self: *Env, name: []const u8, val: Value) !void {
        try self.bindings.put(name, val);
    }

    /// Fast path: set by pre-interned symbol ID (integer key, no hashing strings)
    pub fn setById(self: *Env, id: u48, val: Value) !void {
        try self.id_bindings.put(self.allocator, id, val);
    }

    /// Set into small array (no heap alloc). For use with initSmall().
    pub fn setSmall(self: *Env, id: u48, val: Value) void {
        if (self.small_len < 8) {
            self.small_ids[self.small_len] = id;
            self.small_vals[self.small_len] = val;
            self.small_len += 1;
        }
    }

    pub fn get(self: *const Env, name: []const u8) ?Value {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    /// Fast path: get by pre-interned symbol ID (no string hashing)
    pub fn getById(self: *const Env, id: u48) ?Value {
        // Check small array first (hottest path)
        for (self.small_ids[0..self.small_len], self.small_vals[0..self.small_len]) |sid, val| {
            if (sid == id) return val;
        }
        if (self.id_bindings.get(id)) |v| return v;
        if (self.parent) |p| return p.getById(id);
        return null;
    }

    pub fn createChild(self: *Env) !*Env {
        const child = try self.allocator.create(Env);
        child.* = Env.init(self.allocator, self);
        return child;
    }

    /// Iterator over bindings (for peval env walking)
    pub fn iterator(self: *Env) std.StringHashMap(Value).Iterator {
        return self.bindings.iterator();
    }
};

/// Stack-allocated lightweight env for non-variadic calls with ≤8 params.
/// No heap allocation, no hash maps — just a fixed array of (id, value) pairs.
/// Lookup is O(n) but n≤8, which is faster than hash map init/deinit overhead.
pub const SmallEnv = struct {
    ids: [8]u48 = undefined,
    vals: [8]Value = undefined,
    len: u8 = 0,
    parent: ?*Env,

    pub fn init(parent: ?*Env) SmallEnv {
        return .{ .parent = parent };
    }

    pub fn set(self: *SmallEnv, id: u48, val: Value) void {
        if (self.len < 8) {
            self.ids[self.len] = id;
            self.vals[self.len] = val;
            self.len += 1;
        }
    }

    pub fn getById(self: *const SmallEnv, id: u48) ?Value {
        for (self.ids[0..self.len], self.vals[0..self.len]) |sid, val| {
            if (sid == id) return val;
        }
        if (self.parent) |p| return p.getById(id);
        return null;
    }

    pub fn get(self: *const SmallEnv, name: []const u8) ?Value {
        // SmallEnv doesn't store strings — fall through to parent
        _ = self;
        _ = name;
        return null; // caller should use getById
    }
};
