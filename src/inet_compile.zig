//! INET_COMPILE: Lambda calculus → Interaction net compiler
//!
//! Lamping's algorithm: compile nanoclj expressions into γ/δ/ε nets
//! for optimal sharing. This is the bridge between the Clojure evaluator
//! and the interaction net reducer.
//!
//! Compilation scheme (simplified Lamping):
//!   Literal v     → γ cell with payload v, arity 0
//!   (fn* [x] M)   → γ cell: aux[0] = binder port, aux[1] = body net
//!   (f arg)        → γ cell: aux[0] = f net, aux[1] = arg net
//!   symbol x       → wire to binder (tracked in scope)
//!   multi-use x    → δ (duplicator) fan-out from binder
//!   unused x       → ε (eraser) on binder port
//!
//! The result is a net whose root port carries the final value after reduction.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const inet = @import("inet.zig");
const Net = inet.Net;
const Port = inet.Port;
const CellKind = inet.CellKind;

/// Scope: tracks variable bindings (name → port where the binder lives)
pub const Scope = struct {
    bindings: std.StringHashMap(BindInfo),
    parent: ?*Scope,

    const BindInfo = struct {
        port: Port,   // where the variable's value is available
        uses: u16,    // how many times referenced (for dup/erase)
    };

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .bindings = std.StringHashMap(BindInfo).init(allocator),
            .parent = parent,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.bindings.deinit();
    }

    fn lookup(self: *const Scope, name: []const u8) ?BindInfo {
        if (self.bindings.get(name)) |info| return info;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    fn bind(self: *Scope, name: []const u8, port: Port) !void {
        try self.bindings.put(name, .{ .port = port, .uses = 0 });
    }

    fn markUsed(self: *Scope, name: []const u8) void {
        if (self.bindings.getPtr(name)) |info| {
            info.uses += 1;
            return;
        }
        if (self.parent) |p| p.markUsed(name);
    }
};

/// Compile a nanoclj Value into an interaction net.
/// Returns the "root port" — the port where the result will appear after reduction.
pub const CompileError = error{ Overflow, OutOfMemory, InvalidArgument };

pub fn compile(net: *Net, val: Value, gc: *GC, scope: *Scope) CompileError!Port {
    // Literal: nil, bool, int, string, keyword
    if (val.isNil() or val.isBool() or val.isInt() or val.isString() or val.isKeyword()) {
        const cell = try net.addCell(.gamma, 0, val);
        return Port.principal(cell);
    }

    // Symbol: variable reference
    if (val.isSymbol()) {
        const name = gc.getString(val.asSymbolId());
        if (scope.lookup(name)) |info| {
            scope.markUsed(name);
            return info.port;
        }
        // Free variable: wrap as literal symbol
        const cell = try net.addCell(.gamma, 0, val);
        return Port.principal(cell);
    }

    if (!val.isObj()) {
        const cell = try net.addCell(.gamma, 0, val);
        return Port.principal(cell);
    }

    const obj = val.asObj();

    // Vector literal: γ cell with arity = len, each element compiled to aux port
    if (obj.kind == .vector) {
        const items = obj.data.vector.items.items;
        const arity: u8 = @intCast(@min(items.len, 255));
        const cell = try net.addCell(.gamma, arity, Value.makeNil());
        for (items, 0..) |item, i| {
            if (i >= 255) break;
            const child_port = try compile(net, item, gc, scope);
            try net.connect(Port.aux(cell, @intCast(i)), child_port);
        }
        return Port.principal(cell);
    }

    // Not a list: wrap as literal
    if (obj.kind != .list) {
        const cell = try net.addCell(.gamma, 0, val);
        return Port.principal(cell);
    }

    const items = obj.data.list.items.items;
    if (items.len == 0) {
        const cell = try net.addCell(.gamma, 0, val);
        return Port.principal(cell);
    }

    // Check for special forms
    if (items[0].isSymbol()) {
        const name = gc.getString(items[0].asSymbolId());

        // (fn* [x] body) → lambda node
        if (std.mem.eql(u8, name, "fn*") and items.len >= 3) {
            return compileLambda(net, items, gc, scope);
        }

        // (quote v) → literal
        if (std.mem.eql(u8, name, "quote") and items.len == 2) {
            const cell = try net.addCell(.gamma, 0, items[1]);
            return Port.principal(cell);
        }

        // (if cond then else) → σ(then, else) connected to cond
        // Level 5: both branches compile into the net and reduce in parallel.
        // When cond reduces to γ(bool), the σ-γ rule selects one branch.
        if (std.mem.eql(u8, name, "if") and items.len >= 3) {
            const cond_port = try compile(net, items[1], gc, scope);
            const then_port = try compile(net, items[2], gc, scope);
            const else_port = if (items.len >= 4)
                try compile(net, items[3], gc, scope)
            else
                Port.principal(try net.addCell(.gamma, 0, Value.makeNil()));

            // σ cell: arity 2, aux[0]=then, aux[1]=else
            const sup = try net.addCell(.sup, 2, Value.makeNil());
            try net.connect(Port.aux(sup, 0), then_port);
            try net.connect(Port.aux(sup, 1), else_port);
            // Active pair: σ principal meets condition
            try net.connect(Port.principal(sup), cond_port);
            return Port.principal(sup);
        }
    }

    // Application: (f arg1 arg2 ...)
    // Binary application chain: ((f arg1) arg2) ...
    var func_port = try compile(net, items[0], gc, scope);
    for (items[1..]) |arg| {
        const arg_port = try compile(net, arg, gc, scope);
        // Application node: γ cell with aux[0]=func, aux[1]=arg
        const app = try net.addCell(.gamma, 2, Value.makeNil());
        try net.connect(Port.aux(app, 0), func_port);
        try net.connect(Port.aux(app, 1), arg_port);
        func_port = Port.principal(app);
    }
    return func_port;
}

fn compileLambda(net: *Net, items: []Value, gc: *GC, scope: *Scope) CompileError!Port {
    // items[1] = parameter vector, items[2..] = body forms
    if (!items[1].isObj()) {
        const cell = try net.addCell(.gamma, 0, Value.makeNil());
        return Port.principal(cell);
    }
    const params_obj = items[1].asObj();
    const params = if (params_obj.kind == .vector)
        params_obj.data.vector.items.items
    else if (params_obj.kind == .list)
        params_obj.data.list.items.items
    else {
        const cell = try net.addCell(.gamma, 0, Value.makeNil());
        return Port.principal(cell);
    };

    // Lambda node: γ with arity = 1 + params.len (body + binders)
    const arity: u8 = @intCast(@min(1 + params.len, 255));
    const lam = try net.addCell(.gamma, arity, Value.makeNil());

    // Create child scope with binder ports
    var child_scope = Scope.init(net.allocator, scope);
    defer child_scope.deinit();

    for (params, 0..) |p, i| {
        if (!p.isSymbol()) continue;
        const pname = gc.getString(p.asSymbolId());
        // Each parameter gets a port on the lambda node
        try child_scope.bind(pname, Port.aux(lam, @intCast(1 + i)));
    }

    // Compile body (last form is the result)
    var body_port = Port.principal(lam); // default
    for (items[2..]) |form| {
        body_port = try compile(net, form, gc, &child_scope);
    }
    // Wire body result to lambda's first aux port
    try net.connect(Port.aux(lam, 0), body_port);

    // Handle unused parameters: attach erasers
    for (params, 0..) |p, i| {
        if (!p.isSymbol()) continue;
        const pname = gc.getString(p.asSymbolId());
        const info = child_scope.bindings.get(pname) orelse continue;
        if (info.uses == 0) {
            const eps = try net.addCell(.epsilon, 0, Value.makeNil());
            try net.connect(Port.aux(lam, @intCast(1 + i)), Port.principal(eps));
        }
    }

    return Port.principal(lam);
}

// ============================================================================
// BUILTIN: (inet-compile net-id quoted-expr) → root-cell-index
// ============================================================================

pub fn inetCompileFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.InvalidArgument;
    if (!args[0].isInt()) return error.InvalidArgument;

    const inet_builtins = @import("inet_builtins.zig");
    const net = try inet_builtins.getNetPub(args[0]);

    var scope = Scope.init(net.allocator, null);
    defer scope.deinit();

    const root = try compile(net, args[1], gc, &scope);
    return Value.makeInt(@intCast(root.cell));
}

// ============================================================================
// READBACK: Interaction net → Value
// ============================================================================

/// Read back a Value from a cell in a reduced net.
/// Walks the net from the given cell, reconstructing nanoclj values.
///   γ(arity=0, payload=v)   → v (literal)
///   γ(arity=N, payload=nil) → vector of readback(aux children)
///   ε / dead cell           → nil
pub fn readback(net: *const Net, cell_idx: u16, gc: *GC) !Value {
    if (cell_idx >= net.cells.items.len) return Value.makeNil();
    const cell = net.cells.items[cell_idx];
    if (!cell.alive) return Value.makeNil();

    // Literal: arity 0, payload carries the value
    if (cell.arity == 0) {
        return cell.payload;
    }

    // Eraser: return nil
    if (cell.kind == .epsilon) return Value.makeNil();

    // Compound: collect children from aux ports into a vector
    const vec = try gc.allocObj(.vector);
    for (1..@as(usize, cell.arity) + 1) |port_n| {
        const port = Port{ .cell = cell_idx, .port = @intCast(port_n) };
        const connected = net.findConnected(port);
        if (connected) |cp| {
            const child_val = try readback(net, cp.cell, gc);
            try vec.data.vector.items.append(gc.allocator, child_val);
        } else {
            try vec.data.vector.items.append(gc.allocator, Value.makeNil());
        }
    }
    return Value.makeObj(vec);
}

/// (inet-readback net-id cell-idx) → Value
pub fn inetReadbackFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.InvalidArgument;
    const ib = @import("inet_builtins.zig");
    const net = try ib.getNetPub(args[0]);
    if (!args[1].isInt()) return error.InvalidArgument;
    const raw_idx = args[1].asInt();
    if (raw_idx < 0) return error.InvalidArgument;
    const cell_idx: u16 = std.math.cast(u16, raw_idx) orelse return error.InvalidArgument;
    return readback(net, cell_idx, gc);
}

/// (inet-eval quoted-expr) → Value
/// The full pipeline: compile → reduce → readback in one call.
pub fn inetEvalFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1) return error.InvalidArgument;

    // Create a fresh net
    const alloc = gc.allocator;
    var net = Net.init(alloc);
    defer net.deinit();

    // Compile
    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    const root = try compile(&net, args[0], gc, &scope);

    // Reduce
    const transitivity = @import("transitivity.zig");
    var res = transitivity.Resources.initDefault();
    _ = try net.reduceAll(&res);

    // Readback
    return readback(&net, root.cell, gc);
}

// ============================================================================
// TESTS
// ============================================================================

test "compile literal" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var net = Net.init(std.testing.allocator);
    defer net.deinit();
    var scope = Scope.init(std.testing.allocator, null);
    defer scope.deinit();

    const root = try compile(&net, Value.makeInt(42), &gc, &scope);
    try std.testing.expectEqual(@as(u8, 0), root.port); // principal
    try std.testing.expectEqual(@as(usize, 1), net.liveCells());
    // Cell should hold the literal
    try std.testing.expectEqual(CellKind.gamma, net.cells.items[root.cell].kind);
}

test "compile application" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var net = Net.init(std.testing.allocator);
    defer net.deinit();
    var scope = Scope.init(std.testing.allocator, null);
    defer scope.deinit();

    // Build (f 42) where f is a free variable
    const f_sym = try gc.internString("f");
    const list = try gc.allocObj(.list);
    try list.data.list.items.append(gc.allocator, Value.makeSymbol(f_sym));
    try list.data.list.items.append(gc.allocator, Value.makeInt(42));

    const root = try compile(&net, Value.makeObj(list), &gc, &scope);
    // Should have: γ(f), γ(42), γ(app) = 3 cells
    try std.testing.expectEqual(@as(usize, 3), net.liveCells());
    try std.testing.expectEqual(@as(u8, 0), root.port);
    // App cell has arity 2
    try std.testing.expectEqual(@as(u8, 2), net.cells.items[root.cell].arity);
}

test "compile lambda with unused param" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var net = Net.init(std.testing.allocator);
    defer net.deinit();
    var scope = Scope.init(std.testing.allocator, null);
    defer scope.deinit();

    // Build (fn* [x] 42)
    const fn_sym = try gc.internString("fn*");
    const x_sym = try gc.internString("x");

    const params = try gc.allocObj(.vector);
    try params.data.vector.items.append(gc.allocator, Value.makeSymbol(x_sym));

    const list = try gc.allocObj(.list);
    try list.data.list.items.append(gc.allocator, Value.makeSymbol(fn_sym));
    try list.data.list.items.append(gc.allocator, Value.makeObj(params));
    try list.data.list.items.append(gc.allocator, Value.makeInt(42));

    const root = try compile(&net, Value.makeObj(list), &gc, &scope);
    // Lambda cell + literal 42 + eraser for unused x = 3 cells
    try std.testing.expectEqual(@as(usize, 3), net.liveCells());
    _ = root;
}

test "compile vector" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var net = Net.init(std.testing.allocator);
    defer net.deinit();
    var scope = Scope.init(std.testing.allocator, null);
    defer scope.deinit();

    // Build [1 2 3]
    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(2));
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(3));

    const root = try compile(&net, Value.makeObj(vec), &gc, &scope);
    // Container γ(arity 3) + 3 literal γ cells = 4
    try std.testing.expectEqual(@as(usize, 4), net.liveCells());
    try std.testing.expectEqual(@as(u8, 3), net.cells.items[root.cell].arity);
}

test "readback literal roundtrip" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var net = Net.init(std.testing.allocator);
    defer net.deinit();
    var scope = Scope.init(std.testing.allocator, null);
    defer scope.deinit();

    // Compile 42, readback should give 42
    const root = try compile(&net, Value.makeInt(42), &gc, &scope);
    const result = try readback(&net, root.cell, &gc);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}

test "readback vector roundtrip" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var net = Net.init(std.testing.allocator);
    defer net.deinit();
    var scope = Scope.init(std.testing.allocator, null);
    defer scope.deinit();

    // Compile [1 2], readback
    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const root = try compile(&net, Value.makeObj(vec), &gc, &scope);
    const result = try readback(&net, root.cell, &gc);
    // Should be a vector [1 2]
    try std.testing.expect(result.isObj());
    const robj = result.asObj();
    try std.testing.expectEqual(ObjKind.vector, robj.kind);
    try std.testing.expectEqual(@as(usize, 2), robj.data.vector.items.items.len);
    try std.testing.expectEqual(@as(i48, 1), robj.data.vector.items.items[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), robj.data.vector.items.items[1].asInt());
}

test "inet-eval end-to-end" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    // (inet-eval '42) → 42
    var args = [_]Value{Value.makeInt(42)};
    const result = try inetEvalFn(&args, &gc, &env);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i48, 42), result.asInt());
}
