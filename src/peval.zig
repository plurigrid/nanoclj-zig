//! PEVAL: Partial Evaluation — First Futamura Projection
//!
//! spec(interpreter, program) = compiled_program
//!
//! At load time, walk the environment and compile constant expressions
//! through the interaction net (Lamping/Lafont optimal reduction).
//! This collapses all compile-time-known computation before the REPL starts.
//!
//! In category theory: left Kan extension along the embedding of
//! "compile-time-known" into "all values".
//!
//! Three modes:
//!   1. pevalExpr   — single expression: compile → reduce → readback
//!   2. pevalEnv    — walk all env bindings, PE constant defs
//!   3. pevalPrelude — read a file of defs, PE each one

const std = @import("std");
const Value = @import("value.zig").Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const inet = @import("inet.zig");
const Net = inet.Net;
const inet_compile = @import("inet_compile.zig");
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;
const Reader = @import("reader.zig").Reader;
const eval_mod = @import("eval.zig");

/// Is this value a ground term (no free variables, no side effects)?
/// Ground terms can be safely evaluated at compile time.
pub fn isGroundPublic(val: Value, gc: *GC, env: *const Env) bool {
    return isGround(val, gc, env);
}

fn isGround(val: Value, gc: *GC, env: *const Env) bool {
    if (val.isNil() or val.isBool() or val.isInt() or
        val.isString() or val.isKeyword())
    {
        return true;
    }

    if (val.isSymbol()) {
        const name = gc.getString(val.asSymbolId());
        // A symbol is ground iff it's bound to a ground value
        return env.get(name) != null;
    }

    if (!val.isObj()) return true;
    const obj = val.asObj();

    // Vectors: ground iff all elements are ground
    if (obj.kind == .vector) {
        for (obj.data.vector.items.items) |item| {
            if (!isGround(item, gc, env)) return false;
        }
        return true;
    }

    // Lists: check for safe forms
    if (obj.kind != .list) return false;
    const items = obj.data.list.items.items;
    if (items.len == 0) return true;

    if (items[0].isSymbol()) {
        const head = gc.getString(items[0].asSymbolId());
        // Side-effecting forms are NOT ground
        if (std.mem.eql(u8, head, "def!")) return false;
        if (std.mem.eql(u8, head, "println")) return false;
        if (std.mem.eql(u8, head, "nrepl-start")) return false;
        if (std.mem.eql(u8, head, "bci-read")) return false;
        if (std.mem.eql(u8, head, "http-fetch")) return false;

        // quote is always ground
        if (std.mem.eql(u8, head, "quote")) return true;

        // fn* is ground (it's a value constructor)
        if (std.mem.eql(u8, head, "fn*")) return true;

        // let*, if, do: ground iff all subforms are ground
        if (std.mem.eql(u8, head, "let*") or
            std.mem.eql(u8, head, "if") or
            std.mem.eql(u8, head, "do"))
        {
            for (items[1..]) |sub| {
                if (!isGround(sub, gc, env)) return false;
            }
            return true;
        }

        // Application of known builtin to ground args
        if (env.get(head) != null) {
            for (items[1..]) |arg| {
                if (!isGround(arg, gc, env)) return false;
            }
            return true;
        }
    }

    return false;
}

/// Partially evaluate a single expression through the interaction net.
/// Returns the reduced value, or null if PE fails/is not applicable.
pub fn pevalExpr(val: Value, gc: *GC, env: *Env) ?Value {
    if (!isGround(val, gc, env)) return null;

    // Literals don't need PE
    if (val.isNil() or val.isBool() or val.isInt() or
        val.isString() or val.isKeyword())
    {
        return val;
    }

    // Try inet path: compile → reduce → readback
    var net = Net.init(gc.allocator);
    defer net.deinit();

    var scope = inet_compile.Scope.init(gc.allocator, null);
    defer scope.deinit();

    const root = inet_compile.compile(&net, val, gc, &scope) catch return null;

    var res = Resources.init(.{ .max_fuel = 10_000 });
    _ = net.reduceAll(&res) catch return null;

    return inet_compile.readback(&net, root.cell, gc) catch null;
}

/// Walk the root environment and partially evaluate all constant bindings.
/// Returns the number of bindings that were successfully PE'd.
pub fn pevalEnv(env: *Env, gc: *GC) usize {
    var count: usize = 0;
    var it = env.bindings.iterator();
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;
        // Skip builtins (keywords are builtin sentinels)
        if (val.isKeyword()) continue;
        // Skip non-ground values
        if (!isGround(val, gc, env)) continue;
        // Skip values that are already literals
        if (val.isNil() or val.isBool() or val.isInt() or
            val.isString())
        {
            continue;
        }

        if (pevalExpr(val, gc, env)) |reduced| {
            entry.value_ptr.* = reduced;
            count += 1;
        }
    }
    return count;
}

/// Load and partially evaluate a prelude file.
/// Each top-level form is read, evaluated (to handle def!), then
/// constant bindings are PE'd through inet.
/// Returns (defs_evaluated, defs_pevalued).
pub fn pevalPrelude(path: []const u8, env: *Env, gc: *GC) !struct { evaluated: usize, pevalued: usize } {
    const allocator = gc.allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch return .{ .evaluated = 0, .pevalued = 0 };
    defer file.close();

    const src = file.readToEndAlloc(allocator, 1 << 20) catch return .{ .evaluated = 0, .pevalued = 0 };
    defer allocator.free(src);

    var evaluated: usize = 0;
    var pos: usize = 0;

    while (pos < src.len) {
        // Skip whitespace
        while (pos < src.len and (src[pos] == ' ' or src[pos] == '\n' or
            src[pos] == '\r' or src[pos] == '\t' or src[pos] == ','))
        {
            pos += 1;
        }
        if (pos >= src.len) break;

        var reader = Reader.init(src[pos..], gc);
        const form = reader.readForm() catch break;
        pos += reader.pos;

        // Eval the form (handles def!, fn*, etc.)
        var res = Resources.initDefault();
        _ = @import("semantics.zig").evalBounded(form, env, gc, &res);
        evaluated += 1;
    }

    // Now PE all constant bindings
    const pevalued = pevalEnv(env, gc);
    return .{ .evaluated = evaluated, .pevalued = pevalued };
}

/// Builtin: (peval expr) — partially evaluate through inet
pub fn pevalFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgument;
    return pevalExpr(args[0], gc, env) orelse args[0];
}

// ============================================================================
// TESTS
// ============================================================================

test "isGround: literals" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    try std.testing.expect(isGround(Value.makeInt(42), &gc, &env));
    try std.testing.expect(isGround(Value.makeNil(), &gc, &env));
    try std.testing.expect(isGround(Value.makeBool(true), &gc, &env));
}

test "isGround: unbound symbol is not ground" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const sym = try gc.internString("x");
    try std.testing.expect(!isGround(Value.makeSymbol(sym), &gc, &env));
}

test "isGround: bound symbol is ground" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    try env.set("x", Value.makeInt(42));
    const sym = try gc.internString("x");
    try std.testing.expect(isGround(Value.makeSymbol(sym), &gc, &env));
}

test "pevalExpr: literal passthrough" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const result = pevalExpr(Value.makeInt(42), &gc, &env);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i48, 42), result.?.asInt());
}

test "pevalExpr: vector roundtrip" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const result = pevalExpr(Value.makeObj(vec), &gc, &env);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.isObj());
    const robj = result.?.asObj();
    try std.testing.expectEqual(@as(usize, 2), robj.data.vector.items.items.len);
}
