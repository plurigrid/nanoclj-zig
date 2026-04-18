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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

    const alloc_before = gc.totalAllocated();
    var timer = try std.time.Timer.start();
    var r = Reader.init(buf, &gc);
    var forms: u64 = 0;
    while (r.readForm()) |_| {
        forms += 1;
    } else |_| {}
    const ns = timer.read();
    const peak = gc.totalAllocated() - alloc_before;

    const stdout = std.fs.File.stdout();
    var out: [2048]u8 = undefined;
    var bw = std.io.fixedBufferStream(&out);
    try micro_stats.writeBmfLine(bw.writer());
    try bw.writer().print(
        "{{\"reader_1mb\":{{\"latency\":{{\"value\":{d}}},\"forms\":{{\"value\":{d}}},\"peak_alloc\":{{\"value\":{d}}},\"peak_ratio\":{{\"value\":{d:.3}}}}}}}\n",
        .{ ns, forms, peak, @as(f64, @floatFromInt(peak)) / @as(f64, @floatFromInt(buf.len)) },
    );
    _ = try stdout.write(bw.getWritten());
}
