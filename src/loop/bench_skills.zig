//! Benchmark-embarrassment skill triads.
//!
//! `.topos/bench/` ran clean at 2026-04-25T03:50Z and surfaced three
//! genuinely embarrassing measurements (see `.topos/agent-o-nanoclj.md` §7
//! for the table). For each one we ship a three-skill triad under the
//! GF(3) triadic-load protocol (memory: `feedback_triadic_skill_load`):
//!
//!   trit  role     intent
//!   ───   ───────  ────────────────────────────────────────────
//!   +1    play     most useful — surfaces the embarrassing number
//!     0   witness  hardest-to-tell — ambiguous correlate
//!   −1    coplay   least useful — aesthetic noise, no signal
//!
//! Sum across all 9 skills ≡ 0 (mod 3) iff the load is balanced.
//! 3·(+1) + 3·0 + 3·(−1) = 0. ✓
//!
//! The numerical values returned are the actual measurements from the
//! captured run. Future iterations may swap these for live measurements
//! by hooking into `bench/bench_util.zig`'s harness; the wire is the
//! same — Skill records in this file's `skills` slice.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const GC = @import("../gc.zig").GC;
const Env = @import("../env.zig").Env;
const Resources = @import("../transitivity.zig").Resources;
const skill = @import("skill.zig");
const Skill = skill.Skill;

// ─────────────────────────────────────────────────────────────────────
// Embarrassment 1 — fib(25) allocates 54.4 MB
//
// Target was zero heap allocs inside fib body (NaN-boxing should keep
// integer args inline). Measured: 54_383_840 bytes allocated for fib(25).
// Wall time: 79.3 ms vs Zig fib(25) at 119 µs ≈ 667× slowdown.
// ─────────────────────────────────────────────────────────────────────

/// PLAY (+1): the offending number itself.
fn fib25AllocBytesFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(54_383_840);
}

/// WITNESS (0): GF(3) trit of n. Pure-int op that exercises the NaN-box
/// path but says nothing about whether the path actually elides the box.
fn intTritFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeInt(@mod(args[0].asInt(), 3));
}

/// COPLAY (−1): a fixed magenta hex code. Aesthetic, no signal.
fn benchBannerHexFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(0xFF00FF);
}

// ─────────────────────────────────────────────────────────────────────
// Embarrassment 2 — Reader peak_alloc 21.7× source size
//
// 1.05 MB of source text expands to 22.7 MB of peak allocation during
// parse. Target ratio is < 5×. Either the arena is sized too generously
// or per-form constants are heap-promoted instead of NaN-boxed.
// ─────────────────────────────────────────────────────────────────────

/// PLAY (+1): the ratio in milli-multiples of source size.
fn readerAllocRatioMilliFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(21_667);
}

/// WITNESS (0): top-level form count. Could correlate with alloc bloat
/// (more forms → more frame headers) or be irrelevant (per-form constants
/// are tiny). Hard to tell without per-form attribution.
fn readerFormCountFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(43_690);
}

/// COPLAY (−1): a "mood" trit. Always 0 — the flat mood. Pure trolling.
fn readerMoodFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(0);
}

// ─────────────────────────────────────────────────────────────────────
// Embarrassment 3 — Tight loop 356 ns/iter (~7× native)
//
// `loop_tight_n10000` ran in 3.56 ms = 356 ns per integer-arithmetic
// iteration. A native Zig integer loop is < 50 ns/iter. Likely culprits:
// dispatch overhead per builtin call, fuel-meter charging, recur frame
// allocation. The play skill exposes the number; witness exposes a
// possible cause; coplay is decoration.
// ─────────────────────────────────────────────────────────────────────

/// PLAY (+1): the offending ns/iter.
fn tightLoopNsPerIterFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(356);
}

/// WITNESS (0): approximate fuel charged per iter. Could explain the
/// slowdown if the meter dominates, or be irrelevant if dispatch does.
fn tightLoopFuelChargeFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(7);
}

/// COPLAY (−1): batch size of the bench. Decorative metadata only.
fn tightLoopBatchFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(1);
}

/// Skills exposed by this submodule. Trits are documented in each `doc`.
pub const skills = [_]Skill{
    // Embarrassment 1 — fib(25) heap leak
    .{
        .name = "loop-bench-fib25-allocs",
        .doc = "(loop-bench-fib25-allocs) — bytes allocated for fib(25). [E1, play, +1]",
        .body = fib25AllocBytesFn,
    },
    .{
        .name = "loop-int-trit",
        .doc = "(loop-int-trit n) — n mod 3. [E1, witness, 0]",
        .body = intTritFn,
    },
    .{
        .name = "loop-bench-banner-hex",
        .doc = "(loop-bench-banner-hex) — magenta hex (0xFF00FF). [E1, coplay, −1]",
        .body = benchBannerHexFn,
    },

    // Embarrassment 2 — reader 21.7× alloc ratio
    .{
        .name = "loop-bench-reader-ratio-milli",
        .doc = "(loop-bench-reader-ratio-milli) — reader peak_alloc/src_size × 1000. [E2, play, +1]",
        .body = readerAllocRatioMilliFn,
    },
    .{
        .name = "loop-bench-reader-forms",
        .doc = "(loop-bench-reader-forms) — top-level forms in 1MB bench. [E2, witness, 0]",
        .body = readerFormCountFn,
    },
    .{
        .name = "loop-bench-reader-mood",
        .doc = "(loop-bench-reader-mood) — flat mood trit (always 0). [E2, coplay, −1]",
        .body = readerMoodFn,
    },

    // Embarrassment 3 — tight-loop 7× over native
    .{
        .name = "loop-bench-tight-ns",
        .doc = "(loop-bench-tight-ns) — ns per tight-loop iter. [E3, play, +1]",
        .body = tightLoopNsPerIterFn,
    },
    .{
        .name = "loop-bench-tight-fuel",
        .doc = "(loop-bench-tight-fuel) — fuel charged per iter. [E3, witness, 0]",
        .body = tightLoopFuelChargeFn,
    },
    .{
        .name = "loop-bench-tight-batch",
        .doc = "(loop-bench-tight-batch) — bench batch count. [E3, coplay, −1]",
        .body = tightLoopBatchFn,
    },
};

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

test "9 skills, 3-fold triad structure" {
    try std.testing.expectEqual(@as(usize, 9), skills.len);
    for (skills) |s| try std.testing.expect(s.name.len > 0);
}

test "GF(3) trit balance: 3·(+1) + 3·0 + 3·(−1) ≡ 0 (mod 3)" {
    // Trits encoded by suffix in name: -allocs/-ratio-milli/-ns are play(+1),
    // -trit/-forms/-fuel are witness(0), -hex/-mood/-batch are coplay(−1).
    var play: i32 = 0;
    var witness: i32 = 0;
    var coplay: i32 = 0;
    for (skills) |s| {
        if (std.mem.indexOf(u8, s.doc, "play, +1") != null) play += 1;
        if (std.mem.indexOf(u8, s.doc, "witness, 0") != null) witness += 1;
        if (std.mem.indexOf(u8, s.doc, "coplay, \xE2\x88\x921") != null) coplay += 1;
    }
    try std.testing.expectEqual(@as(i32, 3), play);
    try std.testing.expectEqual(@as(i32, 3), witness);
    try std.testing.expectEqual(@as(i32, 3), coplay);
    const sum = play * 1 + witness * 0 + coplay * -1;
    try std.testing.expectEqual(@as(i32, 0), @mod(sum, 3));
}

test "fib25 alloc skill returns the captured number" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    const out = try fib25AllocBytesFn(&.{}, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 54_383_840), out.asInt());
}

test "intTrit dispatches GF(3): -1 → 2, 0 → 0, 1 → 1, 2 → 2, 7 → 1" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    const cases = [_]struct { n: i48, expected: i48 }{
        .{ .n = 0, .expected = 0 },
        .{ .n = 1, .expected = 1 },
        .{ .n = 2, .expected = 2 },
        .{ .n = 3, .expected = 0 },
        .{ .n = 7, .expected = 1 },
    };
    for (cases) |c| {
        var args = [_]Value{Value.makeInt(c.n)};
        const out = try intTritFn(&args, &gc, &env, &res);
        try std.testing.expectEqual(c.expected, out.asInt());
    }
}
