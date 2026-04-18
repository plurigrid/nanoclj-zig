//! flow_throughput.zig — `flow.Flow(V).inhabit` ops/sec, W1-shape chain.
//!
//! Dialect-profile (tier −1). Baseline: JVM flowmaps-lite + core.async
//! ~50-200 k ops/s. Target >5 M ops/s ReleaseFast.

const std = @import("std");
const util = @import("bench_util.zig");
const flow = @import("nanoclj").flow;

fn inc(inputs: []const i64) i64 {
    return inputs[0] + 1;
}

const SPEC = flow.FlowSpec(i64){
    .blocks = &.{
        .{ .id = "s", .body = .{ .seed = 42 } },
        .{ .id = "b", .body = .{ .compute = &inc } },
        .{ .id = "k", .body = .terminal },
    },
    .connections = &.{
        .{ .src = "s", .dst = "b" },
        .{ .src = "b", .dst = "k" },
    },
    .exit = "k",
};

fn oneInhabit(alloc: std.mem.Allocator) i64 {
    const exit = flow.Flow(i64).inhabit(alloc, SPEC) catch return 0;
    return exit.value orelse 0;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stats = try util.bench(alloc, "flow_inhabit_3block", oneInhabit, .{alloc}, .{
        .min_sample_ns = 5_000_000, // 5 ms / sample — allocator noise compensator
        .samples = 30,
    });

    // Derive ops/sec for human readability (BMF line already has median_ns).
    const ops_per_sec: u64 = @intFromFloat(1e9 / stats.median_ns);
    _ = ops_per_sec;

    const stdout = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var bw = std.io.fixedBufferStream(&buf);
    try stats.writeBmfLine(bw.writer());
    _ = try stdout.write(bw.getWritten());
}
