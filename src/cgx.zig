//! CGX / Cognionics HD-72 serial protocol parser.
//!
//! Reverse-engineered from CGX Acquisition v66 (.NET, CIL disassembly).
//! Supports both legacy and non-legacy (delta-compressed) packet formats.
//! See examples/CGX_PROTOCOL.md for full protocol documentation.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const brainfloj = @import("brainfloj.zig");

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

// --- Protocol constants ---

pub const READ_CONFIG_CMD: u8 = 0x14;
pub const WRITE_CONFIG_CMD: u8 = 0x13;
pub const CONFIG_MAGIC: u24 = 0x392802;
pub const DEVICE_DL_FINISHED: u32 = 0x499602D2;
pub const MAX_BYTES_FLUSH: usize = 262_144;
pub const MAX_BYTES_PREFLUSH: usize = 65_536;

/// XOR encryption keys (legacy format).
const XOR_KEY = [3]u8{ 0xAD, 0x39, 0xBF };

/// Config byte-array offsets (LOC_* constants from .NET).
pub const Config = struct {
    pub const MAX_CONFIG_CHS: usize = 4;
    pub const CH_COUNT_LIMIT: usize = 6;
    pub const CONFIG_FORMAT: usize = 7;
    pub const NUM_ADS: usize = 10;
    pub const NUM_ADSCH: usize = 11;
    pub const EXT_CHS: usize = 12;
    pub const ACC_CHS: usize = 13;
    pub const INPUT_MODE: usize = 14;
    pub const GAIN: usize = 15;
    pub const HIRES_MODE: usize = 16;
    pub const SAMPLE_RATE: usize = 17;
    pub const IMP_MODE: usize = 18;
    pub const DATA_MODE: usize = 20;
    pub const NRF_EN: usize = 21;
    pub const CUR_CHS: usize = 40;
    pub const CH_MASK_START: usize = 160;
    pub const CH_NAME_START: usize = 240;
};

pub const MAX_EEG_CHANNELS = 64;
pub const MAX_EXT_CHANNELS = 8;
pub const MAX_ACC_CHANNELS = 8;
pub const MAX_TOTAL_CHANNELS = MAX_EEG_CHANNELS + MAX_EXT_CHANNELS + MAX_ACC_CHANNELS;

// --- Packet types ---

pub const LegacyPacket = struct {
    sequence: u8,
    eeg: [MAX_EEG_CHANNELS]i32 = undefined,
    ext: [MAX_EXT_CHANNELS]i32 = undefined,
    acc: [MAX_ACC_CHANNELS]i32 = undefined,
    num_eeg: u8 = 0,
    num_ext: u8 = 0,
    num_acc: u8 = 0,
    impedance: u8 = 0,
    battery_raw: u8 = 0,
    trigger: u16 = 0,
};

pub const ModernPacket = struct {
    sequence: u16,
    eeg: [MAX_EEG_CHANNELS]i32 = undefined,
    ext: [MAX_EXT_CHANNELS]i32 = undefined,
    acc: [MAX_ACC_CHANNELS]i32 = undefined,
    num_eeg: u8 = 0,
    num_ext: u8 = 0,
    num_acc: u8 = 0,
    status: u8 = 0,
    trigger: u32 = 0,
    battery_raw: u16 = 0,
    has_impedance: bool = false,
    has_trigger: bool = false,
    has_battery: bool = false,
};

pub const Packet = union(enum) {
    legacy: LegacyPacket,
    modern: ModernPacket,

    pub fn eegSlice(self: *const Packet) []const i32 {
        return switch (self.*) {
            .legacy => |*p| p.eeg[0..p.num_eeg],
            .modern => |*p| p.eeg[0..p.num_eeg],
        };
    }

    pub fn sequence(self: *const Packet) u32 {
        return switch (self.*) {
            .legacy => |p| p.sequence,
            .modern => |p| p.sequence,
        };
    }
};

// --- Stream parser ---

pub const ParseError = error{
    NeedMoreData,
    SyncLost,
    InvalidPacket,
};

pub const StreamParser = struct {
    num_eeg: u8,
    num_ext: u8,
    num_acc: u8,
    encrypted: bool,
    legacy_format: bool,
    battery_gain: f64,

    /// Previous EEG values for delta decoding (modern format).
    prev_eeg: [MAX_EEG_CHANNELS]i32 = [_]i32{0} ** MAX_EEG_CHANNELS,

    last_sequence: ?u32 = null,
    lost_packets: u64 = 0,
    good_packets: u64 = 0,

    pub fn init(num_eeg: u8, num_ext: u8, num_acc: u8, legacy: bool, encrypted: bool) StreamParser {
        return .{
            .num_eeg = num_eeg,
            .num_ext = num_ext,
            .num_acc = num_acc,
            .encrypted = encrypted,
            .legacy_format = legacy,
            .battery_gain = 1.0,
        };
    }

    /// Expected legacy packet size (after sync byte).
    pub fn legacyPacketSize(self: *const StreamParser) usize {
        const ch: usize = @as(usize, self.num_eeg) + self.num_ext + self.num_acc;
        // counter(1) + channels*3 + impedance(1) + battery(1) + trigger(2)
        return 1 + ch * 3 + 1 + 1 + 2;
    }

    /// Parse a legacy packet from a byte slice starting after sync (0xFF).
    /// Returns number of bytes consumed.
    pub fn parseLegacy(self: *StreamParser, data: []const u8, out: *LegacyPacket) ParseError!usize {
        const need = self.legacyPacketSize();
        if (data.len < need) return ParseError.NeedMoreData;

        var pos: usize = 0;

        // Sequence counter
        out.sequence = data[pos];
        pos += 1;

        // Detect lost packets: counter wraps at 0x7F (7-bit)
        if (self.last_sequence) |prev| {
            const expected = (prev + 1) & 0x7F;
            if (out.sequence != @as(u8, @truncate(expected))) {
                // Count gap, wrapping at 0x81 boundary per .NET logic
                const diff = (@as(u32, out.sequence) -% @as(u32, @truncate(expected))) & 0x7F;
                if (diff > 0 and diff < 0x40) {
                    self.lost_packets += diff;
                }
            }
        }
        self.last_sequence = out.sequence;

        const total_ch: usize = @as(usize, self.num_eeg) + self.num_ext + self.num_acc;
        out.num_eeg = self.num_eeg;
        out.num_ext = self.num_ext;
        out.num_acc = self.num_acc;

        // Parse channels: 3 bytes each, big-endian 24-bit signed
        for (0..total_ch) |ch| {
            var b0 = data[pos];
            var b1 = data[pos + 1];
            var b2 = data[pos + 2];
            pos += 3;

            if (self.encrypted) {
                b0 ^= XOR_KEY[0];
                b1 ^= XOR_KEY[1];
                b2 ^= XOR_KEY[2];
            }

            // Legacy assembly: (b0<<24 | b1<<17 | b2<<10) >> 8
            // This is equivalent to (b0<<16 | b1<<9 | b2<<2) with unusual alignment.
            // The .NET CIL shows shifts 24,17,10 then >>8.
            const raw: i32 = (@as(i32, b0) << 24 | @as(i32, b1) << 17 | @as(i32, b2) << 10) >> 8;

            if (ch < self.num_eeg) {
                out.eeg[ch] = raw;
            } else if (ch < @as(usize, self.num_eeg) + self.num_ext) {
                out.ext[ch - self.num_eeg] = raw;
            } else {
                out.acc[ch - @as(usize, self.num_eeg) - self.num_ext] = raw;
            }
        }

        // Impedance byte
        out.impedance = data[pos];
        pos += 1;

        // Battery byte
        out.battery_raw = data[pos];
        pos += 1;

        // Trigger: 2 bytes big-endian
        out.trigger = @as(u16, data[pos]) << 8 | data[pos + 1];
        pos += 2;

        self.good_packets += 1;
        return pos;
    }

    /// Parse a modern (non-legacy) packet from data starting after 3×0xFF sync.
    pub fn parseModern(self: *StreamParser, data: []const u8, out: *ModernPacket) ParseError!usize {
        // Minimum: 2 (seq) + 1 (status) = 3, but EEG delta data is variable
        if (data.len < 3) return ParseError.NeedMoreData;

        var pos: usize = 0;

        // 2-byte sequence
        out.sequence = @as(u16, data[pos]) << 8 | data[pos + 1];
        pos += 2;

        out.num_eeg = self.num_eeg;
        out.num_ext = self.num_ext;
        out.num_acc = self.num_acc;

        // Delta-compressed EEG data (ReadDeltaData)
        // Verified from CIL disassembly of CGX Acquisition v66.
        // First byte is a reset flag: if 1, clear all prev sample buffers.
        if (pos >= data.len) return ParseError.NeedMoreData;
        const reset_flag = data[pos];
        pos += 1;
        if (reset_flag == 1) {
            @memset(&self.prev_eeg, 0);
        }

        // Per-channel: variable-length encoding keyed on low 2 bits of first byte.
        for (0..self.num_eeg) |ch| {
            if (pos >= data.len) return ParseError.NeedMoreData;
            const b: i32 = @intCast(data[pos]);
            pos += 1;

            if (b & 1 != 0) {
                // 1-byte delta: bit0=1 flag. Bits [7:1] are 7-bit signed delta, scaled <<3.
                // CIL: b >>= 1; b <<= 25; b >>= 25; b <<= 3;
                var delta: i32 = b >> 1;
                delta = (delta << 25) >> 25; // sign-extend 7 bits
                delta <<= 3; // scale
                self.prev_eeg[ch] +%= delta;
                out.eeg[ch] = self.prev_eeg[ch];
            } else if ((b >> 1) & 1 != 0) {
                // 2-byte delta: bits [1:0]=10. Second byte from stream.
                // CIL: combined = (b & 0xFC) | (b2 << 8); combined <<= 16; combined >>= 15;
                if (pos >= data.len) return ParseError.NeedMoreData;
                const b2: i32 = @intCast(data[pos]);
                pos += 1;
                var combined: i32 = (b & 0xFC) | (b2 << 8);
                combined = (combined << 16) >> 15; // sign-extend and scale
                self.prev_eeg[ch] +%= combined;
                out.eeg[ch] = self.prev_eeg[ch];
            } else {
                // 3-byte absolute value: bits [1:0]=00. Two more bytes from stream.
                // CIL: val = (b3<<24 | b2<<16 | (b & 0xF8)<<8); val >>= 8;
                if (pos + 2 > data.len) return ParseError.NeedMoreData;
                const b2: i32 = @intCast(data[pos]);
                const b3: i32 = @intCast(data[pos + 1]);
                pos += 2;
                const val: i32 = ((b3 << 24) | (b2 << 16) | ((b & 0xF8) << 8)) >> 8;
                self.prev_eeg[ch] = val;
                out.eeg[ch] = val;
            }
        }

        // EXT channels: 3 bytes each, standard 24-bit BE, shifted left by 3
        for (0..self.num_ext) |ch| {
            if (pos + 3 > data.len) return ParseError.NeedMoreData;
            const raw = signExtend24(data[pos], data[pos + 1], data[pos + 2]);
            pos += 3;
            out.ext[ch] = raw << 3;
        }

        // ACC channels: 3 bytes each, standard 24-bit BE
        for (0..self.num_acc) |ch| {
            if (pos + 3 > data.len) return ParseError.NeedMoreData;
            out.acc[ch] = signExtend24(data[pos], data[pos + 1], data[pos + 2]);
            pos += 3;
        }

        // Status byte
        if (pos >= data.len) return ParseError.NeedMoreData;
        out.status = data[pos];
        pos += 1;

        out.has_impedance = (out.status & 0x01) != 0;
        out.has_trigger = (out.status & 0x04) != 0;
        out.has_battery = (out.status & 0x20) != 0;

        // Optional trigger (4 bytes BE)
        if (out.has_trigger) {
            if (pos + 4 > data.len) return ParseError.NeedMoreData;
            out.trigger = @as(u32, data[pos]) << 24 | @as(u32, data[pos + 1]) << 16 |
                @as(u32, data[pos + 2]) << 8 | data[pos + 3];
            pos += 4;
        }

        // Optional battery (2 bytes)
        if (out.has_battery) {
            if (pos + 2 > data.len) return ParseError.NeedMoreData;
            out.battery_raw = @as(u16, data[pos]) << 8 | data[pos + 1];
            pos += 2;
        }

        self.good_packets += 1;
        return pos;
    }

    /// Scan for sync pattern and parse next packet.
    /// Returns bytes consumed from `data` (including sync bytes).
    pub fn parseNext(self: *StreamParser, data: []const u8, out: *Packet) ParseError!usize {
        if (self.legacy_format) {
            // Legacy sync: single 0xFF byte
            for (0..data.len) |i| {
                if (data[i] == 0xFF) {
                    var pkt: LegacyPacket = .{ .sequence = 0 };
                    const consumed = self.parseLegacy(data[i + 1 ..], &pkt) catch |e| {
                        if (e == ParseError.NeedMoreData) return e;
                        continue; // try next 0xFF
                    };
                    out.* = .{ .legacy = pkt };
                    return i + 1 + consumed;
                }
            }
        } else {
            // Modern sync: three consecutive 0xFF bytes
            if (data.len < 3) return ParseError.NeedMoreData;
            for (0..data.len - 2) |i| {
                if (data[i] == 0xFF and data[i + 1] == 0xFF and data[i + 2] == 0xFF) {
                    var pkt: ModernPacket = .{ .sequence = 0 };
                    const consumed = self.parseModern(data[i + 3 ..], &pkt) catch |e| {
                        if (e == ParseError.NeedMoreData) return e;
                        continue;
                    };
                    out.* = .{ .modern = pkt };
                    return i + 3 + consumed;
                }
            }
        }
        return ParseError.SyncLost;
    }
};

/// Standard 24-bit big-endian sign extension.
fn signExtend24(b0: u8, b1: u8, b2: u8) i32 {
    return (@as(i32, b0) << 24 | @as(i32, b1) << 16 | @as(i32, b2) << 8) >> 8;
}

/// Convert raw ADC value to microvolts given ADS1299 gain.
pub fn adcToMicrovolts(raw: i32, gain: u8) f64 {
    // ADS1299: Vref = 4.5V, 24-bit, microvolts = raw * (4.5 / (2^23 * gain)) * 1e6
    const vref: f64 = 4.5;
    const scale = vref / (@as(f64, @floatFromInt(@as(i32, 1) << 23)) * @as(f64, @floatFromInt(gain)));
    return @as(f64, @floatFromInt(raw)) * scale * 1e6;
}

// --- Config parsing ---

pub const DeviceConfig = struct {
    num_ads: u8 = 0,
    num_adsch: u8 = 0,
    ext_chs: u8 = 0,
    acc_chs: u8 = 0,
    gain: u8 = 1,
    sample_rate_idx: u8 = 0,
    hires_mode: u8 = 0,
    imp_mode: u8 = 0,
    data_mode: u8 = 0,
    nrf_en: u8 = 0,
    cur_chs: u8 = 0,
    config_format: u8 = 0,
    legacy: bool = true,

    pub fn totalEeg(self: DeviceConfig) u8 {
        return self.num_ads * self.num_adsch;
    }

    pub fn totalChannels(self: DeviceConfig) u16 {
        return @as(u16, self.totalEeg()) + self.ext_chs + self.acc_chs;
    }
};

pub fn parseConfig(config_bytes: []const u8) ?DeviceConfig {
    if (config_bytes.len < Config.CH_NAME_START) return null;

    // Check magic word at bytes 0-2
    const magic: u24 = @as(u24, config_bytes[0]) << 16 | @as(u24, config_bytes[1]) << 8 | config_bytes[2];
    if (magic != CONFIG_MAGIC) return null;

    return .{
        .num_ads = config_bytes[Config.NUM_ADS],
        .num_adsch = config_bytes[Config.NUM_ADSCH],
        .ext_chs = config_bytes[Config.EXT_CHS],
        .acc_chs = config_bytes[Config.ACC_CHS],
        .gain = config_bytes[Config.GAIN],
        .sample_rate_idx = config_bytes[Config.SAMPLE_RATE],
        .hires_mode = config_bytes[Config.HIRES_MODE],
        .imp_mode = config_bytes[Config.IMP_MODE],
        .data_mode = config_bytes[Config.DATA_MODE],
        .nrf_en = config_bytes[Config.NRF_EN],
        .cur_chs = config_bytes[Config.CUR_CHS],
        .config_format = config_bytes[Config.CONFIG_FORMAT],
        .legacy = config_bytes[Config.DATA_MODE] == 0,
    };
}

// --- Tests ---

test "legacy packet parse - unencrypted" {
    var parser = StreamParser.init(2, 0, 0, true, false);
    // Build test packet: counter=5, 2 channels of 3 bytes each, imp=0, batt=128, trigger=0x0100
    const pkt = [_]u8{
        5, // counter
        0x00, 0x00, 0x10, // ch0: small positive via legacy assembly
        0x00, 0x00, 0x20, // ch1
        0x00, // impedance
        0x80, // battery
        0x01, 0x00, // trigger
    };
    var out: LegacyPacket = .{ .sequence = 0 };
    const consumed = try parser.parseLegacy(&pkt, &out);
    try std.testing.expectEqual(@as(usize, 11), consumed);
    try std.testing.expectEqual(@as(u8, 5), out.sequence);
    try std.testing.expectEqual(@as(u16, 0x0100), out.trigger);
    try std.testing.expectEqual(@as(u8, 0x80), out.battery_raw);
}

test "legacy packet parse - encrypted XOR" {
    var parser = StreamParser.init(1, 0, 0, true, true);
    // Encrypt bytes: original (0x12, 0x34, 0x56) → XOR with (0xAD, 0x39, 0xBF)
    const b0 = 0x12 ^ 0xAD;
    const b1 = 0x34 ^ 0x39;
    const b2 = 0x56 ^ 0xBF;
    const pkt = [_]u8{ 0, b0, b1, b2, 0, 0, 0, 0 };
    var out: LegacyPacket = .{ .sequence = 0 };
    _ = try parser.parseLegacy(&pkt, &out);
    // After XOR decrypt, legacy assembly: (0x12<<24 | 0x34<<17 | 0x56<<10) >> 8
    const expected: i32 = (@as(i32, 0x12) << 24 | @as(i32, 0x34) << 17 | @as(i32, 0x56) << 10) >> 8;
    try std.testing.expectEqual(expected, out.eeg[0]);
}

test "sign extend 24" {
    // Positive: 0x7FFFFF
    try std.testing.expectEqual(@as(i32, 0x7FFFFF), signExtend24(0x7F, 0xFF, 0xFF));
    // Negative: 0x800000 → -8388608
    try std.testing.expectEqual(@as(i32, -8388608), signExtend24(0x80, 0x00, 0x00));
    // -1: 0xFFFFFF
    try std.testing.expectEqual(@as(i32, -1), signExtend24(0xFF, 0xFF, 0xFF));
}

test "sync scan legacy" {
    var parser = StreamParser.init(1, 0, 0, true, false);
    // Garbage + 0xFF sync + packet
    var buf: [20]u8 = undefined;
    buf[0] = 0x42; // garbage
    buf[1] = 0x13; // garbage
    buf[2] = 0xFF; // sync
    buf[3] = 7; // counter
    buf[4] = 0; // ch0 b0
    buf[5] = 0;
    buf[6] = 0; // ch0 b2
    buf[7] = 0; // impedance
    buf[8] = 0; // battery
    buf[9] = 0;
    buf[10] = 0; // trigger

    var out: Packet = undefined;
    const consumed = try parser.parseNext(&buf, &out);
    try std.testing.expectEqual(@as(usize, 11), consumed); // 2 garbage + 1 sync + 8 payload
    try std.testing.expectEqual(@as(u32, 7), out.sequence());
}

test "modern delta decode - 1 byte delta" {
    var parser = StreamParser.init(2, 0, 0, false, false);
    // Set prev values
    parser.prev_eeg[0] = 1000;
    parser.prev_eeg[1] = 2000;

    // Build packet: seq(2) + reset(1) + ch0_delta(1) + ch1_delta(1) + status(1)
    // 1-byte delta: bit0=1, bits[7:1] = signed 7-bit value, scaled <<3
    // delta=5: (5<<1)|1 = 0x0B. After decode: 5<<3=40, prev+40=1040
    // delta=-3: two's complement 7-bit: (-3)&0x7F=0x7D, (0x7D<<1)|1=0xFB. After: -3<<3=-24, prev-24=1976
    const pkt = [_]u8{
        0x00, 0x01, // sequence
        0x00, // reset=no
        0x0B, // ch0: delta=+5 -> +40
        0xFB, // ch1: delta=-3 -> -24
        0x00, // status
    };
    var out: ModernPacket = .{ .sequence = 0 };
    _ = try parser.parseModern(&pkt, &out);
    try std.testing.expectEqual(@as(i32, 1040), out.eeg[0]);
    try std.testing.expectEqual(@as(i32, 1976), out.eeg[1]);
}

test "modern delta decode - 3 byte absolute" {
    var parser = StreamParser.init(1, 0, 0, false, false);
    // 3-byte absolute: bits[1:0]=00, then 2 more bytes
    // b=0x00, b2=0x12, b3=0x34 -> (0x34<<24 | 0x12<<16 | 0<<8) >> 8 = 0x341200 >> 8 = 0x003412
    const pkt = [_]u8{
        0x00, 0x01, // sequence
        0x00, // reset=no
        0x00, 0x12, 0x34, // ch0: absolute
        0x00, // status
    };
    var out: ModernPacket = .{ .sequence = 0 };
    _ = try parser.parseModern(&pkt, &out);
    const expected: i32 = (@as(i32, 0x34) << 24 | @as(i32, 0x12) << 16 | 0) >> 8;
    try std.testing.expectEqual(expected, out.eeg[0]);
}

test "modern delta decode - reset flag" {
    var parser = StreamParser.init(1, 0, 0, false, false);
    parser.prev_eeg[0] = 99999;
    // Reset flag=1 should clear prev, then 1-byte delta of 0 -> value = 0
    const pkt = [_]u8{
        0x00, 0x01, // sequence
        0x01, // reset=YES
        0x01, // ch0: 1-byte delta=0 (0x01 -> val>>1=0, sign-ext=0, <<3=0)
        0x00, // status
    };
    var out: ModernPacket = .{ .sequence = 0 };
    _ = try parser.parseModern(&pkt, &out);
    try std.testing.expectEqual(@as(i32, 0), out.eeg[0]);
    try std.testing.expectEqual(@as(i32, 0), parser.prev_eeg[0]);
}

test "config parse" {
    var cfg_bytes = [_]u8{0} ** 256;
    // Set magic
    cfg_bytes[0] = 0x39;
    cfg_bytes[1] = 0x28;
    cfg_bytes[2] = 0x02;
    cfg_bytes[Config.NUM_ADS] = 8;
    cfg_bytes[Config.NUM_ADSCH] = 8;
    cfg_bytes[Config.EXT_CHS] = 2;
    cfg_bytes[Config.ACC_CHS] = 3;
    cfg_bytes[Config.GAIN] = 24;

    const cfg = parseConfig(&cfg_bytes).?;
    try std.testing.expectEqual(@as(u8, 64), cfg.totalEeg());
    try std.testing.expectEqual(@as(u16, 69), cfg.totalChannels());
    try std.testing.expectEqual(@as(u8, 24), cfg.gain);
}

// --- Runtime builtins ---

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

fn makeIntVector(gc: *GC, vals: []const i32, count: usize) !Value {
    const vec = try gc.allocObj(.vector);
    for (vals[0..count]) |v| {
        try vec.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(v)));
    }
    return Value.makeObj(vec);
}

/// (cgx-serial port)                          ; defaults: legacy, 64ch, 3Mbaud, 1 helek
/// (cgx-serial port {:keys [baud duration legacy encrypted eeg ext acc gain]})
pub fn cgxSerialFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const port = gc.getString(args[0].asStringId());

    // Defaults for HD-72
    const baud: u32 = 3_000_000;
    const duration_sec: f64 = 10.0 / 3.0; // 1 helek
    const legacy = true;
    const encrypted = false;
    const num_eeg: u8 = 64;
    const num_ext: u8 = 0;
    const num_acc: u8 = 3;
    const gain: u8 = 24;

    // Optional opts map
    if (args.len == 2) {
        if (!args[1].isObj()) return error.TypeError;
        // For now just use defaults — opts parsing can be added later
    }

    const fd = brainfloj.openSerial(port, baud) catch return error.InvalidArgs;
    defer _ = std.c.close(fd);

    // Capture raw bytes for `duration_sec`
    const buf = gc.allocator.alloc(u8, 1024 * 1024) catch return error.OutOfMemory;
    defer gc.allocator.free(buf);

    var total_read: usize = 0;
    const start_us = clockMicros();
    const duration_us: i64 = @intFromFloat(duration_sec * 1_000_000.0);

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
    const elapsed_sec: f64 = @as(f64, @floatFromInt(elapsed_us)) / 1_000_000.0;
    const data = buf[0..total_read];

    // Parse packets
    var parser = StreamParser.init(num_eeg, num_ext, num_acc, legacy, encrypted);
    parser.battery_gain = @floatFromInt(gain);

    // Collect per-channel running stats
    const n_ch: usize = @as(usize, num_eeg) + num_ext + num_acc;
    const means = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(means);
    const mins = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(mins);
    const maxs = try gc.allocator.alloc(f64, n_ch);
    defer gc.allocator.free(maxs);
    var first_eeg: [MAX_EEG_CHANNELS]i32 = undefined;
    var got_first = false;

    @memset(means, 0);
    for (mins) |*v| v.* = std.math.inf(f64);
    for (maxs) |*v| v.* = -std.math.inf(f64);

    var pos: usize = 0;
    var n_packets: usize = 0;

    while (pos < data.len) {
        var pkt: Packet = undefined;
        const consumed = parser.parseNext(data[pos..], &pkt) catch |e| {
            if (e == ParseError.NeedMoreData) break;
            pos += 1; // skip byte on sync loss
            continue;
        };
        pos += consumed;

        const eeg = pkt.eegSlice();
        if (!got_first and eeg.len > 0) {
            @memcpy(first_eeg[0..eeg.len], eeg);
            got_first = true;
        }

        for (eeg, 0..) |v, i| {
            const fv: f64 = @floatFromInt(v);
            means[i] += fv;
            mins[i] = @min(mins[i], fv);
            maxs[i] = @max(maxs[i], fv);
        }
        n_packets += 1;
    }

    // Build result map
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "port", Value.makeString(try gc.internString(port)));
    try addKV(obj, gc, "baud", Value.makeInt(@intCast(baud)));
    try addKV(obj, gc, "bytes", Value.makeInt(@intCast(total_read)));
    try addKV(obj, gc, "elapsed", Value.makeFloat(elapsed_sec));
    try addKV(obj, gc, "bytes-per-sec", Value.makeFloat(@as(f64, @floatFromInt(total_read)) / elapsed_sec));
    try addKV(obj, gc, "packets", Value.makeInt(@intCast(n_packets)));
    try addKV(obj, gc, "lost", Value.makeInt(@intCast(parser.lost_packets)));
    try addKV(obj, gc, "format", Value.makeString(try gc.internString(if (legacy) "legacy" else "modern")));

    if (n_packets > 0) {
        const n_f: f64 = @floatFromInt(n_packets);
        for (means[0..num_eeg]) |*v| v.* /= n_f;
        try addKV(obj, gc, "hz", Value.makeFloat(n_f / elapsed_sec));
        try addKV(obj, gc, "eeg-channels", Value.makeInt(@intCast(num_eeg)));
        if (got_first) try addKV(obj, gc, "sample0", try makeIntVector(gc, &first_eeg, num_eeg));
        try addKV(obj, gc, "means", try makeFloatVector(gc, means[0..num_eeg]));
        try addKV(obj, gc, "mins", try makeFloatVector(gc, mins[0..num_eeg]));
        try addKV(obj, gc, "maxs", try makeFloatVector(gc, maxs[0..num_eeg]));
    }

    return Value.makeObj(obj);
}

/// (cgx-parse raw-bytes)  ; parse a byte string using CGX legacy protocol
pub fn cgxParseFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const data = gc.getString(args[0].asStringId());

    var parser = StreamParser.init(64, 0, 3, true, false);
    var n_packets: usize = 0;
    var pos: usize = 0;

    while (pos < data.len) {
        var pkt: Packet = undefined;
        const consumed = parser.parseNext(@as([]const u8, data)[pos..], &pkt) catch |e| {
            if (e == ParseError.NeedMoreData) break;
            pos += 1;
            continue;
        };
        pos += consumed;
        n_packets += 1;
    }

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "packets", Value.makeInt(@intCast(n_packets)));
    try addKV(obj, gc, "lost", Value.makeInt(@intCast(parser.lost_packets)));
    try addKV(obj, gc, "bytes", Value.makeInt(@intCast(data.len)));
    return Value.makeObj(obj);
}

test "adc to microvolts" {
    // At gain=24, full scale positive (0x7FFFFF) ≈ 22.35 µV per LSB... let's just check non-zero
    const uv = adcToMicrovolts(1000, 24);
    try std.testing.expect(uv > 0);
    try std.testing.expect(uv < 100.0); // 1000 LSBs at gain 24 ≈ 22.35 µV
}
