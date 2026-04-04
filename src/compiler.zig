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
const Env = @import("env.zig").Env;
const core = @import("core.zig");
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

const Upvalue = struct {
    name: []const u8,
    source: bc.UpvalueSource, // how to capture from enclosing scope
};

pub const Compiler = struct {
    code: std.ArrayListUnmanaged(Inst),
    constants: std.ArrayListUnmanaged(Value),
    defs: std.ArrayListUnmanaged(*FuncDef),
    upvalues: std.ArrayListUnmanaged(Upvalue),
    locals: [256]Local,
    local_count: u8,
    next_reg: u8,
    gc: *GC,
    allocator: std.mem.Allocator,
    parent: ?*Compiler, // for nested fn* compilation
    in_tail: bool, // true when compiling in tail position of fn*
    self_name: ?[]const u8, // for self-recursive fn* (set by compileFnStar caller)
    vm_globals: ?*std.StringHashMap(Value), // VM globals — checked before builtins
    loop_entry: ?usize = null, // instruction index of loop head (for recur in loop)
    loop_regs: [64]u8 = undefined, // registers holding loop bindings
    loop_arity: u8 = 0, // number of loop bindings

    pub fn init(allocator: std.mem.Allocator, gc: *GC, parent: ?*Compiler, vm_globals: ?*std.StringHashMap(Value)) Compiler {
        return .{
            .code = .{ .items = &.{}, .capacity = 0 },
            .constants = .{ .items = &.{}, .capacity = 0 },
            .defs = .{ .items = &.{}, .capacity = 0 },
            .upvalues = .{ .items = &.{}, .capacity = 0 },
            .locals = undefined,
            .local_count = 0,
            .next_reg = 0,
            .gc = gc,
            .allocator = allocator,
            .parent = parent,
            .in_tail = false,
            .self_name = null,
            .vm_globals = if (parent) |p| p.vm_globals else vm_globals,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.defs.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
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

    /// Resolve a variable from an enclosing scope, adding upvalue entries
    /// through each intermediate compiler in the chain.
    fn resolveUpvalue(self: *Compiler, name: []const u8) CompileError!?u16 {
        const parent = self.parent orelse return null;

        // Check if it's a local in the immediate parent
        if (parent.resolveLocal(name)) |reg| {
            return try self.addUpvalue(name, .{ .is_local = true, .index = reg });
        }

        // Recursively resolve in grandparent (will add upvalue in parent too)
        if (try parent.resolveUpvalue(name)) |parent_uv_idx| {
            return try self.addUpvalue(name, .{ .is_local = false, .index = @intCast(parent_uv_idx) });
        }

        return null;
    }

    fn addUpvalue(self: *Compiler, name: []const u8, source: bc.UpvalueSource) CompileError!u16 {
        // Deduplicate: if we already capture this source, return existing index
        for (self.upvalues.items, 0..) |uv, i| {
            if (uv.source.is_local == source.is_local and uv.source.index == source.index) {
                return @intCast(i);
            }
        }
        if (self.upvalues.items.len >= 255) return error.TooManyLocals;
        const idx: u16 = @intCast(self.upvalues.items.len);
        self.upvalues.append(self.allocator, .{ .name = name, .source = source }) catch return error.OutOfMemory;
        return idx;
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
            } else if (try self.resolveUpvalue(name)) |uv_idx| {
                try self.emit(bc.encode_ae(.get_upvalue, dest, uv_idx));
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
            if (std.mem.eql(u8, name, "defn")) return self.compileDefn(items, dest);
            if (std.mem.eql(u8, name, "let*")) return self.compileLet(items, dest);
            if (std.mem.eql(u8, name, "do")) return self.compileDo(items, dest);
            if (std.mem.eql(u8, name, "fn*")) return self.compileFnStar(items, dest);
            if (std.mem.eql(u8, name, "recur")) return self.compileRecur(items, dest);
            if (std.mem.eql(u8, name, "loop")) return self.compileLoop(items, dest);
            if (std.mem.eql(u8, name, "and")) return self.compileAnd(items, dest);
            if (std.mem.eql(u8, name, "or")) return self.compileOr(items, dest);
            if (std.mem.eql(u8, name, "when")) return self.compileWhen(items, dest);
            if (std.mem.eql(u8, name, "cond")) return self.compileCond(items, dest);

            // Compile-time macro expansion: check VM globals for macros
            if (self.vm_globals) |globals| {
                if (globals.get(name)) |head_val| {
                    if (head_val.isObj() and head_val.asObj().kind == .macro_fn) {
                        const eval_mod = @import("eval.zig");
                        var dummy_env = @import("env.zig").Env.init(self.allocator, null);
                        defer dummy_env.deinit();
                        const expanded = eval_mod.apply(head_val, items[1..], &dummy_env, self.gc) catch return error.InvalidSyntax;
                        return self.compile(expanded, dest);
                    }
                }
            }

            // Variadic arithmetic: (+ a b c ...) → left-fold of binary ops
            if (items.len >= 3) {
                if (self.tryCompileVariadicOp(name, items[1..], dest)) |_| return;
            }
            // Unary operations
            if (items.len == 2) {
                if (std.mem.eql(u8, name, "-")) return self.compileNegate(items[1], dest);
                if (std.mem.eql(u8, name, "not")) {
                    try self.compile(items[1], dest);
                    // if truthy → false, else → true. Use jump_if_not trick:
                    const jump_idx = self.codeLen();
                    try self.emit(0); // placeholder
                    try self.emit(bc.encode_d(.load_false, dest));
                    const jump_end = self.codeLen();
                    try self.emit(0); // placeholder
                    const else_off: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jump_idx)) - 1);
                    self.emitAt(jump_idx, bc.encode_ae(.jump_if_not, dest, @bitCast(else_off)));
                    try self.emit(bc.encode_d(.load_true, dest));
                    const end_off: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jump_end)) - 1);
                    self.emitAt(jump_end, bc.encode_d(.jump, @bitCast(@as(u24, @bitCast(@as(i24, @intCast(end_off)))))));
                    return;
                }
                if (std.mem.eql(u8, name, "inc")) {
                    try self.compile(items[1], dest);
                    const one = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, one, @bitCast(@as(i16, 1))));
                    try self.emit(bc.encode_abc(.add, dest, dest, one));
                    return;
                }
                if (std.mem.eql(u8, name, "dec")) {
                    try self.compile(items[1], dest);
                    const one = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, one, @bitCast(@as(i16, 1))));
                    try self.emit(bc.encode_abc(.sub, dest, dest, one));
                    return;
                }
                if (std.mem.eql(u8, name, "zero?")) {
                    try self.compile(items[1], dest);
                    const zero = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, zero, 0));
                    try self.emit(bc.encode_abc(.eq, dest, dest, zero));
                    return;
                }
                if (std.mem.eql(u8, name, "pos?")) {
                    try self.compile(items[1], dest);
                    const zero = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, zero, 0));
                    try self.emit(bc.encode_abc(.lt, dest, zero, dest)); // 0 < x
                    return;
                }
                if (std.mem.eql(u8, name, "neg?")) {
                    try self.compile(items[1], dest);
                    const zero = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, zero, 0));
                    try self.emit(bc.encode_abc(.lt, dest, dest, zero)); // x < 0
                    return;
                }
                if (std.mem.eql(u8, name, "even?")) {
                    try self.compile(items[1], dest);
                    const two = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, two, @bitCast(@as(i16, 2))));
                    try self.emit(bc.encode_abc(.rem, dest, dest, two));
                    const zero = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, zero, 0));
                    try self.emit(bc.encode_abc(.eq, dest, dest, zero));
                    return;
                }
                if (std.mem.eql(u8, name, "odd?")) {
                    try self.compile(items[1], dest);
                    const two = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, two, @bitCast(@as(i16, 2))));
                    try self.emit(bc.encode_abc(.rem, dest, dest, two));
                    const zero = try self.allocReg();
                    try self.emit(bc.encode_ae(.load_int, zero, 0));
                    try self.emit(bc.encode_abc(.eq, dest, dest, zero));
                    // negate: eq gave us (rem=0), we want (rem!=0)
                    const jidx = self.codeLen();
                    try self.emit(0);
                    try self.emit(bc.encode_d(.load_false, dest));
                    const jend = self.codeLen();
                    try self.emit(0);
                    const eo: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jidx)) - 1);
                    self.emitAt(jidx, bc.encode_ae(.jump_if_not, dest, @bitCast(eo)));
                    try self.emit(bc.encode_d(.load_true, dest));
                    const eeo: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jend)) - 1);
                    self.emitAt(jend, bc.encode_d(.jump, @bitCast(@as(u24, @bitCast(@as(i24, @intCast(eeo)))))));
                    return;
                }

                // ── List operations ──
                if (std.mem.eql(u8, name, "cons")) {
                    if (items.len != 3) return error.InvalidSyntax;
                    const rb = try self.allocReg();
                    const rc = try self.allocReg();
                    try self.compile(items[1], rb);
                    try self.compile(items[2], rc);
                    try self.emit(bc.encode_abc(.cons, dest, rb, rc));
                    return;
                }
                if (std.mem.eql(u8, name, "first")) {
                    if (items.len != 2) return error.InvalidSyntax;
                    try self.compile(items[1], dest);
                    try self.emit(bc.encode_abc(.first, dest, dest, 0));
                    return;
                }
                if (std.mem.eql(u8, name, "rest")) {
                    if (items.len != 2) return error.InvalidSyntax;
                    try self.compile(items[1], dest);
                    try self.emit(bc.encode_abc(.rest, dest, dest, 0));
                    return;
                }
                if (std.mem.eql(u8, name, "list")) {
                    if (items.len == 1) {
                        // (list) → empty list
                        const r = try self.allocReg();
                        try self.emit(bc.encode_abc(.make_list, dest, r, 0));
                        return;
                    }
                    // Compile elements into contiguous registers
                    const base_reg = self.next_reg;
                    for (items[1..]) |item| {
                        const r = try self.allocReg();
                        try self.compile(item, r);
                    }
                    const cnt: u8 = @intCast(items.len - 1);
                    try self.emit(bc.encode_abc(.make_list, dest, base_reg, cnt));
                    return;
                }
                if (std.mem.eql(u8, name, "count")) {
                    if (items.len != 2) return error.InvalidSyntax;
                    try self.compile(items[1], dest);
                    try self.emit(bc.encode_abc(.count, dest, dest, 0));
                    return;
                }
                if (std.mem.eql(u8, name, "nth")) {
                    if (items.len != 3) return error.InvalidSyntax;
                    const rb = try self.allocReg();
                    const rc = try self.allocReg();
                    try self.compile(items[1], rb);
                    try self.compile(items[2], rc);
                    try self.emit(bc.encode_abc(.nth, dest, rb, rc));
                    return;
                }
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

    /// (defn name [params] body...) => (def name (fn* name [params] body...))
    fn compileDefn(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        // (defn name [params] body1 body2 ...)
        if (items.len < 4) return error.InvalidSyntax;
        if (!items[1].isSymbol()) return error.InvalidSyntax;
        // Rewrite as (fn* name [params] body...) and compile it
        const fn_name = self.gc.getString(items[1].asSymbolId());
        const saved_self_name = self.self_name;
        self.self_name = fn_name;
        defer self.self_name = saved_self_name;
        // Build synthetic fn* items: [fn*, params, body1, body2, ...]
        // items[2] = params vector, items[3..] = body
        var fn_items_buf: [64]Value = undefined;
        fn_items_buf[0] = items[0]; // placeholder (fn* symbol not needed, compileFnStar uses items[1..])
        fn_items_buf[1] = items[2]; // params
        const body = items[3..];
        if (body.len + 2 > fn_items_buf.len) return error.InvalidSyntax;
        for (body, 0..) |b, i| fn_items_buf[2 + i] = b;
        // compileFnStar expects items[1] = params, items[2..] = body
        try self.compileFnStar(fn_items_buf[0 .. 2 + body.len], dest);
        // Now set_global
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

    /// (recur arg1 arg2 ...) — rebind bindings and jump back.
    /// If inside a loop, jumps to loop_entry and updates loop_regs.
    /// If inside a fn*, jumps to instruction 0 and updates param regs.
    fn compileRecur(self: *Compiler, items: []Value, _: u8) CompileError!void {
        const argc = items.len - 1;
        // Eval new arg values into temp registers
        var temps: [64]u8 = undefined;
        for (items[1..], 0..) |arg, i| {
            const tmp = try self.allocReg();
            try self.compile(arg, tmp);
            temps[i] = tmp;
        }

        if (self.loop_entry) |entry| {
            // Loop recur: move temps → loop binding registers
            for (0..argc) |i| {
                if (temps[i] != self.loop_regs[i]) {
                    try self.emit(bc.encode_abc(.move, self.loop_regs[i], temps[i], 0));
                }
            }
            // Jump to loop entry
            const offset: i24 = @intCast(@as(i64, @intCast(entry)) - @as(i64, @intCast(self.codeLen())) - 1);
            try self.emit(bc.encode_d(.jump, @bitCast(@as(u24, @bitCast(offset)))));
        } else {
            // Function recur: move temps → param registers 0..n-1
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
    }

    /// (loop [x init-x y init-y] body...) — like let* but recur jumps back here
    fn compileLoop(self: *Compiler, items: []Value, dest: u8) CompileError!void {
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
        const saved_loop_entry = self.loop_entry;
        const saved_loop_arity = self.loop_arity;
        var saved_loop_regs: [64]u8 = undefined;
        @memcpy(saved_loop_regs[0..saved_loop_arity], self.loop_regs[0..saved_loop_arity]);

        // Compile bindings
        const n_bindings: u8 = @intCast(bindings.len / 2);
        var i: usize = 0;
        var bi: u8 = 0;
        while (i < bindings.len) : (i += 2) {
            if (!bindings[i].isSymbol()) return error.InvalidSyntax;
            const name = self.gc.getString(bindings[i].asSymbolId());
            const reg = try self.allocReg();
            try self.compile(bindings[i + 1], reg);
            try self.addLocal(name, reg);
            self.loop_regs[bi] = reg;
            bi += 1;
        }

        // Mark loop entry point (instruction AFTER binding setup)
        self.loop_entry = self.codeLen();
        self.loop_arity = n_bindings;

        // Compile body (last form in tail position if enclosing is tail)
        const tail = self.in_tail;
        const body = items[2..];
        for (body, 0..) |form, idx| {
            if (idx == body.len - 1 and tail) {
                try self.compileTail(form, dest);
            } else {
                try self.compile(form, dest);
            }
        }

        // Restore
        self.local_count = saved_local_count;
        self.loop_entry = saved_loop_entry;
        self.loop_arity = saved_loop_arity;
        @memcpy(self.loop_regs[0..saved_loop_arity], saved_loop_regs[0..saved_loop_arity]);
    }

    /// (and a b c) → short-circuit: if a is falsy return a, else if b is falsy return b, else c
    fn compileAnd(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len == 1) {
            try self.emit(bc.encode_d(.load_true, dest));
            return;
        }
        var patches = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
        defer patches.deinit(self.allocator);

        for (items[1..]) |form| {
            try self.compile(form, dest);
            const idx = self.codeLen();
            try self.emit(0); // placeholder jump_if_not → end
            patches.append(self.allocator, idx) catch return error.OutOfMemory;
        }
        // Patch all short-circuits to here (dest holds the last falsy or last truthy value)
        for (patches.items) |idx| {
            const offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(idx)) - 1);
            self.emitAt(idx, bc.encode_ae(.jump_if_not, dest, @bitCast(offset)));
        }
    }

    /// (or a b c) → short-circuit: if a is truthy return a, else if b is truthy return b, else c
    fn compileOr(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len == 1) {
            try self.emit(bc.encode_d(.load_nil, dest));
            return;
        }
        var patches = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
        defer patches.deinit(self.allocator);

        for (items[1..]) |form| {
            try self.compile(form, dest);
            const idx = self.codeLen();
            try self.emit(0); // placeholder jump_if → end
            patches.append(self.allocator, idx) catch return error.OutOfMemory;
        }
        for (patches.items) |idx| {
            const offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(idx)) - 1);
            self.emitAt(idx, bc.encode_ae(.jump_if, dest, @bitCast(offset)));
        }
    }

    /// (when test body...) → (if test (do body...) nil)
    fn compileWhen(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len < 2) return error.InvalidSyntax;
        try self.compile(items[1], dest);
        const jump_idx = self.codeLen();
        try self.emit(0); // placeholder jump_if_not → end

        // Body forms
        const tail = self.in_tail;
        const body = items[2..];
        for (body, 0..) |form, i| {
            if (i == body.len - 1 and tail) {
                try self.compileTail(form, dest);
            } else {
                try self.compile(form, dest);
            }
        }
        const end_idx = self.codeLen();
        // jump past nil load
        try self.emit(0); // placeholder jump → after nil

        // Patch jump_if_not to nil
        const else_offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jump_idx)) - 1);
        self.emitAt(jump_idx, bc.encode_ae(.jump_if_not, dest, @bitCast(else_offset)));
        try self.emit(bc.encode_d(.load_nil, dest));

        // Patch jump past nil
        const end_offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(end_idx)) - 1);
        self.emitAt(end_idx, bc.encode_d(.jump, @bitCast(@as(u24, @bitCast(@as(i24, @intCast(end_offset)))))));
    }

    /// (cond test1 expr1 test2 expr2 ... :else default)
    fn compileCond(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        if (items.len < 3 or (items.len - 1) % 2 != 0) return error.InvalidSyntax;
        const tail = self.in_tail;
        var end_patches = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
        defer end_patches.deinit(self.allocator);

        var i: usize = 1;
        while (i < items.len) : (i += 2) {
            const test_expr = items[i];
            const body_expr = items[i + 1];

            // Check for :else keyword (always true)
            if (test_expr.isKeyword()) {
                const kw_name = self.gc.getString(test_expr.asKeywordId());
                if (std.mem.eql(u8, kw_name, "else")) {
                    if (tail) try self.compileTail(body_expr, dest) else try self.compile(body_expr, dest);
                    break;
                }
            }

            try self.compile(test_expr, dest);
            const jump_next = self.codeLen();
            try self.emit(0); // placeholder jump_if_not → next clause

            if (tail) try self.compileTail(body_expr, dest) else try self.compile(body_expr, dest);

            // Jump to end
            const end_jump = self.codeLen();
            try self.emit(0); // placeholder
            end_patches.append(self.allocator, end_jump) catch return error.OutOfMemory;

            // Patch jump_if_not → here (next clause)
            const next_offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(jump_next)) - 1);
            self.emitAt(jump_next, bc.encode_ae(.jump_if_not, dest, @bitCast(next_offset)));
        }

        // If no :else, load nil
        if (i >= items.len) {
            try self.emit(bc.encode_d(.load_nil, dest));
        }

        // Patch all end jumps
        for (end_patches.items) |idx| {
            const offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(idx)) - 1);
            self.emitAt(idx, bc.encode_d(.jump, @bitCast(@as(u24, @bitCast(@as(i24, @intCast(offset)))))));
        }
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

        var child = Compiler.init(self.allocator, self.gc, self, null);

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

        // Build upvalue sources from child's captured upvalues
        const uv_sources = if (child.upvalues.items.len > 0) blk: {
            const sources = self.allocator.alloc(bc.UpvalueSource, child.upvalues.items.len) catch {
                child.deinit();
                return error.OutOfMemory;
            };
            for (child.upvalues.items, 0..) |uv, i| sources[i] = uv.source;
            break :blk sources;
        } else &[_]bc.UpvalueSource{};

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
            .upvalue_sources = uv_sources,
        };
        child.deinit();

        // Add to parent's defs table
        const def_idx: u16 = @intCast(self.defs.items.len);
        self.defs.append(self.allocator, func_def) catch return error.OutOfMemory;

        try self.emit(bc.encode_ae(.closure, dest, def_idx));
    }

    // ========================================================================
    // INLINE OPERATIONS: variadic arithmetic, comparisons, unary negate
    // ========================================================================

    fn nameToArithOp(name: []const u8) ?Op {
        if (std.mem.eql(u8, name, "+")) return .add;
        if (std.mem.eql(u8, name, "-")) return .sub;
        if (std.mem.eql(u8, name, "*")) return .mul;
        if (std.mem.eql(u8, name, "/")) return .div;
        if (std.mem.eql(u8, name, "quot")) return .quot;
        if (std.mem.eql(u8, name, "mod")) return .rem;
        if (std.mem.eql(u8, name, "rem")) return .rem;
        return null;
    }

    const CmpOp = struct { op: Op, swap: bool };

    fn nameToCmpOp(name: []const u8) ?CmpOp {
        if (std.mem.eql(u8, name, "=")) return .{ .op = .eq, .swap = false };
        if (std.mem.eql(u8, name, "<")) return .{ .op = .lt, .swap = false };
        if (std.mem.eql(u8, name, "<=")) return .{ .op = .lte, .swap = false };
        if (std.mem.eql(u8, name, ">")) return .{ .op = .lt, .swap = true };
        if (std.mem.eql(u8, name, ">=")) return .{ .op = .lte, .swap = true };
        if (std.mem.eql(u8, name, "!=")) return .{ .op = .eq, .swap = false }; // will negate
        return null;
    }

    /// (+ a b c ...) → left-fold: tmp = a+b, tmp = tmp+c, ...
    /// (< a b c)     → (and (< a b) (< b c)) with short-circuit
    fn tryCompileVariadicOp(self: *Compiler, name: []const u8, args: []Value, dest: u8) ?void {
        if (nameToArithOp(name)) |op| {
            self.compileVariadicArith(op, args, dest) catch return null;
            return {};
        }
        if (nameToCmpOp(name)) |cmp| {
            if (args.len == 2) {
                const r_lhs = self.allocReg() catch return null;
                self.compile(args[0], r_lhs) catch return null;
                const r_rhs = self.allocReg() catch return null;
                self.compile(args[1], r_rhs) catch return null;
                if (cmp.swap) {
                    self.emit(bc.encode_abc(cmp.op, dest, r_rhs, r_lhs)) catch return null;
                } else {
                    self.emit(bc.encode_abc(cmp.op, dest, r_lhs, r_rhs)) catch return null;
                }
                return {};
            }
            if (args.len >= 3) {
                self.compileVariadicCmp(cmp.op, args, dest) catch return null;
                return {};
            }
        }
        return null;
    }

    fn compileVariadicArith(self: *Compiler, op: Op, args: []Value, dest: u8) CompileError!void {
        // Compile first arg into accumulator
        const acc = try self.allocReg();
        try self.compile(args[0], acc);
        // Left-fold remaining args
        for (args[1..]) |arg| {
            const tmp = try self.allocReg();
            try self.compile(arg, tmp);
            try self.emit(bc.encode_abc(op, acc, acc, tmp));
        }
        if (acc != dest) {
            try self.emit(bc.encode_abc(.move, dest, acc, 0));
        }
    }

    /// (< a b c) → compile as: r0=a, r1=b, cmp(dest, r0, r1), jump_if_not end,
    ///             r2=c, cmp(dest, r1, r2), end:
    fn compileVariadicCmp(self: *Compiler, op: Op, args: []Value, dest: u8) CompileError!void {
        var patches = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
        defer patches.deinit(self.allocator);

        var prev_reg = try self.allocReg();
        try self.compile(args[0], prev_reg);

        for (args[1..]) |arg| {
            const cur_reg = try self.allocReg();
            try self.compile(arg, cur_reg);
            try self.emit(bc.encode_abc(op, dest, prev_reg, cur_reg));
            // Short-circuit: if false, jump to end
            const patch_idx = self.codeLen();
            try self.emit(0); // placeholder jump_if_not
            patches.append(self.allocator, patch_idx) catch return error.OutOfMemory;
            prev_reg = cur_reg;
        }

        // All comparisons passed → dest already holds true from last cmp
        // Patch all jump_if_not to here
        for (patches.items) |idx| {
            const offset: i16 = @intCast(@as(i64, @intCast(self.codeLen())) - @as(i64, @intCast(idx)) - 1);
            self.emitAt(idx, bc.encode_ae(.jump_if_not, dest, @bitCast(offset)));
        }
    }

    fn compileNegate(self: *Compiler, arg: Value, dest: u8) CompileError!void {
        const zero_reg = try self.allocReg();
        try self.emit(bc.encode_ae(.load_int, zero_reg, 0));
        const arg_reg = try self.allocReg();
        try self.compile(arg, arg_reg);
        try self.emit(bc.encode_abc(.sub, dest, zero_reg, arg_reg));
    }

    // ========================================================================
    // GENERAL FUNCTION CALL
    // ========================================================================

    /// Try to resolve a symbol to a builtin_ref constant.
    fn tryResolveBuiltin(self: *Compiler, sym: Value) CompileError!?u16 {
        if (!sym.isSymbol()) return null;
        const name = self.gc.getString(sym.asSymbolId());
        // Don't resolve if it shadows a local or upvalue
        if (self.resolveLocal(name) != null) return null;
        if ((try self.resolveUpvalue(name)) != null) return null;
        // If a VM global exists with this name, prefer it over builtins
        if (self.vm_globals) |globals| {
            if (globals.contains(name)) return null;
        }
        const builtin_fn = core.lookupBuiltin(name) orelse return null;
        // Create builtin_ref Obj as constant
        const obj = self.gc.allocObj(.builtin_ref) catch return error.OutOfMemory;
        obj.data.builtin_ref = .{ .func = builtin_fn, .name = name };
        return try self.addConst(Value.makeObj(obj));
    }

    fn compileCall(self: *Compiler, items: []Value, dest: u8) CompileError!void {
        const argc: u8 = @intCast(items.len - 1);

        // Phase 1: compile all sub-expressions into wherever they land
        var compiled_regs: [64]u8 = undefined;
        const func_tmp = try self.allocReg();

        // Try to resolve function to a builtin at compile time
        if (try self.tryResolveBuiltin(items[0])) |bi_const| {
            try self.emit(bc.encode_ae(.load_const, func_tmp, bi_const));
        } else {
            try self.compile(items[0], func_tmp);
        }
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

    var c = Compiler.init(std.testing.allocator, &gc, null, null);
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

    var c = Compiler.init(std.testing.allocator, &gc, null, null);
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

    var c = Compiler.init(std.testing.allocator, &gc, null, null);
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

    var c = Compiler.init(std.testing.allocator, &gc, null, null);
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
    if (def.upvalue_sources.len > 0) allocator.free(def.upvalue_sources);
    allocator.destroy(def);
}

fn compileAndRun(src: []const u8, allocator: std.mem.Allocator) !Value {
    return compileAndRunWithBuiltins(src, allocator, false);
}

fn compileAndRunWithBuiltins(src: []const u8, allocator: std.mem.Allocator, init_builtins: bool) !Value {
    var gc = GC.init(allocator);
    defer gc.deinit();
    var env = Env.init(allocator, null);
    defer env.deinit();
    if (init_builtins) {
        core.deinitCore(); // reset global state from any prior test
        try core.initCore(&env, &gc);
    }
    defer if (init_builtins) core.deinitCore();
    const Reader = @import("reader.zig").Reader;
    var reader = Reader.init(src, &gc);
    const form = try reader.readForm();
    var comp = Compiler.init(allocator, &gc, null, null);
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
    var c = Compiler.init(std.testing.allocator, &gc, null, null);
    defer c.deinit();
    const dest = try c.allocReg();
    try c.compile(form, dest);
    var found_move = false;
    for (c.code.items) |inst| {
        if (bc.decode_op(inst) == .move) found_move = true;
    }
    try std.testing.expect(found_move);
}

test "compiler: closure captures outer let binding" {
    // (let* [x 10] ((fn* [y] (+ x y)) 32))  =>  42
    const result = try compileAndRun(
        \\(let* [x 10] ((fn* [y] (+ x y)) 32))
    , std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: closure captures multiple outer locals" {
    // (let* [a 100 b 20 c 3] ((fn* [] (+ a (+ b c)))))  =>  123
    const result = try compileAndRun(
        \\(let* [a 100 b 20 c 3] ((fn* [] (+ a (+ b c)))))
    , std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 123), result.asInt());
}

test "compiler: nested closures — two levels of capture" {
    // (let* [x 5] ((fn* [y] ((fn* [z] (+ x (+ y z))) 3)) 2))  =>  10
    const result = try compileAndRun(
        \\(let* [x 5] ((fn* [y] ((fn* [z] (+ x (+ y z))) 3)) 2))
    , std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 10), result.asInt());
}

test "compiler: closure as higher-order return value" {
    // (let* [make-adder (fn* [x] (fn* [y] (+ x y)))
    //        add5 (make-adder 5)]
    //   (add5 37))  =>  42
    const result = try compileAndRun(
        \\(let* [make-adder (fn* [x] (fn* [y] (+ x y))) add5 (make-adder 5)] (add5 37))
    , std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: closure with recur still works" {
    // (let* [base 1000
    //        sum (fn* [n acc] (if (<= n 0) (+ acc base) (recur (- n 1) (+ acc n))))]
    //   (sum 10 0))  =>  1055
    const result = try compileAndRun(
        \\(let* [base 1000 sum (fn* [n acc] (if (<= n 0) (+ acc base) (recur (- n 1) (+ acc n))))] (sum 10 0))
    , std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 1055), result.asInt());
}

test "compiler: builtin inc called from bytecode" {
    const result = try compileAndRunWithBuiltins("(inc 41)", std.testing.allocator, true);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: builtin dec called from bytecode" {
    const result = try compileAndRunWithBuiltins("(dec 43)", std.testing.allocator, true);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: builtin zero? from bytecode" {
    const r1 = try compileAndRunWithBuiltins("(zero? 0)", std.testing.allocator, true);
    try std.testing.expect(r1.isBool());
    try std.testing.expect(r1.asBool());
    const r2 = try compileAndRunWithBuiltins("(zero? 5)", std.testing.allocator, true);
    try std.testing.expect(r2.isBool());
    try std.testing.expect(!r2.asBool());
}

test "compiler: builtin not from bytecode" {
    const r1 = try compileAndRunWithBuiltins("(not false)", std.testing.allocator, true);
    try std.testing.expect(r1.isBool());
    try std.testing.expect(r1.asBool());
    const r2 = try compileAndRunWithBuiltins("(not true)", std.testing.allocator, true);
    try std.testing.expect(r2.isBool());
    try std.testing.expect(!r2.asBool());
}

test "compiler: builtin in recursive loop" {
    // Use inc as a builtin inside a recur loop
    const result = try compileAndRunWithBuiltins(
        \\(let* [count-up (fn* [n acc] (if (= n 0) acc (recur (- n 1) (inc acc))))]
        \\  (count-up 100 0))
    , std.testing.allocator, true);
    try std.testing.expectEqual(@as(i48, 100), result.asInt());
}

test "compiler: chained builtins" {
    // (inc (inc (dec 42)))  =>  43
    const result = try compileAndRunWithBuiltins("(inc (inc (dec 42)))", std.testing.allocator, true);
    try std.testing.expectEqual(@as(i48, 43), result.asInt());
}

// ── Variadic arithmetic ──

test "compiler: variadic + (3 args)" {
    const result = try compileAndRun("(+ 1 2 3)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 6), result.asInt());
}

test "compiler: variadic + (5 args)" {
    const result = try compileAndRun("(+ 10 20 30 40 50)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 150), result.asInt());
}

test "compiler: variadic * (4 args)" {
    const result = try compileAndRun("(* 2 3 4 5)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 120), result.asInt());
}

test "compiler: unary negate" {
    const result = try compileAndRun("(- 42)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, -42), result.asInt());
}

test "compiler: variadic < (chained comparison)" {
    const r1 = try compileAndRun("(< 1 2 3)", std.testing.allocator);
    try std.testing.expect(r1.asBool());
    const r2 = try compileAndRun("(< 1 3 2)", std.testing.allocator);
    try std.testing.expect(!r2.asBool());
}

test "compiler: variadic = (all equal)" {
    const r1 = try compileAndRun("(= 5 5 5)", std.testing.allocator);
    try std.testing.expect(r1.asBool());
    const r2 = try compileAndRun("(= 5 5 6)", std.testing.allocator);
    try std.testing.expect(!r2.asBool());
}

// ── and/or ──

test "compiler: and — all truthy" {
    const result = try compileAndRun("(and 1 2 3)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 3), result.asInt());
}

test "compiler: and — short-circuit on false" {
    const result = try compileAndRun("(and 1 false 3)", std.testing.allocator);
    try std.testing.expect(result.isBool());
    try std.testing.expect(!result.asBool());
}

test "compiler: or — first truthy" {
    const result = try compileAndRun("(or false nil 42)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: or — all falsy" {
    const result = try compileAndRun("(or false nil false)", std.testing.allocator);
    try std.testing.expect(!result.isTruthy());
}

// ── when/cond ──

test "compiler: when — true" {
    const result = try compileAndRun("(when true 1 2 42)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: when — false" {
    const result = try compileAndRun("(when false 42)", std.testing.allocator);
    try std.testing.expect(result.isNil());
}

test "compiler: cond — first match" {
    const result = try compileAndRun("(cond false 1 true 42)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: cond — else clause" {
    const result = try compileAndRun("(cond false 1 false 2 :else 99)", std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 99), result.asInt());
}

test "compiler: cond — no match, no else" {
    const result = try compileAndRun("(cond false 1 false 2)", std.testing.allocator);
    try std.testing.expect(result.isNil());
}

// ── defn ──

test "compiler: defn basic" {
    const result = try compileAndRun(
        \\(do (defn double [x] (* x 2)) (double 21))
    , std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "compiler: defn with multiple body forms" {
    const result = try compileAndRun(
        \\(do (defn add-and-double [a b] (let* [s (+ a b)] (* s 2))) (add-and-double 10 11))
    , std.testing.allocator);
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}
