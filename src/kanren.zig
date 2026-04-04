//! miniKanren — relational programming in nanoclj-zig
//!
//! Street fighting mathematics approach (Mahajan): dimensional analysis first.
//! The "dimension" of a logic program is its substitution environment (σ).
//! A goal is σ → Stream(σ). Unification narrows σ. Fresh extends it.
//!
//! SPJ contribution: type-directed search. Each lvar has a unique id (like
//! a type variable). Unification is Robinson's algorithm. The occurs check
//! prevents infinite types — same reason SPJ needs it in Hindley-Milner.
//!
//! Fogus/Hickey contribution: Clojure interface. Logic variables are opaque
//! values. `run*` collects results. `conde` is disjunction. `fresh` introduces
//! new lvars. The substitution is a persistent map (walk chains).
//!
//! Implementation: lvars are keyword Values with ids like :_0, :_1, etc.
//! Substitution is a vector of (lvar, value) pairs. Stream is a list of
//! substitutions. Goals are functions σ → stream.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const compat = @import("compat.zig");

/// Global lvar counter for fresh variable generation
var lvar_counter: u32 = 0;

/// Create a fresh logic variable. Returns a keyword :_N
pub fn makeLogicVar(gc: *GC) !Value {
    var buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "_{d}", .{lvar_counter}) catch return error.OutOfMemory;
    lvar_counter += 1;
    const id = try gc.internString(name);
    return Value.makeKeyword(id);
}

/// Check if a value is a logic variable (keyword starting with _)
pub fn isLvar(val: Value, gc: *GC) bool {
    if (!val.isKeyword()) return false;
    const name = gc.getString(val.asKeywordId());
    return name.len > 0 and name[0] == '_';
}

/// Walk a value through a substitution to find its ground term.
/// Substitution is a vector of [lvar, val, lvar, val, ...] pairs.
pub fn walk(val: Value, subst: *const value.Obj, gc: *GC) Value {
    if (!isLvar(val, gc)) return val;
    const items = subst.data.vector.items.items;
    var i: usize = 0;
    while (i + 1 < items.len) : (i += 2) {
        if (items[i].bits == val.bits) {
            return walk(items[i + 1], subst, gc);
        }
    }
    return val; // unbound lvar
}

/// Deep walk — recursively walk all nested structures
pub fn walkDeep(val: Value, subst: *const value.Obj, gc: *GC) !Value {
    const v = walk(val, subst, gc);
    if (v.isObj()) {
        const obj = v.asObj();
        if (obj.kind == .list) {
            const new = try gc.allocObj(.list);
            for (obj.data.list.items.items) |item| {
                const walked = try walkDeep(item, subst, gc);
                try new.data.list.items.append(gc.allocator, walked);
            }
            return Value.makeObj(new);
        }
        if (obj.kind == .vector) {
            const new = try gc.allocObj(.vector);
            for (obj.data.vector.items.items) |item| {
                const walked = try walkDeep(item, subst, gc);
                try new.data.vector.items.append(gc.allocator, walked);
            }
            return Value.makeObj(new);
        }
    }
    return v;
}

/// Occurs check: does lvar appear in val under subst?
fn occursCheck(lvar: Value, val: Value, subst: *const value.Obj, gc: *GC) bool {
    const v = walk(val, subst, gc);
    if (v.bits == lvar.bits) return true;
    if (v.isObj()) {
        const obj = v.asObj();
        const items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return false,
        };
        for (items) |item| {
            if (occursCheck(lvar, item, subst, gc)) return true;
        }
    }
    return false;
}

/// Extend substitution: add lvar→val binding. Returns new subst or null (occurs check fail).
fn extendSubst(subst: *const value.Obj, lvar: Value, val: Value, gc: *GC) !?Value {
    if (occursCheck(lvar, val, subst, gc)) return null;
    const new = try gc.allocObj(.vector);
    try new.data.vector.items.appendSlice(gc.allocator, subst.data.vector.items.items);
    try new.data.vector.items.append(gc.allocator, lvar);
    try new.data.vector.items.append(gc.allocator, val);
    return Value.makeObj(new);
}

/// Unify two values under a substitution. Returns new subst or null.
pub fn unify(u: Value, v: Value, subst: *const value.Obj, gc: *GC) !?Value {
    const u_walked = walk(u, subst, gc);
    const v_walked = walk(v, subst, gc);

    // Same value — already unified
    if (u_walked.bits == v_walked.bits) return Value.makeObj(@constCast(subst));

    // One is an lvar — bind it
    if (isLvar(u_walked, gc)) return extendSubst(subst, u_walked, v_walked, gc);
    if (isLvar(v_walked, gc)) return extendSubst(subst, v_walked, u_walked, gc);

    // Both are lists/vectors — unify element-wise
    if (u_walked.isObj() and v_walked.isObj()) {
        const u_obj = u_walked.asObj();
        const v_obj = v_walked.asObj();
        if (u_obj.kind == v_obj.kind) {
            const u_items = switch (u_obj.kind) {
                .list => u_obj.data.list.items.items,
                .vector => u_obj.data.vector.items.items,
                else => return null,
            };
            const v_items = switch (v_obj.kind) {
                .list => v_obj.data.list.items.items,
                .vector => v_obj.data.vector.items.items,
                else => return null,
            };
            if (u_items.len != v_items.len) return null;
            var current_subst = Value.makeObj(@constCast(subst));
            for (u_items, v_items) |ui, vi| {
                const result = try unify(ui, vi, current_subst.asObj(), gc);
                if (result) |s| {
                    current_subst = s;
                } else return null;
            }
            return current_subst;
        }
    }

    // Both are ints/strings/keywords — compare by value
    if (u_walked.isInt() and v_walked.isInt()) {
        return if (u_walked.asInt() == v_walked.asInt()) Value.makeObj(@constCast(subst)) else null;
    }
    if (u_walked.isString() and v_walked.isString()) {
        return if (u_walked.asStringId() == v_walked.asStringId()) Value.makeObj(@constCast(subst)) else null;
    }

    return null; // can't unify
}

// ============================================================================
// BUILTINS — wired into nanoclj as (lvar), (== a b), (run* ...) etc.
// ============================================================================

/// (lvar) → fresh logic variable :_N
pub fn lvarFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    return makeLogicVar(gc);
}

/// (lvar? x) → true if x is a logic variable
pub fn lvarP(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(isLvar(args[0], gc));
}

/// (unify a b subst) → new subst or nil
/// subst is a vector [lvar val lvar val ...]
pub fn unifyFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[2].isObj() or args[2].asObj().kind != .vector) return error.TypeError;
    const result = try unify(args[0], args[1], args[2].asObj(), gc);
    return result orelse Value.makeNil();
}

/// (walk* val subst) → deep-walked value
pub fn walkStarFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[1].isObj() or args[1].asObj().kind != .vector) return error.TypeError;
    return walkDeep(args[0], args[1].asObj(), gc);
}

/// (== a b) → goal function: takes subst, returns stream (list of substs)
/// In street-fighting style: == is the fundamental constraint.
/// Returns a function that closes over a and b.
pub fn eqGoalFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    // Store the goal as a vector [:== a b] — recognized by run*
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("=="));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, args[0]);
    try goal.data.vector.items.append(gc.allocator, args[1]);
    return Value.makeObj(goal);
}

/// (conde [goal ...] [goal ...] ...) → disjunction goal
/// Represented as [:conde [goals1] [goals2] ...]
pub fn condeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("conde"));
    try goal.data.vector.items.append(gc.allocator, tag);
    for (args) |clause| {
        try goal.data.vector.items.append(gc.allocator, clause);
    }
    return Value.makeObj(goal);
}

/// (fresh-goal n body-goal) → [:fresh n body-goal]
/// n = number of fresh vars to introduce
pub fn freshGoalFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("fresh"));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, args[0]);
    try goal.data.vector.items.append(gc.allocator, args[1]);
    return Value.makeObj(goal);
}

/// Execute a goal against a substitution, return stream of substitutions
fn executeGoal(goal: Value, subst: Value, gc: *GC) !Value {
    if (!goal.isObj()) return Value.makeNil();
    const obj = goal.asObj();
    if (obj.kind != .vector) return Value.makeNil();
    const items = obj.data.vector.items.items;
    if (items.len == 0) return Value.makeNil();

    if (!items[0].isKeyword()) return Value.makeNil();
    const tag = gc.getString(items[0].asKeywordId());

    if (std.mem.eql(u8, tag, "==") and items.len == 3) {
        // Unification goal
        if (!subst.isObj() or subst.asObj().kind != .vector) return Value.makeNil();
        const result = try unify(items[1], items[2], subst.asObj(), gc);
        if (result) |s| {
            // Success: return stream of one substitution
            const stream = try gc.allocObj(.list);
            try stream.data.list.items.append(gc.allocator, s);
            return Value.makeObj(stream);
        }
        return Value.makeNil(); // failure: empty stream
    }

    if (std.mem.eql(u8, tag, "conde")) {
        // Disjunction: try each clause, concat streams
        const stream = try gc.allocObj(.list);
        for (items[1..]) |clause| {
            if (clause.isObj() and clause.asObj().kind == .vector) {
                // Each clause is a conjunction of goals
                var clause_stream = try gc.allocObj(.list);
                try clause_stream.data.list.items.append(gc.allocator, subst);
                for (clause.asObj().data.vector.items.items) |g| {
                    var next_stream = try gc.allocObj(.list);
                    for (clause_stream.data.list.items.items) |s| {
                        const results = try executeGoal(g, s, gc);
                        if (results.isObj() and results.asObj().kind == .list) {
                            try next_stream.data.list.items.appendSlice(
                                gc.allocator,
                                results.asObj().data.list.items.items,
                            );
                        }
                    }
                    clause_stream = next_stream;
                }
                try stream.data.list.items.appendSlice(
                    gc.allocator,
                    clause_stream.data.list.items.items,
                );
            }
        }
        return Value.makeObj(stream);
    }

    if (std.mem.eql(u8, tag, "conj") and items.len >= 2) {
        // Conjunction: thread substitution through goals sequentially
        var current_stream = try gc.allocObj(.list);
        try current_stream.data.list.items.append(gc.allocator, subst);
        for (items[1..]) |g| {
            var next_stream = try gc.allocObj(.list);
            for (current_stream.data.list.items.items) |s| {
                const results = try executeGoal(g, s, gc);
                if (results.isObj() and results.asObj().kind == .list) {
                    try next_stream.data.list.items.appendSlice(
                        gc.allocator,
                        results.asObj().data.list.items.items,
                    );
                }
            }
            current_stream = next_stream;
        }
        return Value.makeObj(current_stream);
    }

    return Value.makeNil();
}

/// (conj-goal g1 g2 ...) → [:conj g1 g2 ...]
pub fn conjGoalFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("conj"));
    try goal.data.vector.items.append(gc.allocator, tag);
    for (args) |g| try goal.data.vector.items.append(gc.allocator, g);
    return Value.makeObj(goal);
}

/// (run-goal n query-var goal) → list of up to n results
/// n = max results (0 = all), query-var = lvar to extract, goal = goal tree
pub fn runGoalFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const max_results: usize = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const query_var = args[1];
    const goal = args[2];

    // Start with empty substitution
    const empty_subst = try gc.allocObj(.vector);
    const stream = try executeGoal(goal, Value.makeObj(empty_subst), gc);

    // Extract query variable from each substitution
    const results = try gc.allocObj(.list);
    if (stream.isObj() and stream.asObj().kind == .list) {
        for (stream.asObj().data.list.items.items) |subst| {
            if (max_results > 0 and results.data.list.items.items.len >= max_results) break;
            if (subst.isObj() and subst.asObj().kind == .vector) {
                const walked = try walkDeep(query_var, subst.asObj(), gc);
                try results.data.list.items.append(gc.allocator, walked);
            }
        }
    }
    return Value.makeObj(results);
}

// ============================================================================
// TESTS
// ============================================================================

test "lvar creation" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    lvar_counter = 0;
    const v0 = try makeLogicVar(&gc);
    const v1 = try makeLogicVar(&gc);
    try std.testing.expect(isLvar(v0, &gc));
    try std.testing.expect(isLvar(v1, &gc));
    try std.testing.expect(v0.bits != v1.bits);
    try std.testing.expect(!isLvar(Value.makeInt(42), &gc));
}

test "unification: two lvars" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    lvar_counter = 0;

    const x = try makeLogicVar(&gc);
    const empty = try gc.allocObj(.vector);

    // x == 5
    const s1 = try unify(x, Value.makeInt(5), empty, &gc);
    try std.testing.expect(s1 != null);
    // walk x in s1 should give 5
    const walked = walk(x, s1.?.asObj(), &gc);
    try std.testing.expect(walked.isInt());
    try std.testing.expectEqual(@as(i48, 5), walked.asInt());
}

test "unification: list structural" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    lvar_counter = 0;

    const x = try makeLogicVar(&gc);
    const empty = try gc.allocObj(.vector);

    // unify [x 2] with [1 2]
    const lhs = try gc.allocObj(.vector);
    try lhs.data.vector.items.append(gc.allocator, x);
    try lhs.data.vector.items.append(gc.allocator, Value.makeInt(2));
    const rhs = try gc.allocObj(.vector);
    try rhs.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try rhs.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const s = try unify(Value.makeObj(lhs), Value.makeObj(rhs), empty, &gc);
    try std.testing.expect(s != null);
    const walked = walk(x, s.?.asObj(), &gc);
    try std.testing.expectEqual(@as(i48, 1), walked.asInt());
}

test "unification: occurs check" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    lvar_counter = 0;

    const x = try makeLogicVar(&gc);
    const empty = try gc.allocObj(.vector);

    // unify x with [x] should fail (occurs check)
    const lst = try gc.allocObj(.vector);
    try lst.data.vector.items.append(gc.allocator, x);
    const s = try unify(x, Value.makeObj(lst), empty, &gc);
    try std.testing.expect(s == null);
}

test "run-goal: simple ==, query" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    lvar_counter = 0;

    const x = try makeLogicVar(&gc);

    // Goal: (== x 42)
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("=="));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, x);
    try goal.data.vector.items.append(gc.allocator, Value.makeInt(42));

    var args = [_]Value{ Value.makeInt(0), x, Value.makeObj(goal) };
    const result = try runGoalFn(&args, &gc, undefined);
    try std.testing.expect(result.isObj());
    const items = result.asObj().data.list.items.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i48, 42), items[0].asInt());
}

test "run-goal: conde disjunction" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    lvar_counter = 0;

    const x = try makeLogicVar(&gc);

    // conde: x=1 OR x=2 OR x=3
    const eq_tag = Value.makeKeyword(try gc.internString("=="));
    const conde_tag = Value.makeKeyword(try gc.internString("conde"));

    var clauses: [3]Value = undefined;
    for ([_]i48{ 1, 2, 3 }, 0..) |n, i| {
        const g = try gc.allocObj(.vector);
        try g.data.vector.items.append(gc.allocator, eq_tag);
        try g.data.vector.items.append(gc.allocator, x);
        try g.data.vector.items.append(gc.allocator, Value.makeInt(n));
        // Wrap in a clause vector (conjunction of one goal)
        const clause = try gc.allocObj(.vector);
        try clause.data.vector.items.append(gc.allocator, Value.makeObj(g));
        clauses[i] = Value.makeObj(clause);
    }

    const goal = try gc.allocObj(.vector);
    try goal.data.vector.items.append(gc.allocator, conde_tag);
    for (clauses) |c| try goal.data.vector.items.append(gc.allocator, c);

    var args = [_]Value{ Value.makeInt(0), x, Value.makeObj(goal) };
    const result = try runGoalFn(&args, &gc, undefined);
    const items = result.asObj().data.list.items.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i48, 1), items[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), items[1].asInt());
    try std.testing.expectEqual(@as(i48, 3), items[2].asInt());
}
