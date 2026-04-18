//! bench_util.zig — shared harness for .topos/bench/*.zig.
//!
//! Design from exa (2026-04-18):
//! - Adaptive batching (pyk 2025-12) — scale batch until one sample ≥ 1 ms,
//!   so clock_gettime 20-40 ns latency doesn't dominate sub-ns ops.
//! - Median + CV% (benchmark_harness_plus) — robust vs GC/OS outliers.
//! - BMF JSON (Bencher) — streams to stdout for continuous-benchmarking CI.
//! - std.mem.doNotOptimizeAway — kills dead-code elimination.

const std = @import("std");

pub const Options = struct {
    min_sample_ns: u64 = 1_000_000, // 1 ms per sample
    samples: u64 = 30,
    warmup: u64 = 3,
};

pub const Stats = struct {
    name: []const u8,
    iters: u64,
    batch_size: u64,
    min_ns: f64,
    median_ns: f64,
    mean_ns: f64,
    max_ns: f64,
    stddev_ns: f64,
    cv_pct: f64,
    alloc_bytes: u64 = 0,

    /// Emit one BMF line so `bencher run --adapter json` can ingest it.
    pub fn writeBmfLine(self: Stats, w: anytype) !void {
        try w.print(
            "{{\"{s}\":{{\"latency\":{{\"value\":{d:.2},\"lower_value\":{d:.2},\"upper_value\":{d:.2}}}",
            .{ self.name, self.median_ns, self.min_ns, self.max_ns },
        );
        if (self.alloc_bytes > 0) {
            try w.print(",\"allocated\":{{\"value\":{d}}}", .{self.alloc_bytes});
        }
        try w.print(
            ",\"cv_pct\":{{\"value\":{d:.2}}},\"batch\":{{\"value\":{d}}}}}}}\n",
            .{ self.cv_pct, self.batch_size },
        );
    }
};

/// Run `func(args)` under adaptive batching; return statistics.
pub fn bench(
    alloc: std.mem.Allocator,
    name: []const u8,
    comptime func: anytype,
    args: anytype,
    opts: Options,
) !Stats {
    var timer = try std.time.Timer.start();

    // 1. Calibrate batch so one sample ≥ min_sample_ns.
    var batch: u64 = 1;
    while (true) {
        timer.reset();
        for (0..batch) |_| {
            const r = @call(.auto, func, args);
            std.mem.doNotOptimizeAway(r);
        }
        const elapsed = timer.read();
        if (elapsed >= opts.min_sample_ns) break;
        const ratio_f = @as(f64, @floatFromInt(opts.min_sample_ns)) /
            @as(f64, @floatFromInt(@max(elapsed, 1)));
        const new_batch: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(batch)) * ratio_f));
        batch = @max(new_batch, batch + 1);
        if (batch > 1_000_000_000) break;
    }

    // 2. Warmup (thrown away).
    for (0..opts.warmup) |_| {
        timer.reset();
        for (0..batch) |_| {
            const r = @call(.auto, func, args);
            std.mem.doNotOptimizeAway(r);
        }
        _ = timer.read();
    }

    // 3. Collect samples → per-op ns.
    const samples = try alloc.alloc(f64, opts.samples);
    defer alloc.free(samples);
    for (0..opts.samples) |i| {
        timer.reset();
        for (0..batch) |_| {
            const r = @call(.auto, func, args);
            std.mem.doNotOptimizeAway(r);
        }
        const elapsed = timer.read();
        samples[i] = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(batch));
    }

    return computeStats(name, samples, batch);
}

/// When you need to time a heavyweight op without batching (e.g. cold
/// start where init() is intrinsic to the measurement), call this per
/// sample and aggregate externally via `summarize`.
pub fn summarize(alloc: std.mem.Allocator, name: []const u8, samples_ns: []f64) !Stats {
    const scratch = try alloc.alloc(f64, samples_ns.len);
    defer alloc.free(scratch);
    @memcpy(scratch, samples_ns);
    return computeStats(name, scratch, 1);
}

fn computeStats(name: []const u8, samples: []f64, batch: u64) Stats {
    std.sort.insertion(f64, samples, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / @as(f64, @floatFromInt(samples.len));
    var var_sum: f64 = 0;
    for (samples) |s| {
        const d = s - mean;
        var_sum += d * d;
    }
    const stddev = @sqrt(var_sum / @as(f64, @floatFromInt(samples.len)));
    const median = samples[samples.len / 2];
    return .{
        .name = name,
        .iters = samples.len * batch,
        .batch_size = batch,
        .min_ns = samples[0],
        .median_ns = median,
        .mean_ns = mean,
        .max_ns = samples[samples.len - 1],
        .stddev_ns = stddev,
        .cv_pct = if (mean > 0) (stddev / mean) * 100.0 else 0,
    };
}
