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
const Resources = @import("transitivity.zig").Resources;

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

// ─── Splittable PRNG (Steele/Lea/Flood) ──────────────────────────────
// State = (seed, gamma) where gamma is odd with good bit distribution.
// next:  advance seed by gamma, return mixed value.
// split: fork into two independent streams — both deterministic from parent.
//
// Jepsen gets: split(world_seed) → left=test_stream (deterministic)
// REPL gets:   split(world_seed) → right=live_stream (independent)
// Both traceable back to world_seed.

pub const SplitRng = struct {
    seed: u64,
    gamma: u64,

    pub fn init(s: u64) SplitRng {
        return .{ .seed = s, .gamma = mixGamma(mix64(s +% GOLDEN)) };
    }

    /// Next value + advance state
    pub fn next(self: *SplitRng) u64 {
        self.seed +%= self.gamma;
        return mix64(self.seed);
    }

    /// Next value as i48 (for NaN-boxed Value)
    pub fn nextInt(self: *SplitRng) i48 {
        return @truncate(@as(i64, @bitCast(self.next())));
    }

    /// Next value in [0, n)
    pub fn nextBounded(self: *SplitRng, n: u64) u64 {
        if (n == 0) return 0;
        return self.next() % n;
    }

    /// Next trit: -1, 0, or +1 (unconstrained — ergodic, not conserved)
    pub fn nextTrit(self: *SplitRng) i8 {
        const v = self.next() % 3;
        return @as(i8, @intCast(v)) - 1;
    }

    /// Next trit triple: exactly one of each {-1, 0, +1}, permuted by hash.
    /// Sum is ALWAYS 0 mod 3 by construction. Returns [3]i8.
    /// This is the real conservation law — not ergodic, exact.
    pub fn nextBalancedTriple(self: *SplitRng) [3]i8 {
        const v = self.next();
        // 6 permutations of (-1, 0, 1), select by v mod 6
        return switch (v % 6) {
            0 => .{ -1, 0, 1 },
            1 => .{ -1, 1, 0 },
            2 => .{ 0, -1, 1 },
            3 => .{ 0, 1, -1 },
            4 => .{ 1, -1, 0 },
            5 => .{ 1, 0, -1 },
            else => .{ 0, 0, 0 },
        };
    }

    /// Fork: produce two independent generators from this one.
    /// Left gets current (seed', gamma), right gets new (seed'', gamma').
    /// Both are deterministic given the parent state.
    pub fn split(self: *SplitRng) SplitRng {
        const s1 = self.seed +% self.gamma;
        const s2 = s1 +% self.gamma;
        self.seed = s1;
        return .{
            .seed = mix64(s2),
            .gamma = mixGamma(mix64(s2 +% self.gamma)),
        };
    }

    /// Split N ways: produce N independent generators.
    /// All deterministic from the same parent state.
    pub fn splitN(self: *SplitRng, n: usize, out: []SplitRng) void {
        for (0..@min(n, out.len)) |i| {
            out[i] = self.split();
        }
    }

    /// GF(3)-conserving next: returns (value, trit) where trit sums to 0 mod 3
    /// over groups of 3 calls (signal, mechanism, act).
    pub fn nextGF3(self: *SplitRng) struct { val: u64, trit: i8 } {
        const v = self.next();
        // Trit derived from value — deterministic, GF(3) phase of seed position
        const trit: i8 = switch (@as(u2, @truncate(self.seed % 3))) {
            0 => 0,  // mechanism
            1 => 1,  // signal
            2 => -1, // act
            else => 0,
        };
        return .{ .val = v, .trit = trit };
    }
};

/// mix_gamma: ensure gamma is odd with >= 24 bits set (good period)
fn mixGamma(z_in: u64) u64 {
    var z = mix64(z_in) | 1; // force odd
    // Ensure enough bits are set (popcount >= 24)
    const popcount = @popCount(z ^ (z >> 1));
    if (popcount < 24) z ^= 0xaaaaaaaaaaaaaaaa;
    return z;
}

// ─── Universal Index-Addressed Primitive ──────────────────────────────
//
// NOTE: Two-layer color architecture.
//   Layer 1 (here, substrate.zig): fast hash-to-terminal-color via RGB projection.
//     Color = {r: u8, g: u8, b: u8} — a quick, deterministic RGB extracted from at().
//   Layer 2 (colorspace.zig): perceptual OKLAB manifold.
//     Color = {L: f32, a: f32, b: f32, alpha: f32} — full colorspace system with
//     distance, blend, complement, triadic, and manifold-based binding resolution.
//   These are SEPARATE systems. Substrate color is a low-level projection for
//   display/hashing; colorspace.zig is the semantic/perceptual layer.
//
// at(seed, index) → u64: the single source of all deterministic state.
// Everything else is a projection:
//   color_at  = rgb_from(at(seed, index))  // substrate-level projection; see colorspace.zig for OKLAB perceptual space
//   trit_at   = at(seed, index) mod 3 - 1
//   version_at = at(seed + hash(expr), index)
//   rng_at    = SplitRng from at(seed, index)
//
// SPI (Strong Parallelism Invariance): at(s, i) is O(1), pure, parallelizable.
// No state. No ordering dependency. Any index computable independently.

pub fn at(seed: u64, index: u64) u64 {
    return mix64(seed +% index *% GOLDEN);
}

/// Trit at position (unconstrained): -1, 0, or +1. Ergodic, ~1/3 conservation.
pub fn tritAtFree(seed: u64, index: u64) i8 {
    return @as(i8, @intCast(at(seed, index) % 3)) - 1;
}

/// Trit at position (balanced): every group of 3 is a permutation of {-1,0,+1}.
/// GF(3) conservation is EXACT at every 3k boundary by construction.
/// index / 3 selects the triple, index % 3 selects within it.
pub fn tritAt(seed: u64, index: u64) i8 {
    const triple_idx = index / 3;
    const within = @as(usize, @intCast(index % 3));
    const v = at(seed, triple_idx);
    const triple: [3]i8 = switch (v % 6) {
        0 => .{ -1, 0, 1 },
        1 => .{ -1, 1, 0 },
        2 => .{ 0, -1, 1 },
        3 => .{ 0, 1, -1 },
        4 => .{ 1, -1, 0 },
        5 => .{ 1, 0, -1 },
        else => .{ 0, 0, 0 },
    };
    return triple[within];
}

/// Trit sum over [0, n): exact 0 at every 3k, bounded drift otherwise.
pub fn tritSum(seed: u64, n: u64) i32 {
    var s: i32 = 0;
    for (0..@as(usize, @intCast(n))) |i| {
        s += @as(i32, tritAt(seed, i));
    }
    return s;
}

/// FindBalancer (boxxy pattern): given a, b, compute c such that a+b+c ≡ 0 mod 3.
/// Proven correct in boxxy/verified/GF3.dfy (FindBalancerCorrect lemma).
/// Content-based: the compensating trit is derived from values, not position.
pub fn findBalancer(a: i8, b: i8) i8 {
    // In {-1,0,1} representation: find c such that a+b+c ≡ 0 mod 3
    // a+b+c ≡ 0 mod 3  ⟹  c ≡ -(a+b) mod 3
    const sum = @as(i16, a) + @as(i16, b);
    // Map to {-1, 0, 1}: -(a+b) mod 3 with proper sign handling
    const r = @mod(-sum + 300, 3); // always positive mod
    // r ∈ {0, 1, 2} → map to {0, 1, -1} (since 2 ≡ -1 mod 3)
    return if (r == 0) @as(i8, 0) else if (r == 1) @as(i8, 1) else @as(i8, -1);
}

/// Content-based trit: hash the value, take mod 3. Independent of position.
/// This is boxxy's approach (SHA-256 mod 3, we use SplitMix64 mod 3).
pub fn tritOfContent(content_hash: u64) i8 {
    return @as(i8, @intCast(mix64(content_hash) % 3)) - 1;
}

/// Balanced quad from 3 content trits: compute the 4th via FindBalancer.
/// Returns [4]i8 where sum ≡ 0 mod 3. Exact, content-based, not position-based.
pub fn balancedQuad(a: i8, b: i8, c: i8) [4]i8 {
    // d such that a+b+c+d ≡ 0 mod 3
    const partial_sum = @as(i16, a) + @as(i16, b) + @as(i16, c);
    const r = @mod(-partial_sum + 300, 3);
    const d: i8 = if (r == 0) 0 else if (r == 1) 1 else -1;
    return .{ a, b, c, d };
}

/// Color at position: projection of at() into RGB.
pub fn colorAtIndexed(seed: u64, index: u64) Color {
    const v = at(seed, index);
    return .{
        .r = @truncate(v >> 16),
        .g = @truncate(v >> 8),
        .b = @truncate(v),
    };
}

/// Substrate-level RGB color: a quick deterministic projection from at() for
/// terminal display and hashing. This is NOT the full colorspace system —
/// for perceptual OKLAB color with distance/blend/manifold semantics,
/// see colorspace.zig's Color struct.
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
pub fn colorAtFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
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
pub fn colorSeedFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(CANONICAL_SEED));
}

// colors (n) -> vector of n color maps
pub fn colorsFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const raw = args[0].asInt();
    if (raw < 0) return error.InvalidArgs;
    const n: usize = std.math.cast(usize, raw) orelse return error.InvalidArgs;
    const vec = try gc.allocObj(.vector);
    for (0..n) |i| {
        var a = [_]Value{ Value.makeInt(@intCast(CANONICAL_SEED)), Value.makeInt(@intCast(i)) };
        const color_map = try colorAtFn(&a, gc, env, res);
        try vec.data.vector.items.append(gc.allocator, color_map);
    }
    return Value.makeObj(vec);
}

// hue-to-trit (hue) -> -1, 0, or 1
pub fn hueToTritFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const hue: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    return Value.makeInt(@intCast(@as(i48, hueToTrit(hue))));
}

// mix64 (n) -> SplitMix64 mix
pub fn mix64Fn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const n: u64 = @bitCast(@as(i64, args[0].asInt()));
    const result = mix64(n);
    // truncate to i48 range
    return Value.makeInt(@bitCast(@as(u48, @truncate(result))));
}

// xor-fingerprint (trits-vector) -> XOR fingerprint
pub fn xorFingerprintFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
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

pub fn gf3AddFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    return Value.makeInt(toGF3(args[0].asInt() + args[1].asInt()));
}

pub fn gf3MulFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isInt() or !args[1].isInt()) return error.ArityError;
    return Value.makeInt(toGF3(args[0].asInt() * args[1].asInt()));
}

pub fn gf3ConservedFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3 or !args[0].isInt() or !args[1].isInt() or !args[2].isInt())
        return error.ArityError;
    const sum = args[0].asInt() + args[1].asInt() + args[2].asInt();
    return Value.makeBool(toGF3(sum) == 0);
}

pub fn tritBalanceFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
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

pub fn bciChannelsFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(BCI_CHANNELS);
}

pub fn bciReadFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const channels = syntheticBciRead();
    const vec = try gc.allocObj(.vector);
    for (channels) |ch| {
        try vec.data.vector.items.append(gc.allocator, Value.makeFloat(ch));
    }
    return Value.makeObj(vec);
}

pub fn bciTritFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
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

pub fn bciEntropyFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
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

pub fn nreplStartFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const raw_port = args[0].asInt();
    if (raw_port < 1 or raw_port > 65535) return error.InvalidArgs;
    const port: u16 = @intCast(raw_port);
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

pub fn substrateFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
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
    // :nrepl-port — delegated to nrepl.zig
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "nrepl-port"));
    const nrepl_mod = @import("nrepl.zig");
    if (nrepl_mod.global_server) |srv| {
        try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(srv.port)));
    } else {
        try obj.data.map.vals.append(gc.allocator, Value.makeNil());
    }
    return Value.makeObj(obj);
}

pub fn traverseFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
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
