//! BYTECODE: Register-based VM for nanoclj-zig
//!
//! 32-bit fixed-width instructions (Janet/Lua-style):
//!   OP(8) | A(8) | B(8) | C(8)     — 3-arg
//!   OP(8) | A(8) | E(16)           — 2-arg (A + extended)
//!   OP(8) | D(24)                  — 1-arg (signed/unsigned)
//!
//! Design principle: minimal Kolmogorov complexity. Every opcode must
//! reduce total program size or it doesn't belong. The kernel is the
//! irreducible core that generates the full language.
//!
//! WASM-targetable: no OS-specific calls in the VM loop itself.
//! Fuel-bounded: every instruction costs 1 fuel tick.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

// ============================================================================
// OPCODES: The irreducible kernel (22 instructions)
// ============================================================================

pub const Op = enum(u8) {
    // Control flow (5)
    ret,          // return $D
    ret_nil,      // return nil
    jump,         // pc += DS (signed 24-bit)
    jump_if,      // if truthy($A): pc += ES
    jump_if_not,  // if falsy($A): pc += ES

    // Constants & moves (5)
    load_nil,     // $D = nil
    load_true,    // $D = true
    load_false,   // $D = false
    load_int,     // $A = ES (16-bit signed immediate)
    load_const,   // $A = constants[E]

    // Arithmetic (6)
    add,          // $A = $B + $C
    sub,          // $A = $B - $C
    mul,          // $A = $B * $C
    div,          // $A = $B / $C (float division)
    quot,         // $A = $B ÷ $C (integer truncating division)
    rem,          // $A = $B % $C (integer remainder)

    // Comparison (3)
    eq,           // $A = ($B == $C)
    lt,           // $A = ($B < $C)
    lte,          // $A = ($B <= $C)

    // Function calls (3)
    call,         // $A = call(R[A+1], R[A+2..A+1+B]) with B args
    tail_call,    // return call(R[A], R[A+1..A+B]) with B args
    closure,      // $A = make_closure(defs[E])

    // Data movement (1)
    move,         // $A = $B  (register copy)

    // Globals (2)
    get_global,   // $A = globals[constants[E]]
    set_global,   // globals[constants[E]] = $A
};

// ============================================================================
// INSTRUCTION ENCODING/DECODING
// ============================================================================

pub const Inst = u32;

pub inline fn encode_abc(op: Op, a: u8, b: u8, c: u8) Inst {
    return @as(u32, @intFromEnum(op)) |
        (@as(u32, a) << 8) |
        (@as(u32, b) << 16) |
        (@as(u32, c) << 24);
}

pub inline fn encode_ae(op: Op, a: u8, e: u16) Inst {
    return @as(u32, @intFromEnum(op)) |
        (@as(u32, a) << 8) |
        (@as(u32, e) << 16);
}

pub inline fn encode_d(op: Op, d: u24) Inst {
    return @as(u32, @intFromEnum(op)) |
        (@as(u32, d) << 8);
}

pub inline fn decode_op(inst: Inst) Op {
    return @enumFromInt(@as(u8, @truncate(inst)));
}

pub inline fn decode_a(inst: Inst) u8 {
    return @truncate(inst >> 8);
}

pub inline fn decode_b(inst: Inst) u8 {
    return @truncate(inst >> 16);
}

pub inline fn decode_c(inst: Inst) u8 {
    return @truncate(inst >> 24);
}

pub inline fn decode_e(inst: Inst) u16 {
    return @truncate(inst >> 16);
}

pub inline fn decode_d(inst: Inst) u24 {
    return @truncate(inst >> 8);
}

pub inline fn decode_ds(inst: Inst) i24 {
    return @bitCast(decode_d(inst));
}

pub inline fn decode_es(inst: Inst) i16 {
    return @bitCast(decode_e(inst));
}

// ============================================================================
// FUNCTION DEFINITION (bytecode + constants + sub-defs)
// ============================================================================

pub const FuncDef = struct {
    code: []const Inst,
    constants: []const Value,
    defs: []const *FuncDef,
    arity: u8,
    is_variadic: bool = false,
    num_registers: u8, // max registers used in this function
    name: ?[]const u8 = null,
};

pub const Closure = struct {
    def: *const FuncDef,
    upvalues: []Value,
};

// ============================================================================
// CALL FRAME
// ============================================================================

const CallFrame = struct {
    closure: *const Closure,
    ip: u32, // instruction pointer (index into code)
    base: u32, // base register index in the VM stack
    ret_dest: u8 = 0, // caller's register to store return value
};

// ============================================================================
// VM STATE
// ============================================================================

pub const VM = struct {
    stack: [256 * 64]Value, // 256 registers * 64 frames max
    frames: [64]CallFrame,
    frame_count: u32 = 0,
    gc: *GC,
    globals: std.StringHashMap(Value),
    fuel: u64,

    pub fn init(gc: *GC, fuel: u64) VM {
        var vm: VM = undefined;
        vm.frame_count = 0;
        vm.gc = gc;
        vm.globals = std.StringHashMap(Value).init(gc.allocator);
        vm.fuel = fuel;
        // Zero-init stack
        @memset(&vm.stack, Value.makeNil());
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit();
    }

    fn currentFrame(self: *VM) *CallFrame {
        return &self.frames[self.frame_count - 1];
    }

    fn reg(self: *VM, idx: u8) *Value {
        const base = self.currentFrame().base;
        return &self.stack[base + idx];
    }

    fn readInst(self: *VM) Inst {
        const frame = self.currentFrame();
        const inst = frame.closure.def.code[frame.ip];
        frame.ip += 1;
        return inst;
    }

    // ========================================================================
    // DISPATCH LOOP
    // ========================================================================

    pub const VMError = error{
        FuelExhausted,
        StackOverflow,
        TypeError,
        ArityError,
        UndefinedGlobal,
    };

    pub fn execute(self: *VM, closure: *const Closure) VMError!Value {
        if (self.frame_count >= 64) return error.StackOverflow;
        self.frames[self.frame_count] = .{
            .closure = closure,
            .ip = 0,
            .base = if (self.frame_count == 0) 0 else blk: {
                const prev = self.frames[self.frame_count - 1];
                break :blk prev.base + prev.closure.def.num_registers;
            },
        };
        self.frame_count += 1;

        while (true) {
            if (self.fuel == 0) return error.FuelExhausted;
            self.fuel -= 1;

            const inst = self.readInst();
            const op = decode_op(inst);

            switch (op) {
                // ── Control flow ──
                .ret => {
                    const d = decode_d(inst);
                    const frame = self.currentFrame();
                    const result = self.stack[frame.base + @as(u32, d)];
                    const ret_dest = frame.ret_dest;
                    self.frame_count -= 1;
                    if (self.frame_count == 0) return result;
                    self.reg(ret_dest).* = result;
                },
                .ret_nil => {
                    const ret_dest = self.currentFrame().ret_dest;
                    self.frame_count -= 1;
                    if (self.frame_count == 0) return Value.makeNil();
                    self.reg(ret_dest).* = Value.makeNil();
                },
                .jump => {
                    const offset = decode_ds(inst);
                    const frame = self.currentFrame();
                    frame.ip = @intCast(@as(i64, frame.ip) + @as(i64, offset));
                },
                .jump_if => {
                    const a = decode_a(inst);
                    const offset = decode_es(inst);
                    if (self.reg(a).isTruthy()) {
                        const frame = self.currentFrame();
                        frame.ip = @intCast(@as(i64, frame.ip) + @as(i64, offset));
                    }
                },
                .jump_if_not => {
                    const a = decode_a(inst);
                    const offset = decode_es(inst);
                    if (!self.reg(a).isTruthy()) {
                        const frame = self.currentFrame();
                        frame.ip = @intCast(@as(i64, frame.ip) + @as(i64, offset));
                    }
                },

                // ── Constants & moves ──
                .load_nil => self.stack[self.currentFrame().base + @as(u32, decode_d(inst))] = Value.makeNil(),
                .load_true => self.stack[self.currentFrame().base + @as(u32, decode_d(inst))] = Value.makeBool(true),
                .load_false => self.stack[self.currentFrame().base + @as(u32, decode_d(inst))] = Value.makeBool(false),
                .load_int => {
                    const a = decode_a(inst);
                    const es = decode_es(inst);
                    self.reg(a).* = Value.makeInt(@intCast(es));
                },
                .load_const => {
                    const a = decode_a(inst);
                    const e = decode_e(inst);
                    self.reg(a).* = self.currentFrame().closure.def.constants[e];
                },

                // ── Arithmetic ──
                .add => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    if (bv.isInt() and cv.isInt()) {
                        self.reg(a).* = Value.makeInt(bv.asInt() +% cv.asInt());
                    } else {
                        const bf = if (bv.isInt()) @as(f64, @floatFromInt(bv.asInt())) else bv.asFloat();
                        const cf = if (cv.isInt()) @as(f64, @floatFromInt(cv.asInt())) else cv.asFloat();
                        self.reg(a).* = Value.makeFloat(bf + cf);
                    }
                },
                .sub => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    if (bv.isInt() and cv.isInt()) {
                        self.reg(a).* = Value.makeInt(bv.asInt() -% cv.asInt());
                    } else {
                        const bf = if (bv.isInt()) @as(f64, @floatFromInt(bv.asInt())) else bv.asFloat();
                        const cf = if (cv.isInt()) @as(f64, @floatFromInt(cv.asInt())) else cv.asFloat();
                        self.reg(a).* = Value.makeFloat(bf - cf);
                    }
                },
                .mul => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    if (bv.isInt() and cv.isInt()) {
                        self.reg(a).* = Value.makeInt(bv.asInt() *% cv.asInt());
                    } else {
                        const bf = if (bv.isInt()) @as(f64, @floatFromInt(bv.asInt())) else bv.asFloat();
                        const cf = if (cv.isInt()) @as(f64, @floatFromInt(cv.asInt())) else cv.asFloat();
                        self.reg(a).* = Value.makeFloat(bf * cf);
                    }
                },
                .div => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    const bf = if (bv.isInt()) @as(f64, @floatFromInt(bv.asInt())) else bv.asFloat();
                    const cf = if (cv.isInt()) @as(f64, @floatFromInt(cv.asInt())) else cv.asFloat();
                    self.reg(a).* = Value.makeFloat(bf / cf);
                },
                .quot => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    if (bv.isInt() and cv.isInt()) {
                        const bi = bv.asInt();
                        const ci = cv.asInt();
                        if (ci == 0) return error.TypeError;
                        self.reg(a).* = Value.makeInt(@divTrunc(bi, ci));
                    } else return error.TypeError;
                },
                .rem => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    if (bv.isInt() and cv.isInt()) {
                        const bi = bv.asInt();
                        const ci = cv.asInt();
                        if (ci == 0) return error.TypeError;
                        self.reg(a).* = Value.makeInt(@rem(bi, ci));
                    } else return error.TypeError;
                },

                // ── Comparison ──
                .eq => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    self.reg(a).* = Value.makeBool(self.reg(b).eql(self.reg(c).*));
                },
                .lt => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    const bf = if (bv.isInt()) @as(f64, @floatFromInt(bv.asInt())) else bv.asFloat();
                    const cf = if (cv.isInt()) @as(f64, @floatFromInt(cv.asInt())) else cv.asFloat();
                    self.reg(a).* = Value.makeBool(bf < cf);
                },
                .lte => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    const c = decode_c(inst);
                    const bv = self.reg(b).*;
                    const cv = self.reg(c).*;
                    const bf = if (bv.isInt()) @as(f64, @floatFromInt(bv.asInt())) else bv.asFloat();
                    const cf = if (cv.isInt()) @as(f64, @floatFromInt(cv.asInt())) else cv.asFloat();
                    self.reg(a).* = Value.makeBool(bf <= cf);
                },

                // ── Function calls ──
                // CALL A, B, C: dest=A, argc=B, func_reg=C
                // Callee's args are in R[C+1..C+B]
                .call => {
                    const a = decode_a(inst);
                    const b = decode_b(inst); // argc
                    const c = decode_c(inst); // func_reg
                    const base = self.currentFrame().base;
                    const func_val = self.stack[base + c];

                    // Resolve bc_closure
                    if (!func_val.isObj()) return error.TypeError;
                    const func_obj = func_val.asObj();
                    if (func_obj.kind != .bc_closure) return error.TypeError;
                    const callee = &func_obj.data.bc_closure;

                    if (b != callee.def.arity) return error.ArityError;
                    if (self.frame_count >= 64) return error.StackOverflow;

                    // Set up new frame
                    const new_base = base + self.currentFrame().closure.def.num_registers;
                    // Copy args into callee's register space (R0..Rn-1 = params)
                    for (0..b) |i| {
                        self.stack[new_base + i] = self.stack[base + c + 1 + i];
                    }

                    self.frames[self.frame_count] = .{
                        .closure = callee,
                        .ip = 0,
                        .base = new_base,
                        .ret_dest = a, // caller's register for return value
                    };
                    self.frame_count += 1;
                },
                // TAIL_CALL A, B: func_reg=A, argc=B — reuse current frame
                .tail_call => {
                    const a = decode_a(inst);
                    const b = decode_b(inst); // argc
                    const base = self.currentFrame().base;
                    const func_val = self.stack[base + a];

                    if (!func_val.isObj()) return error.TypeError;
                    const func_obj = func_val.asObj();
                    if (func_obj.kind != .bc_closure) return error.TypeError;
                    const callee = &func_obj.data.bc_closure;

                    if (b != callee.def.arity) return error.ArityError;

                    // Copy args to base (overwrite current frame's registers)
                    for (0..b) |i| {
                        self.stack[base + i] = self.stack[base + a + 1 + i];
                    }

                    // Reuse current frame slot
                    const frame = self.currentFrame();
                    frame.closure = callee;
                    frame.ip = 0;
                    // base stays the same — that's the TCO magic
                },
                // CLOSURE A, E: $A = make_closure(defs[E])
                .closure => {
                    const a = decode_a(inst);
                    const e = decode_e(inst);
                    const frame = self.currentFrame();
                    const sub_def = frame.closure.def.defs[e];

                    // Allocate a bc_closure Obj
                    const obj = self.gc.allocObj(.bc_closure) catch return error.TypeError;
                    obj.data.bc_closure = .{
                        .def = sub_def,
                        .upvalues = &.{}, // TODO: capture upvalues
                    };
                    self.reg(a).* = Value.makeObj(obj);
                },

                // ── Data movement ──
                .move => {
                    const a = decode_a(inst);
                    const b = decode_b(inst);
                    self.reg(a).* = self.reg(b).*;
                },

                // ── Globals ──
                .get_global => {
                    const a = decode_a(inst);
                    const e = decode_e(inst);
                    const name_val = self.currentFrame().closure.def.constants[e];
                    if (name_val.isSymbol()) {
                        const name = self.gc.getString(name_val.asSymbolId());
                        if (self.globals.get(name)) |v| {
                            self.reg(a).* = v;
                        } else return error.UndefinedGlobal;
                    } else return error.TypeError;
                },
                .set_global => {
                    const a = decode_a(inst);
                    const e = decode_e(inst);
                    const name_val = self.currentFrame().closure.def.constants[e];
                    if (name_val.isSymbol()) {
                        const name = self.gc.getString(name_val.asSymbolId());
                        self.globals.put(name, self.reg(a).*) catch return error.TypeError;
                    } else return error.TypeError;
                },
            }
        }
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "bytecode: encode/decode roundtrip" {
    const inst = encode_abc(.add, 0, 1, 2);
    try std.testing.expectEqual(Op.add, decode_op(inst));
    try std.testing.expectEqual(@as(u8, 0), decode_a(inst));
    try std.testing.expectEqual(@as(u8, 1), decode_b(inst));
    try std.testing.expectEqual(@as(u8, 2), decode_c(inst));
}

test "bytecode: encode/decode AE" {
    const inst = encode_ae(.load_const, 5, 1000);
    try std.testing.expectEqual(Op.load_const, decode_op(inst));
    try std.testing.expectEqual(@as(u8, 5), decode_a(inst));
    try std.testing.expectEqual(@as(u16, 1000), decode_e(inst));
}

test "bytecode: simple add program" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Program: load 10 into R0, load 20 into R1, add R2=R0+R1, return R2
    const code = [_]Inst{
        encode_ae(.load_int, 0, @bitCast(@as(i16, 10))),
        encode_ae(.load_int, 1, @bitCast(@as(i16, 20))),
        encode_abc(.add, 2, 0, 1),
        encode_d(.ret, 2),
    };

    const def = FuncDef{
        .code = &code,
        .constants = &.{},
        .defs = &.{},
        .arity = 0,
        .num_registers = 3,
    };

    const closure = Closure{
        .def = &def,
        .upvalues = &.{},
    };

    var vm = VM.init(&gc, 1000);
    defer vm.deinit();

    const result = try vm.execute(&closure);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i48, 30), result.asInt());
}

test "bytecode: conditional jump" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Program: R0=true, if R0 jump +2, R1=0, ret R1, R1=42, ret R1
    const code = [_]Inst{
        encode_d(.load_true, 0),                        // R0 = true
        encode_ae(.jump_if, 0, @bitCast(@as(i16, 2))),  // if R0: skip 2
        encode_ae(.load_int, 1, @bitCast(@as(i16, 0))), // R1 = 0 (skipped)
        encode_d(.ret, 1),                               // return R1 (skipped)
        encode_ae(.load_int, 1, @bitCast(@as(i16, 42))),// R1 = 42
        encode_d(.ret, 1),                               // return R1
    };

    const def = FuncDef{
        .code = &code,
        .constants = &.{},
        .defs = &.{},
        .arity = 0,
        .num_registers = 2,
    };

    const closure = Closure{
        .def = &def,
        .upvalues = &.{},
    };

    var vm = VM.init(&gc, 1000);
    defer vm.deinit();

    const result = try vm.execute(&closure);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "bytecode: fuel exhaustion" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Infinite loop: jump -1 forever
    const code = [_]Inst{
        encode_d(.jump, @bitCast(@as(i24, -1))), // jump to self
    };

    const def = FuncDef{
        .code = &code,
        .constants = &.{},
        .defs = &.{},
        .arity = 0,
        .num_registers = 0,
    };

    const closure = Closure{
        .def = &def,
        .upvalues = &.{},
    };

    var vm = VM.init(&gc, 100);
    defer vm.deinit();

    const result = vm.execute(&closure);
    try std.testing.expectError(VM.VMError.FuelExhausted, result);
}

test "bytecode: function call and return" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Inner function: (fn [x] (+ x 1))
    // R0 = param x, R1 = scratch, R2 = result
    const inner_code = [_]Inst{
        encode_ae(.load_int, 1, @bitCast(@as(i16, 1))), // R1 = 1
        encode_abc(.add, 2, 0, 1),                       // R2 = R0 + R1
        encode_d(.ret, 2),                                // return R2
    };

    const inner_def = FuncDef{
        .code = &inner_code,
        .constants = &.{},
        .defs = &.{},
        .arity = 1,
        .num_registers = 3,
    };

    // Outer: create closure, load arg 10, call, return result
    // R0 = dest for result
    // R1 = closure (func_reg for call)
    // R2 = arg (10)
    const inner_def_ptr: *const FuncDef = &inner_def;
    const outer_defs = [_]*FuncDef{@constCast(inner_def_ptr)};
    const outer_code = [_]Inst{
        encode_ae(.closure, 1, 0),                        // R1 = closure(defs[0])
        encode_ae(.load_int, 2, @bitCast(@as(i16, 10))), // R2 = 10
        encode_abc(.call, 0, 1, 1),                       // R0 = call(R1, 1 arg)
        encode_d(.ret, 0),                                 // return R0
    };

    const outer_def = FuncDef{
        .code = &outer_code,
        .constants = &.{},
        .defs = &outer_defs,
        .arity = 0,
        .num_registers = 4, // need extra slot for return-dest marker
    };

    const closure = Closure{ .def = &outer_def, .upvalues = &.{} };
    var vm = VM.init(&gc, 1000);
    defer vm.deinit();

    const result = try vm.execute(&closure);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i48, 11), result.asInt());
}
