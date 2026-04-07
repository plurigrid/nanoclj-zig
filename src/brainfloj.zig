//! Brainfloj — BrainFlow-adjacent multi-channel ingestion for nanoclj-zig.
//!
//! Focus: make 72-channel-style data usable today without a native BrainFlow
//! dependency. We ingest delimited numeric matrices (CSV/TSV/semicolon), select
//! a contiguous EEG block via `channel-count` + optional `column-offset`, and
//! return a compact summary map suitable for REPL use.

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

const ParseError = error{
    EmptyInput,
    InvalidArgs,
    InvalidData,
    Overflow,
};

pub const BrainflojSummary = struct {
    sample_count: usize,
    channel_count: usize,
    column_offset: usize,
    sample0: []f64,
    means: []f64,
    mins: []f64,
    maxs: []f64,
    energy: []f64,
    entropy: f64,
    trit: i8,

    pub fn deinit(self: *BrainflojSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.sample0);
        allocator.free(self.means);
        allocator.free(self.mins);
        allocator.free(self.maxs);
        allocator.free(self.energy);
    }
};

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn makeFloatVector(gc: *GC, vals: []const f64) !Value {
    const vec = try gc.allocObj(.vector);
    for (vals) |v| {
        try vec.data.vector.items.append(gc.allocator, Value.makeFloat(v));
    }
    return Value.makeObj(vec);
}

fn shannonEntropy(data: []const f64) f64 {
    var total: f64 = 0;
    for (data) |v| total += @abs(v);
    if (total <= 1e-12) return 0;

    var entropy: f64 = 0;
    for (data) |v| {
        const p = @abs(v) / total;
        if (p > 1e-12) entropy -= p * @log(p) / @log(2.0);
    }
    return entropy;
}

fn classifyTrit(means: []const f64) i8 {
    if (means.len == 0) return 0;
    if (means.len == 1) return 0;
    if (means.len == 2) return if (@abs(means[0]) >= @abs(means[1])) 1 else -1;

    const left_end = @max(@as(usize, 1), means.len / 3);
    const mid_end = @max(left_end + 1, (means.len * 2) / 3);

    var left: f64 = 0;
    var mid: f64 = 0;
    var right: f64 = 0;

    for (means[0..left_end]) |v| left += @abs(v);
    for (means[left_end..mid_end]) |v| mid += @abs(v);
    for (means[mid_end..]) |v| right += @abs(v);

    if (left >= mid and left >= right) return 1;
    if (right >= mid and right >= left) return -1;
    return 0;
}

fn parseDelimitedSummary(
    content: []const u8,
    channel_count: usize,
    column_offset: usize,
    allocator: std.mem.Allocator,
) (ParseError || error{OutOfMemory})!BrainflojSummary {
    if (channel_count == 0) return ParseError.InvalidArgs;
    if (column_offset > 4096) return ParseError.InvalidArgs;

    const sample0 = try allocator.alloc(f64, channel_count);
    errdefer allocator.free(sample0);
    const means = try allocator.alloc(f64, channel_count);
    errdefer allocator.free(means);
    const mins = try allocator.alloc(f64, channel_count);
    errdefer allocator.free(mins);
    const maxs = try allocator.alloc(f64, channel_count);
    errdefer allocator.free(maxs);
    const energy = try allocator.alloc(f64, channel_count);
    errdefer allocator.free(energy);
    const frame = try allocator.alloc(f64, channel_count);
    defer allocator.free(frame);

    @memset(means, 0);
    @memset(energy, 0);
    for (mins) |*v| v.* = std.math.inf(f64);
    for (maxs) |*v| v.* = -std.math.inf(f64);

    var sample_count: usize = 0;
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var token_idx: usize = 0;
        var selected: usize = 0;
        var toks = std.mem.tokenizeAny(u8, line, ",\t; ");
        while (toks.next()) |tok| : (token_idx += 1) {
            if (token_idx < column_offset) continue;
            if (selected >= channel_count) break;
            const parsed = std.fmt.parseFloat(f64, tok) catch {
                if (selected == 0) break;
                return ParseError.InvalidData;
            };
            frame[selected] = parsed;
            selected += 1;
        }

        if (selected == 0) continue;
        if (selected != channel_count) return ParseError.InvalidData;

        if (sample_count == 0) @memcpy(sample0, frame);

        for (0..channel_count) |i| {
            const v = frame[i];
            means[i] += v;
            energy[i] += @abs(v);
            mins[i] = @min(mins[i], v);
            maxs[i] = @max(maxs[i], v);
        }
        sample_count += 1;
    }

    if (sample_count == 0) return ParseError.EmptyInput;

    const sample_count_f64 = @as(f64, @floatFromInt(sample_count));
    for (means) |*v| v.* /= sample_count_f64;

    return .{
        .sample_count = sample_count,
        .channel_count = channel_count,
        .column_offset = column_offset,
        .sample0 = sample0,
        .means = means,
        .mins = mins,
        .maxs = maxs,
        .energy = energy,
        .entropy = shannonEntropy(energy),
        .trit = classifyTrit(means),
    };
}

fn summaryToValue(summary: *const BrainflojSummary, gc: *GC, path: ?[]const u8) !Value {
    const obj = try gc.allocObj(.map);
    if (path) |p| try addKV(obj, gc, "path", Value.makeString(try gc.internString(p)));
    try addKV(obj, gc, "samples", Value.makeInt(@intCast(summary.sample_count)));
    try addKV(obj, gc, "channels", Value.makeInt(@intCast(summary.channel_count)));
    try addKV(obj, gc, "column-offset", Value.makeInt(@intCast(summary.column_offset)));
    try addKV(obj, gc, "sample0", try makeFloatVector(gc, summary.sample0));
    try addKV(obj, gc, "means", try makeFloatVector(gc, summary.means));
    try addKV(obj, gc, "mins", try makeFloatVector(gc, summary.mins));
    try addKV(obj, gc, "maxs", try makeFloatVector(gc, summary.maxs));
    try addKV(obj, gc, "entropy", Value.makeFloat(summary.entropy));
    try addKV(obj, gc, "trit", Value.makeInt(@intCast(@as(i48, summary.trit))));
    return Value.makeObj(obj);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.Overflow;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const file = std.c.fopen(@ptrCast(&pbuf), "r") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    var contents = compat.emptyList(u8);
    errdefer contents.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const read_n = std.c.fread(&buf, 1, buf.len, file);
        if (read_n == 0) break;
        try contents.appendSlice(allocator, buf[0..read_n]);
    }
    return try allocator.dupe(u8, contents.items);
}

pub fn brainflojParseFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isInt()) return error.TypeError;

    const content = gc.getString(args[0].asStringId());
    const channels_raw = args[1].asInt();
    if (channels_raw <= 0) return error.InvalidArgs;
    const channel_count: usize = @intCast(channels_raw);

    const column_offset: usize = if (args.len == 3) blk: {
        if (!args[2].isInt()) return error.TypeError;
        if (args[2].asInt() < 0) return error.InvalidArgs;
        break :blk @intCast(args[2].asInt());
    } else 0;

    var summary = try parseDelimitedSummary(content, channel_count, column_offset, gc.allocator);
    defer summary.deinit(gc.allocator);
    return try summaryToValue(&summary, gc, null);
}

pub fn brainflojReadFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isInt()) return error.TypeError;

    const path = gc.getString(args[0].asStringId());
    const channels_raw = args[1].asInt();
    if (channels_raw <= 0) return error.InvalidArgs;
    const channel_count: usize = @intCast(channels_raw);

    const column_offset: usize = if (args.len == 3) blk: {
        if (!args[2].isInt()) return error.TypeError;
        if (args[2].asInt() < 0) return error.InvalidArgs;
        break :blk @intCast(args[2].asInt());
    } else 0;

    const content = try readFileAlloc(gc.allocator, path);
    defer gc.allocator.free(content);

    var summary = try parseDelimitedSummary(content, channel_count, column_offset, gc.allocator);
    defer summary.deinit(gc.allocator);
    return try summaryToValue(&summary, gc, path);
}

test "brainfloj parses headered matrix with offset" {
    const content =
        \\sample,ch0,ch1,ch2
        \\0,1.0,2.0,3.0
        \\1,4.0,5.0,6.0
    ;

    var summary = try parseDelimitedSummary(content, 3, 1, std.testing.allocator);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), summary.sample_count);
    try std.testing.expectEqual(@as(usize, 3), summary.channel_count);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), summary.sample0[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), summary.means[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), summary.means[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), summary.means[2], 1e-9);
    try std.testing.expectEqual(@as(i8, -1), summary.trit);
}

test "brainfloj parse builtin returns map" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const text_id = try gc.internString(
        \\1,2,3
        \\4,5,6
    );
    var args = [_]Value{
        Value.makeString(text_id),
        Value.makeInt(3),
    };
    var res = Resources.initDefault();
    const out = try brainflojParseFn(&args, &gc, &env, &res);
    try std.testing.expect(out.isObj());
    try std.testing.expect(out.asObj().kind == .map);
}

test "brainfloj rejects zero channels" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const text_id = try gc.internString("1,2,3");
    var args = [_]Value{
        Value.makeString(text_id),
        Value.makeInt(0),
    };
    var res = Resources.initDefault();
    try std.testing.expectError(error.InvalidArgs, brainflojParseFn(&args, &gc, &env, &res));
}

// ── Serial stream: (brainfloj-serial port n-channels helek-seconds) ──

fn clockMicros() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

fn sleepMs(ms: u64) void {
    const req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

pub const SerialError = error{
    OpenFailed,
    ConfigFailed,
    ReadFailed,
};

pub fn openSerial(path: []const u8, baud: u32) SerialError!std.posix.fd_t {
    var pbuf: [256]u8 = undefined;
    if (path.len >= pbuf.len) return SerialError.OpenFailed;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const fd = std.posix.openat(std.posix.AT.FDCWD, @ptrCast(pbuf[0..path.len]), .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch
        return SerialError.OpenFailed;

    // Configure termios
    var tio: std.posix.termios = undefined;
    if (std.c.tcgetattr(fd, &tio) != 0) return SerialError.ConfigFailed;

    // Raw mode
    tio.iflag = .{};
    tio.oflag = .{};
    tio.lflag = .{};
    tio.cflag = .{ .CREAD = true, .CLOCAL = true, .CSIZE = .CS8 };

    // Baud rate — set ispeed/ospeed fields directly
    const speed: std.posix.speed_t = switch (baud) {
        9600 => .B9600,
        19200 => .B19200,
        38400 => .B38400,
        57600 => .B57600,
        115200 => .B115200,
        230400 => .B230400,
        else => .B115200,
    };
    tio.ispeed = speed;
    tio.ospeed = speed;

    // VMIN=0, VTIME=10 (1s timeout)
    tio.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    tio.cc[@intFromEnum(std.posix.V.TIME)] = 10;

    if (std.c.tcsetattr(fd, .NOW, &tio) != 0) return SerialError.ConfigFailed;

    // Clear NONBLOCK for blocking reads with VTIME
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = 0x0004; // macOS
    const flags = std.c.fcntl(fd, F_GETFL);
    if (flags == -1) return SerialError.ConfigFailed;
    if (std.c.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == -1)
        return SerialError.ConfigFailed;

    return fd;
}

fn parse24bit(b0: u8, b1: u8, b2: u8) f64 {
    const raw: u32 = (@as(u32, b0) << 16) | (@as(u32, b1) << 8) | @as(u32, b2);
    const signed: i32 = if (raw >= 0x800000) @as(i32, @intCast(raw)) - 0x1000000 else @as(i32, @intCast(raw));
    return @floatFromInt(signed);
}

/// (brainfloj-serial "/dev/cu.usbserial-AI1B2OSR" 20)          ; 1 helek, 115200 baud
/// (brainfloj-serial "/dev/cu.usbserial-AI1B2OSR" 20 3.333)    ; custom duration
/// (brainfloj-serial "/dev/cu.usbserial-AI1B2OSR" 20 3.333 921600) ; custom baud
pub fn brainflojSerialFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2 or args.len > 4) return error.ArityError;
    if (!args[0].isString() or !args[1].isInt()) return error.TypeError;

    const port = gc.getString(args[0].asStringId());
    const n_ch_raw = args[1].asInt();
    if (n_ch_raw <= 0 or n_ch_raw > 256) return error.InvalidArgs;
    const n_ch: usize = @intCast(n_ch_raw);

    const helek_sec: f64 = if (args.len >= 3) blk: {
        if (!args[2].isFloat() and !args[2].isInt()) return error.TypeError;
        break :blk if (args[2].isFloat()) args[2].asFloat() else @as(f64, @floatFromInt(args[2].asInt()));
    } else 10.0 / 3.0; // 1 helek

    const baud: u32 = if (args.len >= 4) blk: {
        if (!args[3].isInt()) return error.TypeError;
        break :blk @intCast(args[3].asInt());
    } else 115200;

    const fd = openSerial(port, baud) catch return error.InvalidArgs;
    defer _ = std.c.close(fd);

    const pkt_size = n_ch * 3;
    const max_samples: usize = @intFromFloat(helek_sec * 1000); // generous upper bound
    const buf_size = max_samples * pkt_size;
    const buf = gc.allocator.alloc(u8, @min(buf_size, 1024 * 1024)) catch return error.OutOfMemory;
    defer gc.allocator.free(buf);

    // Read for helek_sec duration
    var total_read: usize = 0;
    const start_us = clockMicros();
    const duration_us: i64 = @intFromFloat(helek_sec * 1e6);

    while (clockMicros() - start_us < duration_us) {
        if (total_read >= buf.len) break;
        const remaining = buf.len - total_read;
        const n = std.posix.read(fd, buf[total_read..][0..@min(remaining, 4096)]) catch |err| {
            if (err == error.WouldBlock) {
                sleepMs(10);
                continue;
            }
            break;
        };
        if (n == 0) {
            sleepMs(10);
            continue;
        }
        total_read += n;
    }

    const elapsed_us = clockMicros() - start_us;
    const elapsed_sec: f64 = @as(f64, @floatFromInt(elapsed_us)) / 1e6;

    // Parse 24-bit packets
    const n_packets = total_read / pkt_size;
    if (n_packets == 0) return error.EmptyInput;

    const means = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(means);
    const mins = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(mins);
    const maxs = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(maxs);
    const energy_arr = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(energy_arr);
    const sample0 = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(sample0);
    const stds = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(stds);

    @memset(means, 0);
    @memset(energy_arr, 0);
    @memset(stds, 0);
    for (mins) |*v| v.* = std.math.inf(f64);
    for (maxs) |*v| v.* = -std.math.inf(f64);

    for (0..n_packets) |p| {
        for (0..n_ch) |ch| {
            const idx = p * pkt_size + ch * 3;
            const v = parse24bit(buf[idx], buf[idx + 1], buf[idx + 2]);
            if (p == 0) sample0[ch] = v;
            means[ch] += v;
            energy_arr[ch] += @abs(v);
            mins[ch] = @min(mins[ch], v);
            maxs[ch] = @max(maxs[ch], v);
        }
    }

    const n_f: f64 = @floatFromInt(n_packets);
    for (means) |*v| v.* /= n_f;

    // Second pass for std
    for (0..n_packets) |p| {
        for (0..n_ch) |ch| {
            const idx = p * pkt_size + ch * 3;
            const v = parse24bit(buf[idx], buf[idx + 1], buf[idx + 2]);
            const diff = v - means[ch];
            stds[ch] += diff * diff;
        }
    }
    for (stds) |*v| v.* = @sqrt(v.* / n_f);

    const entropy = shannonEntropy(energy_arr);
    const trit = classifyTrit(means);
    const effective_hz = n_f / elapsed_sec;

    // Build result map
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "port", Value.makeString(try gc.internString(port)));
    try addKV(obj, gc, "baud", Value.makeInt(@intCast(baud)));
    try addKV(obj, gc, "samples", Value.makeInt(@intCast(n_packets)));
    try addKV(obj, gc, "channels", Value.makeInt(@intCast(n_ch)));
    try addKV(obj, gc, "hz", Value.makeFloat(effective_hz));
    try addKV(obj, gc, "elapsed", Value.makeFloat(elapsed_sec));
    try addKV(obj, gc, "bytes", Value.makeInt(@intCast(total_read)));
    try addKV(obj, gc, "sample0", try makeFloatVector(gc, sample0));
    try addKV(obj, gc, "means", try makeFloatVector(gc, means));
    try addKV(obj, gc, "stds", try makeFloatVector(gc, stds));
    try addKV(obj, gc, "mins", try makeFloatVector(gc, mins));
    try addKV(obj, gc, "maxs", try makeFloatVector(gc, maxs));
    try addKV(obj, gc, "entropy", Value.makeFloat(entropy));
    try addKV(obj, gc, "trit", Value.makeInt(@intCast(@as(i48, trit))));

    // Mode detection
    const mode_str = if (entropy < 3.8 and stds[0] < 50000) "acquisition" else if (entropy < 4.0) "transitioning" else "impedance";
    try addKV(obj, gc, "mode", Value.makeString(try gc.internString(mode_str)));

    return Value.makeObj(obj);
}
