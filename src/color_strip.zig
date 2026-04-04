//! Terminal Color Strip Renderer
//!
//! Renders SplitMix64-seeded color strips using 24-bit truecolor escapes.
//! Upper-half block (▀) with fg=top, bg=bottom → 2 color rows per line.
//! GF(3) trit conservation overlay: R(+1) G(0) B(-1).

const std = @import("std");
const substrate = @import("substrate.zig");

const compat = @import("compat.zig");
const File = compat.File;

fn filePrint(f: File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return error.NoSpaceLeft;
    compat.fileWriteAll(f, s);
}

pub fn renderStrip(f: File, seed: u64, width: u32, rows: u32) !void {
    var trit_sum: i32 = 0;
    var idx: u64 = 0;

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const top = substrate.colorAt(seed, idx);
            const bot = substrate.colorAt(seed, idx + 1);
            idx += 2;

            trit_sum += substrate.hueToTrit(substrate.rgbToHue(top.r, top.g, top.b));
            trit_sum += substrate.hueToTrit(substrate.rgbToHue(bot.r, bot.g, bot.b));

            try filePrint(f, "\x1b[38;2;{};{};{}m\x1b[48;2;{};{};{}m\xe2\x96\x80", .{
                top.r, top.g, top.b,
                bot.r, bot.g, bot.b,
            });
        }
        compat.fileWriteAll(f,"\x1b[0m\n");
    }

    const balance = @mod(trit_sum, 3);
    const sym: []const u8 = if (balance == 0) "=0 ok" else "!=0";
    try filePrint(f, "\x1b[90mseed={d} cells={d} trit_sum={d} mod3 {s}\x1b[0m\n", .{
        seed, idx, trit_sum, sym,
    });
}

pub fn renderNamedStrip(f: File, name: []const u8, width: u32, rows: u32) !void {
    var seed: u64 = 0;
    for (name) |c| {
        seed = seed *% substrate.GOLDEN +% @as(u64, c);
    }
    seed = substrate.mix64(seed);

    try filePrint(f, "\x1b[1m{s}\x1b[0m seed={x}\n", .{ name, seed });
    try renderStrip(f, seed, width, rows);
}

pub fn renderTritWheel(f: File, width: u32) !void {
    compat.fileWriteAll(f,"\x1b[1mGF(3) trit wheel\x1b[0m\n");
    const third = width / 3;

    var i: u32 = 0;
    while (i < third) : (i += 1) {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(third));
        const r: u8 = 255;
        const g: u8 = @intFromFloat(frac * 255.0);
        try filePrint(f, "\x1b[48;2;{};{};0m ", .{ r, g });
    }
    i = 0;
    while (i < third) : (i += 1) {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(third));
        const r: u8 = @intFromFloat((1.0 - frac) * 255.0);
        const g: u8 = 255;
        const b: u8 = @intFromFloat(frac * 255.0);
        try filePrint(f, "\x1b[48;2;{};{};{}m ", .{ r, g, b });
    }
    i = 0;
    while (i < width - 2 * third) : (i += 1) {
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(width - 2 * third));
        const r: u8 = @intFromFloat(frac * 255.0);
        const b: u8 = @intFromFloat((1.0 - frac) * 255.0);
        try filePrint(f, "\x1b[48;2;{};0;{}m ", .{ r, b });
    }
    compat.fileWriteAll(f,"\x1b[0m\n");
    try filePrint(f, "\x1b[90m{s:>20}{s:>27}{s:>27}\x1b[0m\n", .{ "+1 (red)", "0 (green)", "-1 (blue)" });
}

pub fn renderGapStrip(f: File, name_seed: u64, brain_seed: u64, width: u32) !void {
    compat.fileWriteAll(f,"\x1b[1mname-color vs brain-color gap\x1b[0m\n");

    var col: u32 = 0;
    while (col < width) : (col += 1) {
        const c = substrate.colorAt(name_seed, col);
        try filePrint(f, "\x1b[48;2;{};{};{}m ", .{ c.r, c.g, c.b });
    }
    compat.fileWriteAll(f,"\x1b[0m name\n");

    col = 0;
    while (col < width) : (col += 1) {
        const c = substrate.colorAt(brain_seed, col);
        try filePrint(f, "\x1b[48;2;{};{};{}m ", .{ c.r, c.g, c.b });
    }
    compat.fileWriteAll(f,"\x1b[0m brain\n");

    col = 0;
    while (col < width) : (col += 1) {
        const n = substrate.colorAt(name_seed, col);
        const b = substrate.colorAt(brain_seed, col);
        const dr = if (n.r > b.r) n.r - b.r else b.r - n.r;
        const dg = if (n.g > b.g) n.g - b.g else b.g - n.g;
        const db = if (n.b > b.b) n.b - b.b else b.b - n.b;
        try filePrint(f, "\x1b[48;2;{};{};{}m ", .{ dr, dg, db });
    }
    compat.fileWriteAll(f,"\x1b[0m gap\n");
}
