//! assoc_growth.zig — persistent-map `assoc` growth to N kvs.
//!
//! Dialect-profile (tier −1). Bagwell/Hickey HAMT paper claim: O(log32 N)
//! assoc. Clojure-JVM warm: ~100–300 ns per assoc at N=1000; full loop
//! 100–300 µs. SCI-JVM ~5× slower. Persistent-map structural sharing
//! means total bytes_allocated should grow O(N log N), not O(N²).
//!
//! Target: linearithmic alloc growth, <1 µs/assoc at N=1000 ReleaseFast.

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

const BODY_FMT = "(loop [m {{}} i 0] (if (< i {d}) (recur (assoc m i (* i i)) (inc i)) (count m)))";

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

    const sizes = [_]i64{ 32, 128, 1024 };
    for (sizes) |n| {
        var src_buf: [128]u8 = undefined;
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

        const alloc_before = gc.bytes_allocated;
        _ = ctx.run();
        const alloc_per_call = gc.bytes_allocated - alloc_before;

        var name_buf: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "assoc_growth_n{d}", .{n});
        var stats = try util.bench(alloc, name, Ctx.run, .{ctx}, .{
            .min_sample_ns = 1_000_000,
            .samples = 20,
        });
        stats.alloc_bytes = alloc_per_call;
        compat.fileWriteAll(stdout, try stats.bmfLine(&out_buf));
    }
}
