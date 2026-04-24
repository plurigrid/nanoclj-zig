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
const Resources = @import("transitivity.zig").Resources;
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
        if (obj.kind == .map) {
            const new = try gc.allocObj(.map);
            for (obj.data.map.keys.items, obj.data.map.vals.items) |k, mv| {
                const wk = try walkDeep(k, subst, gc);
                const wv = try walkDeep(mv, subst, gc);
                try new.data.map.keys.append(gc.allocator, wk);
                try new.data.map.vals.append(gc.allocator, wv);
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
pub fn lvarFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    return makeLogicVar(gc);
}

/// (lvar? x) → true if x is a logic variable
pub fn lvarP(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(isLvar(args[0], gc));
}

/// (unify a b subst) → new subst or nil
/// subst is a vector [lvar val lvar val ...]
pub fn unifyFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    if (!args[2].isObj() or args[2].asObj().kind != .vector) return error.TypeError;
    const result = try unify(args[0], args[1], args[2].asObj(), gc);
    return result orelse Value.makeNil();
}

/// (walk* val subst) → deep-walked value
pub fn walkStarFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[1].isObj() or args[1].asObj().kind != .vector) return error.TypeError;
    return walkDeep(args[0], args[1].asObj(), gc);
}

/// (== a b) → goal function: takes subst, returns stream (list of substs)
/// In street-fighting style: == is the fundamental constraint.
/// Returns a function that closes over a and b.
pub fn eqGoalFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
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
pub fn condeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
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
pub fn freshGoalFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
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

    if (std.mem.eql(u8, tag, "conso") and items.len == 4) {
        // conso h t l: unify l with a list whose head=h, tail=t
        // We represent lists as vectors for unification: [h, t_elem1, t_elem2, ...]
        // But actually we need to handle this structurally.
        // Strategy: walk l,h,t then try to unify.
        if (!subst.isObj() or subst.asObj().kind != .vector) return Value.makeNil();
        const h = items[1];
        const t = items[2];
        const l = items[3];

        const l_walked = walk(l, subst.asObj(), gc);
        const t_walked = walk(t, subst.asObj(), gc);

        // If l is a ground list, decompose: head=first, tail=rest
        if (l_walked.isObj() and l_walked.asObj().kind == .list) {
            const l_items = l_walked.asObj().data.list.items.items;
            if (l_items.len == 0) return Value.makeNil(); // empty list can't conso
            // unify h with head
            const s1 = try unify(h, l_items[0], subst.asObj(), gc);
            if (s1 == null) return Value.makeNil();
            // build tail list
            const tail = try gc.allocObj(.list);
            for (l_items[1..]) |item| try tail.data.list.items.append(gc.allocator, item);
            const s2 = try unify(t, Value.makeObj(tail), s1.?.asObj(), gc);
            if (s2 == null) return Value.makeNil();
            const stream = try gc.allocObj(.list);
            try stream.data.list.items.append(gc.allocator, s2.?);
            return Value.makeObj(stream);
        }

        // If t is ground, build l = (cons h t)
        if (t_walked.isObj() and t_walked.asObj().kind == .list) {
            const new_list = try gc.allocObj(.list);
            try new_list.data.list.items.append(gc.allocator, h);
            for (t_walked.asObj().data.list.items.items) |item|
                try new_list.data.list.items.append(gc.allocator, item);
            const s1 = try unify(l, Value.makeObj(new_list), subst.asObj(), gc);
            if (s1 == null) return Value.makeNil();
            // Also unify h with walked h (in case h is lvar)
            const s2 = try unify(h, walk(h, s1.?.asObj(), gc), s1.?.asObj(), gc);
            if (s2 == null) return Value.makeNil();
            const stream = try gc.allocObj(.list);
            try stream.data.list.items.append(gc.allocator, s2.?);
            return Value.makeObj(stream);
        }

        // If l is an lvar and we know h and t, build and bind
        if (isLvar(l_walked, gc)) {
            // Need t to be ground to construct
            if (t_walked.isNil()) {
                // t = nil/empty → l = (h)
                const new_list = try gc.allocObj(.list);
                try new_list.data.list.items.append(gc.allocator, h);
                const s1 = try unify(l, Value.makeObj(new_list), subst.asObj(), gc);
                if (s1 == null) return Value.makeNil();
                const stream = try gc.allocObj(.list);
                try stream.data.list.items.append(gc.allocator, s1.?);
                return Value.makeObj(stream);
            }
        }

        return Value.makeNil();
    }

    if (std.mem.eql(u8, tag, "appendo") and items.len == 4) {
        // appendo l s out: (concat l s) = out
        // Base case: l=() → s=out
        // Recursive: l=(h . t) → out=(h . res), appendo(t, s, res)
        if (!subst.isObj() or subst.asObj().kind != .vector) return Value.makeNil();
        const l = items[1];
        const s = items[2];
        const out = items[3];
        const l_walked = walk(l, subst.asObj(), gc);

        const all_results = try gc.allocObj(.list);

        // Base case: l = () → unify s out
        {
            const empty_list = try gc.allocObj(.list);
            const s1 = try unify(l, Value.makeObj(empty_list), subst.asObj(), gc);
            if (s1) |base_subst| {
                const s2 = try unify(s, out, base_subst.asObj(), gc);
                if (s2) |final| {
                    try all_results.data.list.items.append(gc.allocator, final);
                }
            }
        }

        // Recursive case: l = (h . t)
        // Only recurse if l is a ground list (prevents infinite search)
        if (l_walked.isObj() and l_walked.asObj().kind == .list) {
            const l_items = l_walked.asObj().data.list.items.items;
            if (l_items.len > 0) {
                const head = l_items[0];
                // Build tail
                const tail = try gc.allocObj(.list);
                for (l_items[1..]) |item| try tail.data.list.items.append(gc.allocator, item);

                // Fresh var for recursive result
                const res = try makeLogicVar(gc);

                // Build recursive appendo goal
                const rec_goal = try gc.allocObj(.vector);
                const appendo_tag = Value.makeKeyword(try gc.internString("appendo"));
                try rec_goal.data.vector.items.append(gc.allocator, appendo_tag);
                try rec_goal.data.vector.items.append(gc.allocator, Value.makeObj(tail));
                try rec_goal.data.vector.items.append(gc.allocator, s);
                try rec_goal.data.vector.items.append(gc.allocator, res);

                // Execute recursive goal
                const rec_stream = try executeGoal(Value.makeObj(rec_goal), subst, gc);
                if (rec_stream.isObj() and rec_stream.asObj().kind == .list) {
                    for (rec_stream.asObj().data.list.items.items) |rec_subst| {
                        if (!rec_subst.isObj()) continue;
                        // Now build out = (head . res) via conso
                        const conso_goal = try gc.allocObj(.vector);
                        const conso_tag = Value.makeKeyword(try gc.internString("conso"));
                        try conso_goal.data.vector.items.append(gc.allocator, conso_tag);
                        try conso_goal.data.vector.items.append(gc.allocator, head);
                        try conso_goal.data.vector.items.append(gc.allocator, res);
                        try conso_goal.data.vector.items.append(gc.allocator, out);

                        const conso_stream = try executeGoal(Value.makeObj(conso_goal), rec_subst, gc);
                        if (conso_stream.isObj() and conso_stream.asObj().kind == .list) {
                            try all_results.data.list.items.appendSlice(
                                gc.allocator,
                                conso_stream.asObj().data.list.items.items,
                            );
                        }
                    }
                }
            }
        }

        return Value.makeObj(all_results);
    }

    if (std.mem.eql(u8, tag, "lookupo") and items.len == 4) {
        // lookupo name env val: lookup name in assoc list env, result is val
        // env = ((name1 val1) (name2 val2) ...)
        // Base: empty env → fail
        // Head: first pair matches → unify val
        // Tail: recurse on rest
        if (!subst.isObj() or subst.asObj().kind != .vector) return Value.makeNil();
        const name = items[1];
        const env_val = items[2];
        const val = items[3];
        const env_walked = walk(env_val, subst.asObj(), gc);

        if (!env_walked.isObj() or env_walked.asObj().kind != .list) return Value.makeNil();
        const env_items = env_walked.asObj().data.list.items.items;
        if (env_items.len == 0) return Value.makeNil();

        const all_results = try gc.allocObj(.list);

        // Try head pair
        if (env_items[0].isObj() and env_items[0].asObj().kind == .list) {
            const pair = env_items[0].asObj().data.list.items.items;
            if (pair.len == 2) {
                const s1 = try unify(name, pair[0], subst.asObj(), gc);
                if (s1) |matched| {
                    const s2 = try unify(val, pair[1], matched.asObj(), gc);
                    if (s2) |final| {
                        try all_results.data.list.items.append(gc.allocator, final);
                    }
                }
            }
        }

        // Recurse on tail
        if (env_items.len > 1) {
            const tail_env = try gc.allocObj(.list);
            for (env_items[1..]) |item| try tail_env.data.list.items.append(gc.allocator, item);

            const rec_goal = try gc.allocObj(.vector);
            const lookupo_tag = Value.makeKeyword(try gc.internString("lookupo"));
            try rec_goal.data.vector.items.append(gc.allocator, lookupo_tag);
            try rec_goal.data.vector.items.append(gc.allocator, name);
            try rec_goal.data.vector.items.append(gc.allocator, Value.makeObj(tail_env));
            try rec_goal.data.vector.items.append(gc.allocator, val);

            const rec_stream = try executeGoal(Value.makeObj(rec_goal), subst, gc);
            if (rec_stream.isObj() and rec_stream.asObj().kind == .list) {
                try all_results.data.list.items.appendSlice(
                    gc.allocator,
                    rec_stream.asObj().data.list.items.items,
                );
            }
        }

        return Value.makeObj(all_results);
    }

    if (std.mem.eql(u8, tag, "evalo") and items.len == 4) {
        // evalo expr val env: expr evaluates to val under env
        if (!subst.isObj() or subst.asObj().kind != .vector) return Value.makeNil();
        const expr = items[1];
        const val = items[2];
        const env_val = items[3];

        const expr_walked = walk(expr, subst.asObj(), gc);
        const all_results = try gc.allocObj(.list);

        // Rule 1: Integer/keyword self-evaluation
        // If expr is an int or keyword, val = expr
        {
            if (expr_walked.isInt() or expr_walked.isKeyword()) {
                const s1 = try unify(val, expr_walked, subst.asObj(), gc);
                if (s1) |final| {
                    try all_results.data.list.items.append(gc.allocator, final);
                }
                return Value.makeObj(all_results);
            }
        }

        // For vector expressions, dispatch on the first element (tag)
        if (expr_walked.isObj() and expr_walked.asObj().kind == .vector) {
            const parts = expr_walked.asObj().data.vector.items.items;

            if (parts.len >= 1) {
                const form_tag = walk(parts[0], subst.asObj(), gc);

                // Rule 2: [:quote x] → x
                if (form_tag.isKeyword() and std.mem.eql(u8, gc.getString(form_tag.asKeywordId()), "quote") and parts.len == 2) {
                    const s1 = try unify(val, parts[1], subst.asObj(), gc);
                    if (s1) |final| {
                        try all_results.data.list.items.append(gc.allocator, final);
                    }
                    return Value.makeObj(all_results);
                }

                // Rule 3: [:var name] → lookup in env
                if (form_tag.isKeyword() and std.mem.eql(u8, gc.getString(form_tag.asKeywordId()), "var") and parts.len == 2) {
                    const lookup_goal = try gc.allocObj(.vector);
                    const lookupo_tag = Value.makeKeyword(try gc.internString("lookupo"));
                    try lookup_goal.data.vector.items.append(gc.allocator, lookupo_tag);
                    try lookup_goal.data.vector.items.append(gc.allocator, parts[1]);
                    try lookup_goal.data.vector.items.append(gc.allocator, env_val);
                    try lookup_goal.data.vector.items.append(gc.allocator, val);

                    return executeGoal(Value.makeObj(lookup_goal), subst, gc);
                }

                // Rule 4: [:if test then else] → conditional
                if (form_tag.isKeyword() and std.mem.eql(u8, gc.getString(form_tag.asKeywordId()), "if") and parts.len == 4) {
                    const test_expr = parts[1];
                    const then_expr = parts[2];
                    const else_expr = parts[3];

                    // Branch true: test evaluates to true, result = eval(then)
                    {
                        const test_v = try makeLogicVar(gc);
                        const evalo_tag = Value.makeKeyword(try gc.internString("evalo"));

                        // eval test
                        const test_goal = try gc.allocObj(.vector);
                        try test_goal.data.vector.items.append(gc.allocator, evalo_tag);
                        try test_goal.data.vector.items.append(gc.allocator, test_expr);
                        try test_goal.data.vector.items.append(gc.allocator, test_v);
                        try test_goal.data.vector.items.append(gc.allocator, env_val);

                        const test_stream = try executeGoal(Value.makeObj(test_goal), subst, gc);
                        if (test_stream.isObj() and test_stream.asObj().kind == .list) {
                            for (test_stream.asObj().data.list.items.items) |test_subst| {
                                if (!test_subst.isObj()) continue;
                                const tv = walk(test_v, test_subst.asObj(), gc);
                                // true branch: test is truthy (not false, not nil)
                                if (!tv.isNil() and !(tv.isBool() and !tv.asBool())) {
                                    const then_goal = try gc.allocObj(.vector);
                                    try then_goal.data.vector.items.append(gc.allocator, evalo_tag);
                                    try then_goal.data.vector.items.append(gc.allocator, then_expr);
                                    try then_goal.data.vector.items.append(gc.allocator, val);
                                    try then_goal.data.vector.items.append(gc.allocator, env_val);

                                    const then_stream = try executeGoal(Value.makeObj(then_goal), test_subst, gc);
                                    if (then_stream.isObj() and then_stream.asObj().kind == .list) {
                                        try all_results.data.list.items.appendSlice(gc.allocator, then_stream.asObj().data.list.items.items);
                                    }
                                } else {
                                    // false branch
                                    const else_goal = try gc.allocObj(.vector);
                                    try else_goal.data.vector.items.append(gc.allocator, evalo_tag);
                                    try else_goal.data.vector.items.append(gc.allocator, else_expr);
                                    try else_goal.data.vector.items.append(gc.allocator, val);
                                    try else_goal.data.vector.items.append(gc.allocator, env_val);

                                    const else_stream = try executeGoal(Value.makeObj(else_goal), test_subst, gc);
                                    if (else_stream.isObj() and else_stream.asObj().kind == .list) {
                                        try all_results.data.list.items.appendSlice(gc.allocator, else_stream.asObj().data.list.items.items);
                                    }
                                }
                            }
                        }
                    }
                    return Value.makeObj(all_results);
                }

                // Rule 5: [:lambda param body] → closure value [:closure param body env]
                if (form_tag.isKeyword() and std.mem.eql(u8, gc.getString(form_tag.asKeywordId()), "lambda") and parts.len == 3) {
                    const closure = try gc.allocObj(.vector);
                    const closure_tag = Value.makeKeyword(try gc.internString("closure"));
                    try closure.data.vector.items.append(gc.allocator, closure_tag);
                    try closure.data.vector.items.append(gc.allocator, parts[1]); // param
                    try closure.data.vector.items.append(gc.allocator, parts[2]); // body
                    try closure.data.vector.items.append(gc.allocator, env_val); // captured env

                    const s1 = try unify(val, Value.makeObj(closure), subst.asObj(), gc);
                    if (s1) |final| {
                        try all_results.data.list.items.append(gc.allocator, final);
                    }
                    return Value.makeObj(all_results);
                }

                // Rule 6: [:app f arg] → apply f to arg
                if (form_tag.isKeyword() and std.mem.eql(u8, gc.getString(form_tag.asKeywordId()), "app") and parts.len == 3) {
                    const f_expr = parts[1];
                    const arg_expr = parts[2];

                    const f_val = try makeLogicVar(gc);
                    const arg_val = try makeLogicVar(gc);
                    const evalo_tag = Value.makeKeyword(try gc.internString("evalo"));

                    // eval f
                    const f_goal = try gc.allocObj(.vector);
                    try f_goal.data.vector.items.append(gc.allocator, evalo_tag);
                    try f_goal.data.vector.items.append(gc.allocator, f_expr);
                    try f_goal.data.vector.items.append(gc.allocator, f_val);
                    try f_goal.data.vector.items.append(gc.allocator, env_val);

                    const f_stream = try executeGoal(Value.makeObj(f_goal), subst, gc);
                    if (f_stream.isObj() and f_stream.asObj().kind == .list) {
                        for (f_stream.asObj().data.list.items.items) |f_subst| {
                            if (!f_subst.isObj()) continue;

                            // eval arg
                            const arg_goal = try gc.allocObj(.vector);
                            try arg_goal.data.vector.items.append(gc.allocator, evalo_tag);
                            try arg_goal.data.vector.items.append(gc.allocator, arg_expr);
                            try arg_goal.data.vector.items.append(gc.allocator, arg_val);
                            try arg_goal.data.vector.items.append(gc.allocator, env_val);

                            const arg_stream = try executeGoal(Value.makeObj(arg_goal), f_subst, gc);
                            if (arg_stream.isObj() and arg_stream.asObj().kind == .list) {
                                for (arg_stream.asObj().data.list.items.items) |arg_subst| {
                                    if (!arg_subst.isObj()) continue;

                                    // f must be a closure: [:closure param body closure-env]
                                    const f_walked = walk(f_val, arg_subst.asObj(), gc);
                                    if (f_walked.isObj() and f_walked.asObj().kind == .vector) {
                                        const closure_parts = f_walked.asObj().data.vector.items.items;
                                        if (closure_parts.len == 4) {
                                            const ct = walk(closure_parts[0], arg_subst.asObj(), gc);
                                            if (ct.isKeyword() and std.mem.eql(u8, gc.getString(ct.asKeywordId()), "closure")) {
                                                const param = closure_parts[1];
                                                const body = closure_parts[2];
                                                const closure_env = closure_parts[3];

                                                // Extend closure env with (param arg_val)
                                                const binding = try gc.allocObj(.list);
                                                try binding.data.list.items.append(gc.allocator, param);
                                                const arg_resolved = walk(arg_val, arg_subst.asObj(), gc);
                                                try binding.data.list.items.append(gc.allocator, arg_resolved);

                                                const new_env = try gc.allocObj(.list);
                                                try new_env.data.list.items.append(gc.allocator, Value.makeObj(binding));
                                                // Append closure env entries
                                                const ce_walked = walk(closure_env, arg_subst.asObj(), gc);
                                                if (ce_walked.isObj() and ce_walked.asObj().kind == .list) {
                                                    try new_env.data.list.items.appendSlice(gc.allocator, ce_walked.asObj().data.list.items.items);
                                                }

                                                // eval body in extended env
                                                const body_goal = try gc.allocObj(.vector);
                                                try body_goal.data.vector.items.append(gc.allocator, evalo_tag);
                                                try body_goal.data.vector.items.append(gc.allocator, body);
                                                try body_goal.data.vector.items.append(gc.allocator, val);
                                                try body_goal.data.vector.items.append(gc.allocator, Value.makeObj(new_env));

                                                const body_stream = try executeGoal(Value.makeObj(body_goal), arg_subst, gc);
                                                if (body_stream.isObj() and body_stream.asObj().kind == .list) {
                                                    try all_results.data.list.items.appendSlice(gc.allocator, body_stream.asObj().data.list.items.items);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return Value.makeObj(all_results);
                }
            }
        }

        // For lvar expressions (unknown expr), generate all possible forms
        // This enables backward search (program synthesis)
        if (isLvar(expr_walked, gc)) {
            // Self-eval: expr could be an integer that equals val
            if (val.isInt() or val.isKeyword()) {
                const s1 = try unify(expr, val, subst.asObj(), gc);
                if (s1) |final| {
                    try all_results.data.list.items.append(gc.allocator, final);
                }
            }

            // Quote: expr = [:quote val]
            {
                const quote_expr = try gc.allocObj(.vector);
                const quote_tag = Value.makeKeyword(try gc.internString("quote"));
                try quote_expr.data.vector.items.append(gc.allocator, quote_tag);
                try quote_expr.data.vector.items.append(gc.allocator, val);
                const s1 = try unify(expr, Value.makeObj(quote_expr), subst.asObj(), gc);
                if (s1) |final| {
                    try all_results.data.list.items.append(gc.allocator, final);
                }
            }
        }

        return Value.makeObj(all_results);
    }

    if (std.mem.eql(u8, tag, "membero") and items.len == 3) {
        // membero x l: x is in l
        // (== x head) OR (membero x tail)
        if (!subst.isObj() or subst.asObj().kind != .vector) return Value.makeNil();
        const x = items[1];
        const l = items[2];
        const l_walked = walk(l, subst.asObj(), gc);

        if (!l_walked.isObj() or l_walked.asObj().kind != .list) return Value.makeNil();
        const l_items = l_walked.asObj().data.list.items.items;
        if (l_items.len == 0) return Value.makeNil();

        const all_results = try gc.allocObj(.list);

        // Try head: unify x with first element
        {
            const s1 = try unify(x, l_items[0], subst.asObj(), gc);
            if (s1) |found| {
                try all_results.data.list.items.append(gc.allocator, found);
            }
        }

        // Recurse on tail
        if (l_items.len > 1) {
            const tail = try gc.allocObj(.list);
            for (l_items[1..]) |item| try tail.data.list.items.append(gc.allocator, item);

            const rec_goal = try gc.allocObj(.vector);
            const membero_tag = Value.makeKeyword(try gc.internString("membero"));
            try rec_goal.data.vector.items.append(gc.allocator, membero_tag);
            try rec_goal.data.vector.items.append(gc.allocator, x);
            try rec_goal.data.vector.items.append(gc.allocator, Value.makeObj(tail));

            const rec_stream = try executeGoal(Value.makeObj(rec_goal), subst, gc);
            if (rec_stream.isObj() and rec_stream.asObj().kind == .list) {
                try all_results.data.list.items.appendSlice(
                    gc.allocator,
                    rec_stream.asObj().data.list.items.items,
                );
            }
        }

        return Value.makeObj(all_results);
    }

    return Value.makeNil();
}

/// (conj-goal g1 g2 ...) → [:conj g1 g2 ...]
pub fn conjGoalFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("conj"));
    try goal.data.vector.items.append(gc.allocator, tag);
    for (args) |g| try goal.data.vector.items.append(gc.allocator, g);
    return Value.makeObj(goal);
}

/// (run-goal n query-var goal) → list of up to n results
/// n = max results (0 = all), query-var = lvar to extract, goal = goal tree
pub fn runGoalFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
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

/// (conso h t l) → goal: l = (cons h t)
/// The fundamental list relation. appendo and membero reduce to this.
/// Street fighting: instead of "cons builds a list", we say
/// "h, t, and l are related such that l = h:t". Run it any direction.
pub fn consoFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const h = args[0];
    const t = args[1];
    const l = args[2];
    // Goal: unify l with [h | t] — represented as a list (h . t)
    // We build: (conj (== l constructed-pair))
    // But we need the pair as a value. Use a vector [h, t-items...] flattened.
    // Actually: represent as [:conso h t l] and handle in executeGoal.
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("conso"));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, h);
    try goal.data.vector.items.append(gc.allocator, t);
    try goal.data.vector.items.append(gc.allocator, l);
    return Value.makeObj(goal);
}

/// (appendo l s out) → goal: (concat l s) = out
/// The classic miniKanren relation. Bidirectional: given any two, find the third.
/// Recursive definition:
///   (appendo () s out) :- (== s out)
///   (appendo (h . t) s out) :- (fresh [res] (== out (h . res)) (appendo t s res))
/// Represented as [:appendo l s out] and expanded lazily in executeGoal.
pub fn appendoFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("appendo"));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, args[0]);
    try goal.data.vector.items.append(gc.allocator, args[1]);
    try goal.data.vector.items.append(gc.allocator, args[2]);
    return Value.makeObj(goal);
}

/// (membero x l) → goal: x is a member of l
/// (membero x (h . t)) :- (== x h) OR (membero x t)
pub fn memberoFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("membero"));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, args[0]);
    try goal.data.vector.items.append(gc.allocator, args[1]);
    return Value.makeObj(goal);
}

/// (evalo expr val env-assoc) → goal: expr evaluates to val under env
/// The Byrd crown jewel. A relational interpreter for a small Lisp:
///   - Integers and keywords self-evaluate
///   - [:quote x] → x
///   - [:if test then else] → conditional
///   - [:lambda param body] → closure (as a value)
///   - [:app f arg] → function application
///   - [:var name] → environment lookup
/// Represented as [:evalo expr val env] and expanded in executeGoal.
///
/// Forward: (evalo '[:app [:lambda :x [:var :x]] [:quote 42]] q '()) → q=42
/// Backward: (evalo q 42 '()) → synthesize programs producing 42
pub fn evaloFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("evalo"));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, args[0]); // expr
    try goal.data.vector.items.append(gc.allocator, args[1]); // val
    try goal.data.vector.items.append(gc.allocator, args[2]); // env (assoc list)
    return Value.makeObj(goal);
}

/// (lookupo name env val) → goal: name maps to val in env (assoc list)
pub fn lookupoFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const goal = try gc.allocObj(.vector);
    const tag = Value.makeKeyword(try gc.internString("lookupo"));
    try goal.data.vector.items.append(gc.allocator, tag);
    try goal.data.vector.items.append(gc.allocator, args[0]);
    try goal.data.vector.items.append(gc.allocator, args[1]);
    try goal.data.vector.items.append(gc.allocator, args[2]);
    return Value.makeObj(goal);
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

    var resources = Resources.initDefault();
    var args = [_]Value{ Value.makeInt(0), x, Value.makeObj(goal) };
    const result = try runGoalFn(&args, &gc, undefined, &resources);
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

    var resources = Resources.initDefault();
    var args = [_]Value{ Value.makeInt(0), x, Value.makeObj(goal) };
    const result = try runGoalFn(&args, &gc, undefined, &resources);
    const items = result.asObj().data.list.items.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i48, 1), items[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), items[1].asInt());
    try std.testing.expectEqual(@as(i48, 3), items[2].asInt());
}
