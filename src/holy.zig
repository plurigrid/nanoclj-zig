const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const eval_mod = @import("eval.zig");
const printer = @import("printer.zig");

pub const MiniValue = union(enum) {
    nil,
    int: i64,
    symbol: u32,
    cons: u32,
};

pub const ConsCell = struct {
    car: MiniValue,
    cdr: MiniValue,
};

pub const SymbolTable = struct {
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    vals: std.ArrayListUnmanaged(MiniValue) = .empty,

    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        for (self.names.items) |sym_name| allocator.free(sym_name);
        self.names.deinit(allocator);
        self.vals.deinit(allocator);
    }

    pub fn intern(self: *SymbolTable, allocator: std.mem.Allocator, sym_name: []const u8) !u32 {
        for (self.names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, sym_name)) return @intCast(i);
        }
        try self.names.append(allocator, try allocator.dupe(u8, sym_name));
        try self.vals.append(allocator, .nil);
        return @intCast(self.names.items.len - 1);
    }

    pub fn set(self: *SymbolTable, sym: u32, val: MiniValue) void {
        self.vals.items[sym] = val;
    }

    pub fn get(self: *const SymbolTable, sym: u32) MiniValue {
        return self.vals.items[sym];
    }

    pub fn name(self: *const SymbolTable, sym: u32) []const u8 {
        return self.names.items[sym];
    }
};

pub const Heap = struct {
    cells: std.ArrayListUnmanaged(ConsCell) = .empty,

    pub fn deinit(self: *Heap, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
    }

    pub fn cons(self: *Heap, allocator: std.mem.Allocator, head: MiniValue, tail: MiniValue) !MiniValue {
        try self.cells.append(allocator, .{ .car = head, .cdr = tail });
        return .{ .cons = @intCast(self.cells.items.len - 1) };
    }

    pub fn car(self: *const Heap, v: MiniValue) MiniValue {
        return self.cells.items[v.cons].car;
    }

    pub fn cdr(self: *const Heap, v: MiniValue) MiniValue {
        return self.cells.items[v.cons].cdr;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    symbols: SymbolTable = .{},
    heap: Heap = .{},
    src: []const u8 = "",
    pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Context) void {
        self.symbols.deinit(self.allocator);
        self.heap.deinit(self.allocator);
    }
};

fn skipWs(ctx: *Context) void {
    while (ctx.pos < ctx.src.len) : (ctx.pos += 1) {
        const c = ctx.src[ctx.pos];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') continue;
        break;
    }
}

fn readToken(ctx: *Context) []const u8 {
    const start = ctx.pos;
    while (ctx.pos < ctx.src.len) : (ctx.pos += 1) {
        const c = ctx.src[ctx.pos];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '(' or c == ')') break;
    }
    return ctx.src[start..ctx.pos];
}

fn parseAtom(ctx: *Context) anyerror!MiniValue {
    const tok = readToken(ctx);
    if (tok.len == 0) return .nil;

    const maybe_num = std.fmt.parseInt(i64, tok, 10) catch null;
    if (maybe_num) |n| return .{ .int = n };

    const sym = try ctx.symbols.intern(ctx.allocator, tok);
    return .{ .symbol = sym };
}

fn evalAtom(ctx: *Context) anyerror!MiniValue {
    const atom = try parseAtom(ctx);
    return switch (atom) {
        .symbol => |sym| blk: {
            const val = ctx.symbols.get(sym);
            break :blk if (val == .nil) atom else val;
        },
        else => atom,
    };
}

fn evalList(ctx: *Context) anyerror!MiniValue {
    ctx.pos += 1;
    skipWs(ctx);
    const op = readToken(ctx);
    skipWs(ctx);

    if (std.mem.eql(u8, op, "def")) {
        const sym = try parseAtom(ctx);
        if (sym != .symbol) return error.InvalidForm;
        skipWs(ctx);
        const val = try evalExpr(ctx);
        skipWs(ctx);
        if (ctx.pos >= ctx.src.len or ctx.src[ctx.pos] != ')') return error.InvalidForm;
        ctx.pos += 1;
        ctx.symbols.set(sym.symbol, val);
        return val;
    }

    if (std.mem.eql(u8, op, "list")) {
        var head: MiniValue = .nil;
        var tail: ?u32 = null;
        while (ctx.pos < ctx.src.len and ctx.src[ctx.pos] != ')') {
            const elem = try evalExpr(ctx);
            const cell = try ctx.heap.cons(ctx.allocator, elem, .nil);
            if (head == .nil) {
                head = cell;
                tail = cell.cons;
            } else {
                ctx.heap.cells.items[tail.?].cdr = cell;
                tail = cell.cons;
            }
            skipWs(ctx);
        }
        if (ctx.pos >= ctx.src.len or ctx.src[ctx.pos] != ')') return error.InvalidForm;
        ctx.pos += 1;
        return head;
    }

    if (std.mem.eql(u8, op, "first")) {
        const lst = try evalExpr(ctx);
        skipWs(ctx);
        if (ctx.pos >= ctx.src.len or ctx.src[ctx.pos] != ')') return error.InvalidForm;
        ctx.pos += 1;
        return if (lst == .cons) ctx.heap.car(lst) else .nil;
    }

    if (std.mem.eql(u8, op, "rest")) {
        const lst = try evalExpr(ctx);
        skipWs(ctx);
        if (ctx.pos >= ctx.src.len or ctx.src[ctx.pos] != ')') return error.InvalidForm;
        ctx.pos += 1;
        return if (lst == .cons) ctx.heap.cdr(lst) else .nil;
    }

    const a = try evalExpr(ctx);
    skipWs(ctx);
    const b = try evalExpr(ctx);
    skipWs(ctx);
    if (ctx.pos >= ctx.src.len or ctx.src[ctx.pos] != ')') return error.InvalidForm;
    ctx.pos += 1;

    if (a != .int or b != .int) return error.TypeError;

    if (std.mem.eql(u8, op, "+")) return .{ .int = a.int + b.int };
    if (std.mem.eql(u8, op, "-")) return .{ .int = a.int - b.int };
    if (std.mem.eql(u8, op, "*")) return .{ .int = a.int * b.int };
    if (std.mem.eql(u8, op, "/")) return .{ .int = @divTrunc(a.int, b.int) };
    return error.UnknownOperator;
}

pub fn evalExpr(ctx: *Context) anyerror!MiniValue {
    skipWs(ctx);
    if (ctx.pos >= ctx.src.len) return .nil;
    return switch (ctx.src[ctx.pos]) {
        '(' => try evalList(ctx),
        ')' => .nil,
        else => try evalAtom(ctx),
    };
}

pub fn evalString(ctx: *Context, src: []const u8) anyerror!MiniValue {
    ctx.src = src;
    ctx.pos = 0;
    return evalExpr(ctx);
}

pub fn evalAllString(ctx: *Context, src: []const u8) anyerror!MiniValue {
    ctx.src = src;
    ctx.pos = 0;
    var last: MiniValue = .nil;
    while (true) {
        skipWs(ctx);
        if (ctx.pos >= ctx.src.len) break;
        last = try evalExpr(ctx);
    }
    return last;
}

fn appendValue(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, mini: MiniValue, ctx: *const Context) !void {
    switch (mini) {
        .nil => try buf.appendSlice(allocator, "nil"),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
            try buf.appendSlice(allocator, s);
        },
        .symbol => |sym| try buf.appendSlice(allocator, ctx.symbols.name(sym)),
        .cons => {
            try buf.append(allocator, '(');
            var cursor = mini;
            var first_item = true;
            while (cursor == .cons) {
                if (!first_item) try buf.append(allocator, ' ');
                try appendValue(buf, allocator, ctx.heap.car(cursor), ctx);
                cursor = ctx.heap.cdr(cursor);
                first_item = false;
            }
            if (cursor != .nil) {
                try buf.appendSlice(allocator, " . ");
                try appendValue(buf, allocator, cursor, ctx);
            }
            try buf.append(allocator, ')');
        },
    }
}

pub fn renderAlloc(ctx: *const Context, mini: MiniValue, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try appendValue(&buf, allocator, mini, ctx);
    return try allocator.dupe(u8, buf.items);
}

pub fn holyEvalFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    var ctx = Context.init(gc.allocator);
    defer ctx.deinit();

    const src = gc.getString(args[0].asStringId());
    const result = try evalAllString(&ctx, src);
    const rendered = try renderAlloc(&ctx, result, gc.allocator);
    defer gc.allocator.free(rendered);
    return Value.makeString(try gc.internString(rendered));
}

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn evalAllNanoclj(src: []const u8, env: *Env, gc: *GC) anyerror!Value {
    var reader = Reader.init(src, gc);
    var last = Value.makeNil();
    while (true) {
        const form = reader.readForm() catch |err| switch (err) {
            error.UnexpectedEOF => break,
            else => return err,
        };
        last = try eval_mod.eval(form, env, gc);
    }
    return last;
}

pub fn holyConvergeFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const src = gc.getString(args[0].asStringId());

    var holy_ctx = Context.init(gc.allocator);
    defer holy_ctx.deinit();
    const holy_result = try evalAllString(&holy_ctx, src);
    const holy_rendered = try renderAlloc(&holy_ctx, holy_result, gc.allocator);
    defer gc.allocator.free(holy_rendered);

    const nanoclj_result = try evalAllNanoclj(src, env, gc);
    const nanoclj_rendered = try printer.prStr(nanoclj_result, gc, true);
    defer gc.allocator.free(nanoclj_rendered);

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "holy", Value.makeString(try gc.internString(holy_rendered)));
    try addKV(obj, gc, "nanoclj", Value.makeString(try gc.internString(nanoclj_rendered)));
    try addKV(obj, gc, "converged", Value.makeBool(std.mem.eql(u8, holy_rendered, nanoclj_rendered)));
    return Value.makeObj(obj);
}

pub fn holyConvergeTraceFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const src = gc.getString(args[0].asStringId());
    var holy_ctx = Context.init(gc.allocator);
    defer holy_ctx.deinit();
    holy_ctx.src = src;
    holy_ctx.pos = 0;

    var reader = Reader.init(src, gc);
    const vec = try gc.allocObj(.vector);

    var idx: i48 = 0;
    while (true) {
        skipWs(&holy_ctx);
        const holy_done = holy_ctx.pos >= holy_ctx.src.len;

        const maybe_form = reader.readForm() catch |err| switch (err) {
            error.UnexpectedEOF => null,
            else => return err,
        };

        if (holy_done and maybe_form == null) break;
        if (holy_done or maybe_form == null) return error.InvalidForm;

        const holy_result = try evalExpr(&holy_ctx);
        const holy_rendered = try renderAlloc(&holy_ctx, holy_result, gc.allocator);
        defer gc.allocator.free(holy_rendered);

        const nanoclj_result = try eval_mod.eval(maybe_form.?, env, gc);
        const nanoclj_rendered = try printer.prStr(nanoclj_result, gc, true);
        defer gc.allocator.free(nanoclj_rendered);

        const step = try gc.allocObj(.map);
        try addKV(step, gc, "index", Value.makeInt(idx));
        try addKV(step, gc, "holy", Value.makeString(try gc.internString(holy_rendered)));
        try addKV(step, gc, "nanoclj", Value.makeString(try gc.internString(nanoclj_rendered)));
        try addKV(step, gc, "converged", Value.makeBool(std.mem.eql(u8, holy_rendered, nanoclj_rendered)));
        try vec.data.vector.items.append(gc.allocator, Value.makeObj(step));
        idx += 1;
    }

    return Value.makeObj(vec);
}

pub fn holyConvergeSummaryFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    const trace_val = try holyConvergeTraceFn(args, gc, env);
    if (!trace_val.isObj() or trace_val.asObj().kind != .vector) return error.EvalFailed;

    const steps = trace_val.asObj().data.vector.items.items;
    var converged_count: i48 = 0;
    var last_holy = Value.makeNil();
    var last_nanoclj = Value.makeNil();

    for (steps) |step_val| {
        if (!step_val.isObj() or step_val.asObj().kind != .map) continue;
        const step = step_val.asObj();
        for (step.data.map.keys.items, 0..) |k, i| {
            if (!k.isKeyword()) continue;
            const name = gc.getString(k.asKeywordId());
            const v = step.data.map.vals.items[i];
            if (std.mem.eql(u8, name, "converged") and v.isBool() and v.asBool()) {
                converged_count += 1;
            } else if (std.mem.eql(u8, name, "holy")) {
                last_holy = v;
            } else if (std.mem.eql(u8, name, "nanoclj")) {
                last_nanoclj = v;
            }
        }
    }

    const total: i48 = @intCast(steps.len);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "forms", Value.makeInt(total));
    try addKV(obj, gc, "converged", Value.makeInt(converged_count));
    try addKV(obj, gc, "diverged", Value.makeInt(total - converged_count));
    try addKV(obj, gc, "all-converged", Value.makeBool(converged_count == total));
    try addKV(obj, gc, "last-holy", last_holy);
    try addKV(obj, gc, "last-nanoclj", last_nanoclj);
    return Value.makeObj(obj);
}

fn expectEvalInt(ctx: *Context, src: []const u8, want: i64) !void {
    try std.testing.expectEqual(MiniValue{ .int = want }, try evalString(ctx, src));
}

fn expectRendered(ctx: *Context, mini: MiniValue, want: []const u8) !void {
    const rendered = try renderAlloc(ctx, mini, std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(want, rendered);
}

test "holyzig arithmetic is single-pass and nested" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try expectEvalInt(&ctx, "(* (+ 1 2) (+ 3 4))", 21);
}

test "holyzig symbol table supports def and lookup" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    _ = try evalString(&ctx, "(def answer 42)");
    try expectEvalInt(&ctx, "(+ answer 8)", 50);
}

test "holyzig list, first, rest, and rendering" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const lst = try evalString(&ctx, "(list 1 2 3)");
    const first = try evalString(&ctx, "(first (list 10 20 30))");
    const rest = try evalString(&ctx, "(rest (list 10 20 30))");

    try std.testing.expectEqual(MiniValue{ .int = 10 }, first);
    try expectRendered(&ctx, lst, "(1 2 3)");
    try expectRendered(&ctx, rest, "(20 30)");
}

test "holyzig builtin evaluates string source" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(+ 9 (* 2 3))");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try holyEvalFn(&args, &gc, &env);
    try std.testing.expect(out.isString());
    try std.testing.expectEqualStrings("15", gc.getString(out.asStringId()));
}

test "holyzig builtin supports sequential forms" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(def answer 42) (+ answer 8)");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try holyEvalFn(&args, &gc, &env);
    try std.testing.expect(out.isString());
    try std.testing.expectEqualStrings("50", gc.getString(out.asStringId()));
}

test "holyzig convergence agrees with nanoclj on defs and symbols" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(def answer 42) answer");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try holyConvergeFn(&args, &gc, &env);
    try std.testing.expect(out.isObj());
    try std.testing.expect(out.asObj().kind == .map);
}

test "holyzig convergence trace returns one entry per top-level form" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(def answer 42) answer");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try holyConvergeTraceFn(&args, &gc, &env);
    try std.testing.expect(out.isObj());
    try std.testing.expect(out.asObj().kind == .vector);
    try std.testing.expectEqual(@as(usize, 2), out.asObj().data.vector.items.items.len);
}

test "holyzig convergence summary counts converged steps" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(def answer 42) answer");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try holyConvergeSummaryFn(&args, &gc, &env);
    try std.testing.expect(out.isObj());
    try std.testing.expect(out.asObj().kind == .map);
}
