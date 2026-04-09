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
//!
//! NOTE: This is a stub entry point. Full WASM support requires compat.zig
//! to abstract away libc I/O (write/stderr). For now, this file compiles and
//! links but core.initCore will fail at runtime until compat.zig gets
//! freestanding I/O stubs. The build target exists so that compilation errors
//! in the value/gc/channel/reader layers are caught early.

const std = @import("std");
const wasm_alloc = @import("wasm_alloc.zig");

const alloc = wasm_alloc.allocator();

/// Placeholder: will hold GC + env once compat.zig supports freestanding
var initialized: bool = false;

export fn nanoclj_init() void {
    initialized = true;
}

export fn nanoclj_eval(src_ptr: [*]const u8, src_len: u32) u32 {
    if (!initialized) return 0;
    // Minimal echo: return the input as-is (proves alloc/eval/read roundtrip)
    const out = alloc.alloc(u8, src_len + 1) catch return 0;
    @memcpy(out[0..src_len], src_ptr[0..src_len]);
    out[src_len] = 0;
    return @intCast(@intFromPtr(out.ptr));
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
