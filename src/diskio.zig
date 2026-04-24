//! DISK I/O: Zig-unique primitives that JVM Clojure hides behind slurp/spit.
//!
//! Categorical framing (see topos-polynomial-functors + sdf skills):
//!   file = polynomial p = Σ_{handle} y^{byte-interval}
//!     positions  (p(1))       = open handles       ← open / close
//!     directions (p[i])       = byte-intervals      ← pread / pwrite
//!   file-as-cell: lattice L = bytes* × {0,1}       ← fsync climbs the d-bit
//!     merge = compatible-extension + d ∨ d'        (info-monotone)
//!
//! Six p-directions (pread / pwrite / fsync / size / mmap_ro / flock) + two
//! p-positions (open / close) + one lattice-compat combinator
//! (atomic_spit). mmap_ro returns a zero-copy view-position whose lifetime
//! is explicit (munmap) or GC-managed. flock is a state-direction that
//! mutates the lock-bit on a handle (no data transfer).
//!
//! Positional I/O (pread/pwrite) is thread-safe: no seek state mutated.

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Open-flags the user can set via a keyword map.
pub const OpenFlags = struct {
    read: bool = true,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    excl: bool = false,
    mode: u16 = 0o644,
};

pub const Handle = struct {
    fd: i32,
    closed: bool = false,
    /// Path — freed on GC; borrowed from interned string pool if length fits.
    path: []const u8 = "",

    pub fn close(self: *Handle) void {
        if (self.closed) return;
        if (!is_wasm) _ = std.c.close(self.fd);
        self.closed = true;
    }
};

pub const Bytes = struct {
    data: []u8,
    owned: bool = true,

    pub fn deinit(self: *Bytes, allocator: std.mem.Allocator) void {
        if (self.owned and self.data.len > 0) allocator.free(self.data);
    }
};

/// Zero-copy memory-mapped read-only view. Valid until `unmap` is called
/// (explicitly via `file/munmap!` or implicitly by the GC).
pub const MmapView = struct {
    data: []const u8,
    unmapped: bool = false,

    pub fn unmap(self: *MmapView) void {
        if (self.unmapped or self.data.len == 0) return;
        if (!is_wasm) {
            const aligned: [*]align(std.heap.page_size_min) const u8 =
                @ptrCast(@alignCast(self.data.ptr));
            std.posix.munmap(aligned[0..self.data.len]);
        }
        self.unmapped = true;
    }
};

pub const DiskError = error{
    InvalidPath,
    OpenFailed,
    ReadFailed,
    WriteFailed,
    FsyncFailed,
    StatFailed,
    RenameFailed,
    MmapFailed,
    LockFailed,
    LockWouldBlock,
    OutOfMemory,
    Unsupported,
};

/// Lock mode on a file descriptor.
pub const LockMode = enum { shared, exclusive, unlock };

// ============================================================================
// NATIVE IMPLEMENTATION (POSIX via std.c extern bindings)
// ============================================================================
// Zig 0.16 removed std.posix.{close,openZ,pread,pwrite,fstat,fsync,getpid,
// unlinkZ,renameZ,write} in favor of the vtable-based std.Io.File model. Since
// this module holds a raw fd:i32 as its API boundary and libc is linked by
// build.zig, we call the C extern bindings directly via std.c.*.

fn pathz(path: []const u8, buf: []u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn openNative(path: []const u8, f: OpenFlags) DiskError!i32 {
    var pbuf: [4096]u8 = undefined;
    const p = pathz(path, &pbuf) orelse return DiskError.InvalidPath;
    var flags: std.c.O = .{};
    flags.ACCMODE = if (f.read and f.write) .RDWR else if (f.write) .WRONLY else .RDONLY;
    if (f.create) flags.CREAT = true;
    if (f.truncate) flags.TRUNC = true;
    if (f.append) flags.APPEND = true;
    if (f.excl) flags.EXCL = true;
    const fd = std.c.open(p.ptr, flags, @as(std.c.mode_t, f.mode));
    if (fd < 0) return DiskError.OpenFailed;
    return @intCast(fd);
}

pub fn closeNative(fd: i32) void {
    _ = std.c.close(fd);
}

pub fn sizeNative(fd: i32) DiskError!u64 {
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return DiskError.StatFailed;
    _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
    return @intCast(end);
}

pub fn preadNative(fd: i32, offset: u64, buf: []u8) DiskError!usize {
    const rc = std.c.pread(fd, buf.ptr, buf.len, @intCast(offset));
    if (rc < 0) return DiskError.ReadFailed;
    return @intCast(rc);
}

pub fn pwriteNative(fd: i32, offset: u64, buf: []const u8) DiskError!usize {
    const rc = std.c.pwrite(fd, buf.ptr, buf.len, @intCast(offset));
    if (rc < 0) return DiskError.WriteFailed;
    return @intCast(rc);
}

pub fn fsyncNative(fd: i32) DiskError!void {
    const rc = std.c.fsync(fd);
    if (rc != 0) return DiskError.FsyncFailed;
}

/// Advisory lock on a file descriptor (BSD flock; per-open-file-description).
/// Not inherited across exec but is across fork + shared across dup.
pub fn flockNative(fd: i32, mode: LockMode, nonblocking: bool) DiskError!void {
    // POSIX flock op values: LOCK_SH=1, LOCK_EX=2, LOCK_UN=8, LOCK_NB=4
    var op: c_int = switch (mode) {
        .shared => 1,
        .exclusive => 2,
        .unlock => 8,
    };
    if (nonblocking) op |= 4;
    const rc = std.c.flock(fd, op);
    if (rc == 0) return;
    const errno = std.c._errno().*;
    // EWOULDBLOCK = 35 on darwin, 11 on linux — both covered by this check
    if (nonblocking and (errno == 35 or errno == 11)) return DiskError.LockWouldBlock;
    return DiskError.LockFailed;
}

/// Read the entire file into a freshly-allocated buffer.
pub fn readAllBytesNative(
    allocator: std.mem.Allocator,
    path: []const u8,
) DiskError![]u8 {
    const fd = try openNative(path, .{ .read = true });
    defer closeNative(fd);
    const sz = try sizeNative(fd);
    const buf = allocator.alloc(u8, @intCast(sz)) catch return DiskError.OutOfMemory;
    errdefer allocator.free(buf);
    var off: u64 = 0;
    while (off < sz) {
        const n = try preadNative(fd, off, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    return buf[0..@intCast(off)];
}

/// Crash-safe overwrite: write to a tmp file, fsync, rename over the target.
pub fn atomicSpitNative(path: []const u8, data: []const u8) DiskError!void {
    var pbuf: [4096]u8 = undefined;
    _ = pathz(path, &pbuf) orelse return DiskError.InvalidPath;

    var tmp_buf: [4160]u8 = undefined;
    const pid = std.c.getpid();
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}", .{ path, pid }) catch
        return DiskError.InvalidPath;

    const fd = try openNative(tmp, .{
        .write = true,
        .create = true,
        .truncate = true,
        .read = false,
    });

    errdefer {
        var unlink_buf: [4160]u8 = undefined;
        if (pathz(tmp, &unlink_buf)) |p| _ = std.c.unlink(p.ptr);
        closeNative(fd);
    }

    var off: u64 = 0;
    while (off < data.len) {
        const n = try pwriteNative(fd, off, data[off..]);
        if (n == 0) return DiskError.WriteFailed;
        off += n;
    }
    try fsyncNative(fd);
    closeNative(fd);

    var old_buf: [4160]u8 = undefined;
    var new_buf: [4096]u8 = undefined;
    const old_p = pathz(tmp, &old_buf) orelse return DiskError.InvalidPath;
    const new_p = pathz(path, &new_buf) orelse return DiskError.InvalidPath;
    const rc = std.c.rename(old_p.ptr, new_p.ptr);
    if (rc != 0) return DiskError.RenameFailed;
}

/// Read-only zero-copy view: mmap(PROT_READ, MAP_PRIVATE) the whole file.
pub fn mmapReadOnlyNative(path: []const u8) DiskError!MmapView {
    const fd = try openNative(path, .{ .read = true });
    defer closeNative(fd);
    const sz = try sizeNative(fd);
    if (sz == 0) return .{ .data = &[_]u8{}, .unmapped = true };
    const prot: std.posix.PROT = .{ .READ = true };
    const flags: std.posix.MAP = .{ .TYPE = .PRIVATE };
    const slice = std.posix.mmap(null, @intCast(sz), prot, flags, fd, 0) catch return DiskError.MmapFailed;
    return .{ .data = slice[0..@intCast(sz)], .unmapped = false };
}

// ============================================================================
// WASM STUBS
// ============================================================================

pub fn openStub(_: []const u8, _: OpenFlags) DiskError!i32 {
    return DiskError.Unsupported;
}
pub fn closeStub(_: i32) void {}
pub fn sizeStub(_: i32) DiskError!u64 {
    return DiskError.Unsupported;
}
pub fn preadStub(_: i32, _: u64, _: []u8) DiskError!usize {
    return DiskError.Unsupported;
}
pub fn pwriteStub(_: i32, _: u64, _: []const u8) DiskError!usize {
    return DiskError.Unsupported;
}
pub fn fsyncStub(_: i32) DiskError!void {
    return DiskError.Unsupported;
}
pub fn readAllBytesStub(
    _: std.mem.Allocator,
    _: []const u8,
) DiskError![]u8 {
    return DiskError.Unsupported;
}
pub fn atomicSpitStub(_: []const u8, _: []const u8) DiskError!void {
    return DiskError.Unsupported;
}
pub fn mmapReadOnlyStub(_: []const u8) DiskError!MmapView {
    return DiskError.Unsupported;
}
pub fn flockStub(_: i32, _: LockMode, _: bool) DiskError!void {
    return DiskError.Unsupported;
}

// ============================================================================
// DISPATCH
// ============================================================================

pub const open = if (is_wasm) openStub else openNative;
pub const close = if (is_wasm) closeStub else closeNative;
pub const size = if (is_wasm) sizeStub else sizeNative;
pub const pread = if (is_wasm) preadStub else preadNative;
pub const pwrite = if (is_wasm) pwriteStub else pwriteNative;
pub const fsync = if (is_wasm) fsyncStub else fsyncNative;
pub const readAllBytes = if (is_wasm) readAllBytesStub else readAllBytesNative;
pub const atomicSpit = if (is_wasm) atomicSpitStub else atomicSpitNative;
pub const mmapReadOnly = if (is_wasm) mmapReadOnlyStub else mmapReadOnlyNative;
pub const flock = if (is_wasm) flockStub else flockNative;
