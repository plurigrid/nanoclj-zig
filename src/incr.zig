//! INCR: Incremental compilation bridge for nanoclj-zig
//!
//! This module implements the "third tier" of execution: Clojure expressions
//! compiled to Zig source, incrementally compiled by the Zig 0.16 compiler
//! via --watch -fincremental, and hot-swapped into the running process.
//!
//! The three tiers:
//!   red   = Zig-native bytecode VM (22 opcodes, fuel-bounded)
//!   blue  = tree-walk interpreter (eval.zig, dynamic eval/macros)
//!   green = incremental AOT via Zig compiler (this module)
//!
//! Architecture (from lobste.rs/Zig research):
//!   - Zig 0.16 incremental compilation works at decl-level granularity
//!   - Each top-level fn maps to a symbol, updated via GOT
//!   - --watch + -fincremental keeps the compiler alive, 50ms debounce
//!   - In-place binary patching: no dylib reload, no process restart
//!   - Jamie Brandon's pattern: arena allocator + fuel budget for live REPLs
//!
//! The flow:
//!   1. User types (incr (fn [x] (* x x)))
//!   2. nanoclj-zig transpiles to Zig source in .incr/gen_<hash>.zig
//!   3. Zig 0.16 incrementally compiles just that decl
//!   4. The compiled function is callable from the bytecode VM via @extern
//!
//! This is the Scala Native lesson: most code is red (AOT). Only eval
//! and macros need blue (JIT). Green is red that recompiles in milliseconds.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const compat = @import("compat.zig");

/// A generated Zig function stub that can be called from the VM.
pub const IncrFunc = struct {
    name: []const u8,
    arity: u8,
    /// Hash of the source expression — used for dedup/caching
    source_hash: u64,
    /// Path to the generated .zig file
    gen_path: []const u8,
    /// Whether the function has been compiled and is ready
    ready: bool,
};

/// Registry of incrementally compiled functions.
pub const IncrRegistry = struct {
    funcs: std.StringHashMap(IncrFunc),
    gen_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IncrRegistry {
        return .{
            .funcs = std.StringHashMap(IncrFunc).init(allocator),
            .gen_dir = ".incr",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IncrRegistry) void {
        self.funcs.deinit();
    }

    /// Check if a function exists and is ready for calling
    pub fn isReady(self: *const IncrRegistry, name: []const u8) bool {
        if (self.funcs.get(name)) |f| return f.ready;
        return false;
    }

    /// Mark a function as compiled and ready
    pub fn markReady(self: *IncrRegistry, name: []const u8) void {
        if (self.funcs.getPtr(name)) |f| f.ready = true;
    }

    /// List all registered functions
    pub fn list(self: *const IncrRegistry) []const u8 {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const header = "Incremental functions:\n";
        @memcpy(buf[pos..][0..header.len], header);
        pos += header.len;

        var it = self.funcs.iterator();
        while (it.next()) |entry| {
            const f = entry.value_ptr;
            const status_str = if (f.ready) "READY" else "PENDING";
            const line = std.fmt.bufPrint(buf[pos..], "  {s} (arity {d}) {s} [{s}]\n", .{
                f.name,
                f.arity,
                status_str,
                f.gen_path,
            }) catch break;
            pos += line.len;
        }
        return self.allocator.dupe(u8, buf[0..pos]) catch "Error: alloc failed";
    }
};

/// Transpile a simple arithmetic Clojure expression to Zig.
/// Handles: (+ a b), (* a b), (- a b), (/ a b), nested.
/// This is the "red" subset — expressions that need no runtime dispatch.
pub fn transpileArith(expr: Value, gc: *GC, buf: []u8, pos: *usize, params: []const []const u8) !void {
    if (expr.isInt()) {
        const s = std.fmt.bufPrint(buf[pos.*..], "{d}", .{expr.asInt()}) catch return error.NotTranspilable;
        pos.* += s.len;
        return;
    }
    if (expr.isSymbol()) {
        const sym = gc.getString(expr.asSymbolId());
        for (params) |p| {
            if (std.mem.eql(u8, sym, p)) {
                if (pos.* + sym.len > buf.len) return error.NotTranspilable;
                @memcpy(buf[pos.*..][0..sym.len], sym);
                pos.* += sym.len;
                return;
            }
        }
        if (pos.* + sym.len > buf.len) return error.NotTranspilable;
        @memcpy(buf[pos.*..][0..sym.len], sym);
        pos.* += sym.len;
        return;
    }
    if (!expr.isObj()) return error.NotTranspilable;
    const obj = expr.asObj();
    if (obj.kind != .list) return error.NotTranspilable;

    const items = obj.data.list.items.items;
    if (items.len < 2) return error.NotTranspilable;

    const head = items[0];
    if (!head.isSymbol()) return error.NotTranspilable;
    const op_name = gc.getString(head.asSymbolId());

    if (items.len == 3) {
        if (std.mem.eql(u8, op_name, "/")) {
            const prefix = "@divTrunc(";
            if (pos.* + prefix.len > buf.len) return error.NotTranspilable;
            @memcpy(buf[pos.*..][0..prefix.len], prefix);
            pos.* += prefix.len;
            try transpileArith(items[1], gc, buf, pos, params);
            if (pos.* + 2 > buf.len) return error.NotTranspilable;
            @memcpy(buf[pos.*..][0..2], ", ");
            pos.* += 2;
            try transpileArith(items[2], gc, buf, pos, params);
            if (pos.* + 1 > buf.len) return error.NotTranspilable;
            buf[pos.*] = ')';
            pos.* += 1;
        } else {
            const zig_op: []const u8 = if (std.mem.eql(u8, op_name, "+"))
                "+%"
            else if (std.mem.eql(u8, op_name, "-"))
                "-%"
            else if (std.mem.eql(u8, op_name, "*"))
                "*%"
            else
                return error.NotTranspilable;

            if (pos.* + 1 > buf.len) return error.NotTranspilable;
            buf[pos.*] = '(';
            pos.* += 1;
            try transpileArith(items[1], gc, buf, pos, params);
            const op_s = std.fmt.bufPrint(buf[pos.*..], " {s} ", .{zig_op}) catch return error.NotTranspilable;
            pos.* += op_s.len;
            try transpileArith(items[2], gc, buf, pos, params);
            if (pos.* + 1 > buf.len) return error.NotTranspilable;
            buf[pos.*] = ')';
            pos.* += 1;
        }
        return;
    }

    // Unary minus
    if (items.len == 2 and std.mem.eql(u8, op_name, "-")) {
        const prefix = "(-%";
        if (pos.* + prefix.len > buf.len) return error.NotTranspilable;
        @memcpy(buf[pos.*..][0..prefix.len], prefix);
        pos.* += prefix.len;
        try transpileArith(items[1], gc, buf, pos, params);
        if (pos.* + 1 > buf.len) return error.NotTranspilable;
        buf[pos.*] = ')';
        pos.* += 1;
        return;
    }

    return error.NotTranspilable;
}

/// Full pipeline: parse a (defn name [params] body) form,
/// transpile body to Zig, write .zig file, return status message.
pub fn transpileDefn(
    input: []const u8,
    gc: *GC,
    registry: *IncrRegistry,
) ![]const u8 {
    var reader = Reader.init(input, gc);
    const form = try reader.readForm();

    if (!form.isObj()) return error.NotTranspilable;
    const obj = form.asObj();
    if (obj.kind != .list) return error.NotTranspilable;
    const items = obj.data.list.items.items;
    if (items.len < 4) return error.NotTranspilable;

    const head = items[0];
    if (!head.isSymbol()) return error.NotTranspilable;
    if (!std.mem.eql(u8, gc.getString(head.asSymbolId()), "defn")) return error.NotTranspilable;

    if (!items[1].isSymbol()) return error.NotTranspilable;
    const fn_name = gc.getString(items[1].asSymbolId());

    if (!items[2].isObj()) return error.NotTranspilable;
    const param_obj = items[2].asObj();
    if (param_obj.kind != .vector) return error.NotTranspilable;
    const param_vals = param_obj.data.vector.items.items;

    var param_names: [16][]const u8 = undefined;
    for (param_vals, 0..) |pv, i| {
        if (i >= 16) return error.NotTranspilable;
        if (!pv.isSymbol()) return error.NotTranspilable;
        param_names[i] = gc.getString(pv.asSymbolId());
    }
    const params = param_names[0..param_vals.len];

    const body = items[3];

    // Generate Zig source into a stack buffer
    var src_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Header
    const hdr = std.fmt.bufPrint(&src_buf, "// Generated by nanoclj-zig incr transpiler\n// Source: {s}\n\npub export fn ncz_{s}(", .{ input, fn_name }) catch return error.NotTranspilable;
    pos = hdr.len;

    for (params, 0..) |p, i| {
        if (i > 0) {
            const comma = std.fmt.bufPrint(src_buf[pos..], ", ", .{}) catch return error.NotTranspilable;
            pos += comma.len;
        }
        const arg = std.fmt.bufPrint(src_buf[pos..], "{s}: i64", .{p}) catch return error.NotTranspilable;
        pos += arg.len;
    }
    const ret_hdr = ") i64 {\n    return ";
    @memcpy(src_buf[pos..][0..ret_hdr.len], ret_hdr);
    pos += ret_hdr.len;

    try transpileArith(body, gc, &src_buf, &pos, params);

    const footer = ";\n}\n";
    @memcpy(src_buf[pos..][0..footer.len], footer);
    pos += footer.len;

    // Write file — use C stdlib for 0.16 compat (std.fs.cwd() removed)
    {
        var dir_buf: [256]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{registry.gen_dir}) catch return error.NotTranspilable;
        _ = std.c.mkdir(dir_z, 0o755);
    }

    var path_buf: [256]u8 = undefined;
    const gen_path = std.fmt.bufPrint(&path_buf, "{s}/ncz_{s}.zig", .{ registry.gen_dir, fn_name }) catch return error.NotTranspilable;

    // Write via POSIX open/write/close
    {
        var path_z_buf: [256]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{gen_path}) catch return error.NotTranspilable;
        const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.NotTranspilable;
        defer _ = std.c.close(fd);
        const data = src_buf[0..pos];
        var written: usize = 0;
        while (written < data.len) {
            const rc = std.c.write(fd, data.ptr + written, data.len - written);
            if (rc <= 0) return error.NotTranspilable;
            written += @intCast(rc);
        }
    }

    // Register
    const func = IncrFunc{
        .name = try registry.allocator.dupe(u8, fn_name),
        .arity = @intCast(params.len),
        .source_hash = std.hash.Wyhash.hash(0, input),
        .gen_path = try registry.allocator.dupe(u8, gen_path),
        .ready = false,
    };
    try registry.funcs.put(func.name, func);

    // Return status
    var status_buf: [512]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "Transpiled {s} -> {s}\n  arity: {d}, body: {d} bytes Zig source\n  Compile: zig build-lib {s} -fincremental\n  Or add to build.zig for --watch integration", .{ fn_name, gen_path, params.len, pos, gen_path }) catch return error.NotTranspilable;

    return try registry.allocator.dupe(u8, status);
}

/// REPL command handler for (incr ...) forms
pub fn handleIncrCommand(line: []const u8, gc: *GC, registry: *IncrRegistry) []const u8 {
    if (std.mem.eql(u8, line, "(incr-list)")) {
        return registry.list();
    }

    // (incr (defn name [params] body))
    if (std.mem.startsWith(u8, line, "(incr ") and line[line.len - 1] == ')') {
        const inner = line[6 .. line.len - 1];
        return transpileDefn(inner, gc, registry) catch |err| switch (err) {
            error.NotTranspilable => "Error: expression not transpilable to Zig (only arithmetic on i64 supported)",
            else => "Error: transpilation failed",
        };
    }

    return "Error: unknown incr command. Try (incr (defn name [params] body)) or (incr-list)";
}

// ── Tests ─────────────────────────────────────────────────────────

test "transpileArith basic" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var reader = Reader.init("(+ x (* y 2))", &gc);
    const form = try reader.readForm();

    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    const params = [_][]const u8{ "x", "y" };
    try transpileArith(form, &gc, &buf, &pos, &params);

    try std.testing.expectEqualStrings("(x +% (y *% 2))", buf[0..pos]);
}
