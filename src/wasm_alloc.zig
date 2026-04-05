//! WASM-compatible allocator for nanoclj-zig
//!
//! On wasm32-freestanding there is no mmap, no std.os, no std.c.
//! WASM provides a single linear memory that can be grown via memory.grow.
//! This allocator manages a bump-pointer region within linear memory,
//! with a free-list overlay for reuse after GC sweeps.
//!
//! When building for non-WASM targets, this module exports a thin wrapper
//! around std.heap.page_allocator (or c_allocator) so the same interface
//! can be used everywhere.

const std = @import("std");
const builtin = @import("builtin");

/// Page size for WASM linear memory (64 KiB per spec)
const WASM_PAGE_SIZE: usize = 65536;

const is_wasm = builtin.cpu_arch == .wasm32 or builtin.cpu_arch == .wasm64;

/// WASM bump allocator state
const WasmBump = struct {
    /// Current allocation frontier (byte offset in linear memory)
    frontier: usize,
    /// End of available memory (grows on demand)
    ceiling: usize,

    fn init() WasmBump {
        // __heap_base is provided by the WASM linker
        const heap_base = if (is_wasm) @extern(*anyopaque, .{ .name = "__heap_base" }) else undefined;
        const base: usize = if (is_wasm) @intFromPtr(heap_base) else 0;
        const current_pages = if (is_wasm) @wasmMemorySize(0) else 0;
        return .{
            .frontier = base,
            .ceiling = current_pages * WASM_PAGE_SIZE,
        };
    }

    fn ensureCapacity(self: *WasmBump, needed: usize) bool {
        if (self.frontier + needed <= self.ceiling) return true;
        if (!is_wasm) return false;
        const deficit = (self.frontier + needed) - self.ceiling;
        const pages_needed = (deficit + WASM_PAGE_SIZE - 1) / WASM_PAGE_SIZE;
        const result = @wasmMemoryGrow(0, pages_needed);
        if (result == std.math.maxInt(usize)) return false; // OOM
        self.ceiling += pages_needed * WASM_PAGE_SIZE;
        return true;
    }
};

var wasm_state: WasmBump = if (is_wasm) WasmBump.init() else undefined;

/// Free-list node for reuse after GC sweep
const FreeNode = struct {
    size: usize,
    next: ?*FreeNode,
};

var free_list: ?*FreeNode = null;

fn wasmAlloc(n: usize, _: u8, _: ?usize) ?[*]u8 {
    const aligned = (n + 15) & ~@as(usize, 15); // 16-byte alignment

    // Try free list first
    var prev: ?*FreeNode = null;
    var cur = free_list;
    while (cur) |node| {
        if (node.size >= aligned) {
            // Remove from free list
            if (prev) |p| {
                p.next = node.next;
            } else {
                free_list = node.next;
            }
            return @ptrCast(node);
        }
        prev = node;
        cur = node.next;
    }

    // Bump allocate
    if (!wasm_state.ensureCapacity(aligned)) return null;
    const ptr = wasm_state.frontier;
    wasm_state.frontier += aligned;
    return @ptrFromInt(ptr);
}

fn wasmFree(buf: [*]u8, n: usize) void {
    const aligned = (n + 15) & ~@as(usize, 15);
    if (aligned < @sizeOf(FreeNode)) return; // too small to track
    const node: *FreeNode = @ptrCast(@alignCast(buf));
    node.size = aligned;
    node.next = free_list;
    free_list = node;
}

fn wasmResize(buf: [*]u8, old_n: usize, new_n: usize, _: u8) ?[*]u8 {
    // If shrinking, just return same pointer
    if (new_n <= old_n) return buf;
    // If this is the most recent allocation, extend in place
    const old_aligned = (old_n + 15) & ~@as(usize, 15);
    const buf_end = @intFromPtr(buf) + old_aligned;
    if (buf_end == wasm_state.frontier) {
        const extra = ((new_n + 15) & ~@as(usize, 15)) - old_aligned;
        if (wasm_state.ensureCapacity(extra)) {
            wasm_state.frontier += extra;
            return buf;
        }
    }
    return null; // force alloc+copy
}

/// The allocator to use throughout nanoclj-zig.
/// On WASM: bump allocator over linear memory.
/// On native: standard page allocator.
pub fn allocator() std.mem.Allocator {
    if (is_wasm) {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .alloc = struct {
                    fn f(_: *anyopaque, n: usize, log2_align: u8, _: usize) ?[*]u8 {
                        return wasmAlloc(n, log2_align, null);
                    }
                }.f,
                .resize = struct {
                    fn f(_: *anyopaque, buf: []u8, _: u8, new_n: usize, _: usize) bool {
                        const result = wasmResize(buf.ptr, buf.len, new_n, 0);
                        return result != null;
                    }
                }.f,
                .free = struct {
                    fn f(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
                        wasmFree(buf.ptr, buf.len);
                    }
                }.f,
            },
        };
    } else {
        return std.heap.c_allocator;
    }
}

/// Total bytes currently allocated (frontier - heap_base - free_list_total)
pub fn bytesUsed() usize {
    if (!is_wasm) return 0;
    var free_total: usize = 0;
    var cur = free_list;
    while (cur) |node| {
        free_total += node.size;
        cur = node.next;
    }
    const heap_base_val = if (is_wasm) @intFromPtr(@extern(*anyopaque, .{ .name = "__heap_base" })) else 0;
    return wasm_state.frontier - heap_base_val - free_total;
}

/// Total linear memory available
pub fn bytesTotal() usize {
    if (!is_wasm) return 0;
    return wasm_state.ceiling;
}
