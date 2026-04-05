//! spi_bus.zig: Serial Peripheral Interface as Provider — hardware/software SPI unification.
//!
//! The pun is load-bearing: SPI (Service Provider Interface) from spi.zig and SPI (Serial
//! Peripheral Interface) are structurally isomorphic. Both multiplex N providers on a shared
//! bus via a selection line:
//!
//!   Hardware SPI:  CS (Chip Select)    picks which peripheral talks on MOSI/MISO
//!   Software SPI:  Chomsky level       picks which engine talks on input/output
//!
//! GF(3) trit mapping of SPI bus lines:
//!   MOSI = +1  (efferent — master writes to slave, motor command)
//!   MISO = -1  (afferent — slave reads to master, sensory data)
//!   CLK  =  0  (synchronization — neutral, the metronome)
//!
//! This module defines BCI device providers (ADS1299 for EEG, AFE4404 for fNIRS) that
//! are simultaneously SPI-bus peripherals AND spi.Provider implementors.

const std = @import("std");
const spi = @import("spi.zig");
const pattern = @import("pattern.zig");
const MatchResult = pattern.MatchResult;

// ============================================================================
// SPI BUS PROTOCOL TYPES
// ============================================================================

/// SPI clock polarity: idle state of CLK line
pub const CPOL = enum(u1) {
    idle_low = 0, // CLK idles at 0
    idle_high = 1, // CLK idles at 1
};

/// SPI clock phase: which edge samples data
pub const CPHA = enum(u1) {
    leading_edge = 0, // data sampled on first (leading) clock edge
    trailing_edge = 1, // data sampled on second (trailing) clock edge
};

/// The four SPI modes = (CPOL, CPHA) pairs
pub const Mode = enum(u2) {
    mode0 = 0, // CPOL=0, CPHA=0 — most common (ADS1299 default)
    mode1 = 1, // CPOL=0, CPHA=1
    mode2 = 2, // CPOL=1, CPHA=0
    mode3 = 3, // CPOL=1, CPHA=1

    pub fn cpol(self: Mode) CPOL {
        return if (@intFromEnum(self) & 0b10 != 0) .idle_high else .idle_low;
    }

    pub fn cpha(self: Mode) CPHA {
        return if (@intFromEnum(self) & 0b01 != 0) .trailing_edge else .leading_edge;
    }
};

/// Bit order on the wire
pub const BitOrder = enum(u1) {
    msb_first = 0, // most significant bit first (standard for ADS1299, AFE4404)
    lsb_first = 1,
};

/// GF(3) trit assignments for SPI bus lines.
/// This is the fundamental observation: SPI's three signal lines map onto
/// the three values of GF(3), giving the bus a natural ternary semantics.
pub const BusLine = enum(i8) {
    mosi = 1, // +1: efferent (master→slave, write, motor command)
    clk = 0, //  0: synchronization (neutral, clock)
    miso = -1, // -1: afferent (slave→master, read, sensory data)

    pub fn trit(self: BusLine) i8 {
        return @intFromEnum(self);
    }
};

/// SPI bus configuration for a peripheral device
pub const BusConfig = struct {
    mode: Mode = .mode0,
    bit_order: BitOrder = .msb_first,
    clock_hz: u32, // clock frequency in Hz
    cs_index: u8, // chip select line index (0-based)

    /// The structural homomorphism: CS index ≅ Chomsky level select.
    /// On a hardware SPI bus, CS picks which chip speaks.
    /// On the software SPI registry, Chomsky level picks which engine speaks.
    /// Both are multiplexing N providers on a shared bus.
    pub fn chomskyAnalog(self: BusConfig) u8 {
        // CS 0 → Chomsky 0 (r.e. — most powerful, Prolog/Kanren)
        // CS 1 → Chomsky 1 (CSG — tree-sitter)
        // CS 2 → Chomsky 2 (CFG — PEG engines)
        // CS 3 → Chomsky 3 (regular — regexp engines)
        return self.cs_index;
    }
};

// ============================================================================
// SPI BUS FRAME: what travels on the wire
// ============================================================================

/// A single SPI transaction frame
pub const Frame = struct {
    /// Data written by master (MOSI direction, trit=+1)
    tx: []const u8,
    /// Data read from slave (MISO direction, trit=-1)
    rx: []u8,
    /// Number of clock cycles (CLK direction, trit=0)
    clock_cycles: u32,

    /// GF(3) conservation: tx(+1) + rx(-1) + clk(0) should balance.
    /// In practice: every byte transmitted generates one byte received
    /// and 8 clock cycles. The trit sum over a complete transaction is 0.
    pub fn tritBalance(self: Frame) i8 {
        const tx_trit: i8 = if (self.tx.len > 0) 1 else 0;
        const rx_trit: i8 = if (self.rx.len > 0) -1 else 0;
        const clk_trit: i8 = 0; // CLK is always neutral
        return tx_trit +| rx_trit +| clk_trit;
    }
};

// ============================================================================
// BCI DEVICE PROVIDERS: Hardware SPI peripherals as spi.Providers
// ============================================================================

/// ADS1299: Texas Instruments 24-bit ADC for EEG acquisition.
/// 8 channels, 250/500/1000/2000 SPS, SPI Mode 1 (CPOL=0, CPHA=1).
/// Used in OpenBCI Cyton, HackEEG, and BCI Factory boards.
pub const ADS1299Provider = struct {
    /// SPI bus configuration for this chip
    bus: BusConfig = .{
        .mode = .mode1, // ADS1299 uses CPOL=0, CPHA=1
        .bit_order = .msb_first,
        .clock_hz = 4_000_000, // 4 MHz typical
        .cs_index = 0, // first device on bus
    },

    /// Number of active channels (1-8)
    active_channels: u8 = 8,

    /// Samples per second
    sample_rate: u16 = 250,

    /// ADS1299 register commands (SPI MOSI bytes)
    pub const Command = enum(u8) {
        wakeup = 0x02,
        standby = 0x04,
        reset = 0x06,
        start = 0x08,
        stop = 0x0A,
        rdatac = 0x10, // read data continuous
        sdatac = 0x11, // stop read data continuous
        rdata = 0x12, // read data by command
        // Register read: 0x20 | reg_addr, then num_regs-1
        // Register write: 0x40 | reg_addr, then num_regs-1, then data
    };

    /// Produce a Provider (software SPI) from this hardware SPI device.
    /// The ADS1299 produces raw neural data → we parse it as a "pattern match"
    /// against expected EEG signal structure.
    pub fn provider(self: *const ADS1299Provider) spi.Provider(*const ADS1299Provider) {
        return .{
            .ctx = self,
            .matchFn = matchImpl,
            .nameFn = nameImpl,
            .chomskyFn = chomskyImpl,
        };
    }

    fn matchImpl(ctx: *const ADS1299Provider, input: []const u8, _: []const u8) MatchResult {
        // ADS1299 data frame: 3 bytes status + 3 bytes * N channels
        const frame_size = 3 + 3 * @as(usize, ctx.active_channels);
        if (input.len < frame_size) {
            return .{ .matched = false, .consumed = 0, .trit = -1 };
        }
        // Validate status byte: bits [23:20] = 1100 (fixed)
        const status_high = input[0];
        if (status_high & 0xF0 != 0xC0) {
            return .{ .matched = false, .consumed = 0, .trit = -1 };
        }
        return .{ .matched = true, .consumed = frame_size, .trit = 1 };
    }

    fn nameImpl(_: *const ADS1299Provider) []const u8 {
        return "bci/ads1299-eeg-spi";
    }

    fn chomskyImpl(_: *const ADS1299Provider) u8 {
        // EEG data is regular (fixed-format frames) → Chomsky 3
        // But CS analog maps to cs_index=0 → Chomsky 0
        // We report the DATA complexity, not the bus address
        return 3;
    }

    /// GF(3) interpretation of an EEG sample.
    /// 24-bit signed value → trit: positive=+1, zero=0, negative=-1
    pub fn sampleTrit(raw: [3]u8) i8 {
        // 24-bit two's complement
        const value: i32 = (@as(i32, @as(i8, @bitCast(raw[0]))) << 16) |
            (@as(i32, raw[1]) << 8) |
            @as(i32, raw[2]);
        if (value > 0) return 1;
        if (value < 0) return -1;
        return 0;
    }
};

/// AFE4404: Texas Instruments analog front-end for fNIRS.
/// Measures HbO (oxygenated) and HbR (deoxygenated) hemoglobin via
/// near-infrared light at 660nm and 850nm wavelengths.
/// Used in BCI Factory DIY fNIRS with nRF52840 as SPI master.
pub const AFE4404Provider = struct {
    /// SPI bus configuration
    bus: BusConfig = .{
        .mode = .mode0, // AFE4404 uses CPOL=0, CPHA=0
        .bit_order = .msb_first,
        .clock_hz = 8_000_000, // up to 8 MHz
        .cs_index = 1, // second device on bus (EEG is first)
    },

    /// AFE4404 register addresses (written via SPI MOSI)
    pub const Register = enum(u8) {
        control0 = 0x00,
        led2_start = 0x01,
        led2_end = 0x02,
        led1_start = 0x03,
        led1_end = 0x04,
        ambient_start = 0x05,
        ambient_end = 0x06,
        led2_value = 0x2A, // photodiode reading under LED2 (660nm → HbR)
        led1_value = 0x2C, // photodiode reading under LED1 (850nm → HbO)
        ambient_value = 0x2B,
    };

    pub fn provider(self: *const AFE4404Provider) spi.Provider(*const AFE4404Provider) {
        return .{
            .ctx = self,
            .matchFn = matchImpl,
            .nameFn = nameImpl,
            .chomskyFn = chomskyImpl,
        };
    }

    fn matchImpl(_: *const AFE4404Provider, input: []const u8, _: []const u8) MatchResult {
        // AFE4404 read response: 3 bytes (24-bit register value)
        // Valid fNIRS frame = at least 3 reads (LED1 + LED2 + ambient) = 9 bytes
        if (input.len < 9) {
            return .{ .matched = false, .consumed = 0, .trit = -1 };
        }
        // fNIRS data is always positive (photon counts), so top bit should be 0
        if (input[0] & 0x80 != 0 or input[3] & 0x80 != 0) {
            return .{ .matched = false, .consumed = 0, .trit = -1 };
        }
        return .{ .matched = true, .consumed = 9, .trit = 1 };
    }

    fn nameImpl(_: *const AFE4404Provider) []const u8 {
        return "bci/afe4404-fnirs-spi";
    }

    fn chomskyImpl(_: *const AFE4404Provider) u8 {
        return 3; // fixed-format frames, regular
    }

    /// GF(3) trit for fNIRS: HbO - HbR oxygenation delta.
    ///   +1 = oxygenation increasing (activation)
    ///    0 = stable
    ///   -1 = oxygenation decreasing (deactivation)
    pub fn oxygenationTrit(hbo: u24, hbr: u24) i8 {
        if (hbo > hbr) return 1; // net oxygenation
        if (hbo < hbr) return -1; // net deoxygenation
        return 0;
    }
};

// ============================================================================
// SPI BUS: The multiplexer that unifies hardware and software providers
// ============================================================================

/// Maximum devices on a single SPI bus (limited by CS lines)
const MAX_BUS_DEVICES = 8;

/// A SPI bus manages multiple chip-selected peripherals.
/// Isomorphic to spi.Registry managing multiple Chomsky-leveled engines.
pub const Bus = struct {
    devices: [MAX_BUS_DEVICES]?AnyBusDevice = .{null} ** MAX_BUS_DEVICES,
    count: usize = 0,

    pub fn attach(self: *Bus, device: AnyBusDevice) void {
        if (self.count < MAX_BUS_DEVICES) {
            self.devices[self.count] = device;
            self.count += 1;
        }
    }

    /// Select a device by CS index — the hardware analog of Chomsky level selection
    pub fn select(self: *const Bus, cs: u8) ?AnyBusDevice {
        for (self.devices[0..self.count]) |maybe_dev| {
            if (maybe_dev) |dev| {
                if (dev.cs_index == cs) return dev;
            }
        }
        return null;
    }

    /// Read from a device (MISO direction, trit=-1)
    pub fn read(self: *const Bus, cs: u8, input: []const u8) MatchResult {
        const dev = self.select(cs) orelse return .{ .matched = false, .consumed = 0, .trit = -1 };
        return dev.matchFn(input, "");
    }

    /// Census: how many devices per SPI mode?
    pub fn census(self: *const Bus) [4]usize {
        var counts = [_]usize{0} ** 4;
        for (self.devices[0..self.count]) |maybe_dev| {
            if (maybe_dev) |dev| {
                counts[@intFromEnum(dev.mode)] += 1;
            }
        }
        return counts;
    }
};

/// Type-erased bus device (parallel to spi.AnyProvider)
pub const AnyBusDevice = struct {
    name: []const u8,
    cs_index: u8,
    mode: Mode,
    clock_hz: u32,
    matchFn: *const fn (input: []const u8, rule: []const u8) MatchResult,
};

// ============================================================================
// DISPATCH TRAMPOLINES: Bridge hardware providers to AnyBusDevice
// ============================================================================

fn ads1299Dispatch(input: []const u8, _: []const u8) MatchResult {
    const default_dev = ADS1299Provider{};
    const prov = default_dev.provider();
    return prov.match(input, "");
}

fn afe4404Dispatch(input: []const u8, _: []const u8) MatchResult {
    const default_dev = AFE4404Provider{};
    const prov = default_dev.provider();
    return prov.match(input, "");
}

/// Build a default BCI SPI bus with EEG + fNIRS
pub fn defaultBciBus() Bus {
    var bus = Bus{};
    bus.attach(.{
        .name = "bci/ads1299-eeg-spi",
        .cs_index = 0,
        .mode = .mode1,
        .clock_hz = 4_000_000,
        .matchFn = ads1299Dispatch,
    });
    bus.attach(.{
        .name = "bci/afe4404-fnirs-spi",
        .cs_index = 1,
        .mode = .mode0,
        .clock_hz = 8_000_000,
        .matchFn = afe4404Dispatch,
    });
    return bus;
}

/// Register BCI SPI devices into the software SPI registry.
/// This is the bridge: hardware providers become software providers.
pub fn registerBciDevices(registry: *spi.Registry) void {
    registry.register(.{
        .name = "bci/ads1299-eeg-spi",
        .chomsky = 3, // regular (fixed-format EEG frames)
        .matchFn = ads1299Dispatch,
    });
    registry.register(.{
        .name = "bci/afe4404-fnirs-spi",
        .chomsky = 3, // regular (fixed-format fNIRS frames)
        .matchFn = afe4404Dispatch,
    });
}

// ============================================================================
// STRUCTURAL HOMOMORPHISM TABLE
// ============================================================================
//
//   Hardware SPI                  Software SPI (spi.zig)
//   ────────────                  ──────────────────────
//   SPI Bus                   ≅  Registry
//   Chip Select (CS)          ≅  Chomsky level
//   MOSI (write, +1)          ≅  input (query string)
//   MISO (read, -1)           ≅  MatchResult (response)
//   CLK (sync, 0)             ≅  matchFn dispatch (neutral coordination)
//   SPI Mode (CPOL/CPHA)      ≅  Engine variant within a level
//   Peripheral device         ≅  Provider
//   Frame (tx+rx+clk)         ≅  match(input, rule) → MatchResult
//   GF(3) sum = 0 per frame   ≅  GF(3) trit per match result
//
// ============================================================================

// ============================================================================
// TESTS
// ============================================================================

test "spi mode decomposition" {
    try std.testing.expectEqual(CPOL.idle_low, Mode.mode0.cpol());
    try std.testing.expectEqual(CPHA.leading_edge, Mode.mode0.cpha());
    try std.testing.expectEqual(CPOL.idle_low, Mode.mode1.cpol());
    try std.testing.expectEqual(CPHA.trailing_edge, Mode.mode1.cpha());
    try std.testing.expectEqual(CPOL.idle_high, Mode.mode2.cpol());
    try std.testing.expectEqual(CPHA.leading_edge, Mode.mode2.cpha());
    try std.testing.expectEqual(CPOL.idle_high, Mode.mode3.cpol());
    try std.testing.expectEqual(CPHA.trailing_edge, Mode.mode3.cpha());
}

test "gf3 bus line trits" {
    try std.testing.expectEqual(@as(i8, 1), BusLine.mosi.trit());
    try std.testing.expectEqual(@as(i8, 0), BusLine.clk.trit());
    try std.testing.expectEqual(@as(i8, -1), BusLine.miso.trit());
    // GF(3) conservation: MOSI + CLK + MISO = 1 + 0 + (-1) = 0
    try std.testing.expectEqual(@as(i8, 0), BusLine.mosi.trit() + BusLine.clk.trit() + BusLine.miso.trit());
}

test "frame trit balance" {
    const tx = [_]u8{ 0x12, 0x00 };
    var rx = [_]u8{ 0x00, 0x00 };
    const frame = Frame{ .tx = &tx, .rx = &rx, .clock_cycles = 16 };
    // Full-duplex frame: +1 (tx) + (-1) (rx) + 0 (clk) = 0
    try std.testing.expectEqual(@as(i8, 0), frame.tritBalance());
}

test "ads1299 valid frame" {
    // Status byte 0xC0 + 8 channels * 3 bytes = 27 bytes total
    var frame: [27]u8 = undefined;
    frame[0] = 0xC0; // valid status: bits [23:20] = 1100
    frame[1] = 0x00;
    frame[2] = 0x00;
    @memset(frame[3..], 0x42); // channel data

    const dev = ADS1299Provider{};
    const prov = dev.provider();
    const result = prov.match(&frame, "");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 27), result.consumed);
    try std.testing.expectEqual(@as(i8, 1), result.trit);
}

test "ads1299 invalid status byte" {
    var frame: [27]u8 = undefined;
    frame[0] = 0x00; // invalid status: bits [23:20] != 1100
    const dev = ADS1299Provider{};
    const prov = dev.provider();
    const result = prov.match(&frame, "");
    try std.testing.expect(!result.matched);
    try std.testing.expectEqual(@as(i8, -1), result.trit);
}

test "ads1299 too short" {
    const short = [_]u8{ 0xC0, 0x00 };
    const dev = ADS1299Provider{};
    const prov = dev.provider();
    const result = prov.match(&short, "");
    try std.testing.expect(!result.matched);
}

test "ads1299 sample trit" {
    // Positive sample
    try std.testing.expectEqual(@as(i8, 1), ADS1299Provider.sampleTrit(.{ 0x00, 0x00, 0x01 }));
    // Negative sample (two's complement)
    try std.testing.expectEqual(@as(i8, -1), ADS1299Provider.sampleTrit(.{ 0xFF, 0xFF, 0xFF }));
    // Zero
    try std.testing.expectEqual(@as(i8, 0), ADS1299Provider.sampleTrit(.{ 0x00, 0x00, 0x00 }));
}

test "afe4404 valid fnirs frame" {
    // 3 readings (LED1 + LED2 + ambient) * 3 bytes = 9 bytes
    const frame = [_]u8{ 0x00, 0x10, 0x20, 0x00, 0x30, 0x40, 0x00, 0x50, 0x60 };
    const dev = AFE4404Provider{};
    const prov = dev.provider();
    const result = prov.match(&frame, "");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 9), result.consumed);
}

test "afe4404 invalid high bit" {
    // Top bit set = invalid for photon counts
    const frame = [_]u8{ 0x80, 0x10, 0x20, 0x00, 0x30, 0x40, 0x00, 0x50, 0x60 };
    const dev = AFE4404Provider{};
    const prov = dev.provider();
    const result = prov.match(&frame, "");
    try std.testing.expect(!result.matched);
}

test "afe4404 oxygenation trit" {
    try std.testing.expectEqual(@as(i8, 1), AFE4404Provider.oxygenationTrit(1000, 500)); // more oxy
    try std.testing.expectEqual(@as(i8, -1), AFE4404Provider.oxygenationTrit(500, 1000)); // less oxy
    try std.testing.expectEqual(@as(i8, 0), AFE4404Provider.oxygenationTrit(500, 500)); // balanced
}

test "default bci bus" {
    const bus = defaultBciBus();
    try std.testing.expectEqual(@as(usize, 2), bus.count);

    // Select by CS index
    const eeg = bus.select(0).?;
    try std.testing.expect(std.mem.eql(u8, eeg.name, "bci/ads1299-eeg-spi"));
    try std.testing.expectEqual(Mode.mode1, eeg.mode);

    const fnirs = bus.select(1).?;
    try std.testing.expect(std.mem.eql(u8, fnirs.name, "bci/afe4404-fnirs-spi"));
    try std.testing.expectEqual(Mode.mode0, fnirs.mode);

    // No device at CS 2
    try std.testing.expectEqual(@as(?AnyBusDevice, null), bus.select(2));
}

test "bus census by mode" {
    const bus = defaultBciBus();
    const counts = bus.census();
    try std.testing.expectEqual(@as(usize, 1), counts[0]); // mode0 (AFE4404)
    try std.testing.expectEqual(@as(usize, 1), counts[1]); // mode1 (ADS1299)
    try std.testing.expectEqual(@as(usize, 0), counts[2]); // mode2
    try std.testing.expectEqual(@as(usize, 0), counts[3]); // mode3
}

test "cs-chomsky homomorphism" {
    const eeg_bus = BusConfig{ .clock_hz = 4_000_000, .cs_index = 0 };
    const fnirs_bus = BusConfig{ .clock_hz = 8_000_000, .cs_index = 1 };
    // CS index maps to Chomsky level analog
    try std.testing.expectEqual(@as(u8, 0), eeg_bus.chomskyAnalog());
    try std.testing.expectEqual(@as(u8, 1), fnirs_bus.chomskyAnalog());
}

test "bci devices register into software spi registry" {
    var reg = spi.defaultRegistry();
    const before = reg.total();
    registerBciDevices(&reg);
    try std.testing.expectEqual(before + 2, reg.total());
    // Both registered at Chomsky level 3 (regular)
    try std.testing.expectEqual(@as(usize, 5), reg.census()[3]); // 3 regexp + 2 BCI
}

test "bus read dispatches to correct device" {
    const bus = defaultBciBus();
    // Valid ADS1299 frame on CS 0
    var frame: [27]u8 = undefined;
    frame[0] = 0xC0;
    frame[1] = 0x00;
    frame[2] = 0x00;
    @memset(frame[3..], 0x42);
    const result = bus.read(0, &frame);
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(i8, 1), result.trit);
}
