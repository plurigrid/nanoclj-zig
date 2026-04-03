//! MCP (Model Context Protocol) Server for nanoclj-zig
//!
//! Exposes nanoclj-zig Clojure interpreter as MCP tools over JSON-RPC 2.0 on stdio.
//! Tools: nanoclj_eval, nanoclj_color_at, nanoclj_bci_read, nanoclj_substrate, nanoclj_traverse

const std = @import("std");
const json = std.json;
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const core = @import("core.zig");

const SERVER_NAME = "nanoclj-zig";
const SERVER_VERSION = "0.1.0";
const PROTOCOL_VERSION = "2024-11-05";
const MAX_LINE_SIZE = 4 * 1024 * 1024;
const BUILTIN_COUNT = 35;

// ============================================================================
// SplitMix64 (for trit + color derivation)
// ============================================================================

fn splitMix64(seed: u64) u64 {
    var z = seed +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn hashString(s: []const u8) u64 {
    var h: u64 = 1069;
    for (s) |c| {
        h = splitMix64(h ^ @as(u64, c));
    }
    return h;
}

fn tritFromHash(h: u64) i8 {
    return @as(i8, @intCast(h % 3)) - 1; // -1, 0, +1
}

fn colorFromHash(h: u64) [3]u8 {
    return .{
        @truncate(h >> 16),
        @truncate(h >> 8),
        @truncate(h),
    };
}

fn hexColor(rgb: [3]u8) [7]u8 {
    const hex_chars = "0123456789abcdef";
    return .{
        '#',
        hex_chars[rgb[0] >> 4], hex_chars[rgb[0] & 0xf],
        hex_chars[rgb[1] >> 4], hex_chars[rgb[1] & 0xf],
        hex_chars[rgb[2] >> 4], hex_chars[rgb[2] & 0xf],
    };
}

// Gay color at seed+index (golden angle spiral)
fn gayColorAt(seed: u64, index: u64) [3]u8 {
    const golden_angle: f64 = 137.50776405;
    const hue_deg: f64 = @mod(@as(f64, @floatFromInt(seed +% index)) * golden_angle, 360.0);
    const hue = hue_deg / 360.0;
    // HSV->RGB with S=0.85, V=0.95
    return hsvToRgb(hue, 0.85, 0.95);
}

fn hsvToRgb(h: f64, s: f64, v: f64) [3]u8 {
    const i_sec: u32 = @intFromFloat(h * 6.0);
    const f = h * 6.0 - @as(f64, @floatFromInt(i_sec));
    const p = v * (1.0 - s);
    const q = v * (1.0 - f * s);
    const t = v * (1.0 - (1.0 - f) * s);
    const rgb: [3]f64 = switch (i_sec % 6) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        5 => .{ v, p, q },
        else => .{ v, v, v },
    };
    return .{
        @intFromFloat(rgb[0] * 255.0),
        @intFromFloat(rgb[1] * 255.0),
        @intFromFloat(rgb[2] * 255.0),
    };
}

// ============================================================================
// Nanoclj eval (persistent state)
// ============================================================================

var global_gc: GC = undefined;
var global_env: Env = undefined;
var nanoclj_initialized = false;

fn initNanoclj(allocator: std.mem.Allocator) !void {
    if (nanoclj_initialized) return;
    global_gc = GC.init(allocator);
    global_env = Env.init(allocator, null);
    try core.initCore(&global_env, &global_gc);
    nanoclj_initialized = true;
}

fn evalWithBuiltins(form: Value, env: *Env, gc: *GC) !Value {
    if (form.isObj() and form.asObj().kind == .list) {
        const items = form.asObj().data.list.items.items;
        if (items.len > 0 and items[0].isSymbol()) {
            const name = gc.getString(items[0].asSymbolId());
            if (core.lookupBuiltin(name)) |builtin| {
                var args = @import("compat.zig").emptyList(Value);
                defer args.deinit(gc.allocator);
                for (items[1..]) |arg| {
                    const v = try evalWithBuiltins(arg, env, gc);
                    try args.append(gc.allocator, v);
                }
                return builtin(args.items, gc, env);
            }
        }
    }
    return eval_mod.eval(form, env, gc);
}

fn rep(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    try initNanoclj(allocator);
    var reader = Reader.init(input, &global_gc);
    const form = reader.readForm() catch |err| {
        return switch (err) {
            error.UnexpectedEOF => "Error: unexpected EOF",
            error.UnmatchedParen => "Error: unmatched )",
            error.UnmatchedBracket => "Error: unmatched ]",
            error.UnmatchedBrace => "Error: unmatched }",
            error.InvalidNumber => "Error: invalid number",
            error.UnexpectedChar => "Error: unexpected character",
            else => "Error: read failed",
        };
    };

    const result = evalWithBuiltins(form, &global_env, &global_gc) catch |err| {
        return switch (err) {
            error.SymbolNotFound => "Error: symbol not found",
            error.NotAFunction => "Error: not a function",
            error.ArityError => "Error: wrong number of arguments",
            error.TypeError => "Error: type error",
            else => "Error: eval failed",
        };
    };

    return printer.prStr(result, &global_gc, true) catch "Error: print failed";
}

// ============================================================================
// Tool Definitions
// ============================================================================

const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const http_fetch = @import("http_fetch.zig");

const tools = [_]Tool{
    .{
        .name = "nanoclj_eval",
        .description = "Evaluate a Clojure expression in nanoclj-zig. State persists across calls.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to evaluate"}},"required":["code"]}
    },
    .{
        .name = "nanoclj_color_at",
        .description = "Get Gay color at seed+index using golden angle spiral and SplitMix64",
        .input_schema =
        \\{"type":"object","properties":{"seed":{"type":"integer","default":1069,"description":"SplitMix64 seed (default 1069)"},"index":{"type":"integer","description":"Color index"}},"required":["index"]}
    },
    .{
        .name = "nanoclj_bci_read",
        .description = "Read synthetic BCI data (8ch default). Returns channel values, trit, and entropy.",
        .input_schema =
        \\{"type":"object","properties":{"channels":{"type":"integer","default":8,"description":"Number of channels (default 8)"}},"required":[]}
    },
    .{
        .name = "nanoclj_substrate",
        .description = "Get nanoclj-zig substrate info: runtime, GC objects, builtin count",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "nanoclj_traverse",
        .description = "Traverse to another substrate (e.g. zig-syrup, nashator, goblins-adapter)",
        .input_schema =
        \\{"type":"object","properties":{"target":{"type":"string","description":"Target substrate name"}},"required":["target"]}
    },
    .{
        .name = "nanoclj_http_fetch",
        .description = "HTTP GET/POST. Returns {:status N :body \"...\"}. Methods: get, post, put, delete.",
        .input_schema =
        \\{"type":"object","properties":{"url":{"type":"string","description":"URL to fetch"},"method":{"type":"string","enum":["get","post","put","delete"],"default":"get","description":"HTTP method"},"body":{"type":"string","description":"Request body (for POST/PUT)"}},"required":["url"]}
    },
};

// ============================================================================
// MCP Protocol Messages
// ============================================================================

fn writeJsonLine(writer: anytype, val: json.Value, allocator: std.mem.Allocator) !void {
    const bytes = try json.Stringify.valueAlloc(allocator, val, .{});
    defer allocator.free(bytes);
    try writer.writeAll(bytes);
    try writer.writeAll("\n");
}

fn makeResponse(allocator: std.mem.Allocator, id: json.Value, result: json.Value) !json.Value {
    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", id);
    try obj.put("result", result);
    return .{ .object = obj };
}

fn makeError(allocator: std.mem.Allocator, id: json.Value, code: i64, message: []const u8) !json.Value {
    var err_obj = json.ObjectMap.init(allocator);
    try err_obj.put("code", .{ .integer = code });
    try err_obj.put("message", .{ .string = message });

    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", id);
    try obj.put("error", .{ .object = err_obj });
    return .{ .object = obj };
}

fn toolResult(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });

    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    return .{ .object = result };
}

fn toolError(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });

    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    try result.put("isError", .{ .bool = true });
    return .{ .object = result };
}

// ============================================================================
// Tool Handlers
// ============================================================================

fn handleEval(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const code_val = args.get("code") orelse return toolError(allocator, "missing 'code'");
    const code = switch (code_val) {
        .string => |s| s,
        else => return toolError(allocator, "'code' must be string"),
    };

    const result_str = try rep(allocator, code);
    const h = hashString(result_str);
    const trit = tritFromHash(h);
    const rgb = colorFromHash(h);
    const hex = hexColor(rgb);

    const text = try std.fmt.allocPrint(allocator,
        \\{{"result":"{s}","trit":{d},"color":"{s}"}}
    , .{ result_str, trit, hex[0..] });

    return toolResult(allocator, text);
}

fn handleColorAt(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const seed: u64 = if (args.get("seed")) |s| switch (s) {
        .integer => |i| @intCast(i),
        else => 1069,
    } else 1069;

    const index_val = args.get("index") orelse return toolError(allocator, "missing 'index'");
    const index: u64 = switch (index_val) {
        .integer => |i| @intCast(i),
        else => return toolError(allocator, "'index' must be integer"),
    };

    const rgb = gayColorAt(seed, index);
    const hex = hexColor(rgb);
    const trit = tritFromHash(splitMix64(seed +% index));

    const text = try std.fmt.allocPrint(allocator,
        \\{{"hex":"{s}","r":{d},"g":{d},"b":{d},"trit":{d}}}
    , .{ hex[0..], rgb[0], rgb[1], rgb[2], trit });

    return toolResult(allocator, text);
}

fn handleBciRead(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const channels: u32 = if (args.get("channels")) |c| switch (c) {
        .integer => |i| @intCast(i),
        else => 8,
    } else 8;

    const ch_count = @min(channels, 64);

    // Synthetic BCI: SplitMix64 deterministic per-call, seeded from GC state
    var seed: u64 = 1069;
    if (nanoclj_initialized) {
        seed +%= global_gc.objects.items.len;
    }

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("{\"channels\":[");

    var entropy_sum: f64 = 0.0;
    for (0..ch_count) |i| {
        seed = splitMix64(seed +% @as(u64, @intCast(i)));
        // Map to [-1.0, 1.0] range (microvolts normalized)
        const fval: f64 = @as(f64, @floatFromInt(@as(i64, @bitCast(seed)))) / @as(f64, @floatFromInt(@as(i64, std.math.maxInt(i64))));
        if (i > 0) try w.writeAll(",");
        try w.print("{d:.6}", .{fval});
        entropy_sum += @abs(fval);
    }

    const trit = tritFromHash(seed);
    const entropy = entropy_sum / @as(f64, @floatFromInt(ch_count));

    try w.print("],\"trit\":{d},\"entropy\":{d:.6}}}", .{ trit, entropy });

    const text = try allocator.dupe(u8, fbs.getWritten());
    return toolResult(allocator, text);
}

fn handleSubstrate(allocator: std.mem.Allocator) !json.Value {
    const gc_count: u64 = if (nanoclj_initialized) global_gc.objects.items.len else 0;

    const text = try std.fmt.allocPrint(allocator,
        \\{{"runtime":"nanoclj-zig","gc_objects":{d},"builtins":{d}}}
    , .{ gc_count, BUILTIN_COUNT });

    return toolResult(allocator, text);
}

fn handleHttpFetch(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const url_val = args.get("url") orelse return toolError(allocator, "missing 'url'");
    const url = switch (url_val) {
        .string => |s| s,
        else => return toolError(allocator, "'url' must be string"),
    };
    // Build Clojure expression and eval it
    const method_str = if (args.get("method")) |m| switch (m) {
        .string => |s| s,
        else => "get",
    } else "get";
    const body_str = if (args.get("body")) |b| switch (b) {
        .string => |s| s,
        else => null,
    } else null;

    // Construct and eval: (http-fetch "url") or (http-fetch "url" :method) or (http-fetch "url" :method "body")
    var expr_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&expr_buf);
    const w = fbs.writer();
    if (body_str) |body| {
        try w.print("(http-fetch \"{s}\" :{s} \"{s}\")", .{ url, method_str, body });
    } else {
        try w.print("(http-fetch \"{s}\" :{s})", .{ url, method_str });
    }
    const expr = fbs.getWritten();
    const result_str = try rep(allocator, expr);
    return toolResult(allocator, result_str);
}

fn handleTraverse(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const target_val = args.get("target") orelse return toolError(allocator, "missing 'target'");
    const target = switch (target_val) {
        .string => |s| s,
        else => return toolError(allocator, "'target' must be string"),
    };

    const text = try std.fmt.allocPrint(allocator,
        \\{{"status":"traversal_ready","from":"nanoclj-zig","to":"{s}"}}
    , .{target});

    return toolResult(allocator, text);
}

// ============================================================================
// MCP Dispatch
// ============================================================================

fn handleToolsListResult(allocator: std.mem.Allocator) !json.Value {
    var tool_array = json.Array.init(allocator);
    for (tools) |tool| {
        var tool_obj = json.ObjectMap.init(allocator);
        try tool_obj.put("name", .{ .string = tool.name });
        try tool_obj.put("description", .{ .string = tool.description });

        const schema = try json.parseFromSlice(json.Value, allocator, tool.input_schema, .{
            .allocate = .alloc_always,
        });
        try tool_obj.put("inputSchema", schema.value);

        try tool_array.append(.{ .object = tool_obj });
    }

    var result = json.ObjectMap.init(allocator);
    try result.put("tools", .{ .array = tool_array });
    return .{ .object = result };
}

fn handleCallTool(allocator: std.mem.Allocator, params: json.ObjectMap) !json.Value {
    const name_val = params.get("name") orelse return toolError(allocator, "missing tool name");
    const name = switch (name_val) {
        .string => |s| s,
        else => return toolError(allocator, "tool name must be string"),
    };

    const arguments = if (params.get("arguments")) |a| switch (a) {
        .object => |o| o,
        else => json.ObjectMap.init(allocator),
    } else json.ObjectMap.init(allocator);

    if (std.mem.eql(u8, name, "nanoclj_eval")) {
        return handleEval(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nanoclj_color_at")) {
        return handleColorAt(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nanoclj_bci_read")) {
        return handleBciRead(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nanoclj_substrate")) {
        return handleSubstrate(allocator);
    } else if (std.mem.eql(u8, name, "nanoclj_traverse")) {
        return handleTraverse(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nanoclj_http_fetch")) {
        return handleHttpFetch(allocator, arguments);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "Unknown tool '{s}'", .{name});
        return toolError(allocator, msg);
    }
}

fn handleInitialize(allocator: std.mem.Allocator) !json.Value {
    var server_info = json.ObjectMap.init(allocator);
    try server_info.put("name", .{ .string = SERVER_NAME });
    try server_info.put("version", .{ .string = SERVER_VERSION });

    var capabilities = json.ObjectMap.init(allocator);
    const tools_cap = json.ObjectMap.init(allocator);
    try capabilities.put("tools", .{ .object = tools_cap });

    var result = json.ObjectMap.init(allocator);
    try result.put("protocolVersion", .{ .string = PROTOCOL_VERSION });
    try result.put("capabilities", .{ .object = capabilities });
    try result.put("serverInfo", .{ .object = server_info });
    return .{ .object = result };
}

fn handleMethod(allocator: std.mem.Allocator, method: []const u8, obj: json.ObjectMap) !json.Value {
    if (std.mem.eql(u8, method, "initialize")) {
        return handleInitialize(allocator);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        return .null;
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return handleToolsListResult(allocator);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = if (obj.get("params")) |p| switch (p) {
            .object => |o| o,
            else => json.ObjectMap.init(allocator),
        } else json.ObjectMap.init(allocator);
        return handleCallTool(allocator, params);
    } else {
        var err_obj = json.ObjectMap.init(allocator);
        try err_obj.put("code", .{ .integer = -32601 });
        try err_obj.put("message", .{ .string = "Method not found" });
        return .{ .object = err_obj };
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    const reader = stdin_file.deprecatedReader();
    var stdout = stdout_file.deprecatedWriter();

    var line_buf: [MAX_LINE_SIZE]u8 = undefined;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch return
            orelse return;

        if (line.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const parsed = json.parseFromSlice(json.Value, arena_alloc, line, .{
            .allocate = .alloc_always,
        }) catch {
            const err_resp = try makeError(arena_alloc, .null, -32700, "Parse error");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        };

        if (parsed.value != .object) {
            const err_resp = try makeError(arena_alloc, .null, -32600, "Invalid Request");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        }

        const obj = parsed.value.object;
        const id = obj.get("id") orelse .null;
        const method_val = obj.get("method") orelse {
            const err_resp = try makeError(arena_alloc, id, -32600, "Missing method");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => {
                const err_resp = try makeError(arena_alloc, id, -32600, "Method must be string");
                try writeJsonLine(&stdout, err_resp, arena_alloc);
                continue;
            },
        };

        // notifications don't get responses
        if (std.mem.eql(u8, method, "notifications/initialized")) {
            continue;
        }

        const result = try handleMethod(arena_alloc, method, obj);
        const response = try makeResponse(arena_alloc, id, result);
        try writeJsonLine(&stdout, response, arena_alloc);
    }
}
