//! nanbox_fib.zig — fib(25) under NaN-boxed eval loop vs Zig baseline.
//!
//! Head-to-head (tier 0). Exa precedent (Brion Vibber 2018):
//! heap-boxed doubles 2677 ms, NaN-boxed 48 ms (56×), NaN-boxed + return-
//! type special 17 ms. Bigloo self-tagging (Melançon 2025): 2.4× on
//! float-heavy R7RS, ≈0 allocs in fibfp inner loop.
//!
//! Target: 0 allocs in fib inner loop; wall within 2× of hand-written Zig.

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

const FIB_DEF = "(def fib (fn* [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))";

fn fibZig(n: i64) i64 {
    if (n < 2) return n;
    return fibZig(n - 1) + fibZig(n - 2);
}

// Hide n from comptime/const-prop so LLVM can't precompute fib(25)=75025.
var fib_n_runtime: i64 = 25;

const FibZigCtx = struct {
    n_ptr: *volatile i64,
    fn run(self: @This()) i64 {
        return fibZig(self.n_ptr.*);
    }
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    // -------- Zig baseline --------
    // volatile ptr blocks const-prop so LLVM can't precompute fib(25).
    const fib_zig_ctx = FibZigCtx{ .n_ptr = @ptrCast(&fib_n_runtime) };
    const zig_stats = try util.bench(alloc, "fib25_zig", FibZigCtx.run, .{fib_zig_ctx}, .{
        .min_sample_ns = 1_000_000,
        .samples = 30,
    });

    // -------- nanoclj eval --------
    var gc = GC.init(alloc);
    defer gc.deinit();
    var env = Env.init(alloc, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    var rs = Reader.init(FIB_DEF, &gc);
    const setup = try rs.readForm();
    _ = try eval_mod.eval(setup, &env, &gc);

    var rc = Reader.init("(fib 25)", &gc);
    const call = try rc.readForm();

    const CallCtx = struct {
        form: value_mod.Value,
        env_p: *Env,
        gc_p: *GC,
        fn run(self: @This()) value_mod.Value {
            return eval_mod.eval(self.form, self.env_p, self.gc_p) catch value_mod.Value.makeNil();
        }
    };
    const cctx = CallCtx{ .form = call, .env_p = &env, .gc_p = &gc };

    // Measure allocation delta across one call.
    const alloc_before = gc.bytes_allocated;
    _ = cctx.run();
    const alloc_per_call = gc.bytes_allocated - alloc_before;

    var clj_stats = try util.bench(alloc, "fib25_nanoclj", CallCtx.run, .{cctx}, .{
        .min_sample_ns = 1_000_000,
        .samples = 30,
    });
    clj_stats.alloc_bytes = alloc_per_call;

    const stdout = compat.stdoutFile();
    var buf: [1024]u8 = undefined;
    compat.fileWriteAll(stdout, try zig_stats.bmfLine(&buf));
    compat.fileWriteAll(stdout, try clj_stats.bmfLine(&buf));
}
