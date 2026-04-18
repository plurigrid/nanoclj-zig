const std = @import("std");
const Value = @import("value.zig").Value;
const Env = @import("env.zig").Env;
const GC = @import("gc.zig").GC;
const compat = @import("compat.zig");

/// OKLAB color coordinate — perceptually uniform color space.
/// L ∈ [0,1] (lightness), a ∈ [-0.5,0.5] (green-red), b ∈ [-0.5,0.5] (blue-yellow).
/// Alpha ∈ [0,1] controls binding opacity (1 = fully visible, 0 = private).
pub const Color = struct {
    L: f32 = 0.5,
    a: f32 = 0.0,
    b: f32 = 0.0,
    alpha: f32 = 1.0,

    pub fn distance(self: Color, other: Color) f32 {
        const dL = self.L - other.L;
        const da = self.a - other.a;
        const db = self.b - other.b;
        return @sqrt(dL * dL + da * da + db * db);
    }

    /// Perceptual blend: linear interpolation in OKLAB.
    pub fn blend(self: Color, other: Color, t: f32) Color {
        return .{
            .L = self.L + (other.L - self.L) * t,
            .a = self.a + (other.a - self.a) * t,
            .b = self.b + (other.b - self.b) * t,
            .alpha = self.alpha + (other.alpha - self.alpha) * t,
        };
    }

    /// Perceptual complement: rotate 180° in the a-b chroma plane, invert lightness.
    pub fn complement(self: Color) Color {
        return .{
            .L = 1.0 - self.L,
            .a = -self.a,
            .b = -self.b,
            .alpha = self.alpha,
        };
    }

    /// Analogous: rotate ±30° in a-b plane.
    pub fn analogous(self: Color, angle_deg: f32) Color {
        const rad = angle_deg * std.math.pi / 180.0;
        const cos_r = @cos(rad);
        const sin_r = @sin(rad);
        return .{
            .L = self.L,
            .a = self.a * cos_r - self.b * sin_r,
            .b = self.a * sin_r + self.b * cos_r,
            .alpha = self.alpha,
        };
    }

    /// Triadic: three colors 120° apart.
    pub fn triadic(self: Color) [3]Color {
        return .{ self, self.analogous(120.0), self.analogous(240.0) };
    }

    // Plastic constant ρ ≈ 1.3247 (root of x³ = x + 1, generates GF(27))
    const PLASTIC_ANGLE: f32 = 205.1442;
    const GOLDEN_ANGLE: f32 = 137.5078;

    /// Plastic rotation: rotate by ρ²-derived angle in the a-b chroma plane.
    /// Use for interaction-net / branching structures where depth × arity
    /// needs 2D dispersion (golden = depth, plastic = branch slot).
    pub fn plasticRotate(self: Color, depth: u32, branch: u8) Color {
        const angle = @as(f32, @floatFromInt(depth)) * GOLDEN_ANGLE +
            @as(f32, @floatFromInt(branch)) * PLASTIC_ANGLE;
        return self.analogous(angle);
    }

    /// Generate n colors via plastic spiral (optimal for tree structures).
    pub fn plasticSpiral(self: Color, n: usize, buf: []Color) []Color {
        const count = @min(n, buf.len);
        for (0..count) |i| {
            buf[i] = self.analogous(@as(f32, @floatFromInt(i)) * PLASTIC_ANGLE);
        }
        return buf[0..count];
    }

    /// Chroma (saturation magnitude in a-b plane).
    pub fn chroma(self: Color) f32 {
        return @sqrt(self.a * self.a + self.b * self.b);
    }

    /// Hue angle in degrees [0, 360).
    pub fn hue(self: Color) f32 {
        const h = std.math.atan2(self.b, self.a) * 180.0 / std.math.pi;
        return if (h < 0) h + 360.0 else h;
    }

    pub fn eql(self: Color, other: Color) bool {
        return self.L == other.L and self.a == other.a and self.b == other.b and self.alpha == other.alpha;
    }

    /// Convert sRGB [0,255] to OKLAB. Zero-copy bridge from substrate.Color.
    pub fn fromSRGB(r: u8, g: u8, b: u8) Color {
        // sRGB → linear
        const rl = srgbToLinear(@as(f32, @floatFromInt(r)) / 255.0);
        const gl = srgbToLinear(@as(f32, @floatFromInt(g)) / 255.0);
        const bl = srgbToLinear(@as(f32, @floatFromInt(b)) / 255.0);
        // Linear RGB → LMS (via Oklab M1 matrix)
        const l_ = 0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl;
        const m_ = 0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl;
        const s_ = 0.0883024619 * rl + 0.2220049368 * gl + 0.6696926014 * bl;
        // Cube root
        const l_cr = std.math.cbrt(l_);
        const m_cr = std.math.cbrt(m_);
        const s_cr = std.math.cbrt(s_);
        // LMS → Lab (via Oklab M2 matrix)
        return .{
            .L = 0.2104542553 * l_cr + 0.7936177850 * m_cr - 0.0040720468 * s_cr,
            .a = 1.9779984951 * l_cr - 2.4285922050 * m_cr + 0.4505937099 * s_cr,
            .b = 0.0259040371 * l_cr + 0.7827717662 * m_cr - 0.8086757660 * s_cr,
            .alpha = 1.0,
        };
    }

    fn srgbToLinear(v: f32) f32 {
        return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }

    /// Convert OKLAB back to sRGB [0,255].
    pub fn toSRGB(self: Color) [3]u8 {
        // Lab → LMS (inverse M2)
        const l_cr = self.L + 0.3963377774 * self.a + 0.2158037573 * self.b;
        const m_cr = self.L - 0.1055613458 * self.a - 0.0638541728 * self.b;
        const s_cr = self.L - 0.0894841775 * self.a - 1.2914855480 * self.b;
        // Cube
        const l_ = l_cr * l_cr * l_cr;
        const m_ = m_cr * m_cr * m_cr;
        const s_ = s_cr * s_cr * s_cr;
        // LMS → linear RGB (inverse M1)
        const rl = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_;
        const gl = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_;
        const bl = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_;
        return .{
            linearToSrgb(rl),
            linearToSrgb(gl),
            linearToSrgb(bl),
        };
    }

    fn linearToSrgb(v: f32) u8 {
        const clamped = @max(0.0, @min(1.0, v));
        const s = if (clamped <= 0.0031308)
            clamped * 12.92
        else
            1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
        return @intFromFloat(@round(s * 255.0));
    }
};

/// Named color presets — the "color atlas".
/// Each maps a human-readable name to an OKLAB coordinate.
pub const atlas = struct {
    // Clojure-legacy mappings
    pub const core = Color{ .L = 1.0, .a = 0.0, .b = 0.0, .alpha = 1.0 }; // pure white = universal
    pub const user = Color{ .L = 0.7, .a = 0.0, .b = 0.0, .alpha = 1.0 }; // neutral gray
    // Semantic colors
    pub const crimson = Color{ .L = 0.5, .a = 0.35, .b = 0.1 };
    pub const cerulean = Color{ .L = 0.6, .a = -0.1, .b = -0.25 };
    pub const viridian = Color{ .L = 0.55, .a = -0.25, .b = 0.1 };
    pub const amber = Color{ .L = 0.75, .a = 0.05, .b = 0.3 };
    pub const indigo = Color{ .L = 0.35, .a = 0.1, .b = -0.35 };
    pub const obsidian = Color{ .L = 0.1, .a = 0.0, .b = 0.0, .alpha = 0.5 }; // dark, semi-private

    pub fn lookup(name: []const u8) ?Color {
        if (std.mem.eql(u8, name, "clojure.core")) return core;
        if (std.mem.eql(u8, name, "user")) return user;
        if (std.mem.eql(u8, name, "crimson")) return crimson;
        if (std.mem.eql(u8, name, "cerulean")) return cerulean;
        if (std.mem.eql(u8, name, "viridian")) return viridian;
        if (std.mem.eql(u8, name, "amber")) return amber;
        if (std.mem.eql(u8, name, "indigo")) return indigo;
        if (std.mem.eql(u8, name, "obsidian")) return obsidian;
        return null;
    }
};

/// A colorspace: a point in OKLAB with an associated environment of bindings.
/// Resolution semantics: when looking up a binding, we query all colorspaces
/// within a perceptual radius and weight by inverse distance.
pub const Colorspace = struct {
    color: Color,
    name: []const u8,
    env: *Env,
};

/// The colorspace registry — replaces NamespaceRegistry.
/// Maintains a set of named colorspaces and a "current focus" color.
/// Binding resolution walks the manifold.
pub const ColorspaceRegistry = struct {
    spaces: std.ArrayListUnmanaged(Colorspace),
    focus: Color, // current position on the manifold
    focus_name: []const u8,
    allocator: std.mem.Allocator,
    core_env: *Env,
    /// Resolution radius: bindings from colorspaces within this distance are visible.
    /// 0.0 = only exact match, 1.0 = everything visible.
    radius: f32 = 0.15,

    pub fn init(allocator: std.mem.Allocator, core_env: *Env) !ColorspaceRegistry {
        var reg = ColorspaceRegistry{
            .spaces = compat.emptyList(Colorspace),
            .focus = atlas.user,
            .focus_name = "user",
            .allocator = allocator,
            .core_env = core_env,
            .radius = 0.15,
        };
        // Register clojure.core (white = universal, always within radius via special handling)
        try reg.spaces.append(allocator, .{
            .color = atlas.core,
            .name = "clojure.core",
            .env = core_env,
        });
        // Register user (default focus)
        const user_env = try allocator.create(Env);
        user_env.* = Env.init(allocator, core_env);
        user_env.is_root = true;
        try reg.spaces.append(allocator, .{
            .color = atlas.user,
            .name = "user",
            .env = user_env,
        });
        return reg;
    }

    pub fn deinit(self: *ColorspaceRegistry) void {
        for (self.spaces.items) |sp| {
            if (sp.env != self.core_env) {
                var e = sp.env;
                e.deinit();
                self.allocator.destroy(e);
            }
        }
        self.spaces.deinit(self.allocator);
    }

    /// Move focus to a named or coordinate-specified colorspace.
    /// If the name matches an atlas preset, use its color.
    /// If the colorspace doesn't exist, create it.
    pub fn focus_on(self: *ColorspaceRegistry, name: []const u8) !*Env {
        // Check existing
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, name)) {
                self.focus = sp.color;
                self.focus_name = sp.name;
                return sp.env;
            }
        }
        // Create new with atlas color or derived from name hash
        const color = atlas.lookup(name) orelse nameToColor(name);
        const duped = try self.allocator.dupe(u8, name);
        const env = try self.allocator.create(Env);
        env.* = Env.init(self.allocator, self.core_env);
        env.is_root = true;
        try self.spaces.append(self.allocator, .{ .color = color, .name = duped, .env = env });
        self.focus = color;
        self.focus_name = duped;
        return env;
    }

    /// Move focus to an explicit OKLAB coordinate.
    pub fn focus_at(self: *ColorspaceRegistry, color: Color, name: []const u8) !*Env {
        for (self.spaces.items) |sp| {
            if (sp.color.eql(color)) {
                self.focus = sp.color;
                self.focus_name = sp.name;
                return sp.env;
            }
        }
        const duped = try self.allocator.dupe(u8, name);
        const env = try self.allocator.create(Env);
        env.* = Env.init(self.allocator, self.core_env);
        env.is_root = true;
        try self.spaces.append(self.allocator, .{ .color = color, .name = duped, .env = env });
        self.focus = color;
        self.focus_name = duped;
        return env;
    }

    /// Resolve a binding by walking the color manifold.
    /// Returns the value from the nearest colorspace that has it,
    /// weighted by inverse perceptual distance.
    /// Core (white) is always checked as fallback.
    pub fn resolve(self: *const ColorspaceRegistry, name: []const u8) ?Value {
        // 1. Check focused colorspace first (distance = 0)
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, self.focus_name)) {
                if (sp.env.get(name)) |val| return val;
            }
        }
        // 2. Walk nearby colorspaces within radius, pick nearest match
        var best_val: ?Value = null;
        var best_dist: f32 = std.math.inf(f32);
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, self.focus_name)) continue;
            const d = self.focus.distance(sp.color);
            // Alpha modulates visibility: effective distance = d / alpha
            const effective_d = if (sp.color.alpha > 0.001) d / sp.color.alpha else std.math.inf(f32);
            if (effective_d <= self.radius and effective_d < best_dist) {
                if (sp.env.get(name)) |val| {
                    best_val = val;
                    best_dist = effective_d;
                }
            }
        }
        if (best_val) |v| return v;
        // 3. Fallback to core (always accessible)
        return self.core_env.get(name);
    }

    /// Blend two colorspaces into a new one.
    /// The new colorspace inherits bindings from both, weighted by t.
    /// t=0 → all from cs1, t=1 → all from cs2, t=0.5 → merge (cs2 wins conflicts).
    pub fn blend(self: *ColorspaceRegistry, name1: []const u8, name2: []const u8, t: f32, result_name: []const u8) !*Env {
        var cs1: ?Colorspace = null;
        var cs2: ?Colorspace = null;
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, name1)) cs1 = sp;
            if (std.mem.eql(u8, sp.name, name2)) cs2 = sp;
        }
        const s1 = cs1 orelse return error.OutOfMemory; // not found
        const s2 = cs2 orelse return error.OutOfMemory;
        const blended_color = s1.color.blend(s2.color, t);
        const env = try self.allocator.create(Env);
        env.* = Env.init(self.allocator, self.core_env);
        env.is_root = true;
        // Copy bindings from cs1
        var it1 = s1.env.bindings.iterator();
        while (it1.next()) |entry| {
            env.set(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        // Overlay bindings from cs2 (wins on conflict when t > 0.5,
        // but for simplicity we always overlay — the blend is in the color, not the bindings)
        if (t > 0.0) {
            var it2 = s2.env.bindings.iterator();
            while (it2.next()) |entry| {
                env.set(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }
        const duped = try self.allocator.dupe(u8, result_name);
        try self.spaces.append(self.allocator, .{ .color = blended_color, .name = duped, .env = env });
        return env;
    }

    /// Get current focus env.
    pub fn currentEnv(self: *ColorspaceRegistry) *Env {
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, self.focus_name)) return sp.env;
        }
        return self.core_env;
    }

    pub fn currentName(self: *const ColorspaceRegistry) []const u8 {
        return self.focus_name;
    }

    pub fn currentColor(self: *const ColorspaceRegistry) Color {
        return self.focus;
    }

    pub fn getSpace(self: *const ColorspaceRegistry, name: []const u8) ?Colorspace {
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, name)) return sp;
        }
        return null;
    }

    // ========================================================================
    // LEGACY NAMESPACE ADAPTER
    // ========================================================================
    // These methods provide backward-compatible ns/in-ns/require/refer semantics
    // by mapping namespace names to colorspace coordinates via the atlas.

    /// Legacy: (ns name) → focus_on(name)
    pub fn switchTo(self: *ColorspaceRegistry, name: []const u8) !*Env {
        return self.focus_on(name);
    }

    /// Legacy: (require [ns :as alias]) → focus_on + alias bindings
    pub fn referAll(self: *ColorspaceRegistry, dst_name: []const u8, src_name: []const u8) !void {
        var src_env: ?*Env = null;
        var dst_env: ?*Env = null;
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, src_name)) src_env = sp.env;
            if (std.mem.eql(u8, sp.name, dst_name)) dst_env = sp.env;
        }
        const src = src_env orelse return;
        const dst = dst_env orelse return;
        var it = src.bindings.iterator();
        while (it.next()) |entry| {
            dst.set(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    /// Legacy: alias with prefix
    pub fn addAlias(self: *ColorspaceRegistry, dst_name: []const u8, src_name: []const u8, alias_prefix: []const u8) !void {
        var src_env: ?*Env = null;
        var dst_env: ?*Env = null;
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, src_name)) src_env = sp.env;
            if (std.mem.eql(u8, sp.name, dst_name)) dst_env = sp.env;
        }
        const src = src_env orelse return;
        const dst = dst_env orelse return;
        var it = src.bindings.iterator();
        while (it.next()) |entry| {
            var buf: [256]u8 = undefined;
            const qualified = std.fmt.bufPrint(&buf, "{s}/{s}", .{ alias_prefix, entry.key_ptr.* }) catch continue;
            const duped = self.allocator.dupe(u8, qualified) catch continue;
            dst.set(duped, entry.value_ptr.*) catch {};
        }
    }

    /// Legacy: get namespace by name
    pub fn getNamespace(self: *ColorspaceRegistry, name: []const u8) ?*Env {
        for (self.spaces.items) |sp| {
            if (std.mem.eql(u8, sp.name, name)) return sp.env;
        }
        return null;
    }
};

/// Deterministic color from an arbitrary name string.
/// Hash the name and distribute across the OKLAB gamut.
fn nameToColor(name: []const u8) Color {
    const h = std.hash.Wyhash.hash(0, name);
    const hue_rad = @as(f32, @floatFromInt(h & 0xFFFF)) / 65536.0 * 2.0 * std.math.pi;
    const L = 0.3 + @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0 * 0.5; // 0.3..0.8
    const chroma_val: f32 = 0.1 + @as(f32, @floatFromInt((h >> 24) & 0xFF)) / 255.0 * 0.2; // 0.1..0.3
    return .{
        .L = L,
        .a = @cos(hue_rad) * chroma_val,
        .b = @sin(hue_rad) * chroma_val,
        .alpha = 1.0,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "color: distance and blend" {
    const c1 = Color{ .L = 0.5, .a = 0.0, .b = 0.0 };
    const c2 = Color{ .L = 1.0, .a = 0.0, .b = 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c1.distance(c2), 0.001);

    const mid = c1.blend(c2, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), mid.L, 0.001);
}

test "color: complement" {
    const c = Color{ .L = 0.3, .a = 0.2, .b = -0.1 };
    const comp = c.complement();
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), comp.L, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.2), comp.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), comp.b, 0.001);
}

test "color: nameToColor determinism" {
    const c1 = nameToColor("my.app");
    const c2 = nameToColor("my.app");
    try std.testing.expect(c1.eql(c2));
    const c3 = nameToColor("other.app");
    try std.testing.expect(!c1.eql(c3));
}

test "colorspace: focus and resolve" {
    const alloc = std.heap.page_allocator;
    var core_env = Env.init(alloc, null);
    core_env.is_root = true;
    try core_env.set("inc", Value.makeInt(1));

    var reg = try ColorspaceRegistry.init(alloc, &core_env);
    defer reg.deinit();

    // Default focus = user
    try std.testing.expectEqualStrings("user", reg.currentName());

    // Core bindings resolve from anywhere
    try std.testing.expectEqual(@as(i48, 1), reg.resolve("inc").?.asInt());

    // Switch to crimson
    const crim_env = try reg.focus_on("crimson");
    try crim_env.set("fire", Value.makeInt(42));
    try std.testing.expectEqualStrings("crimson", reg.currentName());
    try std.testing.expectEqual(@as(i48, 42), reg.resolve("fire").?.asInt());

    // Switch away — fire no longer reachable (crimson is far from user)
    _ = try reg.focus_on("user");
    try std.testing.expect(reg.resolve("fire") == null);

    // But core bindings still resolve
    try std.testing.expectEqual(@as(i48, 1), reg.resolve("inc").?.asInt());
}

test "colorspace: blend creates merged space" {
    const alloc = std.heap.page_allocator;
    var core_env = Env.init(alloc, null);
    core_env.is_root = true;

    var reg = try ColorspaceRegistry.init(alloc, &core_env);
    defer reg.deinit();

    const e1 = try reg.focus_on("crimson");
    try e1.set("x", Value.makeInt(10));
    const e2 = try reg.focus_on("cerulean");
    try e2.set("y", Value.makeInt(20));

    const blended = try reg.blend("crimson", "cerulean", 0.5, "magenta");
    try std.testing.expectEqual(@as(i48, 10), blended.get("x").?.asInt());
    try std.testing.expectEqual(@as(i48, 20), blended.get("y").?.asInt());
}

test "colorspace: legacy adapter" {
    const alloc = std.heap.page_allocator;
    var core_env = Env.init(alloc, null);
    core_env.is_root = true;
    try core_env.set("inc", Value.makeInt(1));

    var reg = try ColorspaceRegistry.init(alloc, &core_env);
    defer reg.deinit();

    // switchTo = legacy ns
    const my_env = try reg.switchTo("my.lib");
    try my_env.set("foo", Value.makeInt(99));

    // getNamespace = legacy lookup
    const found = reg.getNamespace("my.lib");
    try std.testing.expect(found != null);

    // Core still accessible
    try std.testing.expectEqual(@as(i48, 1), reg.resolve("inc").?.asInt());
}
