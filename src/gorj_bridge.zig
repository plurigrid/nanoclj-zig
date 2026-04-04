//! gorj_bridge: nanoclj-zig ↔ gorj (Clojure MCP) relay
//!
//! gorj is a Babashka-based MCP server with 29 tools for Clojure REPL
//! interaction (repl_eval, reload_namespace, doc_symbol, etc.).
//! It speaks JSON-RPC over stdio to nREPL.
//!
//! This bridge closes the feedback loop:
//!   gorj repl_eval → nanoclj-zig eval → syrup_bridge → braid versioning
//!   nanoclj-zig (gorj-eval expr) → encode to Syrup → version → result
//!
//! The key insight: gorj and nanoclj-zig are two Clojure evaluators
//! that can relay to each other. gorj handles JVM Clojure via nREPL;
//! nanoclj-zig handles Zig-native Clojure with GF(3) trit tracking.
//! The Syrup bridge provides the canonical wire format between them.
//!
//! Builtins:
//!   (gorj-eval expr)      — eval through local nanoclj, Syrup-encode result, version it
//!   (gorj-encode val)     — convert nanoclj value to Syrup bytes (hex string)
//!   (gorj-decode hex)     — convert Syrup hex bytes back to nanoclj value
//!   (gorj-version)        — return current Braid version ID (hex)
//!   (gorj-tools)          — list gorj's 29 tool names as a vector

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const syrup_bridge = @import("syrup_bridge.zig");
const braid = @import("braid.zig");
const semantics = @import("semantics.zig");
const compat = @import("compat.zig");

var version_log: ?braid.VersionLog = null;

fn getVersionLog(allocator: std.mem.Allocator) *braid.VersionLog {
    if (version_log == null) {
        version_log = braid.VersionLog.init(allocator);
    }
    return &version_log.?;
}

/// (gorj-eval expr) — evaluate expr, Syrup-encode result, create Braid version
pub fn gorjEvalFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const expr = gc.getString(args[0].asStringId());

    // Evaluate through nanoclj-zig's bounded eval
    var reader = Reader.init(expr, gc);
    const form = try reader.readForm();
    var res = semantics.Resources.initDefault();
    const domain = semantics.evalBounded(form, env, gc, &res);

    const result_val: Value = switch (domain) {
        .value => |v| v,
        else => Value.makeNil(),
    };

    // Syrup-encode the result
    const syrup_bytes = syrup_bridge.encode_to_bytes(result_val, gc, gc.allocator) catch |e| {
        _ = e;
        return Value.makeNil();
    };
    defer gc.allocator.free(syrup_bytes);

    // Create Braid version
    const vlog = getVersionLog(gc.allocator);
    const result_str = printer.prStr(result_val, gc, true) catch "nil";
    const parent_id = vlog.frontier();
    var parents_buf: [1]braid.VersionId = undefined;
    const parents: []const braid.VersionId = if (parent_id) |f| blk: {
        parents_buf[0] = f;
        break :blk parents_buf[0..1];
    } else &.{};
    const version = braid.Version{
        .id = braid.hashVersion(expr, parent_id),
        .parents = parents,
        .form = expr,
        .result = result_str,
        .env_patch = syrup_bytes,
        .trit = res.trit_balance,
        .timestamp_ns = std.time.nanoTimestamp(),
    };
    vlog.append(version) catch {};

    // Return a map with result, version-id, trit, syrup-size
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    };

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "result"));
    try obj.data.map.vals.append(gc.allocator, result_val);
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "trit"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(res.trit_balance)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "fuel-spent"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(res.fuel, std.math.maxInt(i48)))));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "syrup-bytes"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(syrup_bytes.len)));
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "version-id"));
    var hex_buf: [32]u8 = undefined;
    for (version.id, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch {};
    }
    try obj.data.map.keys.append(gc.allocator, try kw.intern(gc, "gf3-balanced?"));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(vlog.gf3Balanced()));
    try obj.data.map.vals.insert(gc.allocator, obj.data.map.vals.items.len - 1, Value.makeString(try gc.internString(&hex_buf)));

    return Value.makeObj(obj);
}

/// (gorj-encode val) — convert a nanoclj value to Syrup bytes, return hex string
pub fn gorjEncodeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const bytes = try syrup_bridge.encode_to_bytes(args[0], gc, gc.allocator);
    defer gc.allocator.free(bytes);

    // Convert to hex string
    var hex = try gc.allocator.alloc(u8, bytes.len * 2);
    defer gc.allocator.free(hex);
    for (bytes, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch {};
    }
    return Value.makeString(try gc.internString(hex));
}

/// (gorj-decode hex-string) — decode Syrup hex bytes back to nanoclj value
pub fn gorjDecodeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;
    const hex = gc.getString(args[0].asStringId());

    if (hex.len % 2 != 0) return error.TypeError;

    // Hex decode
    var bytes = try gc.allocator.alloc(u8, hex.len / 2);
    defer gc.allocator.free(bytes);
    for (0..bytes.len) |i| {
        bytes[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.TypeError;
    }

    // Syrup decode → nanoclj value
    const syrup = @import("syrup");
    const decoded = syrup.Value.decodeAlloc(gc.allocator, bytes) catch return Value.makeNil();
    return syrupToNanoclj(decoded, gc);
}

/// Convert Syrup value back to nanoclj value
fn syrupToNanoclj(sv: @import("syrup").Value, gc: *GC) !Value {
    const syrup = @import("syrup");
    _ = syrup;
    switch (sv) {
        .@"null" => return Value.makeNil(),
        .boolean => |b| return Value.makeBool(b),
        .integer => |i| return Value.makeInt(@intCast(@min(i, std.math.maxInt(i48)))),
        .float => |f| return Value.makeFloat(f),
        .string => |s| return Value.makeString(try gc.internString(s)),
        .symbol => |s| return Value.makeSymbol(try gc.internString(s)),
        .list => |items| {
            const obj = try gc.allocObj(.list);
            for (items) |item| {
                try obj.data.list.items.append(gc.allocator, try syrupToNanoclj(item, gc));
            }
            return Value.makeObj(obj);
        },
        .dictionary => |entries| {
            const obj = try gc.allocObj(.map);
            for (entries) |entry| {
                try obj.data.map.keys.append(gc.allocator, try syrupToNanoclj(entry.key, gc));
                try obj.data.map.vals.append(gc.allocator, try syrupToNanoclj(entry.value, gc));
            }
            return Value.makeObj(obj);
        },
        .set => |items| {
            const obj = try gc.allocObj(.set);
            for (items) |item| {
                try obj.data.set.items.append(gc.allocator, try syrupToNanoclj(item, gc));
            }
            return Value.makeObj(obj);
        },
        else => return Value.makeNil(),
    }
}

/// (gorj-version) — return current Braid version frontier as hex string
pub fn gorjVersionFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const vlog = getVersionLog(gc.allocator);
    if (vlog.frontier()) |vid| {
        var hex_buf: [32]u8 = undefined;
        for (vid, 0..) |byte, i| {
            _ = std.fmt.bufPrint(hex_buf[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch {};
        }
        return Value.makeString(try gc.internString(&hex_buf));
    }
    return Value.makeNil();
}

/// (gorj-tools) — list gorj's tool names as a vector
pub fn gorjToolsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const tool_names = [_][]const u8{
        "repl_eval",           "reload_namespace",    "eval_at",
        "eval_comment_block",  "doc_symbol",          "find_usages",
        "create_ns",           "create_test_ns",      "add_require",
        "run_tests",           "run_ns_tests",        "run_test",
        "test_coverage",       "clj_deps",            "add_dep",
        "process_start",       "process_stop",        "process_list",
        "process_log",         "env_info",            "status",
        "eval_file",           "scaffold_api",        "scaffold_config",
        "scaffold_db",         "scaffold_handler",    "scaffold_middleware",
        "scaffold_model",      "scaffold_service",
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

test "gorj-bridge: encode/decode roundtrip for integer" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const val = Value.makeInt(42);
    var encode_args = [_]Value{val};
    const hex_val = try gorjEncodeFn(&encode_args, &gc, &env);

    try std.testing.expect(hex_val.isString());
    const hex = gc.getString(hex_val.asStringId());
    try std.testing.expect(hex.len > 0);

    // Decode back
    var decode_args = [_]Value{hex_val};
    const decoded = try gorjDecodeFn(&decode_args, &gc, &env);
    try std.testing.expect(decoded.isInt());
    try std.testing.expectEqual(@as(i48, 42), decoded.asInt());
}

test "gorj-bridge: encode/decode roundtrip for string" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const val = Value.makeString(try gc.internString("hello gorj"));
    var encode_args = [_]Value{val};
    const hex_val = try gorjEncodeFn(&encode_args, &gc, &env);

    var decode_args = [_]Value{hex_val};
    const decoded = try gorjDecodeFn(&decode_args, &gc, &env);
    try std.testing.expect(decoded.isString());
    const s = gc.getString(decoded.asStringId());
    try std.testing.expectEqualStrings("hello gorj", s);
}

test "gorj-bridge: gorj-tools returns 29 tool names" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var args = [_]Value{};
    const result = try gorjToolsFn(&args, &gc, &env);
    try std.testing.expect(result.isObj());
    const items = result.asObj().data.vector.items.items;
    try std.testing.expectEqual(@as(usize, 29), items.len);

    // First tool should be repl_eval
    const first = gc.getString(items[0].asStringId());
    try std.testing.expectEqualStrings("repl_eval", first);
}

test "gorj-bridge: gorj-version is nil before any eval" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    // Reset version log for test isolation
    version_log = null;
    var args = [_]Value{};
    const result = try gorjVersionFn(&args, &gc, &env);
    try std.testing.expect(result.isNil());
}
