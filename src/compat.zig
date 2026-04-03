//! COMPAT: Zig 0.15 ↔ 0.16 compatibility layer.
//!
//! 0.15: ArrayListUnmanaged(T){} works, std.Thread.Mutex has lock/unlock
//! 0.16: ArrayListUnmanaged(T){} removed → .empty, std.Thread.Mutex gone,
//!        std.atomic.Mutex is enum with tryLock/unlock only

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

/// Cross-version Mutex wrapper.
/// 0.15: std.Thread.Mutex (struct with lock/unlock)
/// 0.16: std.atomic.Mutex (enum with tryLock/unlock) — we spin on tryLock
pub const Mutex = struct {
    inner: InnerType = inner_init,

    const has_thread_mutex = @hasDecl(std.Thread, "Mutex");

    const InnerType = if (has_thread_mutex)
        std.Thread.Mutex
    else if (@hasDecl(std, "atomic") and @hasDecl(std.atomic, "Mutex"))
        std.atomic.Mutex
    else
        @compileError("No Mutex found in std");

    const inner_init: InnerType = if (has_thread_mutex)
        .{}
    else
        .unlocked;

    pub fn lock(self: *Mutex) void {
        if (has_thread_mutex) {
            self.inner.lock();
        } else {
            // Spinlock via tryLock (0.16 atomic.Mutex)
            while (!self.inner.tryLock()) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};
