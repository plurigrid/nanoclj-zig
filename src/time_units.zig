//! time_units.zig — Temporal Ontology for nanoclj-zig
//!
//! Ports zig-syrup's time_unit.zig conversion lattice to Clojure builtins.
//! 32 units across 8 domains, conversion morphisms, notable ratio edges.
//!
//! The trice (423,360,000/s = flick × 3/5) bridges the two codebases:
//!   zig-syrup:  glimpse = flick/5  = 141,120,000/s
//!   nanoclj-zig: trit-tick = flick×3 = 2,116,800,000/s
//!   trice:       flick×3/5          = 423,360,000/s
//!
//! Tower: TimeRef(14.112M) --×5--> glimpse(141.12M) --×3--> trice(423.36M) --×5--> trit-tick(2116.8M)

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const transitivity = @import("transitivity.zig");

// ============================================================================
// CONSTANTS
// ============================================================================

pub const FLICK: u64 = 705_600_000;
pub const GLIMPSE: u64 = 141_120_000; // FLICK / 5
pub const TRICE: u64 = 423_360_000; // FLICK * 3 / 5
pub const TRIT_TICK: u64 = 2_116_800_000; // FLICK * 3
pub const TIME_REF: u64 = 14_112_000; // GLIMPSE / 10

// ============================================================================
// TIME UNIT DATA
// ============================================================================

pub const TimeDomain = enum(u3) {
    physical, // +1
    computational, // 0
    biological, // -1
    phenomenological, // -1
    cultural, // -1
    musical, // -1
    cosmological, // +1
    topological, // 0 (Dreamtime)

    pub fn trit(self: TimeDomain) i8 {
        return switch (self) {
            .physical, .cosmological => 1,
            .computational, .topological => 0,
            .biological, .phenomenological, .cultural, .musical => -1,
        };
    }
};

pub const TimeUnit = struct {
    name: []const u8,
    symbol: []const u8,
    seconds: f64, // NaN = tempo/energy dependent
    domain: TimeDomain,
};

pub const catalog = [_]TimeUnit{
    // --- Physical ---
    .{ .name = "Planck time", .symbol = "tp", .seconds = 5.391e-44, .domain = .physical },
    .{ .name = "chronon", .symbol = "theta0", .seconds = 6.27e-24, .domain = .physical },
    .{ .name = "atomic unit of time", .symbol = "hbar/Eh", .seconds = 24.189e-18, .domain = .physical },
    .{ .name = "attosecond", .symbol = "as", .seconds = 1e-18, .domain = .physical },
    .{ .name = "Svedberg", .symbol = "S", .seconds = 1e-13, .domain = .physical },
    .{ .name = "shake", .symbol = "shake", .seconds = 1e-8, .domain = .physical },
    // --- Computational ---
    .{ .name = "Landauer time", .symbol = "tau_L", .seconds = 0.58e-12, .domain = .computational },
    .{ .name = "jiffy (light-cm)", .symbol = "jiffy", .seconds = 33.3564e-12, .domain = .physical },
    .{ .name = "trice", .symbol = "trice", .seconds = 1.0 / @as(f64, @floatFromInt(TRICE)), .domain = .computational },
    .{ .name = "glimpse", .symbol = "gl", .seconds = 1.0 / @as(f64, @floatFromInt(GLIMPSE)), .domain = .computational },
    .{ .name = "flick", .symbol = "flick", .seconds = 1.0 / @as(f64, @floatFromInt(FLICK)), .domain = .computational },
    .{ .name = "trit-tick", .symbol = "tt", .seconds = 1.0 / @as(f64, @floatFromInt(TRIT_TICK)), .domain = .computational },
    .{ .name = "jiffy (Linux)", .symbol = "jiffy", .seconds = 0.004, .domain = .computational },
    .{ .name = "Margolus-Levitin", .symbol = "tau_ML", .seconds = std.math.nan(f64), .domain = .computational },
    // --- Biological ---
    .{ .name = "truti", .symbol = "truti", .seconds = 29.6e-6, .domain = .cultural },
    .{ .name = "chronaxie", .symbol = "tau_chr", .seconds = 0.0005, .domain = .biological },
    .{ .name = "ksana", .symbol = "ks", .seconds = 1.0 / 75.0, .domain = .phenomenological },
    .{ .name = "critical flicker fusion", .symbol = "CFF", .seconds = 1.0 / 60.0, .domain = .biological },
    .{ .name = "specious present", .symbol = "SP", .seconds = 2.5, .domain = .phenomenological },
    .{ .name = "circadian tau", .symbol = "tau_circ", .seconds = 24.2 * 3600.0, .domain = .biological },
    // --- Musical ---
    .{ .name = "mora", .symbol = "mu", .seconds = std.math.nan(f64), .domain = .musical },
    .{ .name = "longa", .symbol = "longa", .seconds = std.math.nan(f64), .domain = .musical },
    // --- Cultural ---
    .{ .name = "helek", .symbol = "helek", .seconds = 10.0 / 3.0, .domain = .cultural },
    .{ .name = "USH", .symbol = "USH", .seconds = 240.0, .domain = .cultural },
    .{ .name = "ke", .symbol = "ke", .seconds = 864.0, .domain = .cultural },
    .{ .name = "ghurry", .symbol = "ghurry", .seconds = 1440.0, .domain = .cultural },
    .{ .name = "beru", .symbol = "DAN.NA", .seconds = 7200.0, .domain = .cultural },
    .{ .name = "nanocentury", .symbol = "nc", .seconds = 3.15576, .domain = .computational },
    .{ .name = "microcentury", .symbol = "uc", .seconds = 3155.76, .domain = .cultural },
    .{ .name = "nundinae", .symbol = "nund", .seconds = 8.0 * 86400.0, .domain = .cultural },
    .{ .name = "synodic month", .symbol = "syn", .seconds = 29.53059 * 86400.0, .domain = .cosmological },
    // --- Cosmological ---
    .{ .name = "galactic year", .symbol = "GY", .seconds = 225e6 * 365.25 * 86400.0, .domain = .cosmological },
    .{ .name = "kalpa", .symbol = "kalpa", .seconds = 4.32e9 * 365.25 * 86400.0, .domain = .cosmological },
};

// Notable ratios: { from_idx, to_idx, label }
pub const notable_ratios = [_]struct { from: u8, to: u8, label: []const u8 }{
    .{ .from = 9, .to = 10, .label = "glimpse/flick = 5 (EEG bands)" },
    .{ .from = 17, .to = 16, .label = "CFF/ksana = 5:4 exact" },
    .{ .from = 5, .to = 9, .label = "shake/glimpse ~ sqrt(2)" },
    .{ .from = 19, .to = 23, .label = "circadian-tau/USH ~ 360" },
    .{ .from = 12, .to = 14, .label = "jiffy-kernel/truti ~ 1/alpha" },
    .{ .from = 30, .to = 26, .label = "synodic-month/beru ~ 360" },
    .{ .from = 27, .to = 18, .label = "nanocentury/SP ~ 5:4" },
    .{ .from = 8, .to = 9, .label = "trice/glimpse = 3" },
    .{ .from = 11, .to = 8, .label = "trit-tick/trice = 5" },
    .{ .from = 10, .to = 8, .label = "flick*3/5 = trice" },
};

// ============================================================================
// CLOJURE BUILTINS
// ============================================================================

/// (time-units) → list of maps, one per unit
pub fn timeUnitsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const result = try gc.allocObj(.list);
    for (catalog) |unit| {
        const m = try gc.allocObj(.map);
        // :name
        const kn = try gc.internString("name");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kn));
        const vn = try gc.internString(unit.name);
        try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vn));
        // :symbol
        const ks = try gc.internString("symbol");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(ks));
        const vs = try gc.internString(unit.symbol);
        try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vs));
        // :seconds (float or nil for NaN)
        const ksc = try gc.internString("seconds");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(ksc));
        if (std.math.isNan(unit.seconds)) {
            try m.data.map.vals.append(gc.allocator, Value.makeNil());
        } else {
            try m.data.map.vals.append(gc.allocator, Value.makeFloat(unit.seconds));
        }
        // :domain
        const kd = try gc.internString("domain");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kd));
        const vd = try gc.internString(@tagName(unit.domain));
        try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vd));
        // :trit
        const kt = try gc.internString("trit");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kt));
        try m.data.map.vals.append(gc.allocator, Value.makeInt(@as(i48, unit.domain.trit())));

        try result.data.list.items.append(gc.allocator, Value.makeObj(m));
    }
    return Value.makeObj(result);
}

/// (time-unit name) → map for a single unit, or nil
pub fn timeUnitFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const needle = if (args[0].isString())
        gc.getString(args[0].asStringId())
    else if (args[0].isKeyword())
        gc.getString(args[0].asKeywordId())
    else
        return error.TypeError;

    for (catalog) |unit| {
        if (std.mem.eql(u8, unit.name, needle) or std.mem.eql(u8, unit.symbol, needle)) {
            const m = try gc.allocObj(.map);
            const kn = try gc.internString("name");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kn));
            const vn = try gc.internString(unit.name);
            try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vn));
            const ks = try gc.internString("symbol");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(ks));
            const vs = try gc.internString(unit.symbol);
            try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vs));
            const ksc = try gc.internString("seconds");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(ksc));
            if (std.math.isNan(unit.seconds)) {
                try m.data.map.vals.append(gc.allocator, Value.makeNil());
            } else {
                try m.data.map.vals.append(gc.allocator, Value.makeFloat(unit.seconds));
            }
            const kd = try gc.internString("domain");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kd));
            const vd = try gc.internString(@tagName(unit.domain));
            try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vd));
            const kt = try gc.internString("trit");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kt));
            try m.data.map.vals.append(gc.allocator, Value.makeInt(@as(i48, unit.domain.trit())));
            return Value.makeObj(m);
        }
    }
    return Value.makeNil();
}

/// (convert-time from-name to-name count) → float seconds, or nil
pub fn convertTimeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const from_name = if (args[0].isString())
        gc.getString(args[0].asStringId())
    else if (args[0].isKeyword())
        gc.getString(args[0].asKeywordId())
    else
        return error.TypeError;
    const to_name = if (args[1].isString())
        gc.getString(args[1].asStringId())
    else if (args[1].isKeyword())
        gc.getString(args[1].asKeywordId())
    else
        return error.TypeError;
    const count: f64 = if (args[2].isInt())
        @floatFromInt(args[2].asInt())
    else if (args[2].isFloat())
        args[2].asFloat()
    else
        return error.TypeError;

    var from_sec: ?f64 = null;
    var to_sec: ?f64 = null;
    for (catalog) |unit| {
        if (std.mem.eql(u8, unit.name, from_name) or std.mem.eql(u8, unit.symbol, from_name)) {
            from_sec = if (std.math.isNan(unit.seconds)) null else unit.seconds;
        }
        if (std.mem.eql(u8, unit.name, to_name) or std.mem.eql(u8, unit.symbol, to_name)) {
            to_sec = if (std.math.isNan(unit.seconds)) null else unit.seconds;
        }
    }
    const fs = from_sec orelse return Value.makeNil();
    const ts = to_sec orelse return Value.makeNil();
    return Value.makeFloat(count * fs / ts);
}

/// (nice-ratios) → list of maps {:from :to :ratio :label}
pub fn niceRatiosFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const result = try gc.allocObj(.list);
    for (notable_ratios) |r| {
        const from_unit = catalog[r.from];
        const to_unit = catalog[r.to];
        const m = try gc.allocObj(.map);

        const kf = try gc.internString("from");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kf));
        const vf = try gc.internString(from_unit.name);
        try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vf));

        const kt = try gc.internString("to");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kt));
        const vt = try gc.internString(to_unit.name);
        try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vt));

        // ratio
        const kr = try gc.internString("ratio");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kr));
        if (!std.math.isNan(from_unit.seconds) and !std.math.isNan(to_unit.seconds)) {
            try m.data.map.vals.append(gc.allocator, Value.makeFloat(from_unit.seconds / to_unit.seconds));
        } else {
            try m.data.map.vals.append(gc.allocator, Value.makeNil());
        }

        // label
        const kl = try gc.internString("label");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kl));
        const vl = try gc.internString(r.label);
        try m.data.map.vals.append(gc.allocator, Value.makeKeyword(vl));

        try result.data.list.items.append(gc.allocator, Value.makeObj(m));
    }
    return Value.makeObj(result);
}

/// (trice-per-sec) → 423360000
pub fn tricePerSecFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(TRICE));
}

/// (glimpses-per-sec) → 141120000
pub fn glimpsesPerSecFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(GLIMPSE));
}

/// (time-tower) → {:time-ref 14112000 :glimpse 141120000 :trice 423360000 :trit-tick 2116800000 :flick 705600000}
pub fn timeTowerFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const m = try gc.allocObj(.map);
    const pairs = [_]struct { k: []const u8, v: u64 }{
        .{ .k = "time-ref", .v = TIME_REF },
        .{ .k = "glimpse", .v = GLIMPSE },
        .{ .k = "trice", .v = TRICE },
        .{ .k = "flick", .v = FLICK },
        .{ .k = "trit-tick", .v = TRIT_TICK },
    };
    for (pairs) |p| {
        const kid = try gc.internString(p.k);
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kid));
        try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(p.v)));
    }
    return Value.makeObj(m);
}

// ============================================================================
// HYPERREAL / SURREAL TIME
// ============================================================================
//
// The integer tower (TimeRef→glimpse→trice→flick→trit-tick) lives in ℤ.
// But ratios like shake/glimpse ≈ √2 and nanocentury ≈ π live in ℝ.
// Hyperreals (ℝ*) add infinitesimals ε and infinites ω.
// Surreals ({L|R}) contain all ordinals and all reals.
//
// Surreal day-forms for the time tower:
//   { | }     = 0    (the void before time)
//   {0| }     = 1    (one tick)
//   { |0}     = -1   (one anti-tick)
//   {0|1}     = 1/2  (half-tick — the midpoint nobody measures)
//   {1| }     = 2    (one flick = 2 half-ticks? no, but surreally)
//   {0,1,2,...| } = ω (the first infinite — the galactic year's ordinal)
//   { |0,1/2,1/4,...} = ε (the first infinitesimal — below Planck)
//
// In this encoding:
//   ω  = galactic year / Planck time ≈ 10⁶¹ (a surreal with no right set)
//   ε  = Planck time / galactic year ≈ 10⁻⁶¹ (a surreal with no left set past 0)
//   ω·ε = 1 (the fundamental duality: largest × smallest = unity)

/// Surreal number in day-form {L|R} — simplified to birthday + sign.
/// Full Conway construction would need recursive sets; we use the
/// "numeric" surreals where birthday = ordinal day of creation.
pub const SurrealTime = struct {
    /// Birthday (Conway day). 0 = void, 1 = {|} = 0, 2 = {0|} = 1, etc.
    birthday: u32,
    /// Sign: +1 = {L|}, 0 = balanced, -1 = {|R}
    sign: i8,
    /// Optional real approximation (for display / conversion)
    real_approx: f64,

    pub const zero = SurrealTime{ .birthday = 1, .sign = 0, .real_approx = 0.0 };
    pub const one = SurrealTime{ .birthday = 2, .sign = 1, .real_approx = 1.0 };
    pub const neg_one = SurrealTime{ .birthday = 2, .sign = -1, .real_approx = -1.0 };
    pub const omega = SurrealTime{ .birthday = std.math.maxInt(u32), .sign = 1, .real_approx = std.math.inf(f64) };
    pub const epsilon = SurrealTime{ .birthday = std.math.maxInt(u32), .sign = 1, .real_approx = 0.0 };
};

/// Hyperreal time: real part + infinitesimal part.
/// t = standard + ε·infinitesimal
/// Two times are "infinitely close" (t₁ ≈ t₂) iff their standard parts are equal.
pub const HyperrealTime = struct {
    /// Standard part (in seconds)
    standard: f64,
    /// Infinitesimal coefficient (multiples of ε)
    infinitesimal: i64,
    /// Infinite coefficient (multiples of ω, for cosmological scale)
    infinite: i64,

    pub fn fromSeconds(s: f64) HyperrealTime {
        return .{ .standard = s, .infinitesimal = 0, .infinite = 0 };
    }

    pub fn fromGlimpses(n: u64) HyperrealTime {
        return .{
            .standard = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(GLIMPSE)),
            .infinitesimal = @intCast(n % 1069), // sub-glimpse residual as infinitesimal
            .infinite = 0,
        };
    }

    /// Standard part (the real number you'd measure with a clock)
    pub fn st(self: HyperrealTime) f64 {
        return self.standard;
    }

    /// Are two hyperreal times infinitely close? (same standard part)
    pub fn approxEqual(a: HyperrealTime, b: HyperrealTime) bool {
        return a.standard == b.standard;
    }

    /// The monad of t: all hyperreals infinitely close to t.
    /// Returns the infinitesimal offset from standard part.
    pub fn monad(self: HyperrealTime) i64 {
        return self.infinitesimal;
    }

    /// Transfer principle: convert a real-valued time unit to hyperreal,
    /// preserving all first-order properties.
    pub fn transfer(unit: TimeUnit) HyperrealTime {
        if (std.math.isNan(unit.seconds)) {
            // Tempo-dependent units → pure infinitesimal (duration exists but is unmeasured)
            return .{ .standard = 0, .infinitesimal = 1, .infinite = 0 };
        }
        return fromSeconds(unit.seconds);
    }
};

/// Map a time unit to its surreal birthday.
/// Physical units born early (small birthday), cultural units born late.
pub fn surrealBirthday(unit: TimeUnit) SurrealTime {
    // Birthday ≈ -log₁₀(seconds) + offset, clamped to ordinals
    if (std.math.isNan(unit.seconds)) {
        return .{ .birthday = 0, .sign = 0, .real_approx = std.math.nan(f64) };
    }
    const log_s = @abs(@log10(unit.seconds));
    const day: u32 = @intFromFloat(@min(log_s + 1.0, 100.0));
    const sign: i8 = if (unit.seconds >= 1.0) 1 else if (unit.seconds > 0) -1 else 0;
    return .{ .birthday = day, .sign = sign, .real_approx = unit.seconds };
}

// ============================================================================
// COLOR-ENTROPY nREPL PORT ALLOCATION
// ============================================================================
//
// Each nREPL instance gets a port in the ephemeral range (49152-65535)
// derived from the color hash of its project path. This guarantees:
//   - Deterministic: same project always gets same port
//   - Maximally separated: SplitMix64 entropy spreads ports across range
//   - Distinguishable: each port maps to a unique color for visual ID
//   - Recoverable: given a port, you can find which project owns it

const substrate = @import("substrate.zig");

/// Hash a project path to an nREPL port in ephemeral range [49152, 65535].
/// The port is a deterministic function of the path — same project, same port.
pub fn nreplPortFromPath(path: []const u8) u16 {
    var h: u64 = substrate.CANONICAL_SEED; // 1069
    for (path) |byte| {
        h = substrate.mix64(h +% @as(u64, byte) *% substrate.GOLDEN);
    }
    // Map to ephemeral range: 16384 ports available
    const range: u64 = 65535 - 49152 + 1; // 16384
    return @intCast(49152 + (h % range));
}

/// Color for an nREPL port — the visual identity of the REPL session.
pub fn nreplColor(port: u16) substrate.Color {
    return substrate.colorAt(substrate.CANONICAL_SEED, @as(u64, port));
}

/// Entropy distance between two nREPL ports.
/// Higher = more distinguishable. Uses XOR popcount as Hamming distance.
pub fn nreplDistance(port_a: u16, port_b: u16) u8 {
    return @popCount(port_a ^ port_b);
}

/// Generate N maximally deconflicted ports for simultaneous nREPLs.
/// Uses SplitMix64 to spread across the ephemeral range.
/// Returns ports sorted by maximum mutual Hamming distance.
pub fn nreplPortSpread(base_path: []const u8, n: usize, out: []u16) void {
    const base_port = nreplPortFromPath(base_path);
    if (n == 0) return;
    out[0] = base_port;
    var rng = substrate.SplitRng.init(substrate.mix64(@as(u64, base_port)));
    for (1..@min(n, out.len)) |i| {
        // Generate candidate, ensure no collision with existing
        var candidate: u16 = undefined;
        var attempts: u32 = 0;
        while (attempts < 1000) : (attempts += 1) {
            const raw = rng.next();
            candidate = @intCast(49152 + (raw % 16384));
            // Check minimum Hamming distance from all existing
            var min_dist: u8 = 16;
            for (0..i) |j| {
                const d = nreplDistance(candidate, out[j]);
                if (d < min_dist) min_dist = d;
            }
            if (min_dist >= 4) break; // at least 4 bits different
        }
        out[i] = candidate;
    }
}

/// Clojure builtin: (nrepl-port-for path) → port number
pub fn nreplPortForFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const path = if (args[0].isString())
        gc.getString(args[0].asStringId())
    else
        return error.TypeError;
    return Value.makeInt(@intCast(nreplPortFromPath(path)));
}

/// Clojure builtin: (nrepl-color port) → {:r :g :b}
pub fn nreplColorFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    const port: u16 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const c = nreplColor(port);
    const m = try gc.allocObj(.map);
    const kr = try gc.internString("r");
    try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kr));
    try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(c.r)));
    const kg = try gc.internString("g");
    try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kg));
    try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(c.g)));
    const kb = try gc.internString("b");
    try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kb));
    try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(c.b)));
    return Value.makeObj(m);
}

/// Clojure builtin: (nrepl-spread path n) → vector of n deconflicted ports
pub fn nreplSpreadFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const path = if (args[0].isString())
        gc.getString(args[0].asStringId())
    else
        return error.TypeError;
    if (!args[1].isInt()) return error.TypeError;
    const n: usize = @intCast(@max(@as(i48, 1), @min(args[1].asInt(), 16)));
    var ports: [16]u16 = undefined;
    nreplPortSpread(path, n, &ports);
    const vec = try gc.allocObj(.vector);
    for (0..n) |i| {
        try vec.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(ports[i])));
    }
    return Value.makeObj(vec);
}

/// Clojure builtin: (hyperreal-time unit-name) → {:standard :infinitesimal :infinite}
pub fn hyperrealTimeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const needle = if (args[0].isString())
        gc.getString(args[0].asStringId())
    else if (args[0].isKeyword())
        gc.getString(args[0].asKeywordId())
    else
        return error.TypeError;
    for (catalog) |unit| {
        if (std.mem.eql(u8, unit.name, needle) or std.mem.eql(u8, unit.symbol, needle)) {
            const ht = HyperrealTime.transfer(unit);
            const m = try gc.allocObj(.map);
            const ks = try gc.internString("standard");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(ks));
            try m.data.map.vals.append(gc.allocator, Value.makeFloat(ht.standard));
            const ki = try gc.internString("infinitesimal");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(ki));
            try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(ht.infinitesimal)));
            const kw = try gc.internString("infinite");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kw));
            try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(ht.infinite)));
            return Value.makeObj(m);
        }
    }
    return Value.makeNil();
}

/// Clojure builtin: (surreal-birthday unit-name) → {:birthday :sign :real}
pub fn surrealBirthdayFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const needle = if (args[0].isString())
        gc.getString(args[0].asStringId())
    else if (args[0].isKeyword())
        gc.getString(args[0].asKeywordId())
    else
        return error.TypeError;
    for (catalog) |unit| {
        if (std.mem.eql(u8, unit.name, needle) or std.mem.eql(u8, unit.symbol, needle)) {
            const sb = surrealBirthday(unit);
            const m = try gc.allocObj(.map);
            const kb = try gc.internString("birthday");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kb));
            try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(sb.birthday)));
            const ks = try gc.internString("sign");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(ks));
            try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(sb.sign)));
            const kr = try gc.internString("real");
            try m.data.map.keys.append(gc.allocator, Value.makeKeyword(kr));
            try m.data.map.vals.append(gc.allocator, Value.makeFloat(sb.real_approx));
            return Value.makeObj(m);
        }
    }
    return Value.makeNil();
}

// ============================================================================
// TESTS
// ============================================================================

test "trice = flick * 3 / 5" {
    try std.testing.expectEqual(TRICE, FLICK * 3 / 5);
}

test "glimpse = flick / 5" {
    try std.testing.expectEqual(GLIMPSE, FLICK / 5);
}

test "trit-tick = flick * 3" {
    try std.testing.expectEqual(TRIT_TICK, FLICK * 3);
}

test "tower: time-ref * 5 = glimpse" {
    try std.testing.expectEqual(TIME_REF * 10, GLIMPSE);
}

test "tower: glimpse * 3 = trice" {
    try std.testing.expectEqual(GLIMPSE * 3, TRICE);
}

test "tower: trice * 5 = trit-tick" {
    try std.testing.expectEqual(TRICE * 5, TRIT_TICK);
}

test "catalog has 33 units" {
    try std.testing.expectEqual(@as(usize, 33), catalog.len);
}

test "CFF / ksana = 5:4" {
    const cff = catalog[17]; // critical flicker fusion
    const ks = catalog[16]; // ksana
    const ratio = cff.seconds / ks.seconds;
    try std.testing.expect(@abs(ratio - 1.25) < 1e-10);
}

test "nanocentury ~ pi" {
    const nc = catalog[27]; // nanocentury
    try std.testing.expect(@abs(nc.seconds - std.math.pi) < 0.02);
}

test "hyperreal transfer preserves standard part" {
    const ht = HyperrealTime.transfer(catalog[9]); // glimpse
    try std.testing.expect(@abs(ht.standard - 1.0 / @as(f64, @floatFromInt(GLIMPSE))) < 1e-20);
    try std.testing.expectEqual(@as(i64, 0), ht.infinitesimal);
}

test "hyperreal: NaN units become infinitesimal" {
    const ht = HyperrealTime.transfer(catalog[13]); // Margolus-Levitin (NaN)
    try std.testing.expectEqual(@as(f64, 0.0), ht.standard);
    try std.testing.expectEqual(@as(i64, 1), ht.infinitesimal);
}

test "surreal birthdays: Planck early, galactic late" {
    const planck_sb = surrealBirthday(catalog[0]); // Planck
    const gy_sb = surrealBirthday(catalog[31]); // galactic year
    try std.testing.expect(planck_sb.birthday > gy_sb.birthday); // more negative log → higher birthday
    try std.testing.expectEqual(@as(i8, -1), planck_sb.sign); // < 1 second
    try std.testing.expectEqual(@as(i8, 1), gy_sb.sign); // > 1 second
}

test "nrepl port deterministic" {
    const p1 = nreplPortFromPath("/Users/bob/i/nanoclj-zig");
    const p2 = nreplPortFromPath("/Users/bob/i/nanoclj-zig");
    try std.testing.expectEqual(p1, p2);
    try std.testing.expect(p1 >= 49152);
    try std.testing.expect(p1 <= 65535);
}

test "nrepl port spread: distinct ports" {
    var ports: [16]u16 = undefined;
    nreplPortSpread("/Users/bob/i", 4, &ports);
    // All four should be distinct
    for (0..4) |i| {
        for (i + 1..4) |j| {
            try std.testing.expect(ports[i] != ports[j]);
        }
    }
}

test "nrepl color: different ports → different colors" {
    const c1 = nreplColor(50000);
    const c2 = nreplColor(50001);
    // At least one channel should differ (SplitMix64 guarantees this)
    try std.testing.expect(c1.r != c2.r or c1.g != c2.g or c1.b != c2.b);
}
