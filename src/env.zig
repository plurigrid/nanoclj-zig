const std = @import("std");
const Value = @import("value.zig").Value;

pub const Env = struct {
    parent: ?*Env,
    bindings: std.StringHashMap(Value),
    id_bindings: std.AutoHashMapUnmanaged(u48, Value) = .{},
    allocator: std.mem.Allocator,
    marked: bool = false,
    is_root: bool = false, // true for the global env (not GC-tracked)

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) Env {
        return .{
            .parent = parent,
            .bindings = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .marked = false,
            .is_root = false,
        };
    }

    pub fn deinit(self: *Env) void {
        self.bindings.deinit();
        self.id_bindings.deinit(self.allocator);
    }

    pub fn set(self: *Env, name: []const u8, val: Value) !void {
        try self.bindings.put(name, val);
    }

    /// Fast path: set by pre-interned symbol ID (integer key, no hashing strings)
    pub fn setById(self: *Env, id: u48, val: Value) !void {
        try self.id_bindings.put(self.allocator, id, val);
    }

    pub fn get(self: *const Env, name: []const u8) ?Value {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    /// Fast path: get by pre-interned symbol ID (no string hashing)
    pub fn getById(self: *const Env, id: u48) ?Value {
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
