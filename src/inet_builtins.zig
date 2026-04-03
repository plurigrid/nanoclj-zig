//! INET BUILTINS: Clojure-facing interaction net API
//!
//! Exposes inet.zig to the nanoclj REPL:
//!   (inet-new)                    → net-id (int)
//!   (inet-cell net-id kind arity) → cell-index (int)
//!   (inet-wire net-id ca pa cb pb) → nil (connect port a to port b)
//!   (inet-reduce net-id)          → steps (int)
//!   (inet-live net-id)            → count (int)
//!   (inet-pairs net-id)           → count (int)
//!   (inet-trit net-id)            → trit-sum mod 3 (int)

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const inet = @import("inet.zig");
const Net = inet.Net;
const Port = inet.Port;
const CellKind = inet.CellKind;
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;

// ============================================================================
// GLOBAL NET REGISTRY (max 64 nets)
// ============================================================================

var nets: [64]?Net = .{null} ** 64;
var net_allocator: ?std.mem.Allocator = null;

fn ensureAllocator(gc: *GC) std.mem.Allocator {
    if (net_allocator == null) {
        net_allocator = gc.allocator;
    }
    return net_allocator.?;
}

pub fn deinitNets() void {
    for (&nets) |*slot| {
        if (slot.*) |*n| {
            n.deinit();
            slot.* = null;
        }
    }
}

fn findFreeSlot() ?usize {
    for (nets, 0..) |slot, i| {
        if (slot == null) return i;
    }
    return null;
}

// ============================================================================
// BUILTINS
// ============================================================================

/// (inet-new) → net-id
pub fn inetNewFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const alloc = ensureAllocator(gc);
    const slot = findFreeSlot() orelse return error.Overflow;
    nets[slot] = Net.init(alloc);
    return Value.makeInt(@intCast(slot));
}

fn getNet(args: []Value) !*Net {
    if (args.len < 1) return error.InvalidArgument;
    if (!args[0].isInt()) return error.InvalidArgument;
    const id: usize = @intCast(args[0].asInt());
    if (id >= 64) return error.InvalidArgument;
    return &(nets[id] orelse return error.InvalidArgument);
}

fn parseKind(gc: *GC, val: Value) ?CellKind {
    if (val.isKeyword()) {
        const name = gc.getString(val.asKeywordId());
        if (std.mem.eql(u8, name, "gamma")) return .gamma;
        if (std.mem.eql(u8, name, "delta")) return .delta;
        if (std.mem.eql(u8, name, "epsilon")) return .epsilon;
        if (std.mem.eql(u8, name, "iota")) return .iota;
        // Short aliases
        if (std.mem.eql(u8, name, "g")) return .gamma;
        if (std.mem.eql(u8, name, "d")) return .delta;
        if (std.mem.eql(u8, name, "e")) return .epsilon;
        if (std.mem.eql(u8, name, "i")) return .iota;
    }
    if (val.isInt()) {
        const v = val.asInt();
        if (v >= 0 and v <= 3) return @enumFromInt(@as(u8, @intCast(v)));
    }
    return null;
}

/// (inet-cell net-id :gamma arity) → cell-index
/// (inet-cell net-id :gamma arity payload) → cell-index
pub fn inetCellFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3) return error.InvalidArgument;
    const net = try getNet(args);
    const kind = parseKind(gc, args[1]) orelse return error.InvalidArgument;
    if (!args[2].isInt()) return error.InvalidArgument;
    const arity: u8 = @intCast(args[2].asInt());
    const payload = if (args.len >= 4) args[3] else Value.makeNil();
    const idx = try net.addCell(kind, arity, payload);
    return Value.makeInt(@intCast(idx));
}

/// (inet-wire net-id cell-a port-a cell-b port-b) → nil
pub fn inetWireFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len < 5) return error.InvalidArgument;
    const net = try getNet(args);
    if (!args[1].isInt() or !args[2].isInt() or !args[3].isInt() or !args[4].isInt())
        return error.InvalidArgument;
    const pa = Port{ .cell = @intCast(args[1].asInt()), .port = @intCast(args[2].asInt()) };
    const pb = Port{ .cell = @intCast(args[3].asInt()), .port = @intCast(args[4].asInt()) };
    try net.connect(pa, pb);
    return Value.makeNil();
}

/// (inet-reduce net-id) → steps taken
pub fn inetReduceFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    const net = try getNet(args);
    var res = Resources.initDefault();
    const steps = try net.reduceAll(&res);
    return Value.makeInt(@intCast(steps));
}

/// (inet-live net-id) → live cell count
pub fn inetLiveFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    const net = try getNet(args);
    return Value.makeInt(@intCast(net.liveCells()));
}

/// (inet-pairs net-id) → active pair count
pub fn inetPairsFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    const net = try getNet(args);
    var pairs = net.findActivePairs();
    defer pairs.deinit(net.allocator);
    return Value.makeInt(@intCast(pairs.items.len));
}

/// (inet-trit net-id) → GF(3) trit sum mod 3
pub fn inetTritFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    const net = try getNet(args);
    return Value.makeInt(@intCast(net.tritSumMod3()));
}

// ============================================================================
// TESTS
// ============================================================================

test "inet builtins: create and reduce" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    defer deinitNets();

    // (inet-new)
    const net_id = try inetNewFn(&.{}, &gc, &env);
    try std.testing.expect(net_id.isInt());

    // (inet-cell net :epsilon 0)
    const ek = try gc.internString("epsilon");
    var cell_args = [_]Value{ net_id, Value.makeKeyword(ek), Value.makeInt(0) };
    const e1 = try inetCellFn(&cell_args, &gc, &env);
    const e2 = try inetCellFn(&cell_args, &gc, &env);

    // (inet-wire net 0 0 1 0) — connect principals
    var wire_args = [_]Value{ net_id, e1, Value.makeInt(0), e2, Value.makeInt(0) };
    _ = try inetWireFn(&wire_args, &gc, &env);

    // (inet-pairs net) → 1
    var net_args = [_]Value{net_id};
    const pairs = try inetPairsFn(&net_args, &gc, &env);
    try std.testing.expectEqual(@as(i48, 1), pairs.asInt());

    // (inet-reduce net) → 1 step
    const steps = try inetReduceFn(&net_args, &gc, &env);
    try std.testing.expectEqual(@as(i48, 1), steps.asInt());

    // (inet-live net) → 0
    const live = try inetLiveFn(&net_args, &gc, &env);
    try std.testing.expectEqual(@as(i48, 0), live.asInt());
}
