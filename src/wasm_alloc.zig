//! WASM-compatible allocator for nanoclj-zig
//!
//! On wasm32-freestanding there is no mmap, no std.os, no std.c.
//! WASM provides a single linear memory that can be grown via memory.grow.
//!
//! Strategy: on WASM, use a growing linear region managed by wasm_allocator().
//! On native, delegate to std.heap.c_allocator.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// The allocator to use throughout nanoclj-zig.
/// On WASM: std.heap.wasm_allocator (built-in Zig WASM page allocator).
/// On native: std.heap.c_allocator.
pub fn allocator() std.mem.Allocator {
    if (is_wasm) {
        return std.heap.wasm_allocator;
    } else {
        return std.heap.c_allocator;
    }
}
