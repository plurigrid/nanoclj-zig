//! Device-free feasibility harness using the existing reader and evaluator.
//! One interpreter lifetime; FixedBufferAllocator is a bounded arena, not a
//! reclaiming embedded heap. No claims about arbitrary/untrusted programs.
const std = @import("std");
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const Value = @import("value.zig").Value;

pub const heap_capacity = 256 * 1024;
var heap: [heap_capacity]u8 align(16) = undefined;

pub const Report = extern struct {
    status: u32 = 0xffffffff,
    passed: u32 = 0,
    heap_peak: u32 = 0,
    heap_used: u32 = 0,
    max_eval_depth: u32 = 0,
    value_bytes: u32 = @sizeOf(Value),
    object_bytes: u32 = @sizeOf(@import("value.zig").Obj),
    gc_bytes: u32 = @sizeOf(GC),
    env_bytes: u32 = @sizeOf(Env),
};
export var nanoclj_probe_report: Report = .{};
var already_run = false;

// Track the arena cursor after every allocator operation, including transient
// allocations. This includes alignment waste and retained superseded buffers.
const MeasuredArena = struct {
    fba: std.heap.FixedBufferAllocator,
    peak: usize = 0,

    fn allocator(self: *MeasuredArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn cast(ctx: *anyopaque) *MeasuredArena {
        return @ptrCast(@alignCast(ctx));
    }
    fn record(self: *MeasuredArena) void {
        self.peak = @max(self.peak, self.fba.end_index);
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = cast(ctx);
        const result = self.fba.allocator().rawAlloc(n, alignment, ra);
        self.record();
        return result;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const self = cast(ctx);
        const result = self.fba.allocator().rawResize(buf, alignment, n, ra);
        self.record();
        return result;
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self = cast(ctx);
        const result = self.fba.allocator().rawRemap(buf, alignment, n, ra);
        self.record();
        return result;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self = cast(ctx);
        self.fba.allocator().rawFree(buf, alignment, ra);
        self.record();
    }
};

fn evaluate(src: []const u8, gc: *GC, env: *Env, limits: semantics.Limits) !semantics.Domain {
    var reader = Reader.init(src, gc);
    const form = try reader.readForm();
    var resources = semantics.Resources.init(limits);
    const result = semantics.evalBounded(form, env, gc, &resources);
    nanoclj_probe_report.max_eval_depth = @max(nanoclj_probe_report.max_eval_depth, resources.max_depth_seen);
    return result;
}

fn run(arena: *MeasuredArena) u32 {
    var gc = GC.init(arena.allocator());
    var env = Env.init(arena.allocator(), null);
    env.is_root = true;
    core.initMinimalCore(&env, &gc) catch return 1;
    defer core.deinitCore();
    // All GC/env storage belongs to the arena; no OS allocator or GC sweep.
    const cases = [_]struct { source: []const u8, expected: i48 }{
        .{ .source = "(+ 20 22)", .expected = 42 },
        .{ .source = "(let* [x 6 y 7] (* x y))", .expected = 42 },
        .{ .source = "((fn* [x] (+ x 2)) 40)", .expected = 42 },
        .{ .source = "(if (< 2 3) 42 0)", .expected = 42 },
        .{ .source = "(do (def answer 42) answer)", .expected = 42 },
        .{ .source = "(count [1 2 3])", .expected = 3 },
        .{ .source = "(first '(42 7))", .expected = 42 },
        .{ .source = "(loop [n 5 acc 0] (if (= n 0) acc (recur (- n 1) (+ acc n))))", .expected = 15 },
    };
    for (cases, 0..) |case, i| {
        const result = evaluate(case.source, &gc, &env, .{ .max_fuel = 10000, .max_depth = 16 }) catch return @intCast(10 + i);
        if (result != .value or !result.value.isInt() or result.value.asInt() != case.expected) return @intCast(30 + i);
        nanoclj_probe_report.passed += 1;
    }
    const unbound = evaluate("missing-symbol", &gc, &env, .{}) catch return 50;
    if (unbound != .err or unbound.err.kind != .unbound_symbol) return 51;
    nanoclj_probe_report.passed += 1;
    const fuel = evaluate("(loop [n 0] (recur (+ n 1)))", &gc, &env, .{ .max_fuel = 32, .max_depth = 16 }) catch return 52;
    if (fuel != .bottom or fuel.bottom != .fuel_exhausted) return 53;
    nanoclj_probe_report.passed += 1;
    const depth = evaluate("(+ 1 (+ 2 3))", &gc, &env, .{ .max_fuel = 10000, .max_depth = 2 }) catch return 54;
    if (depth != .bottom or depth.bottom != .depth_exceeded) return 55;
    nanoclj_probe_report.passed += 1;
    var broken = Reader.init("(", &gc);
    if (broken.readForm()) |_| return 56 else |err| {
        if (err != error.UnexpectedEOF) return 57;
    }
    nanoclj_probe_report.passed += 1;
    var tiny: [8]u8 = undefined;
    var tiny_fba = std.heap.FixedBufferAllocator.init(&tiny);
    var tiny_gc = GC.init(tiny_fba.allocator());
    var oom_reader = Reader.init("[1 2 3]", &tiny_gc);
    if (oom_reader.readForm()) |_| return 58 else |err| {
        if (err != error.OutOfMemory) return 59;
    }
    nanoclj_probe_report.passed += 1;
    return 0;
}

export fn nanoclj_smoke() u32 {
    if (already_run) return nanoclj_probe_report.status;
    already_run = true;
    var arena = MeasuredArena{ .fba = std.heap.FixedBufferAllocator.init(&heap) };
    const status = run(&arena);
    nanoclj_probe_report.heap_peak = @intCast(arena.peak);
    nanoclj_probe_report.heap_used = @intCast(arena.fba.end_index);
    nanoclj_probe_report.status = status;
    return status;
}

// Native smoke execution also exercises safety checks when built ReleaseSafe.
// The RV32 executable uses the separate assembly _start, never this main.
pub fn main() !void {
    if (nanoclj_smoke() != 0 or nanoclj_probe_report.passed != 13) return error.SmokeFailed;
}
