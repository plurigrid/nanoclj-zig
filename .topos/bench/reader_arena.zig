//! reader_arena.zig — parse SCI's canonical microbench form, beat 528 ns.
//!
//! Head-to-head (tier 0). SCI-JVM parse of `(let [x 1 y 2] (+ x y))` =
//! 528.7 ns ± 36 ns (borkdude criterium 2020). Target <200 ns/form.
//!
//! Also reports 1 MB throughput + peak-arena ratio.

const std = @import("std");
const util = @import("bench_util.zig");
const nanoclj = @import("nanoclj");
const Reader = nanoclj.reader.Reader;
const GC = nanoclj.gc.GC;
const compat = nanoclj.compat;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const FORM = "(let [x 1 y 2] (+ x y))";

const ParseCtx = struct {
    gc_p: *GC,
    src: []const u8,
    fn run(self: @This()) u64 {
        var r = Reader.init(self.src, self.gc_p);
        var n: u64 = 0;
        while (r.readForm()) |_| {
            n +%= 1;
        } else |_| {}
        return n;
    }
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var gc = GC.init(alloc);
    defer gc.deinit();

    // A. Single-form micro-bench (SCI comparator).
    const micro_stats = try util.bench(alloc, "reader_single_form", ParseCtx.run, .{ParseCtx{ .gc_p = &gc, .src = FORM }}, .{
        .min_sample_ns = 1_000_000,
        .samples = 30,
    });

    // B. 1 MB throughput.
    const target: usize = 1 << 20;
    const buf = try alloc.alloc(u8, (target / (FORM.len + 1)) * (FORM.len + 1));
    defer alloc.free(buf);
    var off: usize = 0;
    while (off + FORM.len + 1 <= buf.len) : (off += FORM.len + 1) {
        @memcpy(buf[off .. off + FORM.len], FORM);
        buf[off + FORM.len] = ' ';
    }

    const alloc_before = gc.bytes_allocated;
    const t0 = nowNs();
    var r = Reader.init(buf, &gc);
    var forms: u64 = 0;
    while (r.readForm()) |_| {
        forms += 1;
    } else |_| {}
    const ns = nowNs() - t0;
    const peak = gc.bytes_allocated - alloc_before;

    const stdout = compat.stdoutFile();
    var out: [1024]u8 = undefined;
    compat.fileWriteAll(stdout, try micro_stats.bmfLine(&out));
    const line = try std.fmt.bufPrint(
        &out,
        "{{\"reader_1mb\":{{\"latency\":{{\"value\":{d}}},\"forms\":{{\"value\":{d}}},\"peak_alloc\":{{\"value\":{d}}},\"peak_ratio\":{{\"value\":{d:.3}}}}}}}\n",
        .{ ns, forms, peak, @as(f64, @floatFromInt(peak)) / @as(f64, @floatFromInt(buf.len)) },
    );
    compat.fileWriteAll(stdout, line);
}
