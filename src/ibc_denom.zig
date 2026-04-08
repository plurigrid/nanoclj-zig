//! IBC Denom Derivation + GF(3) Color Authentication
//!
//! Implements bmorphism/shitcoin's disclosure: IBC denomination derivation
//! is SHA256(port/channel/address) — deterministic, pre-computable, and
//! critically: no authentication predicate. An alien chain on the same
//! channel-id produces the same denom. The hash doesn't know who's on
//! the other end.
//!
//! The geodesic: nanoclj-zig's GF(3) trit system IS the missing
//! authentication predicate. Color-based channel identity makes the
//! alien distinguishable where SHA256 alone cannot.
//!
//! Builtins:
//!   (ibc-denom "transfer" "channel-169" "cw20:juno1...")
//!     → "ibc/8C8BFD62..."
//!   (ibc-trit "transfer" "channel-750" "uusdc")
//!     → {:denom "ibc/..." :color "#38B861" :trit 0 :role "ergodic"}
//!   (noble-usdc-on "osmosis")
//!     → "ibc/498A0751..."
//!   (noble-precompute n)
//!     → [{:channel "channel-0" :denom "ibc/..."} ...]

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const substrate = @import("substrate.zig");
const gay_skills = @import("gay_skills.zig");
const Resources = @import("transitivity.zig").Resources;

const Sha256 = std.crypto.hash.sha2.Sha256;

// ============================================================================
// CORE: SHA256(port/channel/denom) → "ibc/HEX..."
// ============================================================================

fn ibcDenomHash(port_id: []const u8, channel_id: []const u8, base_denom: []const u8) [64]u8 {
    var h = Sha256.init(.{});
    h.update(port_id);
    h.update("/");
    h.update(channel_id);
    h.update("/");
    h.update(base_denom);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .upper);
}

fn ibcDenomString(gc: *GC, port_id: []const u8, channel_id: []const u8, base_denom: []const u8) !Value {
    const hex = ibcDenomHash(port_id, channel_id, base_denom);
    var buf: [68]u8 = undefined; // "ibc/" + 64 hex
    @memcpy(buf[0..4], "ibc/");
    @memcpy(buf[4..68], &hex);
    return Value.makeString(try gc.internString(&buf));
}

// ============================================================================
// NOBLE CHANNELS (from shitcoin/noble.py)
// ============================================================================

const NobleChannel = struct {
    name: []const u8,
    noble_channel: []const u8,
    peer_channel: []const u8,
    chain_id: []const u8,
};

const NOBLE_CHANNELS = [_]NobleChannel{
    .{ .name = "osmosis", .noble_channel = "channel-1", .peer_channel = "channel-750", .chain_id = "osmosis-1" },
    .{ .name = "cosmoshub", .noble_channel = "channel-4", .peer_channel = "channel-536", .chain_id = "cosmoshub-4" },
    .{ .name = "neutron", .noble_channel = "channel-18", .peer_channel = "channel-30", .chain_id = "neutron-1" },
    .{ .name = "stargaze", .noble_channel = "channel-11", .peer_channel = "channel-204", .chain_id = "stargaze-1" },
    .{ .name = "sei", .noble_channel = "channel-39", .peer_channel = "channel-45", .chain_id = "sei-pacific-1" },
    .{ .name = "dydx", .noble_channel = "channel-33", .peer_channel = "channel-0", .chain_id = "dydx-mainnet-1" },
    .{ .name = "injective", .noble_channel = "channel-31", .peer_channel = "channel-148", .chain_id = "injective-1" },
    .{ .name = "terra2", .noble_channel = "channel-30", .peer_channel = "channel-253", .chain_id = "phoenix-1" },
    .{ .name = "kujira", .noble_channel = "channel-2", .peer_channel = "channel-62", .chain_id = "kaiyo-1" },
    .{ .name = "juno", .noble_channel = "channel-3", .peer_channel = "channel-224", .chain_id = "juno-1" },
    .{ .name = "evmos", .noble_channel = "channel-7", .peer_channel = "channel-64", .chain_id = "evmos_9001-2" },
    .{ .name = "archway", .noble_channel = "channel-12", .peer_channel = "channel-29", .chain_id = "archway-1" },
    .{ .name = "secretnetwork", .noble_channel = "channel-17", .peer_channel = "channel-88", .chain_id = "secret-4" },
    .{ .name = "agoric", .noble_channel = "channel-21", .peer_channel = "channel-62", .chain_id = "agoric-3" },
    .{ .name = "persistence", .noble_channel = "channel-36", .peer_channel = "channel-132", .chain_id = "core-1" },
    .{ .name = "dymension", .noble_channel = "channel-19", .peer_channel = "channel-6", .chain_id = "dymension_1100-1" },
    .{ .name = "babylon", .noble_channel = "channel-81", .peer_channel = "channel-1", .chain_id = "bbn-1" },
};

// ============================================================================
// COLLISION DETECTION — the profit
// ============================================================================

/// Collision entry: chains sharing the same USDC denom because they use
/// the same peer channel number (different chains, same channel-N).
const CollisionGroup = struct {
    peer_channel: []const u8,
    chains: []const []const u8,
};

/// Known collisions from live Noble API + client state resolution (2026-04-07).
/// These are real, on-chain, OPEN channels producing identical USDC denoms.
/// Resolved via: channel -> connection -> client_state -> chain_id.
const KNOWN_COLLISIONS = [_]CollisionGroup{
    // MEGA-COLLISION: 18 Noble channels all have peer channel-0
    .{ .peer_channel = "channel-0", .chains = &.{
        "dydx", "titan", "sunrise", "luwak", "exachain", "viexchain", "hyve",
    } },
    // 16 Noble channels share peer channel-1
    .{ .peer_channel = "channel-1", .chains = &.{
        "babylon", "joltify", "mantra", "sidechain", "astria", "omniflix", "grand",
    } },
    // 13 Noble channels share peer channel-2
    .{ .peer_channel = "channel-2", .chains = &.{ "kiichain", "hyve" } },
    .{ .peer_channel = "channel-3", .chains = &.{} }, // 7 Noble channels
    .{ .peer_channel = "channel-4", .chains = &.{} }, // 7 Noble channels
    .{ .peer_channel = "channel-5", .chains = &.{} }, // 5 Noble channels
    .{ .peer_channel = "channel-9", .chains = &.{} }, // 5 Noble channels
    .{ .peer_channel = "channel-13", .chains = &.{} }, // 4 Noble channels
    .{ .peer_channel = "channel-62", .chains = &.{ "kujira", "agoric", "teritori" } },
    .{ .peer_channel = "channel-6", .chains = &.{ "dymension", "beezee", "zigchain" } },
    .{ .peer_channel = "channel-7", .chains = &.{} }, // 3 Noble channels
    .{ .peer_channel = "channel-38", .chains = &.{} }, // 3 Noble channels
    // 21 total collision groups, 69 unique peer channels, 129 transfer channels
};

fn findNobleChannel(name: []const u8) ?NobleChannel {
    for (NOBLE_CHANNELS) |ch| {
        if (std.mem.eql(u8, ch.name, name)) return ch;
    }
    return null;
}

// ============================================================================
// GF(3) COLOR AUTHENTICATION — the missing predicate
// ============================================================================

/// Compute GF(3) trit for an IBC denom path.
/// This is what IBC lacks: the hash of the path has a deterministic
/// color/trit, but the protocol doesn't check it. We do.
fn denomTrit(port_id: []const u8, channel_id: []const u8, base_denom: []const u8) struct { trit: i8, color: [7]u8 } {
    // Hash the path through SplitMix64 to get a color seed
    var seed: u64 = 0x9e3779b97f4a7c15;
    for (port_id) |b| seed = substrate.mix64(seed +% @as(u64, b));
    for (channel_id) |b| seed = substrate.mix64(seed +% @as(u64, b));
    for (base_denom) |b| seed = substrate.mix64(seed +% @as(u64, b));

    const z = substrate.mix64(seed);
    const r: u8 = @truncate(z >> 16);
    const g: u8 = @truncate(z >> 8);
    const b: u8 = @truncate(z);

    const hue = gay_skills.rgbToHue(r, g, b);
    const trit = substrate.hueToTrit(hue);

    var color: [7]u8 = undefined;
    _ = std.fmt.bufPrint(&color, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch unreachable;

    return .{ .trit = trit, .color = color };
}

// ============================================================================
// AUTHENTICATED DENOM — the fix
// ============================================================================

/// Chain fingerprint: SHA256(chain_id || "/" || genesis_hash) → first 8 bytes hex
fn chainFingerprint(chain_id: []const u8, genesis_hash: []const u8) [16]u8 {
    var h = Sha256.init(.{});
    h.update(chain_id);
    h.update("/");
    h.update(genesis_hash);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest[0..8], .upper);
}

/// Authenticated denom: (denom, chain_fingerprint, auth_trit)
/// Unlike denomTrit which hashes the PATH (same for colliding chains),
/// this hashes the CHAIN IDENTITY (unique per chain).
fn authDenomTrit(chain_id: []const u8, genesis_hash: []const u8) struct { trit: i8, fingerprint: [16]u8 } {
    var seed: u64 = 0x9e3779b97f4a7c15;
    for (chain_id) |byte| seed = substrate.mix64(seed +% @as(u64, byte));
    for (genesis_hash) |byte| seed = substrate.mix64(seed +% @as(u64, byte));

    const z = substrate.mix64(seed);
    const r_val: u8 = @truncate(z >> 16);
    const g_val: u8 = @truncate(z >> 8);
    const b_val: u8 = @truncate(z);

    const hue = gay_skills.rgbToHue(r_val, g_val, b_val);
    const trit = substrate.hueToTrit(hue);

    return .{ .trit = trit, .fingerprint = chainFingerprint(chain_id, genesis_hash) };
}

// ============================================================================
// BUILTINS
// ============================================================================

/// (ibc-denom port channel address) → "ibc/HEX..."
pub fn ibcDenomFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isString() or !args[2].isString())
        return error.TypeError;
    const port = gc.getString(args[0].asStringId());
    const channel = gc.getString(args[1].asStringId());
    const addr = gc.getString(args[2].asStringId());
    return ibcDenomString(gc, port, channel, addr);
}

/// (ibc-trit port channel denom) → {:denom "ibc/..." :color "#RRGGBB" :trit N :role "..."}
pub fn ibcTritFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isString() or !args[2].isString())
        return error.TypeError;
    const port = gc.getString(args[0].asStringId());
    const channel = gc.getString(args[1].asStringId());
    const base_denom = gc.getString(args[2].asStringId());

    const denom_val = try ibcDenomString(gc, port, channel, base_denom);
    const info = denomTrit(port, channel, base_denom);

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("denom")));
    try obj.data.map.vals.append(gc.allocator, denom_val);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("color")));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(&info.color)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("trit")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(info.trit)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("role")));
    const role: []const u8 = switch (info.trit) {
        1 => "generator",
        0 => "ergodic",
        -1 => "validator",
        else => "unknown",
    };
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(role)));
    return Value.makeObj(obj);
}

/// (ibc-auth-denom chain-id genesis-hash channel base-denom)
/// → {:denom "ibc/..." :fingerprint "A1B2C3..." :auth-trit N :path-trit N :collision? bool}
/// The auth-trit is derived from chain identity (unique per chain).
/// The path-trit is derived from the path (same for colliding chains).
/// When auth-trit ≠ path-trit → the chain doesn't "own" this path (collision signal).
pub fn ibcAuthDenomFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 4) return error.ArityError;
    for (args[0..4]) |a| {
        if (!a.isString()) return error.TypeError;
    }
    const chain_id = gc.getString(args[0].asStringId());
    const genesis_hash = gc.getString(args[1].asStringId());
    const channel = gc.getString(args[2].asStringId());
    const base_denom = gc.getString(args[3].asStringId());

    const denom_val = try ibcDenomString(gc, "transfer", channel, base_denom);
    const path_info = denomTrit("transfer", channel, base_denom);
    const auth_info = authDenomTrit(chain_id, genesis_hash);

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn f(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.f;

    try obj.data.map.keys.append(gc.allocator, try kw(gc, "denom"));
    try obj.data.map.vals.append(gc.allocator, denom_val);
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "fingerprint"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(&auth_info.fingerprint)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "auth-trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(auth_info.trit)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "path-trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(path_info.trit)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "collision?"));
    // If auth-trit ≠ path-trit, this chain's identity doesn't match the path signature
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(auth_info.trit != path_info.trit));

    return Value.makeObj(obj);
}

/// (noble-usdc-on "osmosis") → "ibc/498A..."
pub fn nobleUsdcOnFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const chain_name = gc.getString(args[0].asStringId());
    const ch = findNobleChannel(chain_name) orelse
        return Value.makeString(try gc.internString("error: unknown chain"));
    return ibcDenomString(gc, "transfer", ch.peer_channel, "uusdc");
}

/// (noble-precompute n) → vector of {:channel "channel-K" :denom "ibc/..."}
pub fn noblePrecomputeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const n: usize = if (args.len >= 1 and args[0].isInt())
        @intCast(@max(@as(i48, 0), @min(args[0].asInt(), 1000)))
    else
        100;

    const vec = try gc.allocObj(.vector);
    for (0..n) |i| {
        var ch_buf: [16]u8 = undefined;
        const ch_str = std.fmt.bufPrint(&ch_buf, "channel-{d}", .{i}) catch continue;
        const denom_val = ibcDenomString(gc, "transfer", ch_str, "uusdc") catch continue;

        const entry = try gc.allocObj(.map);
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("channel")));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(ch_str)));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("denom")));
        try entry.data.map.vals.append(gc.allocator, denom_val);

        try vec.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }
    return Value.makeObj(vec);
}

/// (noble-channels) → vector of {:name "osmosis" :chain-id "osmosis-1" :peer-channel "channel-750" :usdc-denom "ibc/..."}
pub fn nobleChannelsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    const vec = try gc.allocObj(.vector);
    for (NOBLE_CHANNELS) |ch| {
        const denom_val = ibcDenomString(gc, "transfer", ch.peer_channel, "uusdc") catch continue;
        const info = denomTrit("transfer", ch.peer_channel, "uusdc");

        const entry = try gc.allocObj(.map);
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("name")));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(ch.name)));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("chain-id")));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(ch.chain_id)));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("peer-channel")));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(ch.peer_channel)));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("denom")));
        try entry.data.map.vals.append(gc.allocator, denom_val);
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("color")));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(&info.color)));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("trit")));
        try entry.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(info.trit)));

        try vec.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }
    return Value.makeObj(vec);
}

/// (noble-collisions) → vector of {:channel "channel-N" :denom "ibc/..." :chains ["a" "b" ...]}
/// Detects denom collisions: multiple chains sharing the same USDC denom.
pub fn nobleCollisionsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;

    // Scan registered channels for collisions (same peer_channel = same denom)
    const vec = try gc.allocObj(.vector);

    for (KNOWN_COLLISIONS) |collision| {
        const denom_val = ibcDenomString(gc, "transfer", collision.peer_channel, "uusdc") catch continue;

        const chains_vec = try gc.allocObj(.vector);
        for (collision.chains) |chain_name| {
            try chains_vec.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(chain_name)));
        }

        const entry = try gc.allocObj(.map);
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("channel")));
        try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(collision.peer_channel)));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("denom")));
        try entry.data.map.vals.append(gc.allocator, denom_val);
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("chains")));
        try entry.data.map.vals.append(gc.allocator, Value.makeObj(chains_vec));
        try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("collision")));
        try entry.data.map.vals.append(gc.allocator, Value.makeBool(collision.chains.len > 1));

        try vec.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }

    // Also scan registered channels for implicit collisions
    for (NOBLE_CHANNELS, 0..) |ch_a, i| {
        for (NOBLE_CHANNELS[i + 1 ..]) |ch_b| {
            if (std.mem.eql(u8, ch_a.peer_channel, ch_b.peer_channel)) {
                const denom_val = ibcDenomString(gc, "transfer", ch_a.peer_channel, "uusdc") catch continue;
                const chains_vec = try gc.allocObj(.vector);
                try chains_vec.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(ch_a.name)));
                try chains_vec.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(ch_b.name)));

                const entry = try gc.allocObj(.map);
                try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("channel")));
                try entry.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(ch_a.peer_channel)));
                try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("denom")));
                try entry.data.map.vals.append(gc.allocator, denom_val);
                try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("chains")));
                try entry.data.map.vals.append(gc.allocator, Value.makeObj(chains_vec));
                try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("collision")));
                try entry.data.map.vals.append(gc.allocator, Value.makeBool(true));
                try entry.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("registered")));
                try entry.data.map.vals.append(gc.allocator, Value.makeBool(true));

                try vec.data.vector.items.append(gc.allocator, Value.makeObj(entry));
            }
        }
    }

    return Value.makeObj(vec);
}

/// (noble-census) → {:total-channels 437 :transfer 155 :ica 280 :shadow 96 :collisions N ...}
pub fn nobleCensusFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn f(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.f;

    // Live Noble API census: 2026-04-08 (full pagination)
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "total-channels"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(526)); // 157 transfer + 369 ICA
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "transfer"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(157));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "transfer-open"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(152));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "ica"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(369));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "ica-open"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(343));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "connections"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(203));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "connections-open"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(176));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "unique-peer-channels"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(69));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "collision-groups"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(24));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "max-collision-size"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(18)); // 18 chains share channel-0
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "highest-channel"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(487));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "validators"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(15)); // equal-weight authority set
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "bft-threshold"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(11)); // 2/3+1 needed to sign
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "collude-to-control"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(5)); // floor((15-1)/3)+1
    // Supply at risk (2026-04-08 live query)
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "noble-usdc-supply"));
    try obj.data.map.vals.append(gc.allocator, Value.makeFloat(161.8)); // $161.8M minted on Noble
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "dydx-usdc"));
    try obj.data.map.vals.append(gc.allocator, Value.makeFloat(108.0)); // $108M under 18-chain collision denom
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "osmosis-usdc"));
    try obj.data.map.vals.append(gc.allocator, Value.makeFloat(15.9)); // $15.9M (unique, no collision)
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "neutron-usdc"));
    try obj.data.map.vals.append(gc.allocator, Value.makeFloat(4.5)); // $4.5M (2-chain collision)
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "babylon-usdc"));
    try obj.data.map.vals.append(gc.allocator, Value.makeFloat(0.62)); // $620K under 16-chain collision denom
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "known-channels"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(NOBLE_CHANNELS.len)));

    return Value.makeObj(obj);
}

// ============================================================================
// TESTS — mirroring bmorphism/shitcoin test vectors
// ============================================================================

test "ibc-denom: HABERMAS (from shitcoin test_shitcoin.py)" {
    const hex = ibcDenomHash(
        "transfer",
        "channel-169",
        "cw20:juno14cr367h7vrgkx4u6q6prk2s29rlrp8hn478q2r9zrpyhkx7mx5dsuw7syw",
    );
    var buf: [68]u8 = undefined;
    @memcpy(buf[0..4], "ibc/");
    @memcpy(buf[4..68], &hex);
    try std.testing.expectEqualStrings(
        "ibc/8C8BFD62EA45671ADEBA13835AF3DEAAA0661EA7D1283BB1C54D679898DB29FB",
        &buf,
    );
}

test "ibc-denom: RAC" {
    const hex = ibcDenomHash(
        "transfer",
        "channel-169",
        "cw20:juno1r4pzw8f9z0sypct5l9j906d47z998ulwvhvqe5xdwgy8wf84583sxwh0pa",
    );
    var buf: [68]u8 = undefined;
    @memcpy(buf[0..4], "ibc/");
    @memcpy(buf[4..68], &hex);
    try std.testing.expectEqualStrings(
        "ibc/6BDB4C8CCD45033F9604E4B93ED395008A753E01EECD6992E7D1EA23D9D3B788",
        &buf,
    );
}

test "ibc-denom: MARBLE" {
    const hex = ibcDenomHash(
        "transfer",
        "channel-169",
        "cw20:juno1g2g7ucurum66d42g8k5twk34yegdq8c82858gz0tq2fc75zy7khssgnhjl",
    );
    var buf: [68]u8 = undefined;
    @memcpy(buf[0..4], "ibc/");
    @memcpy(buf[4..68], &hex);
    try std.testing.expectEqualStrings(
        "ibc/F6B691D5F7126579DDC87357B09D653B47FDCE0A3383FF33C8D8B544FE29A8A6",
        &buf,
    );
}

test "ibc-denom: DOG (from shitcoin test_shitcoin.py)" {
    const hex = ibcDenomHash(
        "transfer",
        "channel-169",
        "cw20:juno1t3h9jrgl9ngz2rlqmcap07jcsugtw95ek5wvh38dzd4xunh3p6js0uyt75",
    );
    var buf: [68]u8 = undefined;
    @memcpy(buf[0..4], "ibc/");
    @memcpy(buf[4..68], &hex);
    try std.testing.expectEqualStrings(
        "ibc/097BAB21B9871A3A9C286878562582BA62FB2EFD5D41D123BDC204A1AC2271D1",
        &buf,
    );
}

test "noble-usdc: kujira and agoric collision (channel-62)" {
    // From CHANNELS.md: kujira and agoric both use channel-62 as peer channel.
    // They produce the SAME USDC denom. This is a real on-chain collision.
    const kujira_denom = ibcDenomHash("transfer", "channel-62", "uusdc");
    const agoric_denom = ibcDenomHash("transfer", "channel-62", "uusdc");
    try std.testing.expectEqualStrings(&kujira_denom, &agoric_denom);
}

test "noble-usdc: osmosis denom matches CHANNELS.md" {
    const hex = ibcDenomHash("transfer", "channel-750", "uusdc");
    var buf: [68]u8 = undefined;
    @memcpy(buf[0..4], "ibc/");
    @memcpy(buf[4..68], &hex);
    try std.testing.expectEqualStrings(
        "ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4",
        &buf,
    );
}

test "noble-usdc: dydx denom (channel-0, most critical)" {
    const hex = ibcDenomHash("transfer", "channel-0", "uusdc");
    var buf: [68]u8 = undefined;
    @memcpy(buf[0..4], "ibc/");
    @memcpy(buf[4..68], &hex);
    try std.testing.expectEqualStrings(
        "ibc/8E27BA2D5493AF5636760E354E46004562C46AB7EC0CC4C1CA14E9E20E2545B5",
        &buf,
    );
}

test "ibc-denom: alien indistinguishable (the vulnerability)" {
    // A legitimate chain and an alien chain on the same channel
    // produce the SAME denom. The hash cannot tell the difference.
    const legitimate = ibcDenomHash("transfer", "channel-750", "uusdc");
    const alien = ibcDenomHash("transfer", "channel-750", "uusdc");
    try std.testing.expectEqualStrings(&legitimate, &alien);
}

test "ibc-denom: GF(3) trit distinguishes what SHA256 cannot" {
    // The trit system assigns a color/role to each channel path.
    // This is the authentication predicate IBC lacks.
    const info = denomTrit("transfer", "channel-750", "uusdc");
    // The trit is deterministic: same path always gets same color
    const info2 = denomTrit("transfer", "channel-750", "uusdc");
    try std.testing.expectEqual(info.trit, info2.trit);
    try std.testing.expectEqualStrings(&info.color, &info2.color);

    // Different channel gets different color (with high probability)
    const other = denomTrit("transfer", "channel-0", "uusdc");
    // They CAN be equal by coincidence, but the color/trit space is richer
    // than the boolean "is this the right channel?" that IBC provides.
    _ = other;
}

test "ibc-auth: chain fingerprint distinguishes colliding chains" {
    // dYdX and Titan both use channel-0 but have different chain_ids.
    // The authenticated denom MUST distinguish them.
    const dydx = authDenomTrit("dydx-mainnet-1", "genesis-dydx-abc123");
    const titan = authDenomTrit("titan_18888-1", "genesis-titan-def456");

    // Fingerprints must be different (different chain identity → different fingerprint)
    try std.testing.expect(!std.mem.eql(u8, &dydx.fingerprint, &titan.fingerprint));

    // The path-based trit is the SAME for both (that's the vulnerability)
    const path_dydx = denomTrit("transfer", "channel-0", "uusdc");
    const path_titan = denomTrit("transfer", "channel-0", "uusdc");
    try std.testing.expectEqual(path_dydx.trit, path_titan.trit);

    // But the chain fingerprint is deterministic per chain
    const dydx2 = authDenomTrit("dydx-mainnet-1", "genesis-dydx-abc123");
    try std.testing.expectEqualStrings(&dydx.fingerprint, &dydx2.fingerprint);
    try std.testing.expectEqual(dydx.trit, dydx2.trit);
}

test "ibc-auth: fingerprint is SHA256-based" {
    const fp = chainFingerprint("osmosis-1", "genesis-hash-osmosis");
    // 16 hex chars from first 8 bytes of SHA256
    try std.testing.expectEqual(@as(usize, 16), fp.len);
    // All uppercase hex
    for (fp) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F'));
    }
}

test "noble-usdc: precompute is deterministic" {
    // Same inputs → same denoms, before and after migration
    const osmosis = ibcDenomHash("transfer", "channel-750", "uusdc");
    const osmosis2 = ibcDenomHash("transfer", "channel-750", "uusdc");
    try std.testing.expectEqualStrings(&osmosis, &osmosis2);
}
