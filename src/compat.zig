//! COMPAT: Zig 0.15 ↔ 0.16 compatibility layer.
//!
//! 0.15: ArrayListUnmanaged(T){} works, std.Thread.Mutex has lock/unlock
//! 0.16: ArrayListUnmanaged(T){} removed → .empty, std.Thread.Mutex gone,
//!        std.atomic.Mutex is enum with tryLock/unlock only

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Type alias for Value lists
pub const ValList = std.ArrayListUnmanaged(@import("value.zig").Value);

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

/// Cross-version stdout/stdin/stderr write helpers.
/// 0.15: std.fs.File with .writeAll()
/// 0.16: std.io.File — no direct writeAll, use system call
/// WASM: buffer to memory (no file descriptors)
const has_fs_file = if (is_wasm) false else @hasDecl(std.fs, "File");

/// WASM output buffer: stdout and stderr both write here.
/// The host reads wasm_output_buf[0..wasm_output_len] after nanoclj_eval.
var wasm_output_backing: [64 * 1024]u8 = undefined;
pub var wasm_output_buf: [*]u8 = &wasm_output_backing;
pub var wasm_output_len: u32 = 0;

pub fn wasmOutputReset() void {
    wasm_output_len = 0;
}

pub fn wasmOutputSlice() []const u8 {
    return wasm_output_backing[0..wasm_output_len];
}

fn wasmAppend(bytes: []const u8) void {
    const avail = wasm_output_backing.len - wasm_output_len;
    const n = @min(bytes.len, avail);
    @memcpy(wasm_output_backing[wasm_output_len..][0..n], bytes[0..n]);
    wasm_output_len += @intCast(n);
}

pub fn stdoutWrite(bytes: []const u8) void {
    if (is_wasm) {
        wasmAppend(bytes);
    } else if (has_fs_file) {
        const f = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        f.writeAll(bytes) catch {};
    } else {
        writeAllFd(std.posix.STDOUT_FILENO, bytes);
    }
}

pub fn stderrWrite(bytes: []const u8) void {
    if (is_wasm) {
        wasmAppend(bytes);
    } else if (has_fs_file) {
        const f = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        f.writeAll(bytes) catch {};
    } else {
        writeAllFd(std.posix.STDERR_FILENO, bytes);
    }
}

/// Native-only: write bytes to a file descriptor (unreferenced on WASM).
fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes.ptr + written, bytes.len - written);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

/// Cross-version GeneralPurposeAllocator / DebugAllocator.
/// (Not used on WASM — wasm_alloc.zig provides the allocator.)
const has_gpa = if (is_wasm) false else @hasDecl(std.heap, "GeneralPurposeAllocator");

pub fn DebugAllocator() type {
    if (has_gpa) {
        return std.heap.GeneralPurposeAllocator(.{});
    } else {
        return std.heap.DebugAllocator(.{});
    }
}

pub fn makeDebugAllocator() DebugAllocator() {
    if (has_gpa) {
        return std.heap.GeneralPurposeAllocator(.{}){};
    } else {
        return std.heap.DebugAllocator(.{}).init;
    }
}

/// Cross-version File type alias.
/// 0.15: std.fs.File
/// 0.16: std.io.File
/// WASM: dummy struct (no real files)
pub const File = if (is_wasm) WasmFile else if (has_fs_file) std.fs.File else std.Io.File;

/// Dummy file type for WASM — all writes go to wasm_output_backing.
pub const WasmFile = struct {
    kind: enum { stdout, stderr, stdin } = .stdout,
};

pub fn stdoutFile() File {
    if (is_wasm) {
        return .{ .kind = .stdout };
    } else if (has_fs_file) {
        return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    } else {
        return std.Io.File.stdout();
    }
}

pub fn stderrFile() File {
    if (is_wasm) {
        return .{ .kind = .stderr };
    } else if (has_fs_file) {
        return std.fs.File{ .handle = std.posix.STDERR_FILENO };
    } else {
        return std.Io.File.stderr();
    }
}

pub fn stdinFile() File {
    if (is_wasm) {
        return .{ .kind = .stdin };
    } else if (has_fs_file) {
        return std.fs.File{ .handle = std.posix.STDIN_FILENO };
    } else {
        return std.Io.File.stdin();
    }
}

/// Cross-version writeAll for a File.
pub const fileWriteAll = if (is_wasm) fileWriteAllWasm else fileWriteAllNative;

fn fileWriteAllWasm(_: File, bytes: []const u8) void {
    wasmAppend(bytes);
}

fn fileWriteAllNative(f: File, bytes: []const u8) void {
    if (has_fs_file) {
        f.writeAll(bytes) catch {};
    } else {
        writeAllFd(f.handle, bytes);
    }
}

/// Cross-version read for a File. Returns bytes read.
pub const fileRead = if (is_wasm) fileReadWasm else fileReadNative;

fn fileReadWasm(_: File, _: []u8) usize {
    return 0;
}

fn fileReadNative(f: File, buf: []u8) usize {
    if (has_fs_file) {
        return f.read(buf) catch 0;
    } else {
        const rc = std.c.read(f.handle, buf.ptr, buf.len);
        if (rc <= 0) return 0;
        return @intCast(rc);
    }
}

/// Cross-version stdin reader.  Returns bytes read into buf.
pub const stdinRead = if (is_wasm) stdinReadWasm else stdinReadNative;

fn stdinReadWasm(_: []u8) usize {
    return 0;
}

fn stdinReadNative(buf: []u8) usize {
    if (has_fs_file) {
        const f = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        return f.read(buf) catch 0;
    } else {
        const rc = std.c.read(std.posix.STDIN_FILENO, buf.ptr, buf.len);
        if (rc <= 0) return 0;
        return @intCast(rc);
    }
}
