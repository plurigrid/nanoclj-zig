//! sorted-set / sorted-map builtins.
//!
//! We do NOT introduce a new ObjKind. Instead we wrap sorted collections in the
//! existing `.set` / `.map` ObjKind and tag them with a metadata map containing
//!   :sorted     -> true
//!   :comparator -> nil | <fn Value>   (nil = use default ordering)
//!
//! Data layout:
//!   sorted-set: obj.data.set.items is kept in ascending order (deduplicated)
//!   sorted-map: obj.data.map.keys/vals are kept in ascending-by-key order
//!
//! Default ordering handles:
//!   integer/float/rational via numeric comparison
//!   strings via lexicographic
//!   keywords/symbols via their string representation
//!   nil is smaller than everything
//!   objects: compared by tag / bit pattern as a last resort (stable)
//!
//! A user-supplied comparator is invoked as `(cmp a b)` and should return a
//! negative integer, zero, or a positive integer (Clojure's `compare`), OR a
//! truthy value meaning `a < b` (Clojure's 2-ary comparator semantics). We
//! support both — negative OR truthy ⇒ `a < b`, positive ⇒ `a > b`, zero/false
//! ⇒ equal.

const std = @import("std");
const compat = @import("compat.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Obj = value_mod.Obj;
const ObjKind = value_mod.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const eval_mod = @import("eval.zig");

// ---------------------------------------------------------------------------
// Public data structs (documentation only — the actual storage lives inside
// the existing .set / .map ObjData variants).  Exported so downstream code
// may @import("sorted.zig").SortedSetData for reflection.
// ---------------------------------------------------------------------------

pub const SortedSetData = struct {
    items: std.ArrayListUnmanaged(Value) = .empty,
    comparator: Value = Value.makeNil(), // nil = default
};

pub const SortedMapData = struct {
    keys: std.ArrayListUnmanaged(Value) = .empty,
    vals: std.ArrayListUnmanaged(Value) = .empty,
    comparator: Value = Value.makeNil(), // nil = default
};

// ---------------------------------------------------------------------------
// Default comparator (total order over primitive Values).
// Returns negative / zero / positive (i32).
// ---------------------------------------------------------------------------

fn tagRank(v: Value) u8 {
    if (v.isNil()) return 0;
    if (v.isBool()) return 1;
    if (v.isInt()) return 2;
    if (v.isFloat()) return 2; // numbers compare together
    if (v.isObj() and v.asObj().kind == .rational) return 2;
    if (v.isString()) return 3;
    if (v.isKeyword()) return 4;
    if (v.isSymbol()) return 5;
    return 9; // other objects
}

fn stringOf(v: Value, gc: *GC) ?[]const u8 {
    if (v.isString()) return gc.getString(v.asStringId());
    if (v.isKeyword()) return gc.getString(v.asKeywordId());
    if (v.isSymbol()) return gc.getString(v.asSymbolId());
    return null;
}

fn defaultCompare(a: Value, b: Value, gc: *GC) i32 {
    const ra = tagRank(a);
    const rb = tagRank(b);
    if (ra != rb) {
        return if (ra < rb) -1 else 1;
    }
    switch (ra) {
        0 => return 0, // both nil
        1 => {
            const ai: i32 = @intFromBool(a.asBool());
            const bi: i32 = @intFromBool(b.asBool());
            return ai - bi;
        },
        2 => {
            // numeric
            const na = a.asNumber() orelse 0;
            const nb = b.asNumber() orelse 0;
            if (na < nb) return -1;
            if (na > nb) return 1;
            return 0;
        },
        3, 4, 5 => {
            const sa = stringOf(a, gc) orelse "";
            const sb = stringOf(b, gc) orelse "";
            return switch (std.mem.order(u8, sa, sb)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        },
        else => {
            // Fall back to raw bit pattern for a total (if arbitrary) order.
            if (a.bits < b.bits) return -1;
            if (a.bits > b.bits) return 1;
            return 0;
        },
    }
}

/// Invoke a user comparator `(cmp a b)`.  Interprets the return value as
/// Clojure-compatible: negative / zero / positive number, OR truthy meaning
/// `a < b`.  Returns negative / zero / positive i32.
fn userCompare(cmp: Value, a: Value, b: Value, env: *Env, gc: *GC) !i32 {
    var pair = [_]Value{ a, b };
    const r = eval_mod.apply(cmp, &pair, env, gc) catch return error.EvalFailed;
    if (r.isInt()) {
        const i = r.asInt();
        if (i < 0) return -1;
        if (i > 0) return 1;
        return 0;
    }
    if (r.isFloat()) {
        const f = r.asFloat();
        if (f < 0) return -1;
        if (f > 0) return 1;
        return 0;
    }
    if (r.isBool()) {
        return if (r.asBool()) -1 else 1;
    }
    if (r.isNil()) return 1; // nil means "not less than" => treat as greater
    // Any other truthy value => a < b
    return -1;
}

fn compareValues(cmp: Value, a: Value, b: Value, env: *Env, gc: *GC) !i32 {
    if (cmp.isNil()) return defaultCompare(a, b, gc);
    return userCompare(cmp, a, b, env, gc);
}

// ---------------------------------------------------------------------------
// Metadata tagging.  We stash `:sorted true` and `:comparator <fn>` on the
// object's meta map so downstream consumers (printers, seq ops, structural
// equality) can discover the sort discipline.
// ---------------------------------------------------------------------------

fn attachSortedMeta(gc: *GC, obj: *Obj, comparator: Value) !void {
    const meta = try gc.allocObj(.map);
    try meta.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("sorted")));
    try meta.data.map.vals.append(gc.allocator, Value.makeBool(true));
    try meta.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("comparator")));
    try meta.data.map.vals.append(gc.allocator, comparator);
    obj.meta = meta;
}

// ---------------------------------------------------------------------------
// Insertion helpers (binary search + shift).
// ---------------------------------------------------------------------------

/// Insert `v` into a sorted Value list, deduplicating if an equal element
/// already exists.  `cmp` is the comparator Value (nil = default).
fn insertSortedSet(
    items: *std.ArrayListUnmanaged(Value),
    v: Value,
    cmp: Value,
    env: *Env,
    gc: *GC,
) !void {
    var lo: usize = 0;
    var hi: usize = items.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const c = try compareValues(cmp, items.items[mid], v, env, gc);
        if (c < 0) {
            lo = mid + 1;
        } else if (c > 0) {
            hi = mid;
        } else {
            return; // equal — set semantics, drop duplicate
        }
    }
    try items.insert(gc.allocator, lo, v);
}

/// Insert or replace `(k, val)` in sorted map.
fn insertSortedMap(
    keys: *std.ArrayListUnmanaged(Value),
    vals: *std.ArrayListUnmanaged(Value),
    k: Value,
    val: Value,
    cmp: Value,
    env: *Env,
    gc: *GC,
) !void {
    var lo: usize = 0;
    var hi: usize = keys.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const c = try compareValues(cmp, keys.items[mid], k, env, gc);
        if (c < 0) {
            lo = mid + 1;
        } else if (c > 0) {
            hi = mid;
        } else {
            vals.items[mid] = val; // replace
            return;
        }
    }
    try keys.insert(gc.allocator, lo, k);
    try vals.insert(gc.allocator, lo, val);
}

// ---------------------------------------------------------------------------
// Builtins
// ---------------------------------------------------------------------------

/// (sorted-set & xs) — default-compare sorted set.
pub fn sortedSetFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    const obj = try gc.allocObj(.set);
    const cmp = Value.makeNil();
    for (args) |a| {
        try insertSortedSet(&obj.data.set.items, a, cmp, env, gc);
    }
    try attachSortedMeta(gc, obj, cmp);
    return Value.makeObj(obj);
}

/// (sorted-set-by cmp & xs) — user-comparator sorted set.
pub fn sortedSetByFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const cmp = args[0];
    const obj = try gc.allocObj(.set);
    for (args[1..]) |a| {
        try insertSortedSet(&obj.data.set.items, a, cmp, env, gc);
    }
    try attachSortedMeta(gc, obj, cmp);
    return Value.makeObj(obj);
}

/// (sorted-map & kvs) — default-compare sorted map.
pub fn sortedMapFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;
    const obj = try gc.allocObj(.map);
    const cmp = Value.makeNil();
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        try insertSortedMap(&obj.data.map.keys, &obj.data.map.vals, args[i], args[i + 1], cmp, env, gc);
    }
    try attachSortedMeta(gc, obj, cmp);
    return Value.makeObj(obj);
}

/// (sorted-map-by cmp & kvs) — user-comparator sorted map.
pub fn sortedMapByFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if ((args.len - 1) % 2 != 0) return error.ArityError;
    const cmp = args[0];
    const obj = try gc.allocObj(.map);
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        try insertSortedMap(&obj.data.map.keys, &obj.data.map.vals, args[i], args[i + 1], cmp, env, gc);
    }
    try attachSortedMeta(gc, obj, cmp);
    return Value.makeObj(obj);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "default compare numeric ordering" {
    const a = Value.makeInt(1);
    const b = Value.makeInt(2);
    var dummy: GC = undefined;
    try std.testing.expect(defaultCompare(a, b, &dummy) < 0);
    try std.testing.expect(defaultCompare(b, a, &dummy) > 0);
    try std.testing.expect(defaultCompare(a, a, &dummy) == 0);
}
