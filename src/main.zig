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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // ── Demo: color strip banner ──────────────────────────────────
    // Detect terminal width (fallback 80)
    const width: u32 = 80;

    stdout.writeAll("\x1b[1mnanoclj-zig v0.1.0\x1b[0m\n") catch {};
    color_strip.renderTritWheel(stdout, width) catch {};
    stdout.writeAll("\n") catch {};

    // Seed from hostname or "world"
    const world_name = std.process.getEnvVarOwned(allocator, "USER") catch
        allocator.dupe(u8, "world") catch "world";
    defer if (@TypeOf(world_name) != []const u8) {} else allocator.free(world_name);

    color_strip.renderNamedStrip(stdout, world_name, width, 2) catch {};
    stdout.writeAll("\n") catch {};

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

    // ── REPL: world=> ─────────────────────────────────────────────
    while (true) {
        // Prompt with world name
        var prompt_buf: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "\x1b[36m{s}\x1b[0m=> ", .{world_name}) catch "world=> ";
        stdout.writeAll(prompt) catch {};

        var line_buf = std.ArrayListUnmanaged(u8){};
        defer line_buf.deinit(allocator);
        while (true) {
            var byte: [1]u8 = undefined;
            const n = stdin_file.read(&byte) catch break;
            if (n == 0) {
                if (line_buf.items.len == 0) {
                    stdout.writeAll("\n") catch {};
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

        const result = rep(line, &env, &gc) catch "Error: internal error";
        stdout.writeAll(result) catch {};
        stdout.writeAll("\n") catch {};
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
}
