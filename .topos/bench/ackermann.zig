//! ackermann.zig — (ack 3 7) = 1021.
//!
//! Head-to-head (tier 0). Classic stack-depth torture test.
//! (ack 3 7) ≈ 2.7M recursive calls; Sussman/Abelson SICP §1.2.2.
//! Reference figures:
//!   C gcc -O2         :  ~0.8 ms
//!   SBCL              :  ~2–5 ms
//!   Racket            :  ~10–25 ms
//!   Clojure JVM warm  :  ~30–80 ms
//!   SCI-JVM           :  ~500 ms – 2 s
//! Target: within 20× of SBCL under ReleaseFast, no stack overflow.

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

const ACK_DEF =
    \\(def ack (fn* [m n]
    \\  (if (= m 0) (+ n 1)
    \\    (if (= n 0) (ack (- m 1) 1)
    \\      (ack (- m 1) (ack m (- n 1)))))))
;

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var gc = GC.init(alloc);
    defer gc.deinit();
    var env = Env.init(alloc, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    var rs = Reader.init(ACK_DEF, &gc);
    const setup = try rs.readForm();
    _ = try eval_mod.eval(setup, &env, &gc);

    var rc = Reader.init("(ack 3 7)", &gc);
    const call = try rc.readForm();

    const Ctx = struct {
        form: value_mod.Value,
        env_p: *Env,
        gc_p: *GC,
        fn run(self: @This()) value_mod.Value {
            return eval_mod.eval(self.form, self.env_p, self.gc_p) catch value_mod.Value.makeNil();
        }
    };
    const ctx = Ctx{ .form = call, .env_p = &env, .gc_p = &gc };

    const alloc_before = gc.bytes_allocated;
    _ = ctx.run();
    const alloc_per_call = gc.bytes_allocated - alloc_before;

    var stats = try util.bench(alloc, "ack_3_7", Ctx.run, .{ctx}, .{
        .min_sample_ns = 5_000_000,
        .samples = 20,
    });
    stats.alloc_bytes = alloc_per_call;

    var buf: [1024]u8 = undefined;
    compat.fileWriteAll(compat.stdoutFile(), try stats.bmfLine(&buf));
}
