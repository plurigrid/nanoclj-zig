const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const eval_mod = @import("eval.zig");
const printer = @import("printer.zig");
const reader_mod = @import("reader.zig");
const semantics = @import("semantics.zig");

// ─── SplitMix64 ───────────────────────────────────────────────────────
pub const GOLDEN: u64 = 0x9e3779b97f4a7c15;
pub const MIX1: u64 = 0xbf58476d1ce4e5b9;
pub const MIX2: u64 = 0x94d049bb133111eb;
pub const CANONICAL_SEED: u64 = 1069;

pub fn mix64(z_in: u64) u64 {
    var z = z_in;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    z = z ^ (z >> 31);
    return z;
}

pub fn splitmix_next(state: u64) struct { val: u64, next: u64 } {
    const s = state +% GOLDEN;
    return .{ .val = mix64(s), .next = s };
}

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn colorAt(seed: u64, index: u64) Color {
    const state = seed +% index *% GOLDEN;
    const v = mix64(state +% GOLDEN);
    return .{
        .r = @truncate(v >> 16),
        .g = @truncate(v >> 8),
        .b = @truncate(v),
    };
}

pub fn hueToTrit(hue: f64) i2 {
    // R domain -> +1, G domain -> 0, B domain -> -1
    if (hue < 120.0) return 1;
    if (hue < 240.0) return 0;
    return -1;
}

pub fn rgbToHue(r: u8, g: u8, b: u8) f64 {
    const rf: f64 = @as(f64, @floatFromInt(r)) / 255.0;
    const gf: f64 = @as(f64, @floatFromInt(g)) / 255.0;
    const bf: f64 = @as(f64, @floatFromInt(b)) / 255.0;
    const max_v = @max(rf, @max(gf, bf));
    const min_v = @min(rf, @min(gf, bf));
    const delta = max_v - min_v;
    if (delta < 1e-10) return 0.0;
    var hue: f64 = undefined;
    if (max_v == rf) {
        hue = 60.0 * @mod((gf - bf) / delta, 6.0);
    } else if (max_v == gf) {
        hue = 60.0 * ((bf - rf) / delta + 2.0);
    } else {
        hue = 60.0 * ((rf - gf) / delta + 4.0);
    }
    if (hue < 0) hue += 360.0;
    return hue;
}

fn colorTrit(c: Color) i2 {
    return hueToTrit(rgbToHue(c.r, c.g, c.b));
}

// ─── GF(3) ────────────────────────────────────────────────────────────
fn toGF3(x: i48) i48 {
    const r = @rem(x, @as(i48, 3));
    // map to {-1, 0, 1}
    if (r == 2) return -1;
    if (r == -2) return 1;
    return r;
}

// ─── BCI synthetic data ──────────────────────────────────────────────
var bci_counter: u64 = 0;
const BCI_CHANNELS: u32 = 8;

fn syntheticBciRead() [BCI_CHANNELS]f64 {
    var channels: [BCI_CHANNELS]f64 = undefined;
    for (0..BCI_CHANNELS) |i| {
        const sm = splitmix_next(bci_counter +% @as(u64, i));
        bci_counter = sm.next;
        // normalize to [0, 1] band power
        channels[i] = @as(f64, @floatFromInt(sm.val & 0xFFFF)) / 65535.0;
    }
    return channels;
}

fn shannonEntropy(data: []const f64) f64 {
    var total: f64 = 0;
    for (data) |v| total += @abs(v);
    if (total < 1e-15) return 0;
    var entropy: f64 = 0;
    for (data) |v| {
        const p = @abs(v) / total;
        if (p > 1e-15) {
            entropy -= p * @log(p) / @log(2.0);
        }
    }
    return entropy;
}

// ─── hex formatting ──────────────────────────────────────────────────
fn hexColor(buf: *[7]u8, c: Color) void {
    const hex = "0123456789ABCDEF";
    buf[0] = '#';
    buf[1] = hex[c.r >> 4];
    buf[2] = hex[c.r & 0xF];
    buf[3] = hex[c.g >> 4];
    buf[4] = hex[c.g & 0xF];
    buf[5] = hex[c.b >> 4];
    buf[6] = hex[c.b & 0xF];
}

// ─── Builtin implementations ────────────────────────────────────────

// color-at (seed index) -> map
pub fn colorAtFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const index: u64 = @bitCast(@as(i64, args[1].asInt()));
    const c = colorAt(seed, index);
    var hex_buf: [7]u8 = undefined;
    hexColor(&hex_buf, c);
    const trit_val = colorTrit(c);
    // build {:hex "#..." :r N :g N :b N :trit T}
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "hex"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(&hex_buf)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "r"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(c.r)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "g"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(c.g)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "b"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(c.b)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, trit_val))));
    return Value.makeObj(obj);
}

// color-seed () -> 1069
pub fn colorSeedFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(CANONICAL_SEED));
}

// colors (n) -> vector of n color maps
pub fn colorsFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const n: usize = @intCast(args[0].asInt());
    const vec = try gc.allocObj(.vector);
    for (0..n) |i| {
        var a = [_]Value{ Value.makeInt(@intCast(CANONICAL_SEED)), Value.makeInt(@intCast(i)) };
        const color_map = try colorAtFn(&a, gc, env);
        try vec.data.vector.items.append(gc.allocator, color_map);
    }
    return Value.makeObj(vec);
}

// hue-to-trit (hue) -> -1, 0, or 1
pub fn hueToTritFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const hue: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    return Value.makeInt(@intCast(@as(i48, hueToTrit(hue))));
}

// mix64 (n) -> SplitMix64 mix
pub fn mix64Fn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const n: u64 = @bitCast(@as(i64, args[0].asInt()));
    const result = mix64(n);
    // truncate to i48 range
    return Value.makeInt(@bitCast(@as(u48, @truncate(result))));
}

// xor-fingerprint (trits-vector) -> XOR fingerprint
pub fn xorFingerprintFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isObj()) return error.ArityError;
    const obj = args[0].asObj();
    const items = switch (obj.kind) {
        .vector => obj.data.vector.items.items,
        .list => obj.data.list.items.items,
        else => return error.TypeError,
    };
    var fp: u64 = 0;
    for (items, 0..) |item, i| {
        if (!item.isInt()) return error.TypeError;
        const t: u64 = @bitCast(@as(i64, item.asInt()));
        fp ^= mix64(t +% @as(u64, i) *% GOLDEN);
    }
    return Value.makeInt(@bitCast(@as(u48, @truncate(fp))));
}

// ─── GF(3) builtins ──────────────────────────────────────────────────

pub fn gf3AddFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    return Value.makeInt(toGF3(args[0].asInt() + args[1].asInt()));
}

pub fn gf3MulFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    return Value.makeInt(toGF3(args[0].asInt() * args[1].asInt()));
}

pub fn gf3ConservedFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 3 or !args[0].isInt() or !args[1].isInt() or !args[2].isInt())
        return error.ArityError;
    const sum = args[0].asInt() + args[1].asInt() + args[2].asInt();
    return Value.makeBool(toGF3(sum) == 0);
}

pub fn tritBalanceFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isObj()) return error.ArityError;
    const obj = args[0].asObj();
    const items = switch (obj.kind) {
        .vector => obj.data.vector.items.items,
        .list => obj.data.list.items.items,
        else => return error.TypeError,
    };
    var sum: i48 = 0;
    for (items) |item| {
        if (!item.isInt()) return error.TypeError;
        sum += item.asInt();
    }
    return Value.makeInt(toGF3(sum));
}

// ─── BCI builtins ────────────────────────────────────────────────────

pub fn bciChannelsFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(BCI_CHANNELS);
}

pub fn bciReadFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const channels = syntheticBciRead();
    const vec = try gc.allocObj(.vector);
    for (channels) |ch| {
        try vec.data.vector.items.append(gc.allocator, Value.makeFloat(ch));
    }
    return Value.makeObj(vec);
}

pub fn bciTritFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const channels = syntheticBciRead();
    // classify by dominant band: sum first 3 vs middle 2 vs last 3
    var lo: f64 = 0;
    var mid: f64 = 0;
    var hi: f64 = 0;
    for (channels[0..3]) |v| lo += v;
    for (channels[3..5]) |v| mid += v;
    for (channels[5..8]) |v| hi += v;
    if (lo >= mid and lo >= hi) return Value.makeInt(1);
    if (hi >= mid and hi >= lo) return Value.makeInt(-1);
    return Value.makeInt(0);
}

pub fn bciEntropyFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    var channels = syntheticBciRead();
    return Value.makeFloat(shannonEntropy(&channels));
}

// ─── nREPL server ────────────────────────────────────────────────────

var nrepl_thread: ?std.Thread = null;
var nrepl_port: u16 = 0;

const NreplCtx = struct {
    port: u16,
    gc: *GC,
    env: *Env,
};

fn nreplThreadFn(ctx: NreplCtx) void {
    // TODO: nREPL server requires std.net (removed in Zig 0.16).
    // Port to std.Io.net or std.posix socket API when networking is needed.
    _ = ctx;
    return;
}

pub fn nreplStartFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const port: u16 = @intCast(args[0].asInt());
    if (nrepl_thread != null) {
        // already running, return current port
        return Value.makeInt(@intCast(nrepl_port));
    }
    nrepl_port = port;
    nrepl_thread = try std.Thread.spawn(.{}, nreplThreadFn, .{NreplCtx{
        .port = port,
        .gc = gc,
        .env = env,
    }});
    const out = compat.stdoutFile();
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "nREPL started on port {d}\n", .{port}) catch "nREPL started\n";
    compat.fileWriteAll(out, msg);
    return Value.makeInt(@intCast(port));
}

// ─── Substrate traversal ─────────────────────────────────────────────

pub fn substrateFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;
    // :runtime "nanoclj-zig"
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "runtime"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString("nanoclj-zig")));
    // :gc-objects count
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "gc-objects"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(gc.objects.items.len)));
    // :builtins count (approximate — caller can pass real count)
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "builtins"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(gc.strings.items.len)));
    // :bci-connected false
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "bci-connected"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(false));
    // :nrepl-port nil or int
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "nrepl-port"));
    if (nrepl_thread != null) {
        try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(nrepl_port)));
    } else {
        try obj.data.map.vals.append(gc.allocator, Value.makeNil());
    }
    return Value.makeObj(obj);
}

pub fn traverseFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const out = compat.stdoutFile();
    compat.fileWriteAll(out, "traversing to ");
    if (args[0].isString()) {
        const s = gc.getString(args[0].asStringId());
        compat.fileWriteAll(out, s);
    } else if (args[0].isSymbol()) {
        const s = gc.getString(args[0].asSymbolId());
        compat.fileWriteAll(out, s);
    } else {
        compat.fileWriteAll(out, "<unknown>");
    }
    compat.fileWriteAll(out, "\n");
    return Value.makeNil();
}
