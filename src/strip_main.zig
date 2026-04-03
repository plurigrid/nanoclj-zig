//! nanoclj-strip: Terminal color strip demo
//! Usage: nanoclj-strip [name] [width] [rows]

const std = @import("std");
const color_strip = @import("color_strip.zig");
const substrate = @import("substrate.zig");

pub fn main() !void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var args = std.process.args();
    _ = args.skip();

    const name = args.next() orelse "bci.horse";
    const width: u32 = if (args.next()) |w| std.fmt.parseInt(u32, w, 10) catch 80 else 80;
    const rows: u32 = if (args.next()) |r| std.fmt.parseInt(u32, r, 10) catch 8 else 8;

    try color_strip.renderTritWheel(stdout, width);
    try stdout.writeAll("\n");
    try color_strip.renderNamedStrip(stdout, name, width, rows);
    try stdout.writeAll("\n");

    var name_seed: u64 = 0;
    for (name) |c| {
        name_seed = name_seed *% substrate.GOLDEN +% @as(u64, c);
    }
    name_seed = substrate.mix64(name_seed);
    try color_strip.renderGapStrip(stdout, name_seed, substrate.CANONICAL_SEED, width);
}
