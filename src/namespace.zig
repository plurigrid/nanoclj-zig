const std = @import("std");
const Value = @import("value.zig").Value;
const Env = @import("env.zig").Env;
const GC = @import("gc.zig").GC;

/// Namespace registry. Each namespace is a named root Env.
/// "clojure.core" is the default; user namespaces inherit from it.
pub const NamespaceRegistry = struct {
    namespaces: std.StringHashMap(*Env),
    current: []const u8,
    allocator: std.mem.Allocator,
    core_env: *Env, // the root env with all builtins

    pub fn init(allocator: std.mem.Allocator, core_env: *Env) !NamespaceRegistry {
        var reg = NamespaceRegistry{
            .namespaces = std.StringHashMap(*Env).init(allocator),
            .current = undefined,
            .allocator = allocator,
            .core_env = core_env,
        };
        // Register clojure.core as the root (dupe key so deinit can free all)
        const core_key = try allocator.dupe(u8, "clojure.core");
        try reg.namespaces.put(core_key, core_env);
        // Create default "user" namespace
        const user_key = try allocator.dupe(u8, "user");
        const user_env = try allocator.create(Env);
        user_env.* = Env.init(allocator, core_env);
        user_env.is_root = true;
        try reg.namespaces.put(user_key, user_env);
        reg.current = user_key;
        return reg;
    }

    pub fn deinit(self: *NamespaceRegistry) void {
        var it = self.namespaces.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            if (e != self.core_env) {
                e.deinit();
                self.allocator.destroy(e);
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.namespaces.deinit();
    }

    /// Switch to namespace, creating it if needed.
    pub fn switchTo(self: *NamespaceRegistry, name: []const u8) !*Env {
        if (self.namespaces.getKeyPtr(name)) |key_ptr| {
            self.current = key_ptr.*;
            return self.namespaces.get(name).?;
        }
        // Create new namespace with clojure.core as parent
        const duped_name = try self.allocator.dupe(u8, name);
        const new_env = try self.allocator.create(Env);
        new_env.* = Env.init(self.allocator, self.core_env);
        new_env.is_root = true;
        try self.namespaces.put(duped_name, new_env);
        self.current = duped_name;
        return new_env;
    }

    /// Get a namespace env by name.
    pub fn getNamespace(self: *NamespaceRegistry, name: []const u8) ?*Env {
        return self.namespaces.get(name);
    }

    /// Get current namespace env.
    pub fn currentEnv(self: *NamespaceRegistry) *Env {
        return self.namespaces.get(self.current) orelse self.core_env;
    }

    /// Get current namespace name.
    pub fn currentName(self: *const NamespaceRegistry) []const u8 {
        return self.current;
    }

    /// Refer all public vars from src namespace into dst namespace.
    pub fn refer(self: *NamespaceRegistry, dst_name: []const u8, src_name: []const u8) !void {
        const src = self.namespaces.get(src_name) orelse return;
        const dst = self.namespaces.get(dst_name) orelse return;
        var it = src.bindings.iterator();
        while (it.next()) |entry| {
            dst.set(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    /// Alias: make all vars from src accessible as alias/name in dst.
    /// Since we don't have qualified symbols yet, this copies bindings
    /// with prefixed names: "alias/original-name".
    pub fn addAlias(self: *NamespaceRegistry, dst_name: []const u8, src_name: []const u8, alias_prefix: []const u8) !void {
        const src = self.namespaces.get(src_name) orelse return;
        const dst = self.namespaces.get(dst_name) orelse return;
        var it = src.bindings.iterator();
        while (it.next()) |entry| {
            var buf: [256]u8 = undefined;
            const qualified = std.fmt.bufPrint(&buf, "{s}/{s}", .{ alias_prefix, entry.key_ptr.* }) catch continue;
            const duped = try self.allocator.dupe(u8, qualified);
            dst.set(duped, entry.value_ptr.*) catch {};
        }
    }
};

test "namespace basic" {
    const allocator = std.testing.allocator;
    var core_env = Env.init(allocator, null);
    core_env.is_root = true;
    defer core_env.deinit();

    try core_env.set("inc", Value.makeInt(1)); // dummy

    var reg = try NamespaceRegistry.init(allocator, &core_env);
    defer reg.deinit();

    try std.testing.expectEqualStrings("user", reg.currentName());

    // Switch to new ns
    const my_env = try reg.switchTo("my.app");
    try std.testing.expectEqualStrings("my.app", reg.currentName());

    // New ns inherits from core
    const inc_val = my_env.get("inc");
    try std.testing.expect(inc_val != null);

    // Set a var in my.app
    try my_env.set("x", Value.makeInt(42));
    const x = my_env.get("x");
    try std.testing.expect(x != null);
    try std.testing.expectEqual(@as(i48, 42), x.?.asInt());

    // user ns doesn't have x
    const user_env = reg.getNamespace("user").?;
    try std.testing.expect(user_env.get("x") == null);
}
