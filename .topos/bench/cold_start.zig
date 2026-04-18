//! cold_start.zig — init GC+Env+namespaces, eval `(+ 1 2)`, exit.
//!
//! Head-to-head (GF(3) tier 0): vs JVM Clojure 1-2 s, Babashka 20-60 ms,
//! SCI-GraalVM native 50-150 ms. Target <1 ms ReleaseFast.
//!
//! Each sample = a full fresh init. We don't batch — cold start *is* the
//! measurement — but we do collect ≥30 samples for median+CV%.

const std = @import("std");
const util = @import("bench_util.zig");
const nanoclj = @import("nanoclj");
const Reader = nanoclj.reader.Reader;
const GC = nanoclj.gc.GC;
const Env = nanoclj.env.Env;
const eval_mod = nanoclj.eval;

const N_SAMPLES: usize = 30;
const WARMUP: usize = 3;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var samples_buf: [N_SAMPLES + WARMUP]f64 = undefined;
    for (0..N_SAMPLES + WARMUP) |i| {
        var timer = try std.time.Timer.start();
        var gc = GC.init(alloc);
        defer gc.deinit();
        var env = Env.init(alloc, null);
        env.is_root = true;
        defer env.deinit();
        try eval_mod.initNamespaces(alloc, &env);

        var r = Reader.init("(+ 1 2)", &gc);
        const form = try r.readForm();
        const result = try eval_mod.eval(form, &env, &gc);
        std.mem.doNotOptimizeAway(result);

        samples_buf[i] = @as(f64, @floatFromInt(timer.read()));
    }

    const stats = try util.summarize(alloc, "cold_start", samples_buf[WARMUP..]);
    const stdout = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var bw = std.io.fixedBufferStream(&buf);
    try stats.writeBmfLine(bw.writer());
    _ = try stdout.write(bw.getWritten());
}
