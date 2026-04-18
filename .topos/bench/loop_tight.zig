//! loop_tight.zig — `(loop [i 0 s 0] (if (< i N) (recur (inc i) (+ s i)) s))`.
//!
//! Head-to-head (tier 0). Tests `loop`/`recur` TCO path vs self-recursive
//! `fn*`. Hickey's 2010 "tail-call via loop/recur" design. Same N=10000
//! arithmetic reduction should be strictly faster via loop than via
//! self-recursion (no stack frame). Clojure-JVM warm: ~30–80 µs;
//! SCI-JVM: ~2–10 ms.
//!
//! Target: within 3× of `(reduce + (range N))` at N=10_000 ReleaseFast.

const std = @import("std");
const util = @import("bench_util.zig");
const nanoclj = @import("nanoclj");
const Reader = nanoclj.reader.Reader;
const GC = nanoclj.gc.GC;
const Env = nanoclj.env.Env;
const value_mod = nanoclj.value;
const eval_mod = nanoclj.eval;
const compat = nanoclj.compat;
const core = nanoclj.core;

const BODY_FMT = "(loop [i 0 s 0] (if (< i {d}) (recur (+ i 1) (+ s i)) s))";

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var gc = GC.init(alloc);
    defer gc.deinit();
    var env = Env.init(alloc, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    const stdout = compat.stdoutFile();
    var out_buf: [512]u8 = undefined;

    const sizes = [_]i64{ 100, 1000, 10_000 };
    for (sizes) |n| {
        var src_buf: [96]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, BODY_FMT, .{n});
        var r = Reader.init(src, &gc);
        const form = try r.readForm();

        const Ctx = struct {
            form: value_mod.Value,
            env_p: *Env,
            gc_p: *GC,
            fn run(self: @This()) value_mod.Value {
                return eval_mod.eval(self.form, self.env_p, self.gc_p) catch value_mod.Value.makeNil();
            }
        };
        const ctx = Ctx{ .form = form, .env_p = &env, .gc_p = &gc };

        var name_buf: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "loop_tight_n{d}", .{n});
        const stats = try util.bench(alloc, name, Ctx.run, .{ctx}, .{
            .min_sample_ns = 1_000_000,
            .samples = 20,
        });
        compat.fileWriteAll(stdout, try stats.bmfLine(&out_buf));
    }
}
