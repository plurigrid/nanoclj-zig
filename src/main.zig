const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const color_strip = @import("color_strip.zig");
const substrate = @import("substrate.zig");
const bc = @import("bytecode.zig");
const Compiler = @import("compiler.zig").Compiler;

fn nanoNow() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}
pub const llm = @import("llm.zig");

/// Bounded REP: uses fuel-bounded eval from semantics.zig.
/// Defends against: infinite loops (fuel), deep recursion (depth),
/// while maintaining denotational/operational agreement.
fn rep(input: []const u8, env: *Env, gc: *GC) ![]const u8 {
    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch |err| {
        return switch (err) {
            error.UnexpectedEOF => "Error: unexpected EOF",
            error.UnmatchedParen => "Error: unmatched )",
            error.UnmatchedBracket => "Error: unmatched ]",
            error.UnmatchedBrace => "Error: unmatched }",
            error.InvalidNumber => "Error: invalid number",
            error.UnexpectedChar => "Error: unexpected character",
            else => "Error: read failed",
        };
    };

    // Fuel-bounded eval: guaranteed termination
    var res = semantics.Resources.initDefault();
    const domain = semantics.evalBounded(form, env, gc, &res);

    return switch (domain) {
        .value => |v| printer.prStr(v, gc, true) catch "Error: print failed",
        .bottom => |reason| switch (reason) {
            .fuel_exhausted => "Error: computation exceeded fuel limit (possible infinite loop)",
            .depth_exceeded => "Error: recursion depth exceeded (possible stack bomb)",
            .read_depth_exceeded => "Error: nesting too deep",
            .divergent => "Error: divergent computation",
        },
        .err => |e| switch (e.kind) {
            .unbound_symbol => "Error: symbol not found",
            .not_a_function => "Error: not a function",
            .arity_error => "Error: wrong number of arguments",
            .type_error => "Error: type error",
            .overflow => "Error: integer overflow",
            .division_by_zero => "Error: division by zero",
            .index_out_of_bounds => "Error: index out of bounds",
            .malformed_input => "Error: malformed input",
            .collection_too_large => "Error: collection too large",
            .string_too_long => "Error: string too long",
            .invalid_syntax => "Error: invalid syntax",
        },
    };
}

/// Bytecode REP: parse -> compile -> VM execute (uses persistent VM for globals)
fn bcRep(input: []const u8, gc: *GC, allocator: std.mem.Allocator, vm: *bc.VM) []const u8 {
    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch return "Error: read failed";

    var comp = Compiler.init(allocator, gc, null);
    defer comp.deinit();

    const dest = comp.allocReg() catch return "Error: too many registers";
    comp.compile(form, dest) catch return "Error: compilation failed";
    comp.emit(bc.encode_d(.ret, dest)) catch return "Error: emit failed";

    const func_def = comp.finalize() catch return "Error: finalize failed";

    const closure_obj = gc.allocObj(.bc_closure) catch return "Error: alloc failed";
    closure_obj.data.bc_closure = .{
        .def = func_def,
        .upvalues = &.{},
    };

    // Reset VM state for new execution but keep globals
    vm.frame_count = 0;
    vm.fuel = 100_000_000;
    @memset(&vm.stack, Value.makeNil());

    const result = vm.execute(&closure_obj.data.bc_closure) catch |err| return switch (err) {
        error.FuelExhausted => "Error: fuel exhausted",
        error.StackOverflow => "Error: stack overflow",
        error.TypeError => "Error: type error",
        error.ArityError => "Error: arity error",
        error.UndefinedGlobal => "Error: undefined global",
    };

    return printer.prStr(result, gc, true) catch "Error: print failed";
}

/// Benchmark: run bytecode VM and tree-walk on same expression, return timing
fn benchRep(input: []const u8, env: *Env, gc: *GC, allocator: std.mem.Allocator) []const u8 {
    // Tree-walk timing
    var reader1 = Reader.init(input, gc);
    const form1 = reader1.readForm() catch return "Error: read failed";
    const tw_start = nanoNow();
    var res = semantics.Resources.initDefault();
    const tw_result = semantics.evalBounded(form1, env, gc, &res);
    const tw_end = nanoNow();
    const tw_ns: u64 = @intCast(tw_end - tw_start);

    const tw_str = switch (tw_result) {
        .value => |v| printer.prStr(v, gc, true) catch "?",
        else => "bottom/err",
    };

    // Bytecode timing
    var reader2 = Reader.init(input, gc);
    const form2 = reader2.readForm() catch return "Error: read failed";

    var comp = Compiler.init(allocator, gc, null);
    defer comp.deinit();
    const dest = comp.allocReg() catch return "Error: compile failed";
    comp.compile(form2, dest) catch return "Error: compile failed";
    comp.emit(bc.encode_d(.ret, dest)) catch return "Error: emit failed";
    const func_def = comp.finalize() catch return "Error: finalize failed";

    const closure_obj = gc.allocObj(.bc_closure) catch return "Error: alloc failed";
    closure_obj.data.bc_closure = .{ .def = func_def, .upvalues = &.{} };

    var vm = bc.VM.init(gc, 1_000_000_000);
    defer vm.deinit();

    const bc_start = nanoNow();
    const bc_result = vm.execute(&closure_obj.data.bc_closure) catch {
        return "Error: VM execution failed";
    };
    const bc_end = nanoNow();
    const bc_ns: u64 = @intCast(bc_end - bc_start);

    const bc_str = printer.prStr(bc_result, gc, true) catch "?";

    // Format result
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "tree-walk: {s} in {d}ms | bytecode: {s} in {d}ms | speedup: {d:.1}x", .{
        tw_str,
        tw_ns / 1_000_000,
        bc_str,
        bc_ns / 1_000_000,
        @as(f64, @floatFromInt(tw_ns)) / @as(f64, @floatFromInt(@max(bc_ns, 1))),
    }) catch return "Error: format failed";

    return allocator.dupe(u8, out) catch "Error: alloc failed";
}

pub fn main() !void {
    const compat = @import("compat.zig");
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
    const tree_vfs = @import("tree_vfs.zig");
    defer tree_vfs.deinitForest();
    const inet_builtins = @import("inet_builtins.zig");
    defer inet_builtins.deinitNets();

    // First Futamura projection: PE constant bindings through inet
    const peval = @import("peval.zig");
    const pe_count = peval.pevalEnv(&env, &gc);
    _ = pe_count;

    const stdout = compat.stdoutFile();
    const stdin_file = compat.stdinFile();

    // ── Demo: color strip banner ──────────────────────────────────
    // Detect terminal width (fallback 80)
    const width: u32 = 80;

    compat.fileWriteAll(stdout, "\x1b[1mnanoclj-zig v0.1.0\x1b[0m\n");
    color_strip.renderTritWheel(stdout, width) catch {};
    compat.fileWriteAll(stdout, "\n");

    // Seed from hostname or "world"
    const world_name: []const u8 = if (std.c.getenv("USER")) |c| std.mem.span(c) else "world";

    color_strip.renderNamedStrip(stdout, world_name, width, 2) catch {};
    compat.fileWriteAll(stdout, "\n");

    // Bind world identity into env
    const world_sym = gc.internString("*world*") catch 0;
    const world_str = gc.internString(world_name) catch 0;
    env.set(gc.getString(world_sym), Value.makeString(world_str)) catch {};

    // Compute and bind seed
    var world_seed: u64 = 0;
    for (world_name) |c| {
        world_seed = world_seed *% substrate.GOLDEN +% @as(u64, c);
    }
    world_seed = substrate.mix64(world_seed);
    const seed_sym = gc.internString("*seed*") catch 0;
    env.set(gc.getString(seed_sym), Value.makeInt(@bitCast(@as(u48, @truncate(world_seed))))) catch {};

    // ── Bytecode VM (persistent across REPL) ──────────────────────
    var vm = bc.VM.init(&gc, 100_000_000);
    defer vm.deinit();

    // ── REPL: world=> ─────────────────────────────────────────────
    while (true) {
        // Prompt with world name
        var prompt_buf: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "\x1b[36m{s}\x1b[0m=> ", .{world_name}) catch "world=> ";
        compat.fileWriteAll(stdout, prompt);

        var line_buf = @import("compat.zig").emptyList(u8);
        defer line_buf.deinit(allocator);
        while (true) {
            var byte: [1]u8 = undefined;
            const n = compat.fileRead(stdin_file, &byte);
            if (n == 0) {
                if (line_buf.items.len == 0) {
                    compat.fileWriteAll(stdout, "\n");
                    return;
                }
                break;
            }
            if (byte[0] == '\n') break;
            line_buf.append(allocator, byte[0]) catch break;
        }

        const line = line_buf.items;
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "(quit)") or std.mem.eql(u8, line, "(exit)")) break;

        // Special REPL commands
        if (std.mem.eql(u8, line, "(colors)")) {
            color_strip.renderNamedStrip(stdout, world_name, width, 4) catch {};
            continue;
        }
        if (std.mem.startsWith(u8, line, "(colors ")) {
            // (colors "name") — show color strip for any name
            const name_start = std.mem.indexOf(u8, line, "\"") orelse continue;
            const name_end = std.mem.lastIndexOf(u8, line, "\"") orelse continue;
            if (name_end > name_start + 1) {
                color_strip.renderNamedStrip(stdout, line[name_start + 1 .. name_end], width, 4) catch {};
            }
            continue;
        }
        if (std.mem.eql(u8, line, "(gap)")) {
            color_strip.renderGapStrip(stdout, world_seed, substrate.CANONICAL_SEED, width) catch {};
            continue;
        }
        if (std.mem.eql(u8, line, "(wheel)")) {
            color_strip.renderTritWheel(stdout, width) catch {};
            continue;
        }

        // Bytecode eval: (bc <expr>)
        if (std.mem.startsWith(u8, line, "(bc ") and line[line.len - 1] == ')') {
            const inner = line[4 .. line.len - 1];
            const bc_result = bcRep(inner, &gc, allocator, &vm);
            compat.fileWriteAll(stdout, bc_result);
            compat.fileWriteAll(stdout, "\n");
            continue;
        }
        // Benchmark: (bench <expr>)
        if (std.mem.startsWith(u8, line, "(bench ") and line[line.len - 1] == ')') {
            const inner = line[7 .. line.len - 1];
            const bench_result = benchRep(inner, &env, &gc, allocator);
            compat.fileWriteAll(stdout, bench_result);
            compat.fileWriteAll(stdout, "\n");
            continue;
        }

        const result = rep(line, &env, &gc) catch "Error: internal error";
        compat.fileWriteAll(stdout, result);
        compat.fileWriteAll(stdout, "\n");
        if (result.len > 0 and result[0] != 'E') {
            allocator.free(result);
        }
    }
}

test {
    _ = @import("value.zig");
    _ = @import("reader.zig");
    _ = @import("gc.zig");
    _ = @import("semantics.zig");
    _ = @import("tree_vfs.zig");
    _ = @import("inet.zig");
    _ = @import("inet_builtins.zig");
    _ = @import("inet_compile.zig");
    _ = @import("thread_peval.zig");
    _ = @import("peval.zig");
    _ = @import("bytecode.zig");
    _ = @import("compiler.zig");
    _ = @import("ibc_denom.zig");
    _ = @import("http_fetch.zig");
    _ = @import("church_turing.zig");
    _ = @import("syrup_bridge.zig");
    _ = @import("gorj_bridge.zig");
    _ = @import("avalon_api_example.zig");
}
