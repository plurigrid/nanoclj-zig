//! COMPILER: AST (Value) -> Bytecode (FuncDef)
//!
//! Single-pass register-allocating compiler. Walks the parsed AST
//! and emits 32-bit instructions for the bytecode VM.
//!
//! Register allocation is trivial: a monotonic counter. Each new
//! temporary or local gets the next register. This wastes registers
//! but keeps the compiler simple and correct.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Inst = bc.Inst;
const FuncDef = bc.FuncDef;

pub const CompileError = error{
    OutOfMemory,
    InvalidSyntax,
    TooManyConstants,
    TooManyRegisters,
    TooManyLocals,
};

const Local = struct {
    name: []const u8,
    reg: u8,
};

pub const Compiler = struct {
    code: std.ArrayListUnmanaged(Inst),
    constants: std.ArrayListUnmanaged(Value),
    defs: std.ArrayListUnmanaged(*FuncDef),
    locals: [256]Local,
    local_count: u8,
    next_reg: u8,
    gc: *GC,
    allocator: std.mem.Allocator,
    parent: ?*Compiler, // for nested fn* compilation
    in_tail: bool, // true when compiling in tail position of fn*
    self_name: ?[]const u8, // for self-recursive fn* (set by compileFnStar caller)

    pub fn init(allocator: std.mem.Allocator, gc: *GC, parent: ?*Compiler) Compiler {
        return .{
            .code = .{ .items = &.{}, .capacity = 0 },
            .constants = .{ .items = &.{}, .capacity = 0 },
            .defs = .{ .items = &.{}, .capacity = 0 },
            .locals = undefined,
            .local_count = 0,
            .next_reg = 0,
            .gc = gc,
            .allocator = allocator,
            .parent = parent,
            .in_tail = false,
            .self_name = null,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.defs.deinit(self.allocator);
    }

    pub fn allocReg(self: *Compiler) CompileError!u8 {
        if (self.next_reg == 255) return error.TooManyRegisters;
        const r = self.next_reg;
        self.next_reg += 1;
        return r;
    }

    fn addConst(self: *Compiler, val: Value) CompileError!u16 {
        // Deduplicate
        for (self.constants.items, 0..) |c, i| {
            if (c.eql(val)) return @intCast(i);
        }
        if (self.constants.items.len >= 65535) return error.TooManyConstants;
        const idx: u16 = @intCast(self.constants.items.len);
        self.constants.append(self.allocator, val) catch return error.OutOfMemory;
        return idx;
    }

    pub fn emit(self: *Compiler, inst: Inst) CompileError!void {
        self.code.append(self.allocator, inst) catch return error.OutOfMemory;
    }

    fn emitAt(self: *Compiler, idx: usize, inst: Inst) void {
        self.code.items[idx] = inst;
    }

    fn codeLen(self: *const Compiler) usize {
        return self.code.items.len;
    }

    fn resolveLocal(self: *const Compiler, name: []const u8) ?u8 {
        var i: u8 = self.local_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals[i].name, name)) return self.locals[i].reg;
        }
        return null;
    }

    fn addLocal(self: *Compiler, name: []const u8, reg: u8) CompileError!void {
        if (self.local_count == 255) return error.TooManyLocals;
        self.locals[self.local_count] = .{ .name = name, .reg = reg };
        self.local_count += 1;
    }

    // ========================================================================
    // COMPILE: Value -> register containing result
    // ========================================================================

    /// Compile an expression, placing the result in `dest` register.
    pub fn compile(self: *Compiler, expr: Value, dest: u8) CompileError!void {
        const saved = self.in_tail;
        self.in_tail = false;
        defer self.in_tail = saved;
        return self.compileInner(expr, dest);
    }

    /// Compile in tail position (for fn* body last expression).
    fn compileTail(self: *Compiler, expr: Value, dest: u8) CompileError!void {
        const saved = self.in_tail;
        self.in_tail = true;
        defer self.in_tail = saved;
        return self.compileInner(expr, dest);
    }

    fn compileInner(self: *Compiler, expr: Value, dest: u8) CompileError!void {
        // nil
        if (expr.isNil()) {
            try self.emit(bc.encode_d(.load_nil, dest));
            return;
        }
        // bool
        if (expr.isBool()) {
            if (expr.asBool()) {
                try self.emit(bc.encode_d(.load_true, dest));
            } else {
                try self.emit(bc.encode_d(.load_false, dest));
            }
            return;
        }
        // integer
        if (expr.isInt()) {
            const i = expr.asInt();
            if (i >= -32768 and i <= 32767) {
                try self.emit(bc.encode_ae(.load_int, dest, @bitCast(@as(i16, @intCast(i)))));
            } else {
                const ci = try self.addConst(expr);
                try self.emit(bc.encode_ae(.load_const, dest, ci));
            }
            return;
        }
        // string/keyword -> constant
        if (expr.isString() or expr.isKeyword()) {
            const ci = try self.addConst(expr);
            try self.emit(bc.encode_ae(.load_const, dest, ci));
            return;
        }
        // symbol -> local or global lookup
        if (expr.isSymbol()) {
            const name = self.gc.getString(expr.asSymbolId());
            if (self.resolveLocal(name)) |local_reg| {
                if (local_reg != dest) {
                    try self.emit(bc.encode_abc(.move, dest, local_reg, 0));
                }
                // else: result already in dest (happens when dest == local_reg)
            } else {
                const sym_const = try self.addConst(Value.makeSymbol(expr.asSymbolId()));
                try self.emit(bc.encode_ae(.get_global, dest, sym_const));
            }
            return;
        }

        // Not an object -> constant
        if (!expr.isObj()) {
            const ci = try self.addConst(expr);
            try self.emit(bc.encode_ae(.load_const, dest, ci));
            return;
        }

        const obj = expr.asObj();
        if (obj.kind != .list) {
            // vectors, maps -> constant for now
            const ci = try self.addConst(expr);
            try self.emit(bc.encode_ae(.load_const, dest, ci));
            return;
        }

        const items = obj.data.list.items.items;
        if (items.len == 0) {
            const ci = try self.addConst(expr);
            try self.emit(bc.encode_ae(.load_const, dest, ci));
            return;
        }

        // Special forms
        if (items[0].isSymbol()) {
            const name = self.gc.getString(items[0].asSymbolId());

            if (std.mem.eql(u8, name, "quote")) {
                if (items.len != 2) return error.InvalidSyntax;
                const ci = try self.addConst(items[1]);
                try self.emit(bc.encode_ae(.load_const, dest, ci));
                return;
            }
            if (std.mem.eql(u8, name, "if")) return self.compileIf(items, dest);
            if (std.mem.eql(u8, name, "def")) return self.compileDef(items, dest);
            if (std.mem.eql(u8, name, "let*")) return self.compileLet(items, dest);
            if (std.mem.eql(u8, name, "do")) return self.compileDo(items, dest);
            if (std.mem.eql(u8, name, "fn*")) return self.compileFnStar(items, dest);
            if (std.mem.eql(u8, name, "recur")) return self.compileRecur(items, dest);

            // Inline arithmetic/comparison for known builtins
            if (items.len == 3) {
                if (self.tryCompileBinop(name, items[1], items[2], dest)) |_| return;
            }
        }

        // General function application: (f arg1 arg2 ...)
        return self.compileCall(items, dest);
    }

    // ========================================================================
    // SPECIAL FORMS
    // ========================================================================

    fn compileIf(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len < 3 or items.len > 4) return error.InvalidSyntax;
        const tail = self.in_tail;

        // Compile test (never in tail)
        try self.compile(items[1], dest);

        const jump_else = self.codeLen();
        try self.emit(0); // placeholder

        // Then branch (tail if outer is tail)
        if (tail) try self.compileTail(items[2], dest) else try self.compile(items[2], dest);

        if (items.len == 4) {
            const jump_end = self.codeLen();
            try self.emit(0); // placeholder

            const else_offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jump_else)) - 1);
            self.emitAt(jump_else, bc.encode_ae(.jump_if_not, dest, @bitCast(else_offset)));

            // Else branch (tail if outer is tail)
            if (tail) try self.compileTail(items[3], dest) else try self.compile(items[3], dest);

            const end_offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jump_end)) - 1);
            self.emitAt(jump_end, bc.encode_d(.jump, @bitCast(@as(u24, @bitCast(@as(i24, @intCast(end_offset)))))));
        } else {
            const else_offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jump_else)));
            self.emitAt(jump_else, bc.encode_ae(.jump_if_not, dest, @bitCast(else_offset)));
            try self.emit(bc.encode_d(.load_nil, dest));
        }
    }

    fn compileDef(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len != 3) return error.InvalidSyntax;
        if (!items[1].isSymbol()) return error.InvalidSyntax;

        try self.compile(items[2], dest);

        const sym_const = try self.addConst(Value.makeSymbol(items[1].asSymbolId()));
        try self.emit(bc.encode_ae(.set_global, dest, sym_const));
    }

    fn compileLet(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len < 3) return error.InvalidSyntax;
        if (!items[1].isObj()) return error.InvalidSyntax;

        const bindings_obj = items[1].asObj();
        const bindings = if (bindings_obj.kind == .vector)
            bindings_obj.data.vector.items.items
        else if (bindings_obj.kind == .list)
            bindings_obj.data.list.items.items
        else
            return error.InvalidSyntax;

        if (bindings.len % 2 != 0) return error.InvalidSyntax;

        const saved_local_count = self.local_count;

        var i: usize = 0;
        while (i < bindings.len) : (i += 2) {
            if (!bindings[i].isSymbol()) return error.InvalidSyntax;
            const name = self.gc.getString(bindings[i].asSymbolId());
            const reg = try self.allocReg();
            try self.compile(bindings[i + 1], reg);
            try self.addLocal(name, reg);
        }

        // Compile body forms (last one inherits tail position)
        const tail = self.in_tail;
        const body = items[2..];
        for (body, 0..) |form, idx| {
            if (idx == body.len - 1 and tail) {
                try self.compileTail(form, dest);
            } else {
                try self.compile(form, dest);
            }
        }

        // Restore locals (let scope ends)
        self.local_count = saved_local_count;
    }

    fn compileDo(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len < 2) {
            try self.emit(bc.encode_d(.load_nil, dest));
            return;
        }
        const tail = self.in_tail;
        const body = items[1..];
        for (body, 0..) |form, idx| {
            if (idx == body.len - 1 and tail) {
                try self.compileTail(form, dest);
            } else {
                try self.compile(form, dest);
            }
        }
    }

    /// (recur arg1 arg2 ...) — rebind params and jump to function entry.
    /// Compiles to: eval args into temps, move to param regs, jump to 0.
    fn compileRecur(self: *Compiler, items: []Value, _: u8) CompileError!void {
        const argc = items.len - 1; // exclude 'recur' symbol
        // Eval new arg values into temp registers
        var temps: [64]u8 = undefined;
        for (items[1..], 0..) |arg, i| {
            const tmp = try self.allocReg();
            try self.compile(arg, tmp);
            temps[i] = tmp;
        }
        // Move temps → param registers 0..n-1
        for (0..argc) |i| {
            const param_reg: u8 = @intCast(i);
            if (temps[i] != param_reg) {
                try self.emit(bc.encode_abc(.move, param_reg, temps[i], 0));
            }
        }
        // Jump to instruction 0 (function entry)
        const offset: i24 = -@as(i24, @intCast(self.codeLen())) - 1;
        try self.emit(bc.encode_d(.jump, @bitCast(@as(u24, @bitCast(offset)))));
    }

    fn compileFnStar(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len < 3) return error.InvalidSyntax;
        if (!items[1].isObj()) return error.InvalidSyntax;

        const params_obj = items[1].asObj();
        const params = if (params_obj.kind == .vector)
            params_obj.data.vector.items.items
        else if (params_obj.kind == .list)
            params_obj.data.list.items.items
        else
            return error.InvalidSyntax;

        var child = Compiler.init(self.allocator, self.gc, self);

        // Params become locals in registers 0..n-1
        for (params) |p| {
            if (!p.isSymbol()) {
                child.deinit();
                return error.InvalidSyntax;
            }
            const name = self.gc.getString(p.asSymbolId());
            const reg = child.allocReg() catch {
                child.deinit();
                return error.TooManyRegisters;
            };
            child.addLocal(name, reg) catch {
                child.deinit();
                return error.TooManyLocals;
            };
        }

        // Compile body in tail position (last form gets tail call optimization)
        const body_dest = child.allocReg() catch {
            child.deinit();
            return error.TooManyRegisters;
        };
        const body = items[2..];
        for (body, 0..) |form, idx| {
            if (idx == body.len - 1) {
                child.compileTail(form, body_dest) catch {
                    child.deinit();
                    return error.InvalidSyntax;
                };
            } else {
                child.compile(form, body_dest) catch {
                    child.deinit();
                    return error.InvalidSyntax;
                };
            }
        }
        child.emit(bc.encode_d(.ret, body_dest)) catch {
            child.deinit();
            return error.OutOfMemory;
        };

        // Build FuncDef from child
        const func_def = self.allocator.create(FuncDef) catch {
            child.deinit();
            return error.OutOfMemory;
        };
        func_def.* = .{
            .code = (self.allocator.dupe(Inst, child.code.items) catch {
                child.deinit();
                return error.OutOfMemory;
            }),
            .constants = (self.allocator.dupe(Value, child.constants.items) catch {
                child.deinit();
                return error.OutOfMemory;
            }),
            .defs = (self.allocator.dupe(*FuncDef, child.defs.items) catch {
                child.deinit();
                return error.OutOfMemory;
            }),
            .arity = @intCast(params.len),
            .num_registers = child.next_reg,
        };
        child.deinit();

        // Add to parent's defs table
        const def_idx: u16 = @intCast(self.defs.items.len);
        self.defs.append(self.allocator, func_def) catch return error.OutOfMemory;

        try self.emit(bc.encode_ae(.closure, dest, def_idx));
    }

    // ========================================================================
    // INLINE BINARY OPERATIONS
    // ========================================================================

    fn tryCompileBinop(self: *Compiler, name: []const u8, lhs: Value, rhs: Value, dest: u8) ?void {
        const op: Op = if (std.mem.eql(u8, name, "+")) .add
        else if (std.mem.eql(u8, name, "-")) .sub
        else if (std.mem.eql(u8, name, "*")) .mul
        else if (std.mem.eql(u8, name, "/")) .div
        else if (std.mem.eql(u8, name, "=")) .eq
        else if (std.mem.eql(u8, name, "<")) .lt
        else if (std.mem.eql(u8, name, "<=")) .lte
        else if (std.mem.eql(u8, name, "quot")) .quot
        else if (std.mem.eql(u8, name, "mod")) .rem
        else if (std.mem.eql(u8, name, "rem")) .rem
        else return null;

        const r_lhs = self.allocReg() catch return null;
        self.compile(lhs, r_lhs) catch return null;
        const r_rhs = self.allocReg() catch return null;
        self.compile(rhs, r_rhs) catch return null;
        self.emit(bc.encode_abc(op, dest, r_lhs, r_rhs)) catch return null;
        return {};
    }

    // ========================================================================
    // GENERAL FUNCTION CALL
    // ========================================================================

    fn compileCall(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        const argc: u8 = @intCast(items.len - 1);

        // Phase 1: compile all sub-expressions into wherever they land
        var compiled_regs: [64]u8 = undefined;
        const func_tmp = try self.allocReg();
        try self.compile(items[0], func_tmp);
        compiled_regs[0] = func_tmp;

        for (items[1..], 0..) |arg, i| {
            const tmp = try self.allocReg();
            try self.compile(arg, tmp);
            compiled_regs[1 + i] = tmp;
        }

        // Phase 2: allocate contiguous block [func_reg, arg0, arg1, ...]
        const func_reg = try self.allocReg();
        var contiguous: [65]u8 = undefined;
        contiguous[0] = func_reg;
        for (0..argc) |i| {
            contiguous[1 + i] = try self.allocReg();
        }

        // Phase 3: move compiled values into contiguous block
        if (compiled_regs[0] != func_reg) {
            try self.emit(bc.encode_abc(.move, func_reg, compiled_regs[0], 0));
        }
        for (0..argc) |i| {
            const src = compiled_regs[1 + i];
            const dst = contiguous[1 + i];
            if (src != dst) {
                try self.emit(bc.encode_abc(.move, dst, src, 0));
            }
        }

        // In tail position: emit tail_call (reuses current frame, no stack growth)
        if (self.in_tail) {
            try self.emit(bc.encode_abc(.tail_call, func_reg, argc, 0));
        } else {
            try self.emit(bc.encode_abc(.call, dest, argc, func_reg));
        }
    }

    // ========================================================================
    // FINALIZE: produce a FuncDef for the top-level expression
    // ========================================================================

    pub fn finalize(self: *Compiler) CompileError!*FuncDef {
        const func_def = self.allocator.create(FuncDef) catch return error.OutOfMemory;
        func_def.* = .{
            .code = self.allocator.dupe(Inst, self.code.items) catch return error.OutOfMemory,
            .constants = self.allocator.dupe(Value, self.constants.items) catch return error.OutOfMemory,
            .defs = self.allocator.dupe(*FuncDef, self.defs.items) catch return error.OutOfMemory,
            .arity = 0,
            .num_registers = self.next_reg,
        };
        return func_def;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "compiler: integer literal" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var c = Compiler.init(std.testing.allocator, &gc, null);
    defer c.deinit();

    const dest = try c.allocReg();
    try c.compile(Value.makeInt(42), dest);
    try c.emit(bc.encode_d(.ret, dest));

    try std.testing.expectEqual(@as(usize, 2), c.code.items.len);
    try std.testing.expectEqual(Op.load_int, bc.decode_op(c.code.items[0]));
}

test "compiler: if expression" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Build: (if true 1 2)
    const list = try gc.allocObj(.list);
    const if_sym = try gc.internString("if");
    try list.data.list.items.append(gc.allocator, Value.makeSymbol(if_sym));
    try list.data.list.items.append(gc.allocator, Value.makeBool(true));
    try list.data.list.items.append(gc.allocator, Value.makeInt(1));
    try list.data.list.items.append(gc.allocator, Value.makeInt(2));

    var c = Compiler.init(std.testing.allocator, &gc, null);
    defer c.deinit();

    const dest = try c.allocReg();
    try c.compile(Value.makeObj(list), dest);
    try c.emit(bc.encode_d(.ret, dest));

    // Should have: load_true, jump_if_not, load_int 1, jump, load_int 2, ret
    try std.testing.expect(c.code.items.len >= 5);
}

test "compiler: add expression -> inline binop" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Build: (+ 10 20)
    const list = try gc.allocObj(.list);
    const plus_sym = try gc.internString("+");
    try list.data.list.items.append(gc.allocator, Value.makeSymbol(plus_sym));
    try list.data.list.items.append(gc.allocator, Value.makeInt(10));
    try list.data.list.items.append(gc.allocator, Value.makeInt(20));

    var c = Compiler.init(std.testing.allocator, &gc, null);
    defer c.deinit();

    const dest = try c.allocReg();
    try c.compile(Value.makeObj(list), dest);
    try c.emit(bc.encode_d(.ret, dest));

    // Should contain an ADD instruction
    var found_add = false;
    for (c.code.items) |inst| {
        if (bc.decode_op(inst) == .add) found_add = true;
    }
    try std.testing.expect(found_add);
}

test "compiler: compile + execute roundtrip" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Build: (+ 10 20)
    const list = try gc.allocObj(.list);
    const plus_sym = try gc.internString("+");
    try list.data.list.items.append(gc.allocator, Value.makeSymbol(plus_sym));
    try list.data.list.items.append(gc.allocator, Value.makeInt(10));
    try list.data.list.items.append(gc.allocator, Value.makeInt(20));

    var c = Compiler.init(std.testing.allocator, &gc, null);
    const dest = try c.allocReg();
    try c.compile(Value.makeObj(list), dest);
    try c.emit(bc.encode_d(.ret, dest));

    const func_def = try c.finalize();
    defer {
        gc.allocator.free(func_def.code);
        gc.allocator.free(func_def.constants);
        gc.allocator.free(func_def.defs);
        gc.allocator.destroy(func_def);
    }
    c.deinit();

    const closure = bc.Closure{ .def = func_def, .upvalues = &.{} };
    var vm = bc.VM.init(&gc, 1000);
    defer vm.deinit();

    const result = try vm.execute(&closure);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i48, 30), result.asInt());
}

fn freeFuncDef(def: *FuncDef, allocator: std.mem.Allocator) void {
    for (def.defs) |child| freeFuncDef(@constCast(child), allocator);
    allocator.free(def.code);
    allocator.free(def.constants);
    allocator.free(def.defs);
    allocator.destroy(def);
}

fn compileAndRun(src: []const u8, allocator: std.mem.Allocator) !Value {
    var gc = GC.init(allocator);
    defer gc.deinit();
    const Reader = @import("reader.zig").Reader;
    var reader = Reader.init(src, &gc);
    const form = try reader.readForm();
    var comp = Compiler.init(allocator, &gc, null);
    const dest = try comp.allocReg();
    try comp.compile(form, dest);
    try comp.emit(bc.encode_d(.ret, dest));
    const func_def = try comp.finalize();
    comp.deinit();
    defer freeFuncDef(func_def, allocator);
    const closure = bc.Closure{ .def = func_def, .upvalues = &.{} };
    var vm = bc.VM.init(&gc, 10_000_000);
    defer vm.deinit();
    return vm.execute(&closure);
}

test "compiler: let* binding" {
    const result = try compileAndRun("(let* [x 10 y 20] (+ x y))", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 30), result.asInt());
}

test "compiler: nested if" {
    const result = try compileAndRun("(if (< 1 2) (if (< 3 4) 42 0) 99)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: do form" {
    const result = try compileAndRun("(do 1 2 3)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 3), result.asInt());
}

test "compiler: fn* and call" {
    const result = try compileAndRun("((fn* [x] (+ x 1)) 10)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 11), result.asInt());
}

test "compiler: recur — sum 1..10" {
    // (let* [sum (fn* [n acc] (if (<= n 0) acc (recur (- n 1) (+ acc n))))]
    //   (sum 10 0))
    const src =
        \\(let* [sum (fn* [n acc] (if (<= n 0) acc (recur (- n 1) (+ acc n))))]
        \\  (sum 10 0))
    ;
    const result = try compileAndRun(src, std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 55), result.asInt());
}

test "compiler: recur — factorial 10" {
    const src =
        \\(let* [fac (fn* [n acc] (if (<= n 1) acc (recur (- n 1) (* acc n))))]
        \\  (fac 10 1))
    ;
    const result = try compileAndRun(src, std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 3628800), result.asInt());
}

test "compiler: recur — fibonacci via accumulator" {
    // fib(30) = 832040, using O(n) iterative recur
    const src =
        \\(let* [fib (fn* [n a b] (if (<= n 0) a (recur (- n 1) b (+ a b))))]
        \\  (fib 30 0 1))
    ;
    const result = try compileAndRun(src, std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 832040), result.asInt());
}

test "compiler: move opcode emitted for local access" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    const Reader = @import("reader.zig").Reader;
    var reader = Reader.init("(let* [x 42] x)", &gc);
    const form = try reader.readForm();
    var c = Compiler.init(std.testing.allocator, &gc, null);
    defer c.deinit();
    const dest = try c.allocReg();
    try c.compile(form, dest);
    var found_move = false;
    for (c.code.items) |inst| {
        if (bc.decode_op(inst) == .move) found_move = true;
    }
    try std.testing.expect(found_move);
}
