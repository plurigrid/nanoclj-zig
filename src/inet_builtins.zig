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
const compat = @import("compat.zig");
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

/// Public accessors for decomp.zig
pub fn findFreeSlotPub() ?usize {
    return findFreeSlot();
}

pub fn setNet(slot: usize, net: Net) void {
    nets[slot] = net;
}

pub fn ensureAllocatorPub(gc: *GC) void {
    _ = ensureAllocator(gc);
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

/// Public accessor for other modules (inet_compile)
pub fn getNetPub(id_val: Value) !*Net {
    if (!id_val.isInt()) return error.InvalidArgument;
    const raw = id_val.asInt();
    if (raw < 0) return error.InvalidArgument;
    const id: usize = std.math.cast(usize, raw) orelse return error.InvalidArgument;
    if (id >= 64) return error.InvalidArgument;
    return &(nets[id] orelse return error.InvalidArgument);
}

fn getNet(args: []Value) !*Net {
    if (args.len < 1) return error.InvalidArgument;
    if (!args[0].isInt()) return error.InvalidArgument;
    const raw = args[0].asInt();
    if (raw < 0) return error.InvalidArgument;
    const id: usize = std.math.cast(usize, raw) orelse return error.InvalidArgument;
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
    const raw_arity = args[2].asInt();
    if (raw_arity < 0 or raw_arity > 255) return error.InvalidArgument;
    const arity: u8 = @intCast(raw_arity);
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
    const raw_ca = args[1].asInt();
    const raw_pa = args[2].asInt();
    const raw_cb = args[3].asInt();
    const raw_pb = args[4].asInt();
    if (raw_ca < 0 or raw_pa < 0 or raw_cb < 0 or raw_pb < 0) return error.InvalidArgument;
    const pa = Port{ .cell = std.math.cast(u16, raw_ca) orelse return error.InvalidArgument, .port = std.math.cast(u8, raw_pa) orelse return error.InvalidArgument };
    const pb = Port{ .cell = std.math.cast(u16, raw_cb) orelse return error.InvalidArgument, .port = std.math.cast(u8, raw_pb) orelse return error.InvalidArgument };
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

/// (inet-from-forest) → net-id
/// Converts the tree VFS transclusion graph into an interaction net.
/// Each tree node → γ cell (arity = number of transclusions).
/// Each transclusion edge → wire from parent's aux port to child's principal.
/// Hub nodes (high out-degree) become natural fan-out points.
pub fn inetFromForestFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const tree_vfs = @import("tree_vfs.zig");
    const alloc = ensureAllocator(gc);
    const slot = findFreeSlot() orelse return error.Overflow;
    nets[slot] = Net.init(alloc);
    const net = &(nets[slot].?);

    // Get forest data
    const ids = tree_vfs.getAllIds() orelse return Value.makeInt(@intCast(slot));

    // Phase 1: create γ cell per tree node, track id→cell mapping
    var id_to_cell = std.StringHashMap(u16).init(alloc);
    defer id_to_cell.deinit();

    for (ids) |id| {
        const arity = tree_vfs.getTranscludeCount(id) orelse 0;
        const cell = try net.addCell(.gamma, @intCast(@min(arity, 255)), Value.makeNil());
        try id_to_cell.put(id, cell);
    }

    // Phase 2: wire transclusion edges
    for (ids) |id| {
        const parent_cell = id_to_cell.get(id) orelse continue;
        const transcludes = tree_vfs.getTranscludes(id) orelse continue;
        for (transcludes, 0..) |target_id, port_n| {
            const child_cell = id_to_cell.get(target_id) orelse continue;
            if (port_n >= 255) break;
            net.connect(
                Port.aux(parent_cell, @intCast(port_n)),
                Port.principal(child_cell),
            ) catch continue;
        }
    }

    return Value.makeInt(@intCast(slot));
}

/// (inet-dot net-id) → DOT graph string
/// Outputs a Graphviz DOT representation of the net.
pub fn inetDotFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const net = try getNet(args);
    var buf = compat.emptyList(u8);

    // 0.16: ArrayListUnmanaged no longer has .writer(); use appendSlice + bufPrint
    try buf.appendSlice(gc.allocator, "digraph inet {\n  rankdir=LR;\n  node [shape=circle];\n");

    // Cells
    var fmt_buf: [256]u8 = undefined;
    for (net.cells.items, 0..) |cell, i| {
        if (!cell.alive) continue;
        const shape: []const u8 = switch (cell.kind) {
            .gamma => "triangle",
            .delta => "invtriangle",
            .epsilon => "point",
            .iota => "diamond",
            .sup => "hexagon",
            .num_op => "box",
        };
        const label: []const u8 = switch (cell.kind) {
            .gamma => "γ",
            .delta => "δ",
            .epsilon => "ε",
            .iota => "ι",
            .sup => "⊔",
            .num_op => "op",
        };
        const line = std.fmt.bufPrint(&fmt_buf, "  c{d} [shape={s} label=\"{s}{d}\"];\n", .{ i, shape, label, i }) catch continue;
        try buf.appendSlice(gc.allocator, line);
    }

    // Wires
    for (net.wires.items) |wire| {
        const style: []const u8 = if (wire.a.port == 0 and wire.b.port == 0) "bold" else "solid";
        const line = std.fmt.bufPrint(&fmt_buf, "  c{d}:p{d} -> c{d}:p{d} [style={s} dir=none];\n", .{
            wire.a.cell, wire.a.port,
            wire.b.cell, wire.b.port,
            style,
        }) catch continue;
        try buf.appendSlice(gc.allocator, line);
    }

    try buf.appendSlice(gc.allocator, "}\n");

    const str_id = try gc.internString(buf.items);
    return Value.makeString(str_id);
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
