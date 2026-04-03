const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const Env = @import("env.zig").Env;
const compat = @import("compat.zig");

pub const GC = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayListUnmanaged(*Obj) = compat.emptyList(*Obj),
    roots: std.ArrayListUnmanaged(*Value) = compat.emptyList(*Value),
    strings: std.ArrayListUnmanaged([]const u8) = compat.emptyList([]const u8),
    envs: std.ArrayListUnmanaged(*Env) = compat.emptyList(*Env),
    bytes_allocated: usize = 0,
    next_gc: usize = 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GC) void {
        for (self.objects.items) |obj| {
            self.freeObj(obj);
        }
        self.objects.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
        for (self.envs.items) |e| {
            e.deinit();
            self.allocator.destroy(e);
        }
        self.envs.deinit(self.allocator);
    }

    /// Register a heap-allocated child Env so the GC can free it.
    pub fn trackEnv(self: *GC, e: *Env) !void {
        try self.envs.append(self.allocator, e);
        self.bytes_allocated += @sizeOf(Env);
    }

    pub fn internString(self: *GC, s: []const u8) !u48 {
        for (self.strings.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, s)) return @intCast(i);
        }
        const copy = try self.allocator.dupe(u8, s);
        const id: u48 = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, copy);
        return id;
    }

    pub fn getString(self: *GC, id: u48) []const u8 {
        return self.strings.items[@intCast(id)];
    }

    pub fn allocObj(self: *GC, kind: ObjKind) !*Obj {
        const obj = try self.allocator.create(Obj);
        obj.* = .{
            .kind = kind,
            .marked = false,
            .data = switch (kind) {
                .list => .{ .list = .{ .items = compat.emptyList(Value) } },
                .vector => .{ .vector = .{ .items = compat.emptyList(Value) } },
                .map => .{ .map = .{
                    .keys = compat.emptyList(Value),
                    .vals = compat.emptyList(Value),
                } },
                .set => .{ .set = .{ .items = compat.emptyList(Value) } },
                .function => .{ .function = .{
                    .params = compat.emptyList(Value),
                    .body = compat.emptyList(Value),
                    .env = null,
                } },
                .macro_fn => .{ .macro_fn = .{
                    .params = compat.emptyList(Value),
                    .body = compat.emptyList(Value),
                    .env = null,
                } },
                .atom => .{ .atom = .{ .val = Value.makeNil() } },
            },
        };
        try self.objects.append(self.allocator, obj);
        self.bytes_allocated += @sizeOf(Obj);
        return obj;
    }

    pub fn addRoot(self: *GC, root: *Value) !void {
        try self.roots.append(self.allocator, root);
    }

    pub fn collect(self: *GC) void {
        // Mark from roots
        for (self.roots.items) |root| {
            self.mark(root.*);
        }
        // Sweep objects
        var i: usize = 0;
        while (i < self.objects.items.len) {
            if (!self.objects.items[i].marked) {
                const obj = self.objects.items[i];
                _ = self.objects.swapRemove(i);
                self.freeObj(obj);
            } else {
                self.objects.items[i].marked = false;
                i += 1;
            }
        }
        // Sweep envs: free any env not marked and not root
        var j: usize = 0;
        while (j < self.envs.items.len) {
            const e = self.envs.items[j];
            if (!e.marked and !e.is_root) {
                _ = self.envs.swapRemove(j);
                e.deinit();
                self.allocator.destroy(e);
                self.bytes_allocated -|= @sizeOf(Env);
            } else {
                e.marked = false;
                j += 1;
            }
        }
    }

    fn mark(self: *GC, val: Value) void {
        if (!val.isObj()) return;
        const obj = val.asObj();
        if (obj.marked) return;
        obj.marked = true;
        switch (obj.kind) {
            .list => for (obj.data.list.items.items) |v| self.mark(v),
            .vector => for (obj.data.vector.items.items) |v| self.mark(v),
            .map => {
                for (obj.data.map.keys.items) |v| self.mark(v);
                for (obj.data.map.vals.items) |v| self.mark(v);
            },
            .set => for (obj.data.set.items.items) |v| self.mark(v),
            .function => {
                for (obj.data.function.params.items) |v| self.mark(v);
                for (obj.data.function.body.items) |v| self.mark(v);
                if (obj.data.function.env) |e| self.markEnv(e);
            },
            .macro_fn => {
                for (obj.data.macro_fn.params.items) |v| self.mark(v);
                for (obj.data.macro_fn.body.items) |v| self.mark(v);
                if (obj.data.macro_fn.env) |e| self.markEnv(e);
            },
            .atom => self.mark(obj.data.atom.val),
        }
    }

    fn markEnv(self: *GC, e: *Env) void {
        if (e.marked or e.is_root) return;
        e.marked = true;
        // Mark all values bound in this env
        var it = e.bindings.valueIterator();
        while (it.next()) |v| {
            self.mark(v.*);
        }
        // Trace parent chain
        if (e.parent) |p| self.markEnv(p);
    }

    fn freeObj(self: *GC, obj: *Obj) void {
        switch (obj.kind) {
            .list => obj.data.list.items.deinit(self.allocator),
            .vector => obj.data.vector.items.deinit(self.allocator),
            .map => {
                obj.data.map.keys.deinit(self.allocator);
                obj.data.map.vals.deinit(self.allocator);
            },
            .set => obj.data.set.items.deinit(self.allocator),
            .function => {
                obj.data.function.params.deinit(self.allocator);
                obj.data.function.body.deinit(self.allocator);
            },
            .macro_fn => {
                obj.data.macro_fn.params.deinit(self.allocator);
                obj.data.macro_fn.body.deinit(self.allocator);
            },
            .atom => {},
        }
        self.allocator.destroy(obj);
        self.bytes_allocated -|= @sizeOf(Obj);
    }
};
