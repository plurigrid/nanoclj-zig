//! CSP channels for nanoclj-zig (core.async-style)
//!
//! Builtins:
//!   (chan)            → unbuffered channel
//!   (chan n)          → buffered channel with capacity n
//!   (chan! ch val)    → put val onto channel, returns val (blocks if full)
//!   (<! ch)           → take from channel (blocks if empty)
//!   (close! ch)       → close channel, no more puts allowed
//!   (closed? ch)      → true if channel is closed
//!   (chan? x)          → true if x is a channel
//!   (chan-count ch)    → number of items currently buffered
//!   (offer! ch val)    → non-blocking put: true if placed, false if full/closed
//!   (poll! ch)         → non-blocking take: value if available, nil if empty
//!
//! Channels are synchronous in single-threaded nanoclj: put into a buffered
//! channel succeeds immediately if capacity allows; unbuffered channels require
//! a pending taker. In fuel-bounded mode, blocking = fuel exhaustion.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const compat = @import("compat.zig");

/// Channel data stored in ObjData.channel
pub const ChannelData = struct {
    buf: std.ArrayListUnmanaged(Value) = compat.emptyList(Value),
    capacity: u32 = 0, // 0 = unbuffered (rendezvous)
    closed: bool = false,
    /// Pending puts waiting for a taker (unbuffered or full-buffer)
    pending_puts: std.ArrayListUnmanaged(Value) = compat.emptyList(Value),

    pub fn buffered(self: *const ChannelData) bool {
        return self.capacity > 0;
    }

    /// Try to put a value. Returns true if accepted.
    pub fn tryPut(self: *ChannelData, allocator: std.mem.Allocator, val: Value) !bool {
        if (self.closed) return false;
        if (self.capacity == 0) {
            // Unbuffered: only succeeds if there's a pending take (handled externally)
            // For single-threaded: buffer one item as rendezvous slot
            if (self.buf.items.len == 0) {
                try self.buf.append(allocator, val);
                return true;
            }
            return false;
        }
        if (self.buf.items.len < self.capacity) {
            try self.buf.append(allocator, val);
            return true;
        }
        return false;
    }

    /// Try to take a value. Returns null if empty.
    pub fn tryTake(self: *ChannelData) ?Value {
        if (self.buf.items.len > 0) {
            // FIFO: remove from front
            const val = self.buf.items[0];
            // Shift remaining (small buffers, this is fine)
            if (self.buf.items.len > 1) {
                std.mem.copyForwards(Value, self.buf.items[0 .. self.buf.items.len - 1], self.buf.items[1..self.buf.items.len]);
            }
            self.buf.items.len -= 1;
            return val;
        }
        return null;
    }
};

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

fn asChan(v: Value) ?*ChannelData {
    if (!v.isObj()) return null;
    const obj = v.asObj();
    if (obj.kind != .channel) return null;
    return &obj.data.channel;
}

/// (chan) or (chan n)
pub fn chanFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.channel);
    if (args.len > 0) {
        if (args[0].isInt()) {
            const n = args[0].asInt();
            if (n > 0) obj.data.channel.capacity = @intCast(@as(u48, @bitCast(n)));
        }
    }
    return Value.makeObj(obj);
}

/// (chan? x)
pub fn chanPredFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(asChan(args[0]) != null);
}

/// (chan! ch val) — blocking put (in single-threaded: immediate if buffer allows)
pub fn chanPutFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const ch = asChan(args[0]) orelse return error.TypeError;
    if (ch.closed) return Value.makeBool(false);
    const ok = try ch.tryPut(gc.allocator, args[1]);
    if (!ok) {
        // Buffer full or unbuffered with no taker — store as pending
        try ch.pending_puts.append(gc.allocator, args[1]);
    }
    return args[1];
}

/// (<! ch) — blocking take
pub fn chanTakeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ch = asChan(args[0]) orelse return error.TypeError;
    // First try buffer
    if (ch.tryTake()) |val| {
        // If there are pending puts, move one into the buffer
        if (ch.pending_puts.items.len > 0) {
            const pending = ch.pending_puts.items[0];
            if (ch.pending_puts.items.len > 1) {
                std.mem.copyForwards(Value, ch.pending_puts.items[0 .. ch.pending_puts.items.len - 1], ch.pending_puts.items[1..ch.pending_puts.items.len]);
            }
            ch.pending_puts.items.len -= 1;
            _ = try ch.tryPut(gc.allocator, pending);
        }
        return val;
    }
    // Try pending puts (for unbuffered rendezvous)
    if (ch.pending_puts.items.len > 0) {
        const val = ch.pending_puts.items[0];
        if (ch.pending_puts.items.len > 1) {
            std.mem.copyForwards(Value, ch.pending_puts.items[0 .. ch.pending_puts.items.len - 1], ch.pending_puts.items[1..ch.pending_puts.items.len]);
        }
        ch.pending_puts.items.len -= 1;
        return val;
    }
    // Empty + closed = nil
    if (ch.closed) return Value.makeNil();
    // Empty + open in single-threaded = nil (no blocking possible)
    return Value.makeNil();
}

/// (close! ch)
pub fn chanCloseFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ch = asChan(args[0]) orelse return error.TypeError;
    ch.closed = true;
    return Value.makeNil();
}

/// (closed? ch)
pub fn chanClosedPredFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ch = asChan(args[0]) orelse return error.TypeError;
    return Value.makeBool(ch.closed);
}

/// (chan-count ch)
pub fn chanCountFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ch = asChan(args[0]) orelse return error.TypeError;
    const n: i48 = @intCast(ch.buf.items.len + ch.pending_puts.items.len);
    return Value.makeInt(n);
}

/// (offer! ch val) — non-blocking put, returns true/false
pub fn chanOfferFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const ch = asChan(args[0]) orelse return error.TypeError;
    if (ch.closed) return Value.makeBool(false);
    const ok = try ch.tryPut(gc.allocator, args[1]);
    return Value.makeBool(ok);
}

/// (poll! ch) — non-blocking take, returns value or nil
pub fn chanPollFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ch = asChan(args[0]) orelse return error.TypeError;
    return ch.tryTake() orelse Value.makeNil();
}
