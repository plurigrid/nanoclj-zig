//! map_reduce.zig — `(reduce + (map inc (range N)))` ∀ N ∈ {100, 1000, 10000}.
//!
//! Dialect-profile (tier −1). Clojure-specific HOF dispatch + lazy-seq
//! realization. Hickey's reduce/transducer talk (Strange Loop 2014) set
//! expectations: JVM Clojure warm ~3–10 ns/element for arithmetic reduce;
//! SCI-JVM 50–200 ns/element; Babashka 30–80 ns/element.
//!
//! Target ReleaseFast: <30 ns/element at N=10000.

const std = @import("std");
const util = @import("bench_util.zig");
const nanoclj = @import("nanoclj");
const Reader = nanoclj.reader.Reader;
const GC = nanoclj.gc.GC;
const Env = nanoclj.env.Env;
const value_mod = nanoclj.value;
const eval_mod = nanoclj.eval;
const compat = nanoclj.compat;
const core = nanoclj.core;

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var gc = GC.init(alloc);
    defer gc.deinit();
    var env = Env.init(alloc, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    const stdout = compat.stdoutFile();
    var out_buf: [512]u8 = undefined;

    const sizes = [_]i64{ 100, 1000, 10_000 };
    for (sizes) |n| {
        var src_buf: [96]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "(reduce + (map inc (range {d})))", .{n});
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

        var name_buf: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "map_reduce_n{d}", .{n});
        const stats = try util.bench(alloc, name, Ctx.run, .{ctx}, .{
            .min_sample_ns = 1_000_000,
            .samples = 20,
        });
        compat.fileWriteAll(stdout, try stats.bmfLine(&out_buf));
    }
}
