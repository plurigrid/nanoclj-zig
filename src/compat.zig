//! COMPAT: Zig 0.15 ↔ 0.16 compatibility layer.
//!
//! 0.15: ArrayListUnmanaged(T){} works, std.Thread.Mutex exists
//! 0.16: ArrayListUnmanaged(T){} removed → .empty, std.Thread.Mutex → std.atomic.Mutex

const std = @import("std");

/// Empty ArrayListUnmanaged — works on both 0.15 and 0.16.
pub fn emptyList(comptime T: type) std.ArrayListUnmanaged(T) {
    const L = std.ArrayListUnmanaged(T);
    if (@hasDecl(L, "empty")) {
        return L.empty;
    } else {
        // 0.15 path: zero-init works
        return .{};
    }
}

/// Mutex type — works on both 0.15 and 0.16.
pub const Mutex = if (@hasDecl(std.Thread, "Mutex"))
    std.Thread.Mutex // 0.15
else if (@hasDecl(std, "atomic") and @hasDecl(std.atomic, "Mutex"))
    std.atomic.Mutex // 0.16
else
    @compileError("No Mutex found in std");

pub fn mutexInit() Mutex {
    return .{};
}
