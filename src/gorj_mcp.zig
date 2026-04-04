//! gorj_mcp: Self-hosting MCP server for gorj
//!
//! Unlike mcp_tool.zig (hardcoded Zig handlers), this server bootstraps
//! its tool definitions from nanoclj Clojure forms. Each MCP tool is a
//! (def gorj-tool-<name> (fn* [args-map] ...)) that gets compiled to
//! bytecode and dispatched through the nanoclj runtime.
//!
//! Self-hosting closure: the MCP server is *written in the language it serves*.
//! The Zig layer is only the JSON-RPC envelope + stdio transport.
//!
//! Tool dispatch:
//!   tools/call {name: "gorj_eval", arguments: {code: "(+ 1 2)"}}
//!   → (gorj-mcp-dispatch "gorj_eval" {:code "(+ 1 2)"})
//!   → nanoclj eval → result → JSON-RPC response
//!
//! The prelude defines: gorj_eval, gorj_pipe, gorj_encode, gorj_decode,
//! gorj_version, gorj_tools, gorj_trit_tick, gorj_color, gorj_substrate,
//! gorj_compile (bytecode compile + execute).

const std = @import("std");
const compat = @import("compat.zig");
const json = std.json;
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const bc = @import("bytecode.zig");
const Compiler = @import("compiler.zig").Compiler;

const SERVER_NAME = "gorj-zig";
const SERVER_VERSION = "0.1.0";
const PROTOCOL_VERSION = "2024-11-05";
const MAX_LINE_SIZE = 4 * 1024 * 1024;

// ============================================================================
// NANOCLJ RUNTIME (persistent across MCP calls)
// ============================================================================

var global_gc: GC = undefined;
var global_env: Env = undefined;
var global_vm: bc.VM = undefined;
var nanoclj_initialized = false;

fn initRuntime(allocator: std.mem.Allocator) !void {
    if (nanoclj_initialized) return;
    global_gc = GC.init(allocator);
    global_env = Env.init(allocator, null);
    global_env.is_root = true;
    try core.initCore(&global_env, &global_gc);
    global_vm = bc.VM.init(&global_gc, 100_000_000);
    nanoclj_initialized = true;

    // Bootstrap: evaluate the self-hosting prelude
    try evalPrelude(allocator);
}

// ============================================================================
// SELF-HOSTING PRELUDE
//
// These nanoclj forms define the MCP tool handlers. They use the gorj-bridge
// builtins (gorj-pipe, gorj-eval, etc.) but wrap them in the MCP tool
// contract: take a map of arguments, return a string result.
//
// The closure: gorj-bridge builtins are Zig. The MCP dispatch is nanoclj.
// The Zig only does JSON-RPC framing. nanoclj does all tool logic.
// ============================================================================

const prelude_forms = [_][]const u8{
    // gorj_eval: evaluate Clojure code via the fused gorj pipeline
    \\(def gorj-mcp-eval
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (gorj-eval code)]
    \\      (pr-str result))))
    ,
    // gorj_pipe: minimal [result vid trit] vector output
    \\(def gorj-mcp-pipe
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (gorj-pipe code)]
    \\      (pr-str result))))
    ,
    // gorj_encode: value → Syrup bytes
    \\(def gorj-mcp-encode
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           val (read-string code)
    \\           encoded (gorj-encode val)]
    \\      (pr-str {:syrup-bytes (count encoded)}))))
    ,
    // gorj_decode: Syrup bytes → value
    \\(def gorj-mcp-decode
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           decoded (gorj-decode code)]
    \\      (pr-str decoded))))
    ,
    // gorj_version: current version frontier
    \\(def gorj-mcp-version
    \\  (fn* [args]
    \\    (pr-str {:version (gorj-version)})))
    ,
    // gorj_tools: list gorj's 29 MCP tool names
    \\(def gorj-mcp-tools
    \\  (fn* [args]
    \\    (pr-str (gorj-tools))))
    ,
    // gorj_trit_tick: generate trit-ticks from seed
    \\(def gorj-mcp-trit-tick
    \\  (fn* [args]
    \\    (let* [n (or (get args "count") 12)
    \\           seed (or (get args "seed") 1069)
    \\           ticks (map (fn* [i] (let* [c (color-at seed i)]
    \\                                 {:index i :hex (get c :hex) :trit (get c :trit)}))
    \\                      (range n))]
    \\      (pr-str {:ticks ticks :count n :seed seed}))))
    ,
    // gorj_color: get gay color at seed+index
    \\(def gorj-mcp-color
    \\  (fn* [args]
    \\    (let* [seed (or (get args "seed") 1069)
    \\           index (or (get args "index") 0)
    \\           c (color-at seed index)]
    \\      (pr-str c))))
    ,
    // gorj_substrate: runtime info
    \\(def gorj-mcp-substrate
    \\  (fn* [args]
    \\    (pr-str {:runtime "nanoclj-zig"
    \\             :server "gorj-zig"
    \\             :self-hosted true
    \\             :bytecode-vm true})))
    ,
    // gorj_compile: compile expression to bytecode and execute via VM
    \\(def gorj-mcp-compile
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (gorj-pipe code)]
    \\      (pr-str {:compiled true :result (first result) :version-id (nth result 1) :trit (nth result 2)}))))
    ,
    // gorj_spacetime: information spacetime metrics
    \\(def gorj-mcp-spacetime
    \\  (fn* [args]
    \\    (let* [distance (or (get args "distance") 0)
    \\           budget (or (get args "budget") 1)
    \\           branching (or (get args "branching") 3)
    \\           depth (or (get args "depth") 3)
    \\           sep (separation distance budget)
    \\           vol (cone-volume branching depth)
    \\           cones (padic-cones depth)]
    \\      (pr-str {:separation sep
    \\               :cone-volume vol
    \\               :padic-cones cones
    \\               :branching branching
    \\               :depth depth}))))
    ,
    // MCP dispatch table: tool name → handler function symbol
    \\(def gorj-mcp-dispatch-table
    \\  {"gorj_eval" gorj-mcp-eval
    \\   "gorj_pipe" gorj-mcp-pipe
    \\   "gorj_encode" gorj-mcp-encode
    \\   "gorj_decode" gorj-mcp-decode
    \\   "gorj_version" gorj-mcp-version
    \\   "gorj_tools" gorj-mcp-tools
    \\   "gorj_trit_tick" gorj-mcp-trit-tick
    \\   "gorj_color" gorj-mcp-color
    \\   "gorj_substrate" gorj-mcp-substrate
    \\   "gorj_compile" gorj-mcp-compile
    \\   "gorj_spacetime" gorj-mcp-spacetime})
    ,
    // The dispatch function itself — self-hosted MCP routing
    \\(def gorj-mcp-dispatch
    \\  (fn* [tool-name args-map]
    \\    (let* [handler (get gorj-mcp-dispatch-table tool-name)]
    \\      (if handler
    \\        (handler args-map)
    \\        (pr-str {:error (str "unknown tool: " tool-name)})))))
    ,
};

fn evalPrelude(allocator: std.mem.Allocator) !void {
    _ = allocator;
    for (prelude_forms) |form_src| {
        var reader = Reader.init(form_src, &global_gc);
        const form = reader.readForm() catch continue;
        var res = semantics.Resources.initDefault();
        _ = semantics.evalBounded(form, &global_env, &global_gc, &res);
    }
}

// ============================================================================
// SELF-HOSTED TOOL DISPATCH
//
// Instead of a Zig switch on tool name, we call into nanoclj:
//   (gorj-mcp-dispatch "tool_name" {"arg1" "val1" ...})
// ============================================================================

fn dispatchTool(allocator: std.mem.Allocator, tool_name: []const u8, arguments: json.ObjectMap) ![]const u8 {
    try initRuntime(allocator);

    // Build nanoclj map from JSON arguments
    const args_obj = try global_gc.allocObj(.map);
    var iter = arguments.iterator();
    while (iter.next()) |entry| {
        const key_id = try global_gc.internString(entry.key_ptr.*);
        const val = switch (entry.value_ptr.*) {
            .string => |s| Value.makeString(try global_gc.internString(s)),
            .integer => |i| Value.makeInt(@intCast(@min(i, std.math.maxInt(i48)))),
            .float => |f| Value.makeFloat(f),
            .bool => |b| Value.makeBool(b),
            .null => Value.makeNil(),
            else => Value.makeNil(),
        };
        try args_obj.data.map.keys.append(global_gc.allocator, Value.makeString(key_id));
        try args_obj.data.map.vals.append(global_gc.allocator, val);
    }

    // Look up gorj-mcp-dispatch in the environment
    const dispatch_name = "gorj-mcp-dispatch";
    const dispatch_sym = global_env.get(dispatch_name) orelse {
        return "Error: gorj-mcp-dispatch not found (prelude failed)";
    };

    // Call: (gorj-mcp-dispatch "tool_name" args-map)
    const tool_name_val = Value.makeString(try global_gc.internString(tool_name));
    const args_val = Value.makeObj(args_obj);

    // Use builtin sentinel check for dispatch function
    if (core.isBuiltinSentinel(dispatch_sym, &global_gc)) |name| {
        if (core.lookupBuiltin(name)) |builtin| {
            var call_args = [_]Value{ tool_name_val, args_val };
            const result = builtin(&call_args, &global_gc, &global_env) catch {
                return "Error: dispatch builtin call failed";
            };
            return printer.prStr(result, &global_gc, false) catch "Error: print failed";
        }
    }

    // dispatch_sym is a user-defined function (from prelude def)
    var call_args = [_]Value{ tool_name_val, args_val };
    const result = eval_mod.apply(dispatch_sym, &call_args, &global_env, &global_gc) catch {
        return "Error: dispatch apply failed";
    };
    return printer.prStr(result, &global_gc, false) catch "Error: print failed";
}

// ============================================================================
// MCP TOOL DEFINITIONS (metadata only — handlers are in nanoclj prelude)
// ============================================================================

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const tool_defs = [_]ToolDef{
    .{
        .name = "gorj_eval",
        .description = "Evaluate Clojure in gorj (self-hosted nanoclj-zig). Persistent state, GF(3) trit tracking, Braid versioning.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression"}},"required":["code"]}
    },
    .{
        .name = "gorj_pipe",
        .description = "Fused eval pipeline: expr → [result version-id trit]. Minimal allocation, no map overhead.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression"}},"required":["code"]}
    },
    .{
        .name = "gorj_encode",
        .description = "Encode nanoclj value as raw Syrup bytes (no hex roundtrip).",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to encode"}},"required":["code"]}
    },
    .{
        .name = "gorj_decode",
        .description = "Decode raw Syrup bytes back to nanoclj value.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Syrup byte string"}},"required":["code"]}
    },
    .{
        .name = "gorj_version",
        .description = "Current Braid version frontier (SplitMix64 chain, monotonic).",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_tools",
        .description = "List gorj's 29 Clojure MCP tool names (for cross-bridge discovery).",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_trit_tick",
        .description = "Generate trit-ticks from seed using golden angle spiral. Returns trit+color per tick.",
        .input_schema =
        \\{"type":"object","properties":{"count":{"type":"integer","default":12,"description":"Number of ticks"},"seed":{"type":"integer","default":1069,"description":"SplitMix64 seed"}},"required":[]}
    },
    .{
        .name = "gorj_color",
        .description = "Get Gay color at seed+index (golden angle spiral, HSV→RGB, SplitMix64).",
        .input_schema =
        \\{"type":"object","properties":{"seed":{"type":"integer","default":1069},"index":{"type":"integer","default":0}},"required":[]}
    },
    .{
        .name = "gorj_substrate",
        .description = "Runtime substrate info: self-hosted gorj-zig with bytecode VM.",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_compile",
        .description = "Compile expression to bytecode and execute via register VM. Returns result + version + trit.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to compile"}},"required":["code"]}
    },
    .{
        .name = "gorj_spacetime",
        .description = "Information spacetime metrics. Classifies separation (timelike/lightlike/spacelike), computes light cone volumes at each p-adic prime [2,3,5,7,1069]. Matter=density, energy=exchange rate, c=info speed limit.",
        .input_schema =
        \\{"type":"object","properties":{"distance":{"type":"integer","default":0,"description":"Graph distance between nodes"},"budget":{"type":"integer","default":1,"description":"Trit-tick budget (light cone radius)"},"branching":{"type":"integer","default":3,"description":"Graph branching factor"},"depth":{"type":"integer","default":3,"description":"Cone depth to compute"}},"required":[]}
    },
};

// ============================================================================
// JSON-RPC FRAMING (minimal Zig — all tool logic is in nanoclj)
// ============================================================================

fn readLineFromStdin(buf: []u8) ?[]u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = compat.stdinRead(&byte);
        if (n == 0) {
            if (pos == 0) return null;
            return buf[0..pos];
        }
        if (byte[0] == '\n') return buf[0..pos];
        buf[pos] = byte[0];
        pos += 1;
    }
    return buf[0..pos];
}

const CompatWriter = struct {
    pub fn writeAll(_: *CompatWriter, bytes: []const u8) !void {
        compat.stdoutWrite(bytes);
    }
};

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
// MCP PROTOCOL HANDLERS
// ============================================================================

fn handleInitialize(allocator: std.mem.Allocator) !json.Value {
    var server_info = json.ObjectMap.init(allocator);
    try server_info.put("name", .{ .string = SERVER_NAME });
    try server_info.put("version", .{ .string = SERVER_VERSION });
    var capabilities = json.ObjectMap.init(allocator);
    try capabilities.put("tools", .{ .object = json.ObjectMap.init(allocator) });
    var result = json.ObjectMap.init(allocator);
    try result.put("protocolVersion", .{ .string = PROTOCOL_VERSION });
    try result.put("capabilities", .{ .object = capabilities });
    try result.put("serverInfo", .{ .object = server_info });
    return .{ .object = result };
}

fn handleToolsList(allocator: std.mem.Allocator) !json.Value {
    var tool_array = json.Array.init(allocator);
    for (tool_defs) |tool| {
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

    // Self-hosted dispatch: call into nanoclj runtime
    const result_text = dispatchTool(allocator, name, arguments) catch {
        return toolError(allocator, "dispatch error");
    };

    return toolResult(allocator, result_text);
}

fn handleMethod(allocator: std.mem.Allocator, method: []const u8, obj: json.ObjectMap) !json.Value {
    if (std.mem.eql(u8, method, "initialize")) {
        return handleInitialize(allocator);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        return .null;
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return handleToolsList(allocator);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = if (obj.get("params")) |p| switch (p) {
            .object => |o| o,
            else => json.ObjectMap.init(allocator),
        } else json.ObjectMap.init(allocator);
        return handleCallTool(allocator, params);
    } else {
        return makeError(allocator, .null, -32601, "Method not found");
    }
}

// ============================================================================
// MAIN: stdio JSON-RPC loop — the only Zig in the critical path
// ============================================================================

pub fn main() !void {
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try initRuntime(allocator);

    var stdout = CompatWriter{};
    var line_buf: [MAX_LINE_SIZE]u8 = undefined;

    while (true) {
        const line = readLineFromStdin(&line_buf) orelse return;
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

        if (std.mem.eql(u8, method, "notifications/initialized")) continue;

        const result = try handleMethod(arena_alloc, method, obj);
        const response = try makeResponse(arena_alloc, id, result);
        try writeJsonLine(&stdout, response, arena_alloc);
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "gorj_mcp: prelude bootstraps and dispatch table is populated" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    // Evaluate prelude
    for (prelude_forms) |form_src| {
        var reader = Reader.init(form_src, &gc);
        const form = reader.readForm() catch continue;
        var res = semantics.Resources.initDefault();
        _ = semantics.evalBounded(form, &env, &gc, &res);
    }

    // gorj-mcp-dispatch-table should exist
    const table_val = env.get("gorj-mcp-dispatch-table");
    try std.testing.expect(table_val != null);
    try std.testing.expect(table_val.?.isObj());

    // gorj-mcp-dispatch should exist
    const dispatch_val = env.get("gorj-mcp-dispatch");
    try std.testing.expect(dispatch_val != null);
}

test "gorj_mcp: self-hosted eval dispatch roundtrip" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    for (prelude_forms) |form_src| {
        var reader = Reader.init(form_src, &gc);
        const form = reader.readForm() catch continue;
        var res = semantics.Resources.initDefault();
        _ = semantics.evalBounded(form, &env, &gc, &res);
    }

    // Call gorj-mcp-substrate with empty args
    const dispatch_val = env.get("gorj-mcp-substrate") orelse return error.SkipZigTest;
    var empty_map = try gc.allocObj(.map);
    _ = &empty_map;
    var call_args = [_]Value{Value.makeObj(empty_map)};
    const result = eval_mod.apply(dispatch_val, &call_args, &env, &gc) catch return;
    // Should return a string (pr-str output)
    try std.testing.expect(result.isString());
    const s = gc.getString(result.asStringId());
    try std.testing.expect(s.len > 0);
}
