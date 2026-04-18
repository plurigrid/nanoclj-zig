//! tak_gabriel.zig — Takeuchi function (tak 18 12 6), Gabriel 1985.
//!
//! Head-to-head (tier 0). Iconic Lisp microbench from Gabriel's
//! "Performance and Evaluation of Lisp Systems" (1985). (tak 18 12 6)
//! makes ~63k recursive calls; no tail call, deep stack.
//! Reference figures (wall time):
//!   SBCL 2.1 ReleaseFast :  ~0.8 ms
//!   Chez Scheme 9       :  ~1.2 ms
//!   Gambit-C            :  ~1.5 ms
//!   Clojure JVM warm    :  ~3–8 ms
//!   SCI-JVM             :  ~50–200 ms
//! Target: within 3× of SBCL under ReleaseFast.

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

const TAK_DEF =
    \\(def tak (fn* [x y z]
    \\  (if (< y x)
    \\    (tak (tak (- x 1) y z)
    \\         (tak (- y 1) z x)
    \\         (tak (- z 1) x y))
    \\    z)))
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

    var rs = Reader.init(TAK_DEF, &gc);
    const setup = try rs.readForm();
    _ = try eval_mod.eval(setup, &env, &gc);

    var rc = Reader.init("(tak 18 12 6)", &gc);
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

    var stats = try util.bench(alloc, "tak_18_12_6", Ctx.run, .{ctx}, .{
        .min_sample_ns = 5_000_000,
        .samples = 20,
    });
    stats.alloc_bytes = alloc_per_call;

    var buf: [1024]u8 = undefined;
    compat.fileWriteAll(compat.stdoutFile(), try stats.bmfLine(&buf));
}
