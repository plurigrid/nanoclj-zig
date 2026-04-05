//! Source location tracking for nanoclj-zig
//!
//! Attaches {:line N :col M :file "..."} metadata to forms during read.
//! Provides stack frame tracking during eval for error traces.
//!
//! Design: source locations are metadata maps on Obj values. The reader
//! sets them; the evaluator reads them to build stack traces on error.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const compat = @import("compat.zig");

/// Compact source location: 4 bytes line + 2 bytes col + string ID for file.
/// Stored as metadata map on forms (lists, symbols in function position).
pub const SourceLoc = struct {
    line: u32,
    col: u16,
    file_id: u48, // interned string ID

    pub fn toMeta(self: SourceLoc, gc: *GC) !*Obj {
        const m = try gc.allocObj(.map);
        const line_kw = try gc.internString("line");
        const col_kw = try gc.internString("col");
        const file_kw = try gc.internString("file");
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(line_kw));
        try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(self.line)));
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(col_kw));
        try m.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(self.col)));
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(file_kw));
        try m.data.map.vals.append(gc.allocator, Value.makeString(self.file_id));
        return m;
    }
};

/// Call stack frame for error reporting.
pub const StackFrame = struct {
    name: []const u8, // function name or "<anonymous>"
    loc: ?SourceLoc,
};

/// Maximum call stack depth for trace capture.
const MAX_STACK_DEPTH: usize = 64;

/// Thread-local (global in single-threaded nanoclj) call stack.
var call_stack: [MAX_STACK_DEPTH]StackFrame = undefined;
var stack_depth: usize = 0;

pub fn pushFrame(name: []const u8, loc: ?SourceLoc) void {
    if (stack_depth < MAX_STACK_DEPTH) {
        call_stack[stack_depth] = .{ .name = name, .loc = loc };
        stack_depth += 1;
    }
}

pub fn popFrame() void {
    if (stack_depth > 0) stack_depth -= 1;
}

pub fn currentDepth() usize {
    return stack_depth;
}

pub fn resetStack() void {
    stack_depth = 0;
}

/// Extract SourceLoc from an Obj's metadata (if present).
pub fn getLocFromMeta(obj: *Obj, gc: *GC) ?SourceLoc {
    const meta = obj.meta orelse return null;
    if (meta.kind != .map) return null;

    var line: ?u32 = null;
    var col: ?u16 = null;
    var file_id: ?u48 = null;

    for (meta.data.map.keys.items, meta.data.map.vals.items) |k, v| {
        if (!k.isKeyword()) continue;
        const kname = gc.getString(k.asKeywordId());
        if (std.mem.eql(u8, kname, "line") and v.isInt()) {
            line = @intCast(@as(u48, @bitCast(v.asInt())));
        } else if (std.mem.eql(u8, kname, "col") and v.isInt()) {
            col = @intCast(@as(u48, @bitCast(v.asInt())));
        } else if (std.mem.eql(u8, kname, "file") and v.isString()) {
            file_id = v.asStringId();
        }
    }

    if (line) |l| {
        return .{
            .line = l,
            .col = col orelse 0,
            .file_id = file_id orelse 0,
        };
    }
    return null;
}

/// Format a stack trace into a buffer for error reporting.
pub fn formatTrace(gc: *GC, buf: *std.ArrayListUnmanaged(u8)) !void {
    var i: usize = stack_depth;
    while (i > 0) {
        i -= 1;
        const frame = call_stack[i];
        try buf.appendSlice(gc.allocator, "  at ");
        try buf.appendSlice(gc.allocator, frame.name);
        if (frame.loc) |loc| {
            const file = gc.getString(loc.file_id);
            var tmp: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, " ({s}:{d}:{d})", .{ file, loc.line, loc.col }) catch "";
            try buf.appendSlice(gc.allocator, s);
        }
        try buf.append(gc.allocator, '\n');
    }
}

// ============================================================================
// BUILTIN: (stacktrace) — return current call stack as vector of maps
// ============================================================================

pub fn stacktraceFn(args: []Value, gc: *GC, _: @import("env.zig").Env) anyerror!Value {
    _ = args;
    const vec = try gc.allocObj(.vector);
    var i: usize = stack_depth;
    while (i > 0) {
        i -= 1;
        const frame = call_stack[i];
        const m = try gc.allocObj(.map);
        const name_kw = try gc.internString("name");
        const name_str = try gc.internString(frame.name);
        try m.data.map.keys.append(gc.allocator, Value.makeKeyword(name_kw));
        try m.data.map.vals.append(gc.allocator, Value.makeString(name_str));
        if (frame.loc) |loc| {
            const loc_meta = try loc.toMeta(gc);
            const line_kw = try gc.internString("line");
            const col_kw = try gc.internString("col");
            const file_kw = try gc.internString("file");
            for (loc_meta.data.map.keys.items, loc_meta.data.map.vals.items) |k, v| {
                try m.data.map.keys.append(gc.allocator, k);
                try m.data.map.vals.append(gc.allocator, v);
                _ = file_kw;
                _ = col_kw;
                _ = line_kw;
            }
        }
        try vec.data.vector.items.append(gc.allocator, Value.makeObj(m));
    }
    return Value.makeObj(vec);
}
