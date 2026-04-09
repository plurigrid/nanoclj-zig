//! Zipf's law module for nanoclj-zig
//!
//! Zipf's law: frequency ∝ 1/rank^s (s = exponent, typically ~1.0)
//! Models: web traffic, word frequencies, city sizes, domain popularity
//!
//! Builtins:
//!   (zipf-rank rank s)           → frequency at rank (unnormalized 1/rank^s)
//!   (zipf-pmf rank s n)          → P(rank) = (1/rank^s) / H(n,s)
//!   (zipf-harmonic n s)          → generalized harmonic number H(n,s) = Σ 1/k^s
//!   (zipf-sample rng-seed n s k) → k samples from Zipf(n,s) distribution
//!   (zipf-top-share top n s)     → fraction of total probability in top ranks
//!   (zipf-taper n s)             → map of {rank frequency cumulative} showing taper

const std = @import("std");
const math = std.math;
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const substrate = @import("substrate.zig");

// ============================================================================
// CORE MATH
// ============================================================================

/// Generalized harmonic number H(n, s) = Σ_{k=1}^{n} 1/k^s
fn harmonicNumber(n: u64, s: f64) f64 {
    var h: f64 = 0.0;
    var k: u64 = 1;
    while (k <= n) : (k += 1) {
        h += 1.0 / math.pow(f64, @floatFromInt(k), s);
    }
    return h;
}

/// Zipf PMF: P(rank) = (1/rank^s) / H(n,s)
fn zipfPmf(rank: u64, s: f64, n: u64) f64 {
    if (rank == 0 or rank > n) return 0.0;
    const h = harmonicNumber(n, s);
    if (h == 0.0) return 0.0;
    return (1.0 / math.pow(f64, @floatFromInt(rank), s)) / h;
}

/// Cumulative share of top `top` ranks out of `n` total
fn topShare(top: u64, n: u64, s: f64) f64 {
    const h_n = harmonicNumber(n, s);
    if (h_n == 0.0) return 0.0;
    const h_top = harmonicNumber(top, s);
    return h_top / h_n;
}

/// Sample from Zipf distribution using inverse CDF + splitmix RNG
fn zipfSample(seed: u64, n: u64, s: f64, count: u64) []u64 {
    _ = seed;
    _ = n;
    _ = s;
    _ = count;
    // returned via builtin as a nanoclj vector
    unreachable;
}

// ============================================================================
// BUILTIN FUNCTIONS
// ============================================================================

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

/// (zipf-rank rank s) → 1/rank^s
pub fn zipfRankFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.InvalidArgs;
    const rank_f = args[0].asNumber() orelse return error.InvalidArgs;
    const s = args[1].asNumber() orelse return error.InvalidArgs;
    const rank: u64 = if (rank_f > 0) @intFromFloat(rank_f) else return error.InvalidArgs;
    return Value.makeFloat(1.0 / math.pow(f64, @floatFromInt(rank), s));
}

/// (zipf-pmf rank s n) → probability mass at rank
pub fn zipfPmfFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 3) return error.InvalidArgs;
    const rank_f = args[0].asNumber() orelse return error.InvalidArgs;
    const s = args[1].asNumber() orelse return error.InvalidArgs;
    const n_f = args[2].asNumber() orelse return error.InvalidArgs;
    const rank: u64 = if (rank_f > 0) @intFromFloat(rank_f) else return error.InvalidArgs;
    const n: u64 = if (n_f > 0) @intFromFloat(n_f) else return error.InvalidArgs;
    return Value.makeFloat(zipfPmf(rank, s, n));
}

/// (zipf-harmonic n s) → generalized harmonic number
pub fn zipfHarmonicFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.InvalidArgs;
    const n_f = args[0].asNumber() orelse return error.InvalidArgs;
    const s = args[1].asNumber() orelse return error.InvalidArgs;
    const n: u64 = if (n_f > 0) @intFromFloat(n_f) else return error.InvalidArgs;
    return Value.makeFloat(harmonicNumber(n, s));
}

/// (zipf-top-share top n s) → fraction of total in top ranks
pub fn zipfTopShareFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 3) return error.InvalidArgs;
    const top_f = args[0].asNumber() orelse return error.InvalidArgs;
    const n_f = args[1].asNumber() orelse return error.InvalidArgs;
    const s = args[2].asNumber() orelse return error.InvalidArgs;
    const top: u64 = if (top_f > 0) @intFromFloat(top_f) else return error.InvalidArgs;
    const n: u64 = if (n_f > 0) @intFromFloat(n_f) else return error.InvalidArgs;
    return Value.makeFloat(topShare(top, n, s));
}

/// (zipf-sample seed n s k) → vector of k samples from Zipf(n,s)
/// Uses inverse-CDF with splitmix RNG
pub fn zipfSampleFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 4) return error.InvalidArgs;
    const seed_f = args[0].asNumber() orelse return error.InvalidArgs;
    const n_f = args[1].asNumber() orelse return error.InvalidArgs;
    const s = args[2].asNumber() orelse return error.InvalidArgs;
    const k_f = args[3].asNumber() orelse return error.InvalidArgs;

    var seed: u64 = @intFromFloat(seed_f);
    const n: u64 = if (n_f > 0) @intFromFloat(n_f) else return error.InvalidArgs;
    const k: u64 = if (k_f > 0) @intFromFloat(k_f) else return error.InvalidArgs;
    const clamped_k = if (k > 100_000) @as(u64, 100_000) else k;

    // Build CDF
    const h_n = harmonicNumber(n, s);
    if (h_n == 0.0) return Value.makeNil();

    // Inverse CDF sampling
    const vec = try gc.allocObj(.vector);
    var i: u64 = 0;
    while (i < clamped_k) : (i += 1) {
        seed = substrate.mix64(seed);
        const u: f64 = @as(f64, @floatFromInt(seed >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
        const target = u * h_n;

        // Linear scan for small n, could optimize with binary search
        var cumulative: f64 = 0.0;
        var rank: u64 = 1;
        while (rank <= n) : (rank += 1) {
            cumulative += 1.0 / math.pow(f64, @floatFromInt(rank), s);
            if (cumulative >= target) break;
        }
        try vec.data.vector.items.append(gc.allocator, Value.makeFloat(@floatFromInt(rank)));
    }
    return Value.makeObj(vec);
}

/// (zipf-taper n s) → vector of maps [{:rank 1 :freq f :cumulative c} ...]
/// Shows the full taper curve
pub fn zipfTaperFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.InvalidArgs;
    const n_f = args[0].asNumber() orelse return error.InvalidArgs;
    const s = args[1].asNumber() orelse return error.InvalidArgs;
    const n: u64 = if (n_f > 0) @intFromFloat(n_f) else return error.InvalidArgs;
    const clamped_n = if (n > 10_000) @as(u64, 10_000) else n;

    const h_n = harmonicNumber(clamped_n, s);
    if (h_n == 0.0) return Value.makeNil();

    const vec = try gc.allocObj(.vector);
    var cumulative: f64 = 0.0;
    var rank: u64 = 1;
    while (rank <= clamped_n) : (rank += 1) {
        const freq = 1.0 / math.pow(f64, @floatFromInt(rank), s);
        const pmf = freq / h_n;
        cumulative += pmf;

        const m = try gc.allocObj(.map);
        try addKV(m, gc, "rank", Value.makeFloat(@floatFromInt(rank)));
        try addKV(m, gc, "freq", Value.makeFloat(freq));
        try addKV(m, gc, "pmf", Value.makeFloat(pmf));
        try addKV(m, gc, "cumulative", Value.makeFloat(cumulative));
        try vec.data.vector.items.append(gc.allocator, Value.makeObj(m));
    }
    return Value.makeObj(vec);
}

/// (zipf-mandelbrot rank s q) → (rank + q)^(-s) generalization
/// Zipf-Mandelbrot law: f(rank) = 1/(rank + q)^s
pub fn zipfMandelbrotFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 3) return error.InvalidArgs;
    const rank_f = args[0].asNumber() orelse return error.InvalidArgs;
    const s = args[1].asNumber() orelse return error.InvalidArgs;
    const q = args[2].asNumber() orelse return error.InvalidArgs;
    const rank: f64 = if (rank_f > 0) rank_f else return error.InvalidArgs;
    return Value.makeFloat(1.0 / math.pow(f64, rank + q, s));
}
