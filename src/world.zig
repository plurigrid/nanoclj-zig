//! nanoclj-zig demo: 30-second showcase
//! Usage: zig build demo
//! Shows NaN-boxing, eval, color strips, GF(3) conservation in one screen.

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const substrate = @import("substrate.zig");
const color_strip = @import("color_strip.zig");

fn demoEval(input: []const u8, env: *Env, gc: *GC, f: compat.File) void {
    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch return;
    var res = semantics.Resources.initDefault();
    const domain = semantics.evalBounded(form, env, gc, &res);
    // Print input => output
    var buf: [256]u8 = undefined;
    const prompt = std.fmt.bufPrint(&buf, "  \x1b[36m>\x1b[0m {s}\n", .{input}) catch return;
    compat.fileWriteAll(f, prompt);
    switch (domain) {
        .value => |v| {
            const s = printer.prStr(v, gc, true) catch "?";
            defer if (s.len > 0) gc.allocator.free(s);
            const out = std.fmt.bufPrint(&buf, "  \x1b[32m=>\x1b[0m {s}\n", .{s}) catch return;
            compat.fileWriteAll(f, out);
        },
        .bottom => |reason| {
            const msg: []const u8 = switch (reason) {
                .fuel_exhausted => "BOTTOM: fuel exhausted",
                .depth_exceeded => "BOTTOM: depth exceeded",
                else => "BOTTOM",
            };
            const out = std.fmt.bufPrint(&buf, "  \x1b[33m=>\x1b[0m {s} (fuel used: {d})\n", .{ msg, 1_000_000 - res.fuel }) catch return;
            compat.fileWriteAll(f, out);
        },
        .err => |e| {
            const msg: []const u8 = switch (e.kind) {
                .type_error => "ERROR: type error",
                .arity_error => "ERROR: wrong arity",
                .unbound_symbol => "ERROR: unbound symbol",
                else => "ERROR",
            };
            const out = std.fmt.bufPrint(&buf, "  \x1b[31m=>\x1b[0m {s}\n", .{msg}) catch return;
            compat.fileWriteAll(f, out);
        },
    }
}

pub fn main() !void {
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gc = GC.init(allocator);
    defer gc.deinit();
    var env = Env.init(allocator, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    const f = compat.stdoutFile();
    const width: u32 = 80;

    // ── Header ──
    compat.fileWriteAll(f,"\n\x1b[1;97m");
    compat.fileWriteAll(f,"  nanoclj-zig: Clojure in ~5K lines of Zig\x1b[0m\n\n");

    // ── NaN-boxing diagram ──
    compat.fileWriteAll(f,"\x1b[1m  NaN-boxing\x1b[0m (every value = one u64):\n");
    compat.fileWriteAll(f,"  \x1b[90m┌─────┬──────────┬──┬────┬──────────────────────────────────────────┐\x1b[0m\n");
    compat.fileWriteAll(f,"  \x1b[90m│\x1b[0msign \x1b[90m│\x1b[0m exponent \x1b[90m│\x1b[0mQ \x1b[90m│\x1b[0mtag \x1b[90m│\x1b[0m payload (48 bits)                      \x1b[90m│\x1b[0m\n");
    compat.fileWriteAll(f,"  \x1b[90m└─────┴──────────┴──┴────┴──────────────────────────────────────────┘\x1b[0m\n");
    compat.fileWriteAll(f,"  \x1b[90mtag: 0=nil 1=bool 2=i48 3=sym 4=kw 5=str 6=obj  (non-NaN = float)\x1b[0m\n\n");

    // ── Eval demos ──
    compat.fileWriteAll(f,"\x1b[1m  Eval\x1b[0m (fuel-bounded, 1M steps max):\n");
    demoEval("(+ 1 2 3)", &env, &gc, f);
    demoEval("(str \"hello\" \" \" \"world\")", &env, &gc, f);
    demoEval("(let* [x 10 y 20] (* x y))", &env, &gc, f);
    demoEval("(assoc {:a 1} :b 2 :c 3)", &env, &gc, f);
    demoEval("(first [10 20 30])", &env, &gc, f);
    demoEval("(count [1 2 3 4 5])", &env, &gc, f);
    demoEval("(if (> 3 2) \"math works\" \"uh oh\")", &env, &gc, f);
    compat.fileWriteAll(f,"\n");

    // ── GF(3) algebra ──
    compat.fileWriteAll(f,"\x1b[1m  GF(3) algebra\x1b[0m (trit conservation: sum mod 3 = 0):\n");
    demoEval("(gf3-add 1 1)", &env, &gc, f);
    demoEval("(gf3-add 1 -1)", &env, &gc, f);
    demoEval("(gf3-mul -1 -1)", &env, &gc, f);
    demoEval("(color-at 1069 0)", &env, &gc, f);
    demoEval("(color-at 1069 1)", &env, &gc, f);
    compat.fileWriteAll(f,"\n");

    // ── Color strip ──
    compat.fileWriteAll(f,"\x1b[1m  Color strip\x1b[0m (SplitMix64 seed=1069, GF(3) verified):\n");
    color_strip.renderTritWheel(f, width) catch {};
    compat.fileWriteAll(f,"\n");
    color_strip.renderStrip(f, 1069, width, 2) catch {};
    compat.fileWriteAll(f,"\n");

    // ── Footer ──
    compat.fileWriteAll(f,"  \x1b[90m21 modules | 5K LOC | MIT license | zig 0.15+\x1b[0m\n");
    compat.fileWriteAll(f,"  \x1b[90mhttps://github.com/plurigrid/nanoclj-zig\x1b[0m\n\n");
}
