//! fuel_slope.zig — regress ns ≈ α + β·n on fib(n), n ∈ {5,10,15,18,20,22}.
//!
//! Tier −1. β-slope stability between releases is the claim that our
//! fuel accounting faithfully tracks wall time. Emits one BMF row per n.
//! TODO: once eval.zig exposes a fuel counter, replace n with fuel_units.

const std = @import("std");
const util = @import("bench_util.zig");
const nanoclj = @import("nanoclj");
const Reader = nanoclj.reader.Reader;
const GC = nanoclj.gc.GC;
const Env = nanoclj.env.Env;
const value_mod = nanoclj.value;
const eval_mod = nanoclj.eval;

const SETUP = "(def fib (fn* [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var gc = GC.init(alloc);
    defer gc.deinit();
    var env = Env.init(alloc, null);
    env.is_root = true;
    defer env.deinit();
    try eval_mod.initNamespaces(alloc, &env);

    var rs = Reader.init(SETUP, &gc);
    const setup = try rs.readForm();
    _ = try eval_mod.eval(setup, &env, &gc);

    const ns_values = [_]i64{ 5, 10, 15, 18, 20, 22 };
    const stdout = std.fs.File.stdout();
    var out_buf: [512]u8 = undefined;

    for (ns_values) |n| {
        var src_buf: [64]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "(fib {d})", .{n});
        var r = Reader.init(src, &gc);
        const form = try r.readForm();

        const Ctx = struct {
            form: value_mod.Value,
            env_p: *Env,
            gc_p: *GC,
            fn run(self: @This()) value_mod.Value {
                return eval_mod.eval(self.form, self.env_p, self.gc_p) catch value_mod.Value.makeNil();
            }
        };
        const ctx = Ctx{ .form = form, .env_p = &env, .gc_p = &gc };

        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fib_n{d}", .{n});
        const stats = try util.bench(alloc, name, Ctx.run, .{ctx}, .{
            .min_sample_ns = 1_000_000,
            .samples = 20,
        });

        var bw = std.io.fixedBufferStream(&out_buf);
        try stats.writeBmfLine(bw.writer());
        _ = try stdout.write(bw.getWritten());
    }
}
