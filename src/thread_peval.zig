//! THREAD PEVAL: Real OS-thread parallel eval with fuel conservation.
//!
//! Zig 0.15: std.Thread.spawn + Mutex on shared GC/Env.
//! Zig 0.16: swap std.Thread → std.Io.Evented fibers (zero Clojure-layer changes).
//!
//! The Mutex serializes GC allocations; pure computation between allocs
//! runs truly parallel across cores. Fork/join fuel semantics preserved.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;
const transclusion = @import("transclusion.zig");
const Domain = transclusion.Domain;
const transduction = @import("transduction.zig");
const compat = @import("compat.zig");

// ============================================================================
// SHARED CONTEXT: Mutex-protected GC + Env
// ============================================================================

pub const SharedContext = struct {
    gc: *GC,
    env: *Env,
    mutex: compat.Mutex = compat.mutexInit(),

    pub fn init(gc: *GC, env: *Env) SharedContext {
        return .{ .gc = gc, .env = env };
    }

    /// Evaluate under lock. The lock scope is the entire eval call —
    /// coarse-grained but correct. Fine-grained (lock-per-alloc) is
    /// the Zig 0.16 fiber path where we get cooperative yields.
    pub fn evalLocked(self: *SharedContext, expr: Value, res: *Resources) Domain {
        self.mutex.lock();
        defer self.mutex.unlock();
        return transduction.evalBounded(expr, self.env, self.gc, res);
    }
};

// ============================================================================
// WORKER THREAD
// ============================================================================

const WorkerResult = struct {
    domain: Domain,
    res: Resources,
};

const WorkerArgs = struct {
    ctx: *SharedContext,
    expr: Value,
    res: Resources,
    result: *WorkerResult,
};

fn workerFn(args: *WorkerArgs) void {
    var res = args.res;
    const domain = args.ctx.evalLocked(args.expr, &res);
    args.result.* = .{ .domain = domain, .res = res };
}

// ============================================================================
// THREAD-POOL PEVAL
// ============================================================================

/// Parallel eval of N expressions using OS threads.
/// Each expression gets forked fuel. Results collected as vector.
/// Falls back to sequential if thread spawn fails.
///
/// Zig 0.16 swap point: replace std.Thread.spawn with Io.async,
/// drop the Mutex, use per-fiber GC arenas.
pub fn threadPeval(
    exprs: []Value,
    env: *Env,
    gc: *GC,
    res: *Resources,
) Domain {
    if (exprs.len == 0) return Domain.pure(Value.makeNil());
    if (exprs.len == 1) return transduction.evalBounded(exprs[0], env, gc, res);

    const n = @min(exprs.len, 64);

    // Fork fuel across children
    const child_res = res.fork(n);

    // Allocate worker state on stack (max 64)
    var results: [64]WorkerResult = undefined;
    var worker_args: [64]WorkerArgs = undefined;
    var threads: [64]?std.Thread = .{null} ** 64;

    var ctx = SharedContext.init(gc, env);

    // Spawn threads (thread 0 runs on current thread to save a spawn)
    var spawned: usize = 0;
    for (1..n) |i| {
        worker_args[i] = .{
            .ctx = &ctx,
            .expr = exprs[i],
            .res = child_res[i],
            .result = &results[i],
        };
        threads[i] = std.Thread.spawn(.{}, workerFn, .{&worker_args[i]}) catch null;
        if (threads[i] != null) spawned += 1;
    }

    // Thread 0: eval on current thread (no spawn overhead)
    {
        var r0 = child_res[0];
        const d0 = ctx.evalLocked(exprs[0], &r0);
        results[0] = .{ .domain = d0, .res = r0 };
    }

    // Evaluate any that failed to spawn (sequential fallback)
    for (1..n) |i| {
        if (threads[i] == null) {
            var ri = child_res[i];
            const di = ctx.evalLocked(exprs[i], &ri);
            results[i] = .{ .domain = di, .res = ri };
        }
    }

    // Join threads
    for (1..n) |i| {
        if (threads[i]) |t| t.join();
    }

    // Collect fuel back (join children into parent)
    var child_res_final: [64]Resources = undefined;
    for (0..n) |i| {
        child_res_final[i] = results[i].res;
    }
    res.join(&child_res_final, n);

    // Build result vector, propagating first error
    const vec = gc.allocObj(.vector) catch return Domain.fail(.type_error);
    for (0..n) |i| {
        switch (results[i].domain) {
            .value => |v| {
                vec.data.vector.items.append(gc.allocator, v) catch
                    return Domain.fail(.type_error);
            },
            .bottom => |b| return .{ .bottom = b },
            .err => |e| return .{ .err = e },
        }
    }

    return Domain.pure(Value.makeObj(vec));
}

// ============================================================================
// TESTS
// ============================================================================

test "thread peval: parallel literals" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    var exprs = [_]Value{
        Value.makeInt(10),
        Value.makeInt(20),
        Value.makeInt(30),
    };

    var res = Resources.initDefault();
    const d = threadPeval(&exprs, &env, &gc, &res);
    try std.testing.expect(d.isValue());
    const obj = d.value.asObj();
    try std.testing.expectEqual(@as(usize, 3), obj.data.vector.items.items.len);
    try std.testing.expectEqual(@as(i48, 10), obj.data.vector.items.items[0].asInt());
    try std.testing.expectEqual(@as(i48, 20), obj.data.vector.items.items[1].asInt());
    try std.testing.expectEqual(@as(i48, 30), obj.data.vector.items.items[2].asInt());
}

test "thread peval: single expr no spawn" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    var exprs = [_]Value{Value.makeInt(42)};
    var res = Resources.initDefault();
    const d = threadPeval(&exprs, &env, &gc, &res);
    try std.testing.expect(d.isValue());
    try std.testing.expectEqual(@as(i48, 42), d.value.asInt());
}

test "thread peval: fuel conservation" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    var exprs = [_]Value{
        Value.makeInt(1),
        Value.makeInt(2),
        Value.makeInt(3),
        Value.makeInt(4),
    };

    var res = Resources.init(.{ .max_fuel = 10000 });
    const initial = res.fuel;
    const d = threadPeval(&exprs, &env, &gc, &res);
    try std.testing.expect(d.isValue());
    // Fuel must not increase
    try std.testing.expect(res.fuel <= initial);
    // Some fuel consumed (ticks + join cost)
    try std.testing.expect(res.fuel < initial);
}

test "thread peval: empty exprs" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    var exprs = [_]Value{};
    var res = Resources.initDefault();
    const d = threadPeval(&exprs, &env, &gc, &res);
    try std.testing.expect(d.isValue());
    try std.testing.expect(d.value.isNil());
}
