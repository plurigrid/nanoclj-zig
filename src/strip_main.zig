//! nanoclj-strip: Terminal color strip demo
//! Usage: nanoclj-strip [name] [width] [rows]

const std = @import("std");
const compat = @import("compat.zig");
const color_strip = @import("color_strip.zig");
const substrate = @import("substrate.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const stdout = compat.stdoutFile();
    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.next(); // skip argv[0]

    const name = args_iter.next() orelse "bci.horse";
    const width: u32 = if (args_iter.next()) |w| std.fmt.parseInt(u32, w, 10) catch 80 else 80;
    const rows: u32 = if (args_iter.next()) |r| std.fmt.parseInt(u32, r, 10) catch 8 else 8;

    try color_strip.renderTritWheel(stdout, width);
    compat.fileWriteAll(stdout, "\n");
    try color_strip.renderNamedStrip(stdout, name, width, rows);
    compat.fileWriteAll(stdout, "\n");

    var name_seed: u64 = 0;
    for (name) |c| {
        name_seed = name_seed *% substrate.GOLDEN +% @as(u64, c);
    }
    name_seed = substrate.mix64(name_seed);
    try color_strip.renderGapStrip(stdout, name_seed, substrate.CANONICAL_SEED, width);
}
