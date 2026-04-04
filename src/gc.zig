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
    string_index: std.StringHashMapUnmanaged(u48) = .{},
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
        self.string_index.deinit(self.allocator);
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
        if (self.string_index.get(s)) |id| return id;
        const copy = try self.allocator.dupe(u8, s);
        const id: u48 = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, copy);
        try self.string_index.put(self.allocator, copy, id);
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
                .bc_closure => .{ .bc_closure = .{ .def = undefined, .upvalues = &.{} } },
                .builtin_ref => .{ .builtin_ref = .{ .func = undefined, .name = "" } },
                .lazy_seq => .{ .lazy_seq = .{ .thunk = Value.makeNil() } },
                .partial_fn => .{ .partial_fn = .{ .func = Value.makeNil(), .bound_args = compat.emptyList(Value) } },
                .multimethod => .{ .multimethod = .{ .name = "", .dispatch_fn = Value.makeNil(), .methods = compat.emptyList(value.MethodEntry), .default_method = null } },
                .protocol => .{ .protocol = .{ .name = "", .method_names = compat.emptyList([]const u8), .impls = compat.emptyList(value.TypeImpl) } },
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

    /// Worklist-based mark: no recursion, bounded stack usage.
    /// Avoids stack overflow on deep object graphs and improves cache locality.
    fn mark(self: *GC, val: Value) void {
        if (!val.isObj()) return;
        const obj = val.asObj();
        if (obj.marked) return;

        // Use a worklist instead of recursion
        var worklist = compat.emptyList(*Obj);
        defer worklist.deinit(self.allocator);

        obj.marked = true;
        worklist.append(self.allocator, obj) catch return;

        while (worklist.items.len > 0) {
            const cur = worklist.items[worklist.items.len - 1];
            worklist.items.len -= 1; // pop

            switch (cur.kind) {
                .list => for (cur.data.list.items.items) |v| self.enqueueVal(v, &worklist),
                .vector => for (cur.data.vector.items.items) |v| self.enqueueVal(v, &worklist),
                .map => {
                    for (cur.data.map.keys.items) |v| self.enqueueVal(v, &worklist);
                    for (cur.data.map.vals.items) |v| self.enqueueVal(v, &worklist);
                },
                .set => for (cur.data.set.items.items) |v| self.enqueueVal(v, &worklist),
                .function => {
                    for (cur.data.function.params.items) |v| self.enqueueVal(v, &worklist);
                    for (cur.data.function.body.items) |v| self.enqueueVal(v, &worklist);
                    if (cur.data.function.env) |e| self.markEnv(e);
                },
                .macro_fn => {
                    for (cur.data.macro_fn.params.items) |v| self.enqueueVal(v, &worklist);
                    for (cur.data.macro_fn.body.items) |v| self.enqueueVal(v, &worklist);
                    if (cur.data.macro_fn.env) |e| self.markEnv(e);
                },
                .atom => self.enqueueVal(cur.data.atom.val, &worklist),
                .bc_closure => {}, // FuncDef + upvalues managed by allocator, not GC
                .lazy_seq => {
                    self.enqueueVal(cur.data.lazy_seq.thunk, &worklist);
                    if (cur.data.lazy_seq.cached) |c| self.enqueueVal(c, &worklist);
                },
                .partial_fn => {
                    self.enqueueVal(cur.data.partial_fn.func, &worklist);
                    for (cur.data.partial_fn.bound_args.items) |v| self.enqueueVal(v, &worklist);
                },
                .multimethod => {
                    self.enqueueVal(cur.data.multimethod.dispatch_fn, &worklist);
                    for (cur.data.multimethod.methods.items) |m| {
                        self.enqueueVal(m.dispatch_val, &worklist);
                        self.enqueueVal(m.impl_fn, &worklist);
                    }
                    if (cur.data.multimethod.default_method) |d| self.enqueueVal(d, &worklist);
                },
                .protocol => {
                    for (cur.data.protocol.impls.items) |impl| {
                        for (impl.methods.items) |m| {
                            self.enqueueVal(m.func, &worklist);
                        }
                    }
                },
            }
        }
    }

    fn enqueueVal(self: *const GC, val: Value, worklist: *std.ArrayListUnmanaged(*Obj)) void {
        if (!val.isObj()) return;
        const obj = val.asObj();
        if (obj.marked) return;
        obj.marked = true;
        worklist.append(self.allocator, obj) catch {};
    }

    fn markEnv(self: *GC, e: *Env) void {
        var cur = e;
        while (true) {
            if (cur.marked or cur.is_root) return;
            cur.marked = true;
            // Mark all values bound in this env
            var it = cur.bindings.valueIterator();
            while (it.next()) |v| {
                self.mark(v.*);
            }
            // Iterate parent chain (no recursion)
            cur = cur.parent orelse return;
        }
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
            .bc_closure => {
                if (obj.data.bc_closure.upvalues.len > 0) {
                    self.allocator.free(obj.data.bc_closure.upvalues);
                }
            },
            .builtin_ref => {},
            .lazy_seq => {},
            .partial_fn => {
                obj.data.partial_fn.bound_args.deinit(self.allocator);
            },
            .multimethod => {
                obj.data.multimethod.methods.deinit(self.allocator);
            },
            .protocol => {
                obj.data.protocol.method_names.deinit(self.allocator);
                for (obj.data.protocol.impls.items) |*impl| {
                    impl.methods.deinit(self.allocator);
                }
                obj.data.protocol.impls.deinit(self.allocator);
            },
        }
        self.allocator.destroy(obj);
        self.bytes_allocated -|= @sizeOf(Obj);
    }
};
