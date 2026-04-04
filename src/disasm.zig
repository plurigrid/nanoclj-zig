//! DISASSEMBLER: FuncDef → human-readable bytecode listing
//!
//! Output format per instruction:
//!   ADDR  OPCODE       OPERANDS          ; annotation
//!
//! Annotations include: constant values, jump targets, upvalue info.

const std = @import("std");
const bc = @import("bytecode.zig");
const Op = bc.Op;
const FuncDef = bc.FuncDef;
const Inst = bc.Inst;
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const printer = @import("printer.zig");

pub fn disassemble(def: *const FuncDef, gc: *GC, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer buf.deinit(allocator);

    try disassembleInto(&buf, def, gc, allocator, 0);
    return allocator.dupe(u8, buf.items);
}

fn disassembleInto(
    buf: *std.ArrayListUnmanaged(u8),
    def: *const FuncDef,
    gc: *GC,
    allocator: std.mem.Allocator,
    depth: u8,
) !void {
    // Header
    const indent = @as(usize, depth) * 2;
    try writeIndent(buf, allocator, indent);
    try appendFmt(buf, allocator, "; arity={d} regs={d} code={d} consts={d}", .{
        def.arity, def.num_registers, def.code.len, def.constants.len,
    });
    if (def.upvalue_sources.len > 0) {
        try appendFmt(buf, allocator, " upvalues={d}", .{def.upvalue_sources.len});
    }
    try buf.append(allocator, '\n');

    // Constants table
    if (def.constants.len > 0) {
        try writeIndent(buf, allocator, indent);
        try buf.appendSlice(allocator, "; constants:\n");
        for (def.constants, 0..) |c, i| {
            try writeIndent(buf, allocator, indent);
            try appendFmt(buf, allocator, ";   [{d}] ", .{i});
            try appendValue(buf, c, gc, allocator);
            try buf.append(allocator, '\n');
        }
    }

    // Upvalue sources
    if (def.upvalue_sources.len > 0) {
        try writeIndent(buf, allocator, indent);
        try buf.appendSlice(allocator, "; upvalue sources:\n");
        for (def.upvalue_sources, 0..) |src, i| {
            try writeIndent(buf, allocator, indent);
            if (src.is_local) {
                try appendFmt(buf, allocator, ";   [{d}] local R{d}\n", .{ i, src.index });
            } else {
                try appendFmt(buf, allocator, ";   [{d}] upvalue [{d}]\n", .{ i, src.index });
            }
        }
    }

    // Instructions
    for (def.code, 0..) |inst, addr| {
        try writeIndent(buf, allocator, indent);
        try appendFmt(buf, allocator, "{d:0>4}  ", .{addr});
        try disassembleInst(buf, inst, def, gc, allocator, addr);
        try buf.append(allocator, '\n');
    }

    // Sub-defs (nested fn*)
    for (def.defs, 0..) |sub, i| {
        try buf.append(allocator, '\n');
        try writeIndent(buf, allocator, indent);
        try appendFmt(buf, allocator, "; --- sub-fn {d} ---\n", .{i});
        try disassembleInto(buf, sub, gc, allocator, depth + 1);
    }
}

fn disassembleInst(
    buf: *std.ArrayListUnmanaged(u8),
    inst: Inst,
    def: *const FuncDef,
    gc: *GC,
    allocator: std.mem.Allocator,
    addr: usize,
) !void {
    const op = bc.decode_op(inst);
    const name = @tagName(op);

    switch (op) {
        // D-format (24-bit operand)
        .ret => {
            const d = bc.decode_d(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}", .{ name, d });
        },
        .ret_nil => try buf.appendSlice(allocator, "ret_nil"),
        .jump => {
            const ds = bc.decode_ds(inst);
            const target: i64 = @as(i64, @intCast(addr)) + 1 + @as(i64, ds);
            try appendFmt(buf, allocator, "{s:<14} -> {d}", .{ name, target });
        },
        .load_nil, .load_true, .load_false => {
            const d = bc.decode_d(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}", .{ name, d });
        },

        // AE-format (8-bit A + 16-bit E)
        .jump_if, .jump_if_not => {
            const a = bc.decode_a(inst);
            const es = bc.decode_es(inst);
            const target: i64 = @as(i64, @intCast(addr)) + 1 + @as(i64, es);
            try appendFmt(buf, allocator, "{s:<14} R{d}, -> {d}", .{ name, a, target });
        },
        .load_int => {
            const a = bc.decode_a(inst);
            const es = bc.decode_es(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, {d}", .{ name, a, es });
        },
        .load_const => {
            const a = bc.decode_a(inst);
            const e = bc.decode_e(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, [{d}]", .{ name, a, e });
            if (e < def.constants.len) {
                try buf.appendSlice(allocator, "  ; ");
                try appendValue(buf, def.constants[e], gc, allocator);
            }
        },
        .closure => {
            const a = bc.decode_a(inst);
            const e = bc.decode_e(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, def[{d}]", .{ name, a, e });
        },
        .get_upvalue => {
            const a = bc.decode_a(inst);
            const e = bc.decode_e(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, uv[{d}]", .{ name, a, e });
        },
        .get_global => {
            const a = bc.decode_a(inst);
            const e = bc.decode_e(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, [{d}]", .{ name, a, e });
            if (e < def.constants.len) {
                try buf.appendSlice(allocator, "  ; ");
                try appendValue(buf, def.constants[e], gc, allocator);
            }
        },
        .set_global => {
            const a = bc.decode_a(inst);
            const e = bc.decode_e(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, [{d}]", .{ name, a, e });
            if (e < def.constants.len) {
                try buf.appendSlice(allocator, "  ; ");
                try appendValue(buf, def.constants[e], gc, allocator);
            }
        },

        // ABC-format (8-bit A, B, C)
        .add, .sub, .mul, .div, .quot, .rem, .eq, .lt, .lte => {
            const a = bc.decode_a(inst);
            const b = bc.decode_b(inst);
            const c = bc.decode_c(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, R{d}, R{d}", .{ name, a, b, c });
        },
        .move => {
            const a = bc.decode_a(inst);
            const b = bc.decode_b(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}, R{d}", .{ name, a, b });
        },
        .call => {
            const a = bc.decode_a(inst);
            const b = bc.decode_b(inst);
            const c = bc.decode_c(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d} = R{d}({d} args)", .{ name, a, c, b });
        },
        .tail_call => {
            const a = bc.decode_a(inst);
            const b = bc.decode_b(inst);
            try appendFmt(buf, allocator, "{s:<14} R{d}({d} args)", .{ name, a, b });
        },
    }
}

// ── Helpers ──

fn appendFmt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var tmp: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
    try buf.appendSlice(allocator, s);
}

fn appendValue(buf: *std.ArrayListUnmanaged(u8), val: Value, gc: *GC, allocator: std.mem.Allocator) !void {
    if (val.isNil()) {
        try buf.appendSlice(allocator, "nil");
    } else if (val.isBool()) {
        try buf.appendSlice(allocator, if (val.asBool()) "true" else "false");
    } else if (val.isInt()) {
        try appendFmt(buf, allocator, "{d}", .{val.asInt()});
    } else if (val.isString()) {
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, gc.getString(val.asStringId()));
        try buf.append(allocator, '"');
    } else if (val.isKeyword()) {
        try buf.append(allocator, ':');
        try buf.appendSlice(allocator, gc.getString(val.asKeywordId()));
    } else if (val.isSymbol()) {
        try buf.appendSlice(allocator, gc.getString(val.asSymbolId()));
    } else if (val.isObj()) {
        const obj = val.asObj();
        switch (obj.kind) {
            .builtin_ref => {
                try buf.appendSlice(allocator, "#<builtin ");
                try buf.appendSlice(allocator, obj.data.builtin_ref.name);
                try buf.append(allocator, '>');
            },
            else => try buf.appendSlice(allocator, "#<obj>"),
        }
    } else {
        try appendFmt(buf, allocator, "{d:.4}", .{val.asFloat()});
    }
}

fn writeIndent(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: usize) !void {
    for (0..n) |_| try buf.append(allocator, ' ');
}

// ============================================================================
// TESTS
// ============================================================================

const Compiler = @import("compiler.zig").Compiler;
const Reader = @import("reader.zig").Reader;

fn disasmExpr(src: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var gc = GC.init(allocator);
    defer gc.deinit();
    var reader = Reader.init(src, &gc);
    const form = try reader.readForm();
    var comp = Compiler.init(allocator, &gc, null);
    const dest = try comp.allocReg();
    try comp.compile(form, dest);
    try comp.emit(bc.encode_d(.ret, dest));
    const func_def = try comp.finalize();
    comp.deinit();
    defer {
        for (func_def.defs) |child| {
            allocator.free(child.code);
            allocator.free(child.constants);
            allocator.free(child.defs);
            if (child.upvalue_sources.len > 0) allocator.free(child.upvalue_sources);
            allocator.destroy(@constCast(child));
        }
        allocator.free(func_def.code);
        allocator.free(func_def.constants);
        allocator.free(func_def.defs);
        if (func_def.upvalue_sources.len > 0) allocator.free(func_def.upvalue_sources);
        allocator.destroy(func_def);
    }
    const result = try disassemble(func_def, &gc, allocator);
    defer allocator.free(result);
    return allocator.dupe(u8, result);
}

test "disasm: simple addition" {
    const output = try disasmExpr("(+ 1 2)", std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "load_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ret") != null);
}

test "disasm: if expression" {
    const output = try disasmExpr("(if true 1 2)", std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "load_true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "jump_if_not") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "jump") != null);
}

test "disasm: closure shows sub-fn" {
    const output = try disasmExpr("(fn* [x] (+ x 1))", std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sub-fn 0") != null);
}

test "disasm: variadic addition folds" {
    const output = try disasmExpr("(+ 1 2 3 4)", std.testing.allocator);
    defer std.testing.allocator.free(output);
    // Should have 3 add instructions for 4 args
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, output, pos, "add ")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "disasm: let with upvalue capture" {
    const output = try disasmExpr("(let* [x 10] (fn* [y] (+ x y)))", std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "get_upvalue") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "upvalue sources") != null);
}
