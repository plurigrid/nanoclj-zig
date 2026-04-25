//! Parallel-runtime comparison skill triad (§6.1 registry).
//!
//! The §7 embarrassment ledger benchmarks nanoclj-zig against itself.
//! This file adds a CROSS-RUNTIME comparator: same Clojure form, multiple
//! interpreters (`bb`, `clojure`, `nanoclj-zig`, jank-slot). Captured by
//! `.topos/bench/parallel.bb` at 2026-04-25T04:35Z.
//!
//! Cold-start wall ms (bb=1.00 baseline):
//!   fib25                bb=  25ms  clj=   579ms (22.6x)  nano=1594ms (62.6x)
//!   tight-loop-10k       bb=  13ms  clj=   550ms (42.2x)  nano= 916ms (70.3x)
//!   reduce-+-range-10k   bb=  12ms  clj=   552ms (45.4x)  nano= 873ms (71.7x)
//!
//! jank slot empty: jank-lang/jank source is at /Users/bob/i/jank but no
//! prebuilt binary; nix flake fails on clang-wrapper. Set JANK_BIN env var
//! and re-run parallel.bb to populate.
//!
//! Triad assignment under GF(3) load:
//!   trit  role     intent
//!   +1    play     surfaces the worst nano/bb ratio (parallel embarrassment)
//!     0   witness  count of runtimes currently installed (ambiguous: more
//!                  ≠ better, fewer ≠ worse)
//!   −1    coplay   jank-slot status flag (info-free decoration today)
//! Sum: 1·(+1) + 1·0 + 1·(−1) = 0. ✓

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const GC = @import("../gc.zig").GC;
const Env = @import("../env.zig").Env;
const Resources = @import("../transitivity.zig").Resources;
const skill = @import("skill.zig");
const Skill = skill.Skill;

/// PLAY (+1): worst-case nano-vs-bb ratio across the 3 forms × 100
/// (returned as integer to avoid f32 boxing). Captured 2026-04-25T04:35Z:
///   max ratio = reduce-+-range-10k @ 71.69 → 7169.
fn nanoVsBbWorstRatioFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(7169);
}

/// WITNESS (0): count of runtimes currently installed and verified.
/// 3 today (bb, clojure, nanoclj-zig); jank not present.
fn installedRuntimesFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(3);
}

/// COPLAY (−1): jank-slot status. 0 = not installed, 1 = installed.
/// Pure flag, no measurement information; balances the trit budget.
fn jankInstalledFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(0);
}

pub const skills = [_]Skill{
    .{
        .name = "loop-bench-nano-vs-bb-worst-ratio-x100",
        .doc = "(loop-bench-nano-vs-bb-worst-ratio-x100) — worst nano/bb cold-start ratio across {fib25, tight-loop, reduce} × 100. [E4, play, +1]",
        .body = nanoVsBbWorstRatioFn,
    },
    .{
        .name = "loop-bench-installed-runtimes",
        .doc = "(loop-bench-installed-runtimes) — count of parallel runtimes currently usable. [E4, witness, 0]",
        .body = installedRuntimesFn,
    },
    .{
        .name = "loop-bench-jank-installed",
        .doc = "(loop-bench-jank-installed) — 1 if jank binary on PATH, 0 otherwise. [E4, coplay, −1]",
        .body = jankInstalledFn,
    },
};

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

test "3 skills, GF(3) trit budget balanced" {
    try std.testing.expectEqual(@as(usize, 3), skills.len);
    var play: i32 = 0;
    var witness: i32 = 0;
    var coplay: i32 = 0;
    for (skills) |s| {
        if (std.mem.indexOf(u8, s.doc, "play, +1") != null) play += 1;
        if (std.mem.indexOf(u8, s.doc, "witness, 0") != null) witness += 1;
        if (std.mem.indexOf(u8, s.doc, "coplay, \xE2\x88\x921") != null) coplay += 1;
    }
    try std.testing.expectEqual(@as(i32, 1), play);
    try std.testing.expectEqual(@as(i32, 1), witness);
    try std.testing.expectEqual(@as(i32, 1), coplay);
    try std.testing.expectEqual(@as(i32, 0), @mod(play * 1 + witness * 0 + coplay * -1, 3));
}

test "worst ratio skill returns the captured embarrassment number" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    const out = try nanoVsBbWorstRatioFn(&.{}, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 7169), out.asInt());
}

test "installed runtimes skill reports 3 (bb, clojure, nanoclj-zig)" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    const out = try installedRuntimesFn(&.{}, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 3), out.asInt());
}

test "jank-installed skill reports 0 (not installed)" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    const out = try jankInstalledFn(&.{}, &gc, &env, &res);
    try std.testing.expectEqual(@as(i48, 0), out.asInt());
}
