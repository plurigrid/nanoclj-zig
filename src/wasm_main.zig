//! WASM entry point for nanoclj-zig
//!
//! Exports:
//!   nanoclj_init()              → initialize GC, env, core builtins
//!   nanoclj_eval(ptr, len)      → evaluate Clojure source, return result ptr+len
//!   nanoclj_alloc(len)          → allocate len bytes in WASM linear memory
//!   nanoclj_free(ptr, len)      → free previously allocated bytes
//!   nanoclj_result_len()        → length of last eval result (call after nanoclj_eval)
//!
//! The host (JS/browser) calls nanoclj_alloc to get a buffer, writes source
//! into it, calls nanoclj_eval, then reads nanoclj_result_len() bytes from
//! the returned pointer.

const std = @import("std");
const wasm_alloc = @import("wasm_alloc.zig");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const compat = @import("compat.zig");

const alloc = wasm_alloc.allocator();

var gc: GC = undefined;
var env: Env = undefined;
var initialized: bool = false;

/// Last eval result stored here so JS can read ptr+len
var last_result_ptr: u32 = 0;
var last_result_len: u32 = 0;

export fn nanoclj_init() void {
    if (initialized) return;

    gc = GC.init(alloc);
    env = Env.init(alloc, null);
    env.is_root = true;

    core.initCore(&env, &gc) catch {
        initialized = false;
        return;
    };
    initialized = true;
}

export fn nanoclj_eval(src_ptr: [*]const u8, src_len: u32) u32 {
    if (!initialized) return 0;

    const input = src_ptr[0..src_len];

    // Reset WASM output buffer (captures println side-effects)
    compat.wasmOutputReset();

    // Read
    var reader = Reader.init(input, &gc);
    const form = reader.readForm() catch |err| {
        const msg = switch (err) {
            error.UnexpectedEOF => "Error: unexpected EOF",
            error.UnmatchedParen => "Error: unmatched )",
            error.UnmatchedBracket => "Error: unmatched ]",
            error.UnmatchedBrace => "Error: unmatched }",
            error.InvalidNumber => "Error: invalid number",
            error.UnexpectedChar => "Error: unexpected character",
            else => "Error: read failed",
        };
        return copyResult(msg);
    };

    // Eval (fuel-bounded)
    var res = semantics.Resources.initDefault();
    const domain = semantics.evalBounded(form, &env, &gc, &res);

    // Format result
    const result_str: []const u8 = switch (domain) {
        .value => |v| printer.prStr(v, &gc, true) catch "Error: print failed",
        .bottom => |reason| switch (reason) {
            .fuel_exhausted => "Error: computation exceeded fuel limit",
            .depth_exceeded => "Error: recursion depth exceeded",
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

    // If there's captured output from println etc., prepend it
    const captured = compat.wasmOutputSlice();
    if (captured.len > 0) {
        const total = captured.len + result_str.len;
        const out = alloc.alloc(u8, total) catch return copyResult(result_str);
        @memcpy(out[0..captured.len], captured);
        @memcpy(out[captured.len..], result_str);
        last_result_len = @intCast(total);
        last_result_ptr = @intCast(@intFromPtr(out.ptr));
        return last_result_ptr;
    }

    return copyResult(result_str);
}

fn copyResult(s: []const u8) u32 {
    const out = alloc.alloc(u8, s.len) catch return 0;
    @memcpy(out, s);
    last_result_len = @intCast(s.len);
    last_result_ptr = @intCast(@intFromPtr(out.ptr));
    return last_result_ptr;
}

export fn nanoclj_result_len() u32 {
    return last_result_len;
}

export fn nanoclj_alloc(len: u32) u32 {
    const buf = alloc.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

export fn nanoclj_free(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    alloc.free(p[0..len]);
}
