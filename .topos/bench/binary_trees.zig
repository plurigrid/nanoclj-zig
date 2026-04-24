//! binary_trees.zig — CLBG binary-trees (Boehm-style allocator stress).
//!
//! Dialect-profile (tier −1). Computer Language Benchmarks Game (CLBG)
//! binary-trees. Stresses alloc/GC: builds full binary tree of depth d,
//! counts nodes, drops. Pattern: `(count (make-tree d))` for d ∈ {8, 12}.
//!
//! Reference figures (depth 12 ≈ 8191 nodes):
//!   C gcc -O2 + tcmalloc : ~2–5 ms
//!   OCaml native         : ~5–10 ms
//!   Clojure JVM warm     : ~20–80 ms
//!   SCI-JVM              : ~200 ms – 1 s
//! Target: depth 12 alloc <2 MB; wall <30 ms ReleaseFast.

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

const TREE_DEFS =
    \\(def make-tree (fn* [d]
    \\  (if (= d 0)
    \\    (list 0 nil nil)
    \\    (let* [s (- d 1)]
    \\      (list d (make-tree s) (make-tree s))))))
    \\
    \\(def count-tree (fn* [t]
    \\  (if (nil? t) 0
    \\    (+ 1 (count-tree (first (rest t)))
    \\         (count-tree (first (rest (rest t))))))))
;

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var gc = GC.init(alloc);
    defer gc.deinit();
    var env = Env.init(alloc, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    // Setup: define make-tree and count-tree.
    // Reader consumes one form at a time; loop until EOF.
    var rs = Reader.init(TREE_DEFS, &gc);
    while (rs.readForm()) |form| {
        _ = try eval_mod.eval(form, &env, &gc);
    } else |_| {}

    const stdout = compat.stdoutFile();
    var out_buf: [512]u8 = undefined;

    const depths = [_]i64{ 6, 8, 10, 12 };
    for (depths) |d| {
        var src_buf: [96]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "(count-tree (make-tree {d}))", .{d});
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

        const alloc_before = gc.bytes_allocated;
        _ = ctx.run();
        const alloc_per_call = gc.bytes_allocated - alloc_before;

        var name_buf: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "binary_trees_d{d}", .{d});
        var stats = try util.bench(alloc, name, Ctx.run, .{ctx}, .{
            .min_sample_ns = 1_000_000,
            .samples = 20,
        });
        stats.alloc_bytes = alloc_per_call;
        compat.fileWriteAll(stdout, try stats.bmfLine(&out_buf));
    }
}
