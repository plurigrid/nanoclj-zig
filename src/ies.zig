//! IES: Interaction Expression Signatures
//!
//! Inspired by Lux's session-typed closure interactions and causal's
//! ops-based dispatch. Maps Clojure function calls to typed interaction
//! protocols for debugging and verification.
//!
//! Key insight from Lux: closures carry session type metadata
//! (Send/Recv/Offer/Select/End) describing their interaction protocol.
//! Key insight from causal: operations form capability sets that can
//! be verified at resolution time.
//!
//! In nanoclj-zig, IES bridges these patterns through the trace ObjKind:
//! - Each function call can be recorded as a Send/Recv interaction
//! - The colorspace alpha modulates capability access (Lux's branded types)
//! - Protocol duality enables compile-time verification of call chains

const std = @import("std");
const Value = @import("value.zig").Value;
const GC = @import("gc.zig").GC;
const compat = @import("compat.zig");

/// Session type — describes the interaction protocol of a computation.
pub const SessionType = enum(u8) {
    send, // Sends a value, then continues
    recv, // Receives a value, then continues
    offer, // External choice (callee decides)
    select, // Internal choice (caller decides)
    end, // Protocol complete
};

/// A single interaction event in an execution trace.
pub const Interaction = struct {
    session_type: SessionType,
    site_name: u32, // interned string ID
    value: Value, // the value sent/received
    timestamp: u64, // monotonic counter
    log_prob: f64 = 0.0, // for probabilistic interactions

    pub fn isSend(self: Interaction) bool {
        return self.session_type == .send;
    }

    pub fn isRecv(self: Interaction) bool {
        return self.session_type == .recv;
    }
};

/// IES Trace — records a sequence of interactions for protocol verification.
/// Compatible with the trace ObjKind's parallel array structure.
pub const IESTrace = struct {
    interactions: std.ArrayListUnmanaged(Interaction),
    counter: u64 = 0,
    log_weight: f64 = 0.0,

    pub fn init() IESTrace {
        return .{
            .interactions = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *IESTrace, allocator: std.mem.Allocator) void {
        self.interactions.deinit(allocator);
    }

    /// Record a function call as a Send interaction (caller sends args).
    pub fn recordSend(self: *IESTrace, allocator: std.mem.Allocator, name_id: u32, val: Value) !void {
        self.counter += 1;
        try self.interactions.append(allocator, .{
            .session_type = .send,
            .site_name = name_id,
            .value = val,
            .timestamp = self.counter,
        });
    }

    /// Record a function return as a Recv interaction (caller receives result).
    pub fn recordRecv(self: *IESTrace, allocator: std.mem.Allocator, name_id: u32, val: Value, lp: f64) !void {
        self.counter += 1;
        self.log_weight += lp;
        try self.interactions.append(allocator, .{
            .session_type = .recv,
            .site_name = name_id,
            .value = val,
            .timestamp = self.counter,
            .log_prob = lp,
        });
    }

    /// Check if two traces are duals (every Send in one matches a Recv in other).
    pub fn isDual(self: *const IESTrace, other: *const IESTrace) bool {
        if (self.interactions.items.len != other.interactions.items.len) return false;
        for (self.interactions.items, other.interactions.items) |a, b| {
            const dual = switch (a.session_type) {
                .send => b.session_type == .recv,
                .recv => b.session_type == .send,
                .offer => b.session_type == .select,
                .select => b.session_type == .offer,
                .end => b.session_type == .end,
            };
            if (!dual) return false;
            if (a.site_name != b.site_name) return false;
        }
        return true;
    }

    /// Number of send interactions (arity proxy).
    pub fn sends(self: *const IESTrace) usize {
        var count: usize = 0;
        for (self.interactions.items) |i| {
            if (i.session_type == .send) count += 1;
        }
        return count;
    }

    /// Number of recv interactions.
    pub fn recvs(self: *const IESTrace) usize {
        var count: usize = 0;
        for (self.interactions.items) |i| {
            if (i.session_type == .recv) count += 1;
        }
        return count;
    }

    /// GF(3) conservation check: sum of trit values must be 0 mod 3.
    /// Send = 1, Recv = 2, End = 0 in GF(3).
    pub fn isConserved(self: *const IESTrace) bool {
        var trit_sum: u64 = 0;
        for (self.interactions.items) |i| {
            trit_sum += switch (i.session_type) {
                .send => 1,
                .recv => 2,
                .offer => 1,
                .select => 2,
                .end => 0,
            };
        }
        return (trit_sum % 3) == 0;
    }
};

/// Capability set — inspired by causal's ops-based backend dispatch.
/// Each colorspace can declare what operations it supports.
pub const CapabilitySet = struct {
    ops: u32 = 0, // bitfield of supported operations

    // Operation bits (matching causal's backend ops)
    pub const OP_READ: u32 = 1 << 0;
    pub const OP_WRITE: u32 = 1 << 1;
    pub const OP_EVAL: u32 = 1 << 2;
    pub const OP_COMPILE: u32 = 1 << 3;
    pub const OP_TRACE: u32 = 1 << 4;
    pub const OP_BLEND: u32 = 1 << 5;
    pub const OP_RESOLVE: u32 = 1 << 6;
    pub const OP_OBSERVE: u32 = 1 << 7; // probabilistic observation

    pub const ALL: u32 = 0xFF;

    pub fn has(self: CapabilitySet, op: u32) bool {
        return (self.ops & op) != 0;
    }

    pub fn grant(self: CapabilitySet, op: u32) CapabilitySet {
        return .{ .ops = self.ops | op };
    }

    pub fn revoke(self: CapabilitySet, op: u32) CapabilitySet {
        return .{ .ops = self.ops & ~op };
    }

    pub fn intersect(self: CapabilitySet, other: CapabilitySet) CapabilitySet {
        return .{ .ops = self.ops & other.ops };
    }

    pub fn count(self: CapabilitySet) u32 {
        return @popCount(self.ops);
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "IES: send/recv recording" {
    var trace = IESTrace.init();
    defer trace.deinit(std.testing.allocator);
    try trace.recordSend(std.testing.allocator, 0, Value.makeInt(42));
    try trace.recordRecv(std.testing.allocator, 0, Value.makeInt(43), -0.5);
    try std.testing.expectEqual(@as(usize, 2), trace.interactions.items.len);
    try std.testing.expectEqual(@as(usize, 1), trace.sends());
    try std.testing.expectEqual(@as(usize, 1), trace.recvs());
    try std.testing.expect(trace.log_weight == -0.5);
}

test "IES: duality check" {
    var t1 = IESTrace.init();
    defer t1.deinit(std.testing.allocator);
    var t2 = IESTrace.init();
    defer t2.deinit(std.testing.allocator);
    try t1.recordSend(std.testing.allocator, 0, Value.makeInt(1));
    try t1.recordRecv(std.testing.allocator, 1, Value.makeInt(2), 0);
    try t2.recordRecv(std.testing.allocator, 0, Value.makeInt(1), 0);
    try t2.recordSend(std.testing.allocator, 1, Value.makeInt(2));
    try std.testing.expect(t1.isDual(&t2));
}

test "IES: GF(3) conservation" {
    var trace = IESTrace.init();
    defer trace.deinit(std.testing.allocator);
    // send(1) + recv(2) + end(0) = 3 ≡ 0 mod 3 → conserved
    try trace.recordSend(std.testing.allocator, 0, Value.makeInt(1));
    try trace.recordRecv(std.testing.allocator, 0, Value.makeInt(1), 0);
    try trace.interactions.append(std.testing.allocator, .{
        .session_type = .end,
        .site_name = 0,
        .value = Value.makeNil(),
        .timestamp = 3,
    });
    try std.testing.expect(trace.isConserved());
}

test "IES: capability set" {
    const full = CapabilitySet{ .ops = CapabilitySet.ALL };
    const read_only = CapabilitySet{ .ops = CapabilitySet.OP_READ };
    try std.testing.expect(full.has(CapabilitySet.OP_READ));
    try std.testing.expect(full.has(CapabilitySet.OP_WRITE));
    try std.testing.expect(read_only.has(CapabilitySet.OP_READ));
    try std.testing.expect(!read_only.has(CapabilitySet.OP_WRITE));
    try std.testing.expectEqual(@as(u32, 1), read_only.count());
    try std.testing.expectEqual(@as(u32, 8), full.count());
    const narrowed = full.intersect(read_only);
    try std.testing.expectEqual(@as(u32, 1), narrowed.count());
}
