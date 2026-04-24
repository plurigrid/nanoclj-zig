//! TIER POLICY: Predicate-dispatched tier selection with hysteresis
//!
//! Three tiers, three colors (GF(3)):
//!   blue  (-1)  — tree-walk interpreter (transduction.evalBounded)
//!   red   (+1)  — bytecode VM (compiler.zig → bytecode.zig)
//!   green ( 0)  — incremental AOT (incr.zig → native Zig)
//!
//! Hysteresis prevents oscillation between tiers:
//!   promote_threshold  — invocations before considering promotion
//!   demote_threshold   — consecutive failures before demotion
//!
//! Inspired by HotSpot's Tier3DelayOn/Off, Futamura projections,
//! and SDF Ch.8 degeneracy (multiple implementation strategies).

const std = @import("std");
const Value = @import("value.zig").Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const peval = @import("peval.zig");

pub const Tier = enum(u2) {
    blue = 0, // tree-walk (always works)
    red = 1, // bytecode (faster, needs compilation)
    green = 2, // native (fastest, needs transpilability)

    pub fn trit(self: Tier) i8 {
        return switch (self) {
            .blue => -1,
            .red => 1,
            .green => 0,
        };
    }

    pub fn name(self: Tier) []const u8 {
        return switch (self) {
            .blue => "blue",
            .red => "red",
            .green => "green",
        };
    }

    pub fn ansiColor(self: Tier) []const u8 {
        return switch (self) {
            .blue => "\x1b[34m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
        };
    }
};

/// Per-expression profiling entry
const ProfileEntry = struct {
    invocations: u32 = 0,
    current_tier: Tier = .blue,
    /// Consecutive failures at the current promoted tier
    failures_at_tier: u16 = 0,
    /// Total fuel consumed across all invocations (for cost estimation)
    total_fuel_consumed: u64 = 0,
    /// Whether bytecode compilation succeeded
    bc_compilable: bool = false,
    /// Whether incr transpilation succeeded
    incr_transpilable: bool = false,
    /// Sticky: once we know it's NOT compilable, don't retry until reset
    bc_tried: bool = false,
    incr_tried: bool = false,
};

pub const TierPolicy = struct {
    /// Expression hash → profile entry
    profiles: std.AutoHashMap(u64, ProfileEntry),

    // Hysteresis thresholds (analogous to HotSpot's CompileThreshold)
    promote_to_red: u32 = 3, // invoke 3x before trying bytecode
    promote_to_green: u32 = 10, // invoke 10x before trying green
    demote_after_failures: u16 = 2, // 2 consecutive failures → demote

    pub fn init(allocator: std.mem.Allocator) TierPolicy {
        return .{
            .profiles = std.AutoHashMap(u64, ProfileEntry).init(allocator),
        };
    }

    pub fn deinit(self: *TierPolicy) void {
        self.profiles.deinit();
    }

    /// Hash an expression string for profiling lookup.
    /// We use the expression text as key (cheap, deterministic).
    pub fn exprHash(input: []const u8) u64 {
        return std.hash.Wyhash.hash(0, input);
    }

    /// Record an invocation and decide which tier to use.
    /// Returns the recommended tier. Caller should attempt that tier
    /// and call `recordResult` afterward.
    pub fn recommend(self: *TierPolicy, input: []const u8, gc: *GC, env: *const Env) !Tier {
        const h = exprHash(input);
        const gop = try self.profiles.getOrPut(h);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        const p = gop.value_ptr;
        p.invocations += 1;

        // If already at a tier that works, stay there (hysteresis: don't demote eagerly)
        if (p.current_tier == .green and p.failures_at_tier < self.demote_after_failures) return .green;
        if (p.current_tier == .red and p.failures_at_tier < self.demote_after_failures) {
            // But check if we should try promoting to green
            if (p.invocations >= self.promote_to_green and !p.incr_tried) {
                return .green; // tentative promotion
            }
            return .red;
        }

        // Blue tier: check for promotion
        if (p.invocations >= self.promote_to_green and !p.incr_tried) {
            // Try green first (skip red) if expression looks ground
            const reader_mod = @import("reader.zig");
            var reader = reader_mod.Reader.init(input, gc);
            if (reader.readForm()) |form| {
                if (peval.isGroundPublic(form, gc, env)) return .green;
            } else |_| {}
        }

        if (p.invocations >= self.promote_to_red and !p.bc_tried) {
            return .red; // tentative promotion to bytecode
        }

        return .blue;
    }

    /// Record the outcome of executing at a given tier.
    pub fn recordResult(self: *TierPolicy, input: []const u8, tier: Tier, success: bool, fuel_consumed: u64) void {
        const h = exprHash(input);
        const p = self.profiles.getPtr(h) orelse return;

        p.total_fuel_consumed += fuel_consumed;

        if (success) {
            p.current_tier = tier;
            p.failures_at_tier = 0;
            switch (tier) {
                .red => p.bc_compilable = true,
                .green => p.incr_transpilable = true,
                .blue => {},
            }
        } else {
            p.failures_at_tier += 1;
            switch (tier) {
                .red => p.bc_tried = true,
                .green => p.incr_tried = true,
                .blue => {},
            }
            // Demote on repeated failure
            if (p.failures_at_tier >= self.demote_after_failures) {
                p.current_tier = switch (tier) {
                    .green => .red,
                    .red => .blue,
                    .blue => .blue,
                };
                p.failures_at_tier = 0;
            }
        }
    }

    /// Get the current tier for an expression (without incrementing).
    pub fn currentTier(self: *const TierPolicy, input: []const u8) Tier {
        const h = exprHash(input);
        return if (self.profiles.get(h)) |p| p.current_tier else .blue;
    }

    /// Get profile stats for introspection.
    pub fn getProfile(self: *const TierPolicy, input: []const u8) ?ProfileEntry {
        return self.profiles.get(exprHash(input));
    }

    /// Reset all profiles (e.g., after environment changes).
    pub fn reset(self: *TierPolicy) void {
        self.profiles.clearRetainingCapacity();
    }

    /// Format a tier status line for REPL display.
    pub fn formatStatus(tier: Tier, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}[{s}]\x1b[0m ", .{ tier.ansiColor(), tier.name() }) catch "";
    }
};
