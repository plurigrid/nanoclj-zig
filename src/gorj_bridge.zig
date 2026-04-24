//! gorj_bridge: nanoclj-zig ↔ gorj (Clojure MCP) relay — collapsed loops
//!
//! Design principle: AVOID ROUNDTRIPS by collapsing intermediate representations.
//!
//! Before (3 roundtrips for eval+encode+version):
//!   expr → read → eval → result → prStr → syrup_encode → hex → version_struct
//!        → version_log_append → map_build(8 keys) → return
//!
//! After (collapsed, 0 roundtrips):
//!   expr → read → eval → result_val (done if only value needed)
//!        ↘ version_id: inline SplitMix64, no Version struct
//!        ↘ trit: already in Resources from eval
//!        ↘ syrup: raw bytes as string (no hex encoding)
//!
//! The hex encoding/decoding loop was the worst offender:
//!   encode: bytes[N] → hex[2N] → internString(2N) → return
//!   decode: getString → hex[2N] → parseInt×N → bytes[N] → syrup_decode → value
//!   That's 4 allocations and 2N×2 character conversions for a roundtrip.
//!   Collapsed: bytes[N] → internString(N) → return. One alloc. No conversion.
//!
//! Builtins:
//!   (gorj-pipe expr)       — fused eval→version→result, returns [result version-id trit]
//!   (gorj-eval expr)       — gorj-pipe with map output (backward compat)
//!   (gorj-encode val)      — value → raw Syrup bytes as string (no hex)
//!   (gorj-decode bytes)    — raw Syrup string → value (no hex parsing)
//!   (gorj-version)         — current version frontier (inline u64, not hex)
//!   (gorj-tools)           — gorj's 29 MCP tool names

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const syrup_bridge = @import("syrup_bridge.zig");
const braid = @import("braid.zig");
const semantics = @import("semantics.zig");
const compat = @import("compat.zig");

// ============================================================================
// INLINE VERSION ID: no Version struct, no VersionLog append
// ============================================================================

// Index-addressed versioning (Gay.jl SPI pattern):
//   version_id(seed, index, expr) = mix64(mix64(seed) + index * GOLDEN + hash(expr))
// No chained state. Any eval can be reproduced from (root_seed, invocation_index).
// Trit accumulator uses index mod 3 — deterministic from position alone.
const GOLDEN = 0x9e3779b97f4a7c15;

var root_seed: u64 = 0; // set once from world seed via initSession
var invocation_index: u64 = 0; // monotonic, but only for ordering — not state
var trit_accumulator: i32 = 0;

/// SplitMix64 — canonical bijection, same constants as Gay.jl/substrate.zig
inline fn mix64(seed: u64) u64 {
    var z = seed +% GOLDEN;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Initialize session with a root seed (called once at REPL/MCP startup)
pub fn initSession(seed: u64) void {
    root_seed = seed;
    invocation_index = 0;
    trit_accumulator = 0;
}

/// Index-addressed version ID: pure function of (root_seed, index, expr).
/// Reproducible: same (seed, index, expr) → same version_id, always.
inline fn computeVersionId(expr: []const u8) u64 {
    var h = mix64(root_seed +% invocation_index *% GOLDEN);
    for (expr) |byte| {
        h = mix64(h ^ @as(u64, byte));
    }
    invocation_index += 1;
    return h;
}

/// Version ID at arbitrary index without advancing state (SPI: O(1) random access)
pub fn versionAt(seed: u64, index: u64, expr: []const u8) u64 {
    var h = mix64(seed +% index *% GOLDEN);
    for (expr) |byte| {
        h = mix64(h ^ @as(u64, byte));
    }
    return h;
}

// ============================================================================
// FUSED EVAL PIPELINE
// ============================================================================

/// Core pipeline: expr → read → eval → (result_val, trit, version_id)
/// No intermediate allocations beyond what eval itself needs.
const PipeResult = struct {
    result: Value,
    trit: i8,
    version_id: u64,
    fuel_spent: u64,
    gf3_balanced: bool,
};

fn evalPipe(expr: []const u8, env: *Env, gc: *GC) PipeResult {
    var reader = Reader.init(expr, gc);
    const form = reader.readForm() catch return .{
        .result = Value.makeNil(),
        .trit = 0,
        .version_id = computeVersionId(expr),
        .fuel_spent = 0,
        .gf3_balanced = @mod(trit_accumulator, 3) == 0,
    };

    var res = semantics.Resources.initDefault();
    const initial_fuel = res.fuel;
    const domain = semantics.evalBounded(form, env, gc, &res);
    const result_val: Value = switch (domain) {
        .value => |v| v,
        else => Value.makeNil(),
    };

    const vid = computeVersionId(expr);
    trit_accumulator += res.trit_balance;

    return .{
        .result = result_val,
        .trit = res.trit_balance,
        .version_id = vid,
        .fuel_spent = initial_fuel - res.fuel,
        .gf3_balanced = @mod(trit_accumulator, 3) == 0,
    };
}

// ============================================================================
// BUILTINS
// ============================================================================

/// (gorj-pipe expr) → [result version-id trit]
/// Minimal output: 3-element vector. No map. No Syrup. No hex.
/// This is the collapsed hot path.
pub fn gorjPipeFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const expr = gc.getString(args[0].asStringId());

    const p = evalPipe(expr, env, gc);

    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.append(gc.allocator, p.result);
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(@as(i48, @truncate(@as(i64, @bitCast(p.version_id)))))));
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(p.trit)));
    return Value.makeObj(obj);
}

/// (gorj-eval expr) → {:result val :trit N :version-id N :gf3-balanced? bool}
/// Backward-compatible map output, but uses fused pipeline internally.
pub fn gorjEvalFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const expr = gc.getString(args[0].asStringId());

    const p = evalPipe(expr, env, gc);

    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "result"));
    try obj.data.map.vals.append(gc.allocator, p.result);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(p.trit)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "fuel-spent"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(p.fuel_spent, std.math.maxInt(i48)))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "version-id"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, @truncate(@as(i64, @bitCast(p.version_id)))))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "gf3-balanced?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(p.gf3_balanced));
    return Value.makeObj(obj);
}

/// (gorj-encode val) → raw Syrup bytes as interned string (no hex conversion)
pub fn gorjEncodeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const bytes = try syrup_bridge.encode_to_bytes(args[0], gc, gc.allocator);
    defer gc.allocator.free(bytes);
    return Value.makeString(try gc.internString(bytes));
}

/// (gorj-decode syrup-string) → nanoclj value
/// Accepts raw Syrup bytes (string), no hex. Direct decode via syrup_bridge.
pub fn gorjDecodeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const raw = gc.getString(args[0].asStringId());
    return syrup_bridge.decode_from_bytes(raw, gc, gc.allocator) catch Value.makeNil();
}

/// (gorj-version) → current invocation index (deterministic position in session)
pub fn gorjVersionFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    _ = gc;
    if (invocation_index == 0) return Value.makeNil();
    // Return version at current index — reproducible from (root_seed, index)
    const vid = mix64(root_seed +% (invocation_index - 1) *% GOLDEN);
    return Value.makeInt(@intCast(@as(i48, @truncate(@as(i64, @bitCast(vid))))));
}

/// (gorj-tools) → vector of gorj's 45 MCP tool names
pub fn gorjToolsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    const tool_names = [_][]const u8{
        // Core eval + pipeline
        "gorj_eval",            "gorj_pipe",            "gorj_encode",
        "gorj_decode",          "gorj_version",         "gorj_tools",
        "gorj_trit_tick",       "gorj_generate_ticks",  "gorj_partition_by_trit",
        "gorj_spi_verify",      "gorj_color",           "gorj_substrate",
        "gorj_compile",         "gorj_spacetime",       "gorj_peval",
        "gorj_atom",            "gorj_session",         "gorj_fuel",
        // Convergence bridge (OCapN/CapTP + MCP proxy + inet)
        "gorj_captp_bootstrap", "gorj_captp_introduce", "gorj_captp_deliver",
        "gorj_captp_abort",     "gorj_inet_reduce",     "gorj_mcp_proxy",
        "gorj_convergence",
        // String diagram tools (v0.3.0)
            "gorj_string_diagram",  "gorj_diagram_reduce",
        "gorj_diagram_compose", "gorj_diagram_parse",   "gorj_diagram_kernel",
        // Dialect bridges
        "gorj_bb",              "gorj_jank",            "gorj_cljw",
        "gorj_squint",          "gorj_dart",            "gorj_basilisp",
        "gorj_glojure",         "gorj_joker",           "gorj_nbb",
        "gorj_scittle",         "gorj_clr",             "gorj_cherry",
        "gorj_cream",           "gorj_clojerl",         "gorj_dialects",
    };
    const obj = try gc.allocObj(.vector);
    for (tool_names) |name| {
        try obj.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(name)));
    }
    return Value.makeObj(obj);
}

// ============================================================================
// TESTS
// ============================================================================

test "gorj-bridge: encode/decode roundtrip — no hex, raw Syrup bytes" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var resources = Resources.initDefault();

    // Encode integer → raw Syrup bytes (not hex)
    const val = Value.makeInt(42);
    var encode_args = [_]Value{val};
    const syrup_val = try gorjEncodeFn(&encode_args, &gc, &env, &resources);
    try std.testing.expect(syrup_val.isString());

    // Decode raw bytes back — zero conversion overhead
    var decode_args = [_]Value{syrup_val};
    const decoded = try gorjDecodeFn(&decode_args, &gc, &env, &resources);
    try std.testing.expect(decoded.isInt());
    try std.testing.expectEqual(@as(i48, 42), decoded.asInt());
}

test "gorj-bridge: encode/decode roundtrip for string — raw Syrup" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var resources = Resources.initDefault();

    const val = Value.makeString(try gc.internString("hello gorj"));
    var encode_args = [_]Value{val};
    const syrup_val = try gorjEncodeFn(&encode_args, &gc, &env, &resources);

    var decode_args = [_]Value{syrup_val};
    const decoded = try gorjDecodeFn(&decode_args, &gc, &env, &resources);
    try std.testing.expect(decoded.isString());
    try std.testing.expectEqualStrings("hello gorj", gc.getString(decoded.asStringId()));
}

test "gorj-bridge: gorj-pipe returns 3-element vector [result vid trit]" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    // Reset state for test isolation
    invocation_index = 0;
    root_seed = 0;
    trit_accumulator = 0;

    var resources = Resources.initDefault();
    var args = [_]Value{Value.makeString(try gc.internString("42"))};
    const result = try gorjPipeFn(&args, &gc, &env, &resources);
    try std.testing.expect(result.isObj());
    const items = result.asObj().data.vector.items.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);

    // items[0] = result value
    try std.testing.expect(items[0].isInt());
    try std.testing.expectEqual(@as(i48, 42), items[0].asInt());

    // items[1] = version-id (integer)
    try std.testing.expect(items[1].isInt());

    // items[2] = trit (integer)
    try std.testing.expect(items[2].isInt());
}

test "gorj-bridge: version counter increments across pipe calls" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    invocation_index = 0;
    root_seed = 0;
    trit_accumulator = 0;

    var resources = Resources.initDefault();

    var args1 = [_]Value{Value.makeString(try gc.internString("1"))};
    const r1 = try gorjPipeFn(&args1, &gc, &env, &resources);
    const vid1 = r1.asObj().data.vector.items.items[1].asInt();

    var args2 = [_]Value{Value.makeString(try gc.internString("2"))};
    const r2 = try gorjPipeFn(&args2, &gc, &env, &resources);
    const vid2 = r2.asObj().data.vector.items.items[1].asInt();

    // Different expressions → different version IDs
    try std.testing.expect(vid1 != vid2);
    // Counter advanced
    try std.testing.expectEqual(@as(u64, 2), invocation_index);
}

test "gorj-bridge: gorj-tools returns 45 names" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var resources = Resources.initDefault();
    var args = [_]Value{};
    const result = try gorjToolsFn(&args, &gc, &env, &resources);
    try std.testing.expect(result.isObj());
    try std.testing.expectEqual(@as(usize, 45), result.asObj().data.vector.items.items.len);
    try std.testing.expectEqualStrings("gorj_eval", gc.getString(result.asObj().data.vector.items.items[0].asStringId()));
}

test "gorj-bridge: gorj-version nil before first eval" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    invocation_index = 0;
    root_seed = 0;
    var resources = Resources.initDefault();
    var args = [_]Value{};
    const result = try gorjVersionFn(&args, &gc, &env, &resources);
    try std.testing.expect(result.isNil());
}
