# SRFI-171 Transducer Implementation Plan for nanoclj-zig

## 1. Overview

SRFI-171 defines **transducers** — composable algorithmic transformations that are independent of the collection type they operate on. This plan implements SRFI-171 as **Tier 5** of SectorClojure in `sector.zig`.

**Source**: https://srfi.schemers.org/srfi-171/srfi-171.html (final, 2019-10-26)

---

## 2. SRFI-171 → Clojure Mapping

| SRFI-171 | Clojure Equivalent | Type | State |
|---|---|---|---|
| `tmap` | `(map f)` 1-arity transducer | transducer | stateless |
| `tfilter` | `(filter pred)` 1-arity transducer | transducer | stateless |
| `tremove` | `(remove pred)` 1-arity transducer | transducer | stateless |
| `tfilter-map` | `(keep f)` | transducer | stateless |
| `treplace` | `(replace smap)` | transducer | stateless |
| `tdrop` | `(drop n)` 1-arity transducer | transducer | stateful |
| `ttake` | `(take n)` 1-arity transducer | transducer | stateful |
| `tdrop-while` | `(drop-while pred)` 1-arity transducer | transducer | stateful |
| `ttake-while` | `(take-while pred)` 1-arity transducer | transducer | stateful |
| `tconcatenate` | `cat` | transducer (value) | stateless |
| `tappend-map` | `(mapcat f)` | transducer | stateless |
| `tflatten` | (recursive flatten xf) | transducer (value) | stateless |
| `tdelete-neighbor-duplicates` | `(dedupe)` | transducer | stateful |
| `tdelete-duplicates` | `(distinct)` 1-arity transducer | transducer | stateful |
| `tsegment` | `(partition-all n)` 1-arity transducer | transducer | stateful |
| `tpartition` | `(partition-by f)` 1-arity transducer | transducer | stateful |
| `tadd-between` | `(interpose sep)` 1-arity transducer | transducer | stateful |
| `tenumerate` | `(map-indexed vector)` | transducer | stateful |
| `tlog` | (debug tap) | transducer | stateless |
| `rcons` | `conj` + reverse completion | reducer | — |
| `reverse-rcons` | `conj` (no reverse) | reducer | — |
| `rcount` | counting reducer | reducer | — |
| `rany` | `(some pred)` reducer | reducer factory | — |
| `revery` | `(every? pred)` reducer | reducer factory | — |
| `reduced` | `reduced` | meta helper | — ✅ exists |
| `reduced?` | `reduced?` | meta helper | — ✅ exists |
| `unreduce`/`unreduced` | `unreduced` | meta helper | — ✅ exists |
| `ensure-reduced` | `ensure-reduced` | meta helper | — missing |
| `preserving-reduced` | `preserving-reduced` | meta helper | — missing |

---

## 3. What Already Exists in nanoclj-zig

### ✅ Fully implemented (core.zig)
- `reduced` (line 4151): wraps value in `vector` with `is_transient=true` marker
- `reduced?` (line 4159): checks transient vector marker
- `unreduced` (line 4166): unwraps reduced value
- `transduce` (line 4177): `(transduce xform f init coll)` — calls `(xform f)` to get rf, reduces over coll, handles early termination
- `reductions` (line 4111): intermediate reduce values with reduced support
- `reduce` (line 1290): standard 2/3-arity reduce
- `comp` (line 2710): function composition via `partial_fn` with `__comp__` marker

### ✅ Eager collection ops (exist but NOT as transducers)
- `map`, `filter`, `remove`, `into`, `take`, `drop`, `take-while`, `drop-while`
- `concat`, `reverse`, `flatten`, `mapcat`, `interpose`, `partition`, `distinct`

### ❌ Missing (to implement as Tier 5)
- All `t*` transducer factory functions
- All `r*` reducer functions
- `ensure-reduced`, `preserving-reduced` meta helpers
- `list-transduce` (SRFI-171 convenience — maps to `transduce` in Clojure)

---

## 4. Architecture: How Transducers Work in Zig

### 4.1 Representation via `partial_fn` Dispatch

The existing `partial_fn` mechanism (eval.zig:1324-1369) already dispatches on keyword markers in `bound_args[0]` when `func == nil`. We extend this pattern:

```
Transducer Factory (e.g., tmap):
  partial_fn {
    func: nil (sentinel)
    bound_args: [__tmap__, captured_f]
  }

When called with (reducer) → creates:
  Transducer Reducer (e.g., tmap-rf):
    partial_fn {
      func: nil (sentinel)
      bound_args: [__tmap_rf__, downstream_reducer, captured_f]
    }

When tmap-rf is called:
  0 args → init:     call downstream_reducer()
  1 arg  → complete: call downstream_reducer(result)
  2 args → step:     call downstream_reducer(result, f(input))
```

### 4.2 Mutable State for Stateful Transducers

Stateful transducers (ttake, tdrop, etc.) need mutable state. Use an `atom` ObjKind in `bound_args`:

```
ttake Reducer:
  partial_fn {
    func: nil
    bound_args: [__ttake_rf__, downstream_reducer, atom{n_remaining}]
  }
```

The atom's value is mutated during the step function.

### 4.3 The `reduced` Protocol

Already implemented. A reduced value is a `vector` with `is_transient=true` containing one element. Detection:
```zig
fn isReduced(v: Value) bool {
    return v.isObj() and v.asObj().kind == .vector 
           and v.asObj().is_transient 
           and v.asObj().data.vector.items.items.len == 1;
}
fn deref_reduced(v: Value) Value {
    return v.asObj().data.vector.items.items[0];
}
```

---

## 5. Implementation Plan: Exact Zig Functions

### 5.1 File: `sector.zig` — New Tier 5 Builtins

All transducer factory functions are registered as `BuiltinEntry` items in `SECTOR_BUILTINS`:

```zig
// ────────────────────────────────────────────────────────────────
// Tier 5: SRFI-171 — Transducers
// ────────────────────────────────────────────────────────────────

// ── Meta helpers ──
.{ .name = "ensure-reduced",     .func = &t5_ensure_reduced,     .tier = .transducers },
.{ .name = "preserving-reduced", .func = &t5_preserving_reduced, .tier = .transducers },

// ── Transducer factories ──
.{ .name = "tmap",               .func = &t5_tmap,               .tier = .transducers },
.{ .name = "tfilter",            .func = &t5_tfilter,            .tier = .transducers },
.{ .name = "tremove",            .func = &t5_tremove,            .tier = .transducers },
.{ .name = "tfilter-map",        .func = &t5_tfilter_map,        .tier = .transducers },
.{ .name = "treplace",           .func = &t5_treplace,           .tier = .transducers },
.{ .name = "tdrop",              .func = &t5_tdrop,              .tier = .transducers },
.{ .name = "ttake",              .func = &t5_ttake,              .tier = .transducers },
.{ .name = "tdrop-while",        .func = &t5_tdrop_while,        .tier = .transducers },
.{ .name = "ttake-while",        .func = &t5_ttake_while,        .tier = .transducers },
.{ .name = "tconcatenate",       .func = &t5_tconcatenate,       .tier = .transducers },
.{ .name = "tappend-map",        .func = &t5_tappend_map,        .tier = .transducers },
.{ .name = "tflatten",           .func = &t5_tflatten,           .tier = .transducers },
.{ .name = "tdelete-neighbor-duplicates", .func = &t5_tdelete_neighbor_dups, .tier = .transducers },
.{ .name = "tdelete-duplicates", .func = &t5_tdelete_dups,       .tier = .transducers },
.{ .name = "tsegment",           .func = &t5_tsegment,           .tier = .transducers },
.{ .name = "tpartition",         .func = &t5_tpartition,         .tier = .transducers },
.{ .name = "tadd-between",       .func = &t5_tadd_between,       .tier = .transducers },
.{ .name = "tenumerate",         .func = &t5_tenumerate,         .tier = .transducers },
.{ .name = "tlog",               .func = &t5_tlog,               .tier = .transducers },

// ── Reducers ──
.{ .name = "rcons",              .func = &t5_rcons,              .tier = .transducers },
.{ .name = "reverse-rcons",      .func = &t5_reverse_rcons,      .tier = .transducers },
.{ .name = "rcount",             .func = &t5_rcount,             .tier = .transducers },
.{ .name = "rany",               .func = &t5_rany,               .tier = .transducers },
.{ .name = "revery",             .func = &t5_revery,             .tier = .transducers },

// ── Transduce entry points ──
.{ .name = "list-transduce",     .func = &t5_list_transduce,     .tier = .transducers },
.{ .name = "transduce",          .func = &t5_transduce,          .tier = .transducers },
```

### 5.2 Helper: Transducer/Reducer Creation

```zig
/// Create a transducer partial_fn with marker keyword and captured args
fn makeTransducer(gc: *GC, marker: []const u8, captured: []const Value) !Value {
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil(); // sentinel
    const mk = Value.makeKeyword(try gc.internString(marker));
    try obj.data.partial_fn.bound_args.append(gc.allocator, mk);
    for (captured) |c| try obj.data.partial_fn.bound_args.append(gc.allocator, c);
    return Value.makeObj(obj);
}

/// Create a reducer partial_fn with marker, downstream reducer, and captured state
fn makeReducer(gc: *GC, marker: []const u8, downstream: Value, captured: []const Value) !Value {
    const obj = try gc.allocObj(.partial_fn);
    obj.data.partial_fn.func = Value.makeNil();
    const mk = Value.makeKeyword(try gc.internString(marker));
    try obj.data.partial_fn.bound_args.append(gc.allocator, mk);
    try obj.data.partial_fn.bound_args.append(gc.allocator, downstream);
    for (captured) |c| try obj.data.partial_fn.bound_args.append(gc.allocator, c);
    return Value.makeObj(obj);
}

/// Create a mutable state atom holding initial value
fn makeStateAtom(gc: *GC, init: Value) !Value {
    const obj = try gc.allocObj(.atom);
    obj.data.atom.val = init;
    return Value.makeObj(obj);
}

/// Check if value is reduced (transient vector wrapper)
fn isReduced(v: Value) bool {
    if (!v.isObj()) return false;
    const obj = v.asObj();
    return obj.kind == .vector and obj.is_transient and obj.data.vector.items.items.len == 1;
}

/// Unwrap reduced value
fn derefReduced(v: Value) Value {
    return v.asObj().data.vector.items.items[0];
}

/// Wrap in reduced if not already
fn ensureReduced(v: Value, gc: *GC) !Value {
    if (isReduced(v)) return v;
    const obj = try gc.allocObj(.vector);
    obj.is_transient = true;
    try obj.data.vector.items.append(gc.allocator, v);
    return Value.makeObj(obj);
}
```

### 5.3 Transducer Factory Functions (sector.zig)

Each factory creates a `partial_fn` with a marker:

```zig
// ── Stateless transducers ──

/// (tmap f) → transducer that applies f to each value
fn t5_tmap(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tmap__", args[0..1]);
}

/// (tfilter pred?) → transducer that keeps values where (pred? v) is truthy
fn t5_tfilter(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tfilter__", args[0..1]);
}

/// (tremove pred?) → transducer that removes values where (pred? v) is truthy
fn t5_tremove(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tremove__", args[0..1]);
}

/// (tfilter-map f) → (compose (tmap f) (tfilter identity))
fn t5_tfilter_map(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tfilter_map__", args[0..1]);
}

/// (treplace mapping) → transducer that replaces values found in mapping
fn t5_treplace(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__treplace__", args[0..1]);
}

// ── Stateful transducers ──

/// (tdrop n) → transducer that discards first n values
fn t5_tdrop(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    return makeTransducer(gc, "__tdrop__", args[0..1]);
}

/// (ttake n) → transducer that takes first n values then stops
fn t5_ttake(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    return makeTransducer(gc, "__ttake__", args[0..1]);
}

/// (tdrop-while pred?) → transducer that drops while pred? returns true
fn t5_tdrop_while(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tdrop_while__", args[0..1]);
}

/// (ttake-while pred?) → transducer that takes while pred? returns true
fn t5_ttake_while(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    return makeTransducer(gc, "__ttake_while__", args[0..args.len]);
}

/// tconcatenate — a transducer (not a factory), concatenates list elements
fn t5_tconcatenate(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    // tconcatenate IS a transducer, so when called with 0 args it returns itself,
    // or with 1 arg (reducer) it returns the reducer fn
    if (args.len == 0) return makeTransducer(gc, "__tconcatenate__", &.{});
    // If called with 1 arg, treat as (tconcatenate reducer)
    if (args.len == 1) return makeReducer(gc, "__tconcatenate_rf__", args[0], &.{});
    return error.ArityError;
}

/// (tappend-map f) → (compose (tmap f) tconcatenate)
fn t5_tappend_map(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tappend_map__", args[0..1]);
}

/// tflatten — a transducer that recursively flattens nested lists
fn t5_tflatten(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return makeTransducer(gc, "__tflatten__", &.{});
    if (args.len == 1) return makeReducer(gc, "__tflatten_rf__", args[0], &.{});
    return error.ArityError;
}

/// (tdelete-neighbor-duplicates [eq?]) → transducer removing consecutive dups
fn t5_tdelete_neighbor_dups(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    return makeTransducer(gc, "__tdedup_neighbor__", args[0..args.len]);
}

/// (tdelete-duplicates [eq?]) → transducer removing all duplicates
fn t5_tdelete_dups(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    return makeTransducer(gc, "__tdedup__", args[0..args.len]);
}

/// (tsegment n) → transducer that groups into lists of n elements
fn t5_tsegment(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    return makeTransducer(gc, "__tsegment__", args[0..1]);
}

/// (tpartition pred?) → transducer that groups by predicate changes
fn t5_tpartition(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tpartition__", args[0..1]);
}

/// (tadd-between value) → transducer interposing value between elements
fn t5_tadd_between(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__tadd_between__", args[0..1]);
}

/// (tenumerate [start]) → transducer that pairs index with each value
fn t5_tenumerate(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const start = if (args.len > 0 and args[0].isInt()) args[0] else Value.makeInt(0);
    return makeTransducer(gc, "__tenumerate__", &.{start});
}

/// (tlog [logger]) → transducer that logs each value (side effect)
fn t5_tlog(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len > 1) return error.ArityError;
    return makeTransducer(gc, "__tlog__", args[0..args.len]);
}
```

### 5.4 Reducer Functions (sector.zig)

Reducers follow the 3-arity protocol: `() → init`, `(result) → complete`, `(result, input) → step`.

```zig
/// rcons — 3-arity reducer: () → '(), (result) → reverse(result), (result, input) → cons(input, result)
fn t5_rcons(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    switch (args.len) {
        0 => return Value.makeObj(try gc.allocObj(.list)),  // identity: empty list
        1 => {
            // completion: reverse the accumulated list
            if (args[0].isNil()) return Value.makeObj(try gc.allocObj(.list));
            if (!args[0].isObj()) return args[0];
            const obj = args[0].asObj();
            if (obj.kind != .list) return args[0];
            const items = obj.data.list.items.items;
            const new = try gc.allocObj(.list);
            var i = items.len;
            while (i > 0) { i -= 1; try new.data.list.items.append(gc.allocator, items[i]); }
            return Value.makeObj(new);
        },
        2 => {
            // step: cons input onto front of result (builds in reverse)
            const new = try gc.allocObj(.list);
            try new.data.list.items.append(gc.allocator, args[1]); // input first
            if (args[0].isObj() and args[0].asObj().kind == .list) {
                for (args[0].asObj().data.list.items.items) |item|
                    try new.data.list.items.append(gc.allocator, item);
            }
            return Value.makeObj(new);
        },
        else => return error.ArityError,
    }
}

/// reverse-rcons — same as rcons but completion returns as-is (no reverse)
fn t5_reverse_rcons(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    switch (args.len) {
        0 => return Value.makeObj(try gc.allocObj(.list)),
        1 => return args[0], // no reverse
        2 => {
            const new = try gc.allocObj(.list);
            try new.data.list.items.append(gc.allocator, args[1]);
            if (args[0].isObj() and args[0].asObj().kind == .list) {
                for (args[0].asObj().data.list.items.items) |item|
                    try new.data.list.items.append(gc.allocator, item);
            }
            return Value.makeObj(new);
        },
        else => return error.ArityError,
    }
}

/// rcount — 3-arity reducer: () → 0, (result) → result, (result, _) → result + 1
fn t5_rcount(args: []Value, _: *GC, _: *Env) anyerror!Value {
    switch (args.len) {
        0 => return Value.makeInt(0),
        1 => return args[0],
        2 => return Value.makeInt((if (args[0].isInt()) args[0].asInt() else @as(i48, 0)) + 1),
        else => return error.ArityError,
    }
}

/// (rany pred?) → 3-arity reducer that returns (reduced (pred? v)) on first truthy
fn t5_rany(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // Returns a partial_fn reducer
    return makeTransducer(gc, "__rany__", args[0..1]);
}

/// (revery pred?) → 3-arity reducer that returns (reduced false) on first falsy
fn t5_revery(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__revery__", args[0..1]);
}
```

### 5.5 Meta Helpers (sector.zig)

```zig
/// (ensure-reduced val) → wrap in reduced if not already
fn t5_ensure_reduced(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return ensureReduced(args[0], gc);
}

/// (preserving-reduced reducer) → reducer that double-wraps reduced values
fn t5_preserving_reduced(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return makeTransducer(gc, "__preserving_reduced__", args[0..1]);
}
```

### 5.6 Transduce Entry Point (sector.zig)

```zig
/// (list-transduce xform f [init] lst) — SRFI-171 convenience
/// Maps to: (transduce xform f [init] lst) with completion step
fn t5_list_transduce(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    return t5_transduce(args, gc, env);
}

/// (transduce xform f init coll) — full transduction with completion
/// 1. rf = (xform f)
/// 2. acc = init (or (f) if no init)
/// 3. For each item in coll: acc = (rf acc item); break if reduced
/// 4. result = (rf acc) — completion step
/// 5. return unreduced(result)
fn t5_transduce(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 3) return error.ArityError;

    const xform = args[0];
    const f = args[1];
    var init: Value = undefined;
    var coll: Value = undefined;

    if (args.len == 3) {
        // (transduce xform f coll) — init = (f)
        var empty = [_]Value{};
        init = try callReducer(f, &empty, gc, env);
        coll = args[2];
    } else {
        // (transduce xform f init coll)
        init = args[2];
        coll = args[3];
    }

    // Step 1: create the reducing function
    var xf_args = [_]Value{f};
    const rf = try eval_mod.apply(xform, &xf_args, env, gc);

    // Step 2: reduce
    var acc = init;
    const items = getItems(coll) orelse return error.TypeError;
    for (items) |item| {
        var step_args = [_]Value{ acc, item };
        acc = try callReducer(rf, &step_args, gc, env);
        if (isReduced(acc)) {
            acc = derefReduced(acc);
            break;
        }
    }

    // Step 3: completion
    var complete_args = [_]Value{acc};
    acc = try callReducer(rf, &complete_args, gc, env);

    // Step 4: unreduced
    if (isReduced(acc)) acc = derefReduced(acc);
    return acc;
}

/// Call a reducer (could be builtin, partial_fn, or user fn)
fn callReducer(rf: Value, args: []Value, gc: *GC, env: *Env) !Value {
    if (rf.isKeyword()) {
        // Builtin sentinel
        const core = @import("core.zig");
        if (core.isBuiltinSentinel(rf, gc)) |name| {
            if (core.lookupBuiltin(name)) |builtin| {
                return builtin(args, gc, env);
            }
        }
        // Also check sector builtins
        const name = gc.getString(rf.asKeywordId());
        if (lookupSectorBuiltin(name, .transducers)) |builtin| {
            return builtin(args, gc, env);
        }
    }
    return eval_mod.apply(rf, args, env, gc);
}
```

### 5.7 Dispatch in eval.zig — Transducer Partial_fn Markers

Add to `eval.zig` in the `partial_fn` dispatch block (after the existing `__constantly__` check):

```zig
// ── SRFI-171 Transducer dispatch ──
// Transducer factories: called with (reducer) → create reducer fn
if (std.mem.eql(u8, marker, "__tmap__")) {
    if (args.len != 1) return error.ArityError;
    const sector = @import("sector.zig");
    return sector.makeReducer(gc, "__tmap_rf__", args[0], bound[1..]);
}
if (std.mem.eql(u8, marker, "__tfilter__")) {
    if (args.len != 1) return error.ArityError;
    return sector.makeReducer(gc, "__tfilter_rf__", args[0], bound[1..]);
}
if (std.mem.eql(u8, marker, "__tremove__")) {
    if (args.len != 1) return error.ArityError;
    return sector.makeReducer(gc, "__tremove_rf__", args[0], bound[1..]);
}
// ... (all other transducer factory markers)

// Stateful transducer factories: create atom for mutable state
if (std.mem.eql(u8, marker, "__ttake__")) {
    if (args.len != 1) return error.ArityError;
    const n = bound[1]; // the n value
    const state = try sector.makeStateAtom(gc, n); // atom holding remaining count
    return sector.makeReducer(gc, "__ttake_rf__", args[0], &.{state});
}
if (std.mem.eql(u8, marker, "__tdrop__")) {
    if (args.len != 1) return error.ArityError;
    const state = try sector.makeStateAtom(gc, bound[1]);
    return sector.makeReducer(gc, "__tdrop_rf__", args[0], &.{state});
}
// ... (all other stateful factory markers)

// ── Transducer reducer dispatch ──
// tmap-rf: 0→init, 1→complete, 2→step
if (std.mem.eql(u8, marker, "__tmap_rf__")) {
    const downstream = bound[1]; // downstream reducer
    const f = bound[2]; // mapping function
    switch (args.len) {
        0 => return apply(downstream, &.{}, caller_env, gc),
        1 => return apply(downstream, args, caller_env, gc),
        2 => {
            // (rf result (f input))
            var mapped = [_]Value{args[1]};
            const v = try apply(f, &mapped, caller_env, gc);
            var step = [_]Value{args[0], v};
            return apply(downstream, &step, caller_env, gc);
        },
        else => return error.ArityError,
    }
}

if (std.mem.eql(u8, marker, "__tfilter_rf__")) {
    const downstream = bound[1];
    const pred = bound[2];
    switch (args.len) {
        0 => return apply(downstream, &.{}, caller_env, gc),
        1 => return apply(downstream, args, caller_env, gc),
        2 => {
            var test_args = [_]Value{args[1]};
            const keep = try apply(pred, &test_args, caller_env, gc);
            if (keep.isTruthy()) {
                var step = [_]Value{args[0], args[1]};
                return apply(downstream, &step, caller_env, gc);
            }
            return args[0]; // skip: return result unchanged
        },
        else => return error.ArityError,
    }
}

if (std.mem.eql(u8, marker, "__tremove_rf__")) {
    // Inverse of tfilter
    const downstream = bound[1];
    const pred = bound[2];
    switch (args.len) {
        0 => return apply(downstream, &.{}, caller_env, gc),
        1 => return apply(downstream, args, caller_env, gc),
        2 => {
            var test_args = [_]Value{args[1]};
            const remove = try apply(pred, &test_args, caller_env, gc);
            if (!remove.isTruthy()) {
                var step = [_]Value{args[0], args[1]};
                return apply(downstream, &step, caller_env, gc);
            }
            return args[0];
        },
        else => return error.ArityError,
    }
}

if (std.mem.eql(u8, marker, "__ttake_rf__")) {
    const downstream = bound[1];
    const state_atom = bound[2].asObj(); // atom holding remaining count
    switch (args.len) {
        0 => return apply(downstream, &.{}, caller_env, gc),
        1 => return apply(downstream, args, caller_env, gc),
        2 => {
            const n = state_atom.data.atom.val.asInt();
            if (n > 0) {
                state_atom.data.atom.val = Value.makeInt(n - 1);
                var step = [_]Value{args[0], args[1]};
                const result = try apply(downstream, &step, caller_env, gc);
                if (n - 1 <= 0) return sector.ensureReduced(result, gc);
                return result;
            }
            return sector.ensureReduced(args[0], gc); // done
        },
        else => return error.ArityError,
    }
}

if (std.mem.eql(u8, marker, "__tdrop_rf__")) {
    const downstream = bound[1];
    const state_atom = bound[2].asObj();
    switch (args.len) {
        0 => return apply(downstream, &.{}, caller_env, gc),
        1 => return apply(downstream, args, caller_env, gc),
        2 => {
            const n = state_atom.data.atom.val.asInt();
            if (n > 0) {
                state_atom.data.atom.val = Value.makeInt(n - 1);
                return args[0]; // skip
            }
            var step = [_]Value{args[0], args[1]};
            return apply(downstream, &step, caller_env, gc);
        },
        else => return error.ArityError,
    }
}

// ... (similar patterns for all other transducer reducer markers)

// ── rany/revery reducer dispatch ──
if (std.mem.eql(u8, marker, "__rany__")) {
    const pred = bound[1];
    switch (args.len) {
        0 => return Value.makeBool(false),  // identity
        1 => return args[0],                // completion
        2 => {
            var test_args = [_]Value{args[1]};
            const result = try apply(pred, &test_args, caller_env, gc);
            if (result.isTruthy()) return sector.ensureReduced(result, gc);
            return args[0];
        },
        else => return error.ArityError,
    }
}
if (std.mem.eql(u8, marker, "__revery__")) {
    const pred = bound[1];
    switch (args.len) {
        0 => return Value.makeBool(true),
        1 => return args[0],
        2 => {
            var test_args = [_]Value{args[1]};
            const result = try apply(pred, &test_args, caller_env, gc);
            if (!result.isTruthy()) {
                return sector.ensureReduced(Value.makeBool(false), gc);
            }
            return result; // return last truthy
        },
        else => return error.ArityError,
    }
}
```

---

## 6. Complete Marker Reference

| Marker | Kind | Args in bound_args |
|---|---|---|
| `__tmap__` | factory | `[marker, f]` |
| `__tmap_rf__` | reducer | `[marker, downstream, f]` |
| `__tfilter__` | factory | `[marker, pred]` |
| `__tfilter_rf__` | reducer | `[marker, downstream, pred]` |
| `__tremove__` | factory | `[marker, pred]` |
| `__tremove_rf__` | reducer | `[marker, downstream, pred]` |
| `__tfilter_map__` | factory | `[marker, f]` |
| `__tfilter_map_rf__` | reducer | `[marker, downstream, f]` |
| `__treplace__` | factory | `[marker, mapping]` |
| `__treplace_rf__` | reducer | `[marker, downstream, mapping]` |
| `__ttake__` | factory | `[marker, n]` |
| `__ttake_rf__` | reducer | `[marker, downstream, atom{n}]` |
| `__tdrop__` | factory | `[marker, n]` |
| `__tdrop_rf__` | reducer | `[marker, downstream, atom{n}]` |
| `__ttake_while__` | factory | `[marker, pred, ?retf]` |
| `__ttake_while_rf__` | reducer | `[marker, downstream, pred, atom{done?}, ?retf]` |
| `__tdrop_while__` | factory | `[marker, pred]` |
| `__tdrop_while_rf__` | reducer | `[marker, downstream, pred, atom{dropping?}]` |
| `__tconcatenate__` | factory | `[marker]` |
| `__tconcatenate_rf__` | reducer | `[marker, downstream]` |
| `__tappend_map__` | factory | `[marker, f]` |
| `__tappend_map_rf__` | reducer | `[marker, downstream, f]` |
| `__tflatten__` | factory | `[marker]` |
| `__tflatten_rf__` | reducer | `[marker, downstream]` |
| `__tdedup_neighbor__` | factory | `[marker, ?eq]` |
| `__tdedup_neighbor_rf__` | reducer | `[marker, downstream, atom{prev}, ?eq]` |
| `__tdedup__` | factory | `[marker, ?eq]` |
| `__tdedup_rf__` | reducer | `[marker, downstream, atom{seen_set}]` |
| `__tsegment__` | factory | `[marker, n]` |
| `__tsegment_rf__` | reducer | `[marker, downstream, n, atom{buffer}]` |
| `__tpartition__` | factory | `[marker, pred]` |
| `__tpartition_rf__` | reducer | `[marker, downstream, pred, atom{buffer}, atom{prev_val}]` |
| `__tadd_between__` | factory | `[marker, value]` |
| `__tadd_between_rf__` | reducer | `[marker, downstream, value, atom{started?}]` |
| `__tenumerate__` | factory | `[marker, start]` |
| `__tenumerate_rf__` | reducer | `[marker, downstream, atom{counter}]` |
| `__tlog__` | factory | `[marker, ?logger]` |
| `__tlog_rf__` | reducer | `[marker, downstream, ?logger]` |
| `__rany__` | reducer | `[marker, pred]` |
| `__revery__` | reducer | `[marker, pred]` |
| `__preserving_reduced__` | wrapper | `[marker, inner_reducer]` |

---

## 7. Implementation Order

### Phase 1: Infrastructure
1. Add `isReduced`, `derefReduced`, `ensureReduced` helpers to sector.zig
2. Add `makeTransducer`, `makeReducer`, `makeStateAtom` helpers
3. Add `callReducer` helper
4. Implement `t5_transduce` with full 4-step protocol (init, step, complete, unreduced)
5. Add `t5_ensure_reduced`, `t5_preserving_reduced`

### Phase 2: Core Stateless Transducers
6. `tmap` + `__tmap_rf__` dispatch
7. `tfilter` + `__tfilter_rf__` dispatch
8. `tremove` + `__tremove_rf__` dispatch
9. `tfilter-map` + `__tfilter_map_rf__` dispatch

### Phase 3: Core Reducers
10. `rcons` (3-arity)
11. `reverse-rcons` (3-arity)
12. `rcount` (3-arity)
13. `rany` + dispatch
14. `revery` + dispatch

### Phase 4: Stateful Transducers
15. `ttake` + `__ttake_rf__` dispatch (with atom state)
16. `tdrop` + `__tdrop_rf__` dispatch
17. `ttake-while` + dispatch
18. `tdrop-while` + dispatch

### Phase 5: Compound Transducers
19. `tconcatenate` + dispatch
20. `tappend-map` + dispatch
21. `tflatten` + dispatch (recursive)

### Phase 6: Advanced Stateful Transducers
22. `tdelete-neighbor-duplicates` + dispatch
23. `tdelete-duplicates` + dispatch
24. `tsegment` + dispatch (flush on complete)
25. `tpartition` + dispatch (flush on complete)
26. `tadd-between` + dispatch
27. `tenumerate` + dispatch
28. `tlog` + dispatch

### Phase 7: Integration
29. `treplace` + dispatch
30. `list-transduce` convenience
31. Update `TIER_SPECS[5].builtin_count` to actual count
32. Add Tier 5 macros if needed

---

## 8. Test Plan

```clojure
;; Phase 2 tests
(list-transduce (tmap inc) rcons '(1 2 3))           ;=> (2 3 4)
(list-transduce (tfilter odd?) rcons '(1 2 3 4 5))   ;=> (1 3 5)
(list-transduce (tremove odd?) rcons '(1 2 3 4 5))   ;=> (2 4)
(list-transduce (tfilter-map (fn [x] (if (odd? x) (* x x) nil))) rcons '(1 2 3 4 5)) ;=> (1 9 25)

;; Phase 3 tests
(list-transduce (tmap inc) rcount '(1 2 3))           ;=> 3
(list-transduce (tmap inc) (rany odd?) '(1 3 5))      ;=> #f / false
(list-transduce (tmap inc) (rany odd?) '(1 3 4 5))    ;=> #t / true

;; Phase 4 tests
(list-transduce (ttake 3) rcons '(1 2 3 4 5))         ;=> (1 2 3)
(list-transduce (tdrop 2) rcons '(1 2 3 4 5))         ;=> (3 4 5)
(list-transduce (ttake-while odd?) rcons '(1 3 5 2 4)) ;=> (1 3 5)
(list-transduce (tdrop-while odd?) rcons '(1 3 5 2 4)) ;=> (2 4)

;; Phase 5 tests
(list-transduce tconcatenate rcons '((1 2) (3 4)))     ;=> (1 2 3 4)
(list-transduce (tappend-map (fn [x] (list x x))) rcons '(1 2 3)) ;=> (1 1 2 2 3 3)
(list-transduce tflatten rcons '((1 2) 3 (4 (5 6))))   ;=> (1 2 3 4 5 6)

;; Phase 6 tests
(list-transduce (tsegment 2) rcons '(1 2 3 4 5))      ;=> ((1 2) (3 4) (5))
(list-transduce (tpartition odd?) rcons '(1 3 2 4 1))  ;=> ((1 3) (2 4) (1))
(list-transduce (tadd-between 0) rcons '(1 2 3))       ;=> (1 0 2 0 3)
(list-transduce (tenumerate) rcons '(a b c))            ;=> ((0 . a) (1 . b) (2 . c))

;; Composition
(list-transduce (comp (tfilter odd?) (tmap (fn [x] (* x x)))) rcons '(1 2 3 4 5)) ;=> (1 9 25)

;; Early termination
(list-transduce (comp (tfilter odd?) (ttake 2)) rcons '(1 2 3 4 5)) ;=> (1 3)
```

---

## 9. Files Modified

| File | Changes |
|---|---|
| `src/sector.zig` | Add ~25 `t5_*` builtin functions, helpers, register in `SECTOR_BUILTINS` |
| `src/eval.zig` | Add ~30 marker dispatch cases in `partial_fn` block |

**Estimated LOC**: ~600 lines in sector.zig, ~400 lines in eval.zig = ~1000 total
