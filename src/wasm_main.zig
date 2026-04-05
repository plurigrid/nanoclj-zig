//! WASM entry point for nanoclj-zig
//!
//! Exports:
//!   nanoclj_init()              → initialize GC, env, core builtins
//!   nanoclj_eval(ptr, len)      → evaluate Clojure source, return result ptr+len
//!   nanoclj_alloc(len)          → allocate len bytes in WASM linear memory
//!   nanoclj_free(ptr, len)      → free previously allocated bytes
//!
//! The host (JS/browser) calls nanoclj_alloc to get a buffer, writes source
//! into it, calls nanoclj_eval, then reads the result from the returned pointer.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const reader_mod = @import("reader.zig");
const eval_mod = @import("eval.zig");
const core = @import("core.zig");
const printer = @import("printer.zig");
const wasm_alloc = @import("wasm_alloc.zig");
const compat = @import("compat.zig");

var gc: GC = undefined;
var env: *Env = undefined;
var initialized: bool = false;

/// Result buffer for returning strings to host
var result_buf: std.ArrayListUnmanaged(u8) = compat.emptyList(u8);

const allocator = wasm_alloc.allocator();

export fn nanoclj_init() void {
    gc = GC.init(allocator);
    env = allocator.create(Env) catch return;
    env.* = Env.init(allocator);
    env.is_root = true;
    core.initCore(env, &gc) catch return;
    initialized = true;
}

/// Evaluate source code, return pointer to result string.
/// The result is a NUL-terminated string at the returned address.
/// The length (excluding NUL) is stored at address (result_ptr - 4) as u32 LE.
export fn nanoclj_eval(src_ptr: [*]const u8, src_len: u32) u32 {
    if (!initialized) return 0;

    const src = src_ptr[0..src_len];
    var reader = reader_mod.Reader.init(src, &gc);

    // Clear previous result
    result_buf.items.len = 0;

    while (!reader.atEnd()) {
        const form = reader.readForm() catch {
            result_buf.appendSlice(allocator, "#<read-error>") catch {};
            break;
        };
        const result = eval_mod.eval(form, env, &gc) catch {
            result_buf.appendSlice(allocator, "#<eval-error>") catch {};
            break;
        };
        printer.prStrInto(&result_buf, result, &gc, true) catch {};
    }

    // NUL terminate
    result_buf.append(allocator, 0) catch return 0;

    // Return pointer as u32 (WASM linear memory address)
    return @intCast(@intFromPtr(result_buf.items.ptr));
}

/// Allocate bytes in WASM linear memory (for host to write source into)
export fn nanoclj_alloc(len: u32) u32 {
    const buf = allocator.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

/// Free previously allocated bytes
export fn nanoclj_free(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    allocator.free(p[0..len]);
}
