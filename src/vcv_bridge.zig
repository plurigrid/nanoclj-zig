const std = @import("std");
const compat = @import("compat.zig");

/// VCV Rack CV bridge via shared memory ring buffer.
///
/// Reads CV frames from /tmp/gatomic-vcv.shm (mmap'd by gatomic JVM)
/// or from a raw .f32 file, and exposes them as audio-rate buffers
/// suitable for VCV Rack plugin consumption or direct WAV output.
///
/// Frame layout: 6 channels × f32
///   ch0: V/Oct  (0V=C3, 1V=C4, 2V=C5)
///   ch1: Gate   (0V or 10V)
///   ch2: Filter (0-5V, mu mapping)
///   ch3: Pan    (-5V to +5V, color hue)
///   ch4: Tau    (0-10V, WLC residence time)
///   ch5: Sweep  (0-10V, sequence position)
///
/// Two modes:
///   1. Live: mmap ring buffer, chase gatomic's write pointer
///   2. File: read .f32 dump, interpolate to audio rate

const FRAME_CHANNELS: usize = 6;
const RING_FRAMES: usize = 4096;
const HEADER_BYTES: usize = 16;
const SAMPLE_RATE: f32 = 48000.0;
const CONTROL_RATE: f32 = 120.0; // trit-ticks per second (2 per beat at 120BPM)

/// Shared memory header layout (little-endian):
///   [0..4)   u32 write_pos
///   [4..8)   u32 read_pos
///   [8..12)  f32 sample_rate
///   [12..16) u32 channels
const ShmHeader = packed struct {
    write_pos: u32,
    read_pos: u32,
    sample_rate: f32,
    channels: u32,
};

/// A single CV frame: 6 voltage channels
pub const CvFrame = struct {
    voct: f32 = 0,
    gate: f32 = 0,
    filter: f32 = 0,
    pan: f32 = 0,
    tau: f32 = 0,
    sweep: f32 = 0,

    pub fn fromSlice(s: []const f32) CvFrame {
        return .{
            .voct = if (s.len > 0) s[0] else 0,
            .gate = if (s.len > 1) s[1] else 0,
            .filter = if (s.len > 2) s[2] else 0,
            .pan = if (s.len > 3) s[3] else 0,
            .tau = if (s.len > 4) s[4] else 0,
            .sweep = if (s.len > 5) s[5] else 0,
        };
    }

    pub fn lerp(a: CvFrame, b: CvFrame, t: f32) CvFrame {
        return .{
            .voct = a.voct + (b.voct - a.voct) * t,
            .gate = if (t < 0.5) a.gate else b.gate, // gate: no interp
            .filter = a.filter + (b.filter - a.filter) * t,
            .pan = a.pan + (b.pan - a.pan) * t,
            .tau = a.tau + (b.tau - a.tau) * t,
            .sweep = a.sweep + (b.sweep - a.sweep) * t,
        };
    }

    pub fn toArray(self: CvFrame) [FRAME_CHANNELS]f32 {
        return .{ self.voct, self.gate, self.filter, self.pan, self.tau, self.sweep };
    }
};

/// Live ring buffer reader (chases gatomic JVM writer)
pub const ShmReader = struct {
    mapped: []align(4096) u8,
    fd: std.posix.fd_t,
    last_read: u32 = 0,

    pub fn open(path: []const u8) !ShmReader {
        const fd = try std.posix.open(
            @ptrCast(path),
            .{ .ACCMODE = .RDONLY },
            0,
        );
        const size = HEADER_BYTES + RING_FRAMES * FRAME_CHANNELS * 4;
        const mapped = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        return .{ .mapped = mapped, .fd = fd };
    }

    pub fn close(self: *ShmReader) void {
        std.posix.munmap(self.mapped);
        std.posix.close(self.fd);
    }

    pub fn header(self: *const ShmReader) *const ShmHeader {
        return @ptrCast(@alignCast(self.mapped.ptr));
    }

    pub fn readFrame(self: *ShmReader, index: u32) CvFrame {
        const off = HEADER_BYTES + @as(usize, index % RING_FRAMES) * FRAME_CHANNELS * 4;
        const ptr: [*]const f32 = @ptrCast(@alignCast(self.mapped[off..]));
        return CvFrame.fromSlice(ptr[0..FRAME_CHANNELS]);
    }

    /// Read all new frames since last call
    pub fn drain(self: *ShmReader, out: *std.ArrayList(CvFrame)) !void {
        const wp = self.header().write_pos;
        while (self.last_read != wp) {
            try out.append(self.readFrame(self.last_read));
            self.last_read = (self.last_read + 1) % RING_FRAMES;
        }
    }
};

/// File-based reader for .f32 dumps from gatomic
pub const FileReader = struct {
    frames: []CvFrame,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !FileReader {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const reader = file.reader();

        const n_frames = try reader.readInt(u32, .little);
        const n_channels = try reader.readInt(u32, .little);
        _ = n_channels;

        var frames = try allocator.alloc(CvFrame, n_frames);
        for (0..n_frames) |i| {
            var buf: [FRAME_CHANNELS]f32 = undefined;
            for (0..FRAME_CHANNELS) |c| {
                buf[c] = @bitCast(try reader.readInt(u32, .little));
            }
            frames[i] = CvFrame.fromSlice(&buf);
        }
        return .{ .frames = frames, .allocator = allocator };
    }

    pub fn deinit(self: *FileReader) void {
        self.allocator.free(self.frames);
    }
};

/// Audio-rate interpolator: upsamples control-rate CV frames to audio rate.
/// At 48kHz with 120 ticks/sec, each tick spans 400 samples.
pub const Interpolator = struct {
    frames: []const CvFrame,
    pos: f64 = 0,
    samples_per_frame: f64,

    pub fn init(frames: []const CvFrame, sample_rate: f32, control_rate: f32) Interpolator {
        return .{
            .frames = frames,
            .samples_per_frame = @as(f64, sample_rate / control_rate),
        };
    }

    pub fn next(self: *Interpolator) CvFrame {
        const idx = @as(usize, @intFromFloat(self.pos));
        if (idx + 1 >= self.frames.len) {
            return if (self.frames.len > 0)
                self.frames[self.frames.len - 1]
            else
                CvFrame{};
        }
        const t: f32 = @floatCast(self.pos - @as(f64, @floatFromInt(idx)));
        self.pos += 1.0 / self.samples_per_frame;
        return CvFrame.lerp(self.frames[idx], self.frames[idx + 1], t);
    }

    pub fn done(self: *const Interpolator) bool {
        return @as(usize, @intFromFloat(self.pos)) + 1 >= self.frames.len;
    }
};

/// Write interpolated CV frames as a 6-channel WAV file.
/// VCV Rack can load WAV as a sample source, or use it for offline analysis.
pub fn writeWav(allocator: std.mem.Allocator, frames: []const CvFrame, path: []const u8) !void {
    const n_channels: u16 = FRAME_CHANNELS;
    const sample_rate: u32 = @intFromFloat(SAMPLE_RATE);
    const bits_per_sample: u16 = 32;

    var interp = Interpolator.init(frames, SAMPLE_RATE, CONTROL_RATE);
    var samples = std.ArrayList([FRAME_CHANNELS]f32).init(allocator);
    defer samples.deinit();

    while (!interp.done()) {
        try samples.append(interp.next().toArray());
    }

    const data_size: u32 = @intCast(samples.items.len * n_channels * 4);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const w = file.writer();

    // RIFF header
    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + data_size, .little);
    try w.writeAll("WAVE");

    // fmt chunk (IEEE float)
    try w.writeAll("fmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 3, .little); // IEEE float
    try w.writeInt(u16, n_channels, .little);
    try w.writeInt(u32, sample_rate, .little);
    try w.writeInt(u32, sample_rate * n_channels * 4, .little);
    try w.writeInt(u16, n_channels * 4, .little);
    try w.writeInt(u16, bits_per_sample, .little);

    // data chunk
    try w.writeAll("data");
    try w.writeInt(u32, data_size, .little);
    for (samples.items) |frame| {
        for (frame) |sample| {
            try w.writeInt(u32, @bitCast(sample), .little);
        }
    }
}

/// CLI: read a .f32 file → WAV, or attach to live shm
pub fn main() !void {
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: vcv_bridge <input.f32> <output.wav>\n", .{});
        std.debug.print("       vcv_bridge --live <output.wav>  (reads /tmp/gatomic-vcv.shm)\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "--live")) {
        std.debug.print("Live mode: reading from /tmp/gatomic-vcv.shm\n", .{});
        var reader = try ShmReader.open("/tmp/gatomic-vcv.shm");
        defer reader.close();

        var cv_frames = std.array_list.AlignedManaged(CvFrame, null).init(allocator);
        defer cv_frames.deinit();

        // Drain for 5 seconds
        const end_time = std.time.milliTimestamp() + 5000;
        while (std.time.milliTimestamp() < end_time) {
            try reader.drain(&cv_frames);
            std.time.sleep(1_000_000); // 1ms poll
        }

        std.debug.print("Captured {} frames, writing WAV...\n", .{cv_frames.items.len});
        try writeWav(allocator, cv_frames.items, args[2]);
    } else {
        var fr = try FileReader.load(allocator, args[1]);
        defer fr.deinit();
        std.debug.print("Loaded {} frames, writing WAV...\n", .{fr.frames.len});
        try writeWav(allocator, fr.frames, args[2]);
    }

    std.debug.print("Done.\n", .{});
}

test "cv frame lerp" {
    const a = CvFrame{ .voct = 0, .gate = 10, .filter = 1 };
    const b = CvFrame{ .voct = 2, .gate = 0, .filter = 5 };
    const mid = CvFrame.lerp(a, b, 0.5);
    try std.testing.expectApproxEqAbs(mid.voct, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(mid.filter, 3.0, 0.01);
    // gate snaps at 0.5
    try std.testing.expectApproxEqAbs(mid.gate, 0.0, 0.01);
}

test "cv frame from slice" {
    const s = [_]f32{ 1.0, 10.0, 3.0, -2.5, 7.0, 4.0 };
    const f = CvFrame.fromSlice(&s);
    try std.testing.expectApproxEqAbs(f.voct, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(f.pan, -2.5, 0.01);
}
