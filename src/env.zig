const std = @import("std");
const Value = @import("value.zig").Value;

pub const Env = struct {
    parent: ?*Env,
    bindings: std.StringHashMap(Value),
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
    }

    pub fn set(self: *Env, name: []const u8, val: Value) !void {
        try self.bindings.put(name, val);
    }

    pub fn get(self: *const Env, name: []const u8) ?Value {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }

    pub fn createChild(self: *Env) !*Env {
        const child = try self.allocator.create(Env);
        child.* = Env.init(self.allocator, self);
        return child;
    }
};
