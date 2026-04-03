# nanoclj-zig Fuel Bottleneck Analysis

## Executive Summary

The ~29x gap between nanoclj-zig (0.29s) and Janet (0.01s) on `fib(28)` stems from
three compounding bottlenecks in the fuel-bounded eval path (`transduction.zig`).
Five concrete optimizations are ranked below by estimated speedup × ease.

---

## Call-Count Model: `fib(28)`

For `fib(28)`, the interpreter makes:

| Operation | Count (approx) | Per-call cost |
|---|---|---|
| `evalBounded` calls | ~10M | tick() + descend/ascend |
| `Resources.fork()` | ~5M | Initialize [64]Resources on stack (~5KB) |
| `Resources.join()` | ~5M | Loop over children, accumulate trits |
| `depthFuelCost()` | ~10M | splitmix64 → RGB → rgbToHue (float) → hueToTrit |
| `Env.createChild()` | ~1M | Heap alloc + StringHashMap init + GC track |
| `lookupBuiltin()` | ~4M | HashMap string lookup |
| Special form string compare | ~10M | Up to 7× `std.mem.eql` per eval |

---

## Optimization #1: Lazy Fork (HIGHEST IMPACT)

**Problem:** `fork()` creates a `[64]Resources` array on every function application
and every builtin call, even though execution is sequential.

```zig
// CURRENT: transduction.zig lines 81-96 (function application)
var child_res = res.fork(raw_args.len);  // ← 5KB stack alloc + init!
var args_buf: [64]Value = undefined;
var args_count: usize = 0;
for (raw_args, 0..) |arg, i| {
    const d = evalBounded(arg, env, gc, &child_res[i]);
    ...
}
res.join(&child_res, args_count);  // ← loop + trit accumulation
```

The `Resources` struct is ~80 bytes (fuel u64 + depth u32 + read_depth u32 +
steps_taken u64 + max_depth_seen u32 + Limits ~40 bytes + trit_balance i8).
`[64]Resources` = **~5120 bytes initialized per fork**.

For fib(28), that's ~5M × 5KB = ~25GB of memory writes (even though it's stack,
the CPU still pays for cache-line filling and zeroing).

**Fix:** Only fork when `peval` is used. For sequential eval, pass `res` directly:

```zig
// PROPOSED: transduction.zig — sequential arg eval (no fork)
var args_buf: [64]Value = undefined;
var args_count: usize = 0;
for (raw_args) |arg| {
    if (args_count >= 64) return Domain.fail(.collection_too_large);
    const d = evalBounded(arg, env, gc, res);  // ← same res, no fork
    if (!d.isValue()) return d;
    args_buf[args_count] = d.value;
    args_count += 1;
}
return applyBounded(func_d.value, args_buf[0..args_count], env, gc, res);
```

Same change needed in `evalBoundedBuiltin`. The `peval` path already has its own
fork logic in `thread_peval.zig` and stays unchanged.

**Estimated speedup:** 3–5× on recursive benchmarks  
**Difficulty:** Easy — ~20 lines changed in transduction.zig  
**Risk:** GF(3) trit per-child tracking lost for sequential eval. Acceptable because
trit conservation is only meaningful for actual parallel execution.

---

## Optimization #2: Precompute depthFuelCost Lookup Table

**Problem:** Every `tick()` call computes `depthFuelCost(depth)` which runs:

```zig
// CURRENT: gay_skills.zig depthFuelCost()
pub fn depthFuelCost(depth: u32) u64 {
    const state = @as(u64, depth) *% GOLDEN +% GAY_SEED;
    var z = state +% GOLDEN;
    z = (z ^ (z >> 30)) *% MIX1;      // ← multiply
    z = (z ^ (z >> 27)) *% MIX2;      // ← multiply
    z = z ^ (z >> 31);
    const r: u8 = @truncate(z >> 16);
    const g: u8 = @truncate(z >> 8);
    const b: u8 = @truncate(z);
    // Then: rgbToHue → 3 float divides + comparisons + modular arith
    const trit = substrate.hueToTrit(rgbToHue(r, g, b));
    return switch (trit) { 1 => 1, 0 => 2, -1 => 3, else => 2 };
}
```

This is ~20 operations including floating-point division, called ~10M times.

**Fix:** Precompute a `[1024]u64` table at comptime (depth is bounded by
`Limits.max_depth = 1024`):

```zig
// PROPOSED: gay_skills.zig
const depth_fuel_lut: [1024]u64 = blk: {
    var table: [1024]u64 = undefined;
    for (0..1024) |d| {
        table[d] = computeDepthFuelCost(@intCast(d));
    }
    break :blk table;
};

pub fn depthFuelCost(depth: u32) u64 {
    if (depth < 1024) return depth_fuel_lut[depth];
    return computeDepthFuelCost(depth);  // fallback (never hit in practice)
}
```

Zig `comptime` makes this zero-cost: the table is embedded in the binary.

**Estimated speedup:** 1.5–2× (eliminates ~10M float computations)  
**Difficulty:** Trivial — ~10 lines  
**Risk:** None. Deterministic function, same results.

---

## Optimization #3: Symbol-ID Based Special Form Dispatch

**Problem:** Every `evalBounded` call on a list does sequential string comparisons:

```zig
// CURRENT: transduction.zig evalBounded()
if (std.mem.eql(u8, name, "quote")) { ... }   // strcmp #1
if (std.mem.eql(u8, name, "def")) { ... }     // strcmp #2
if (std.mem.eql(u8, name, "let*")) { ... }    // strcmp #3
if (std.mem.eql(u8, name, "if")) { ... }      // strcmp #4
if (std.mem.eql(u8, name, "do")) { ... }      // strcmp #5
if (std.mem.eql(u8, name, "fn*")) { ... }     // strcmp #6
if (std.mem.eql(u8, name, "peval")) { ... }   // strcmp #7
// Then: core.lookupBuiltin(name) — HashMap string lookup
```

For `(if (<= n 1) ...)`, this runs 4 string comparisons before matching "if".

**Fix:** Intern special form symbol IDs once at startup. Compare u48 integers:

```zig
// PROPOSED: transduction.zig
var sf_quote: u48 = undefined;
var sf_def: u48 = undefined;
var sf_let: u48 = undefined;
var sf_if: u48 = undefined;
var sf_do: u48 = undefined;
var sf_fn: u48 = undefined;
var sf_peval: u48 = undefined;

pub fn initSpecialForms(gc: *GC) !void {
    sf_quote = try gc.internString("quote");
    sf_def   = try gc.internString("def");
    sf_let   = try gc.internString("let*");
    sf_if    = try gc.internString("if");
    sf_do    = try gc.internString("do");
    sf_fn    = try gc.internString("fn*");
    sf_peval = try gc.internString("peval");
}

// In evalBounded:
const sym_id = items[0].asSymbolId();
if (sym_id == sf_if) return evalBoundedIf(items, env, gc, res);
// ... single u48 compare per check instead of mem.eql
```

**Estimated speedup:** 1.2–1.5× (saves ~50M+ byte comparisons)  
**Difficulty:** Easy — ~30 lines  
**Risk:** None. Symbol interning already guarantees unique IDs.

---

## Optimization #4: Flat Environment Frames

**Problem:** Every function application allocates a heap `Env` with a `StringHashMap`:

```zig
// CURRENT: transduction.zig applyBounded()
const child = fn_env.createChild() catch return Domain.fail(.type_error);
gc.trackEnv(child) catch return Domain.fail(.type_error);
// Then for each param:
child.set(name, args[i])  // → HashMap put (alloc bucket + hash + probe)
```

For `fib`, the function has 1 parameter (`n`). A HashMap for 1 entry is enormous
overhead: hash computation, bucket allocation, probe chain.

**Fix:** Small-env fast path — use a fixed-size array for ≤8 bindings:

```zig
// PROPOSED: env.zig — add SmallEnv variant
pub const SmallBinding = struct {
    name_ptr: [*]const u8,
    name_len: u16,
    val: Value,
};

pub const SmallEnv = struct {
    parent: ?*Env,
    bindings: [8]SmallBinding = undefined,
    count: u8 = 0,

    pub fn set(self: *SmallEnv, name: []const u8, val: Value) void {
        self.bindings[self.count] = .{
            .name_ptr = name.ptr,
            .name_len = @intCast(name.len),
            .val = val,
        };
        self.count += 1;
    }

    pub fn get(self: *const SmallEnv, name: []const u8) ?Value {
        var i: u8 = self.count;
        while (i > 0) {
            i -= 1;
            const b = &self.bindings[i];
            if (b.name_len == name.len and
                std.mem.eql(u8, b.name_ptr[0..b.name_len], name))
                return b.val;
        }
        if (self.parent) |p| return p.get(name);
        return null;
    }
};
```

For fib's 1-param env, lookup is a single pointer comparison + 1 byte comparison.

**Estimated speedup:** 1.5–2× (eliminates ~1M HashMap allocs + hash computations)  
**Difficulty:** Medium — requires dual-path Env or stack-allocated env frames  
**Risk:** Low. Falls back to HashMap for >8 bindings.

---

## Optimization #5: Tail-Call Optimization (TCO)

**Problem:** No tail-call optimization. Every recursive call grows the Zig call
stack (evalBounded → applyBounded → evalBounded → ...) and creates a new env frame.

For `fib`, TCO doesn't directly help (both recursive calls are under `+`, so
neither is in tail position). But for `sum`, `fact`, `loop/recur` patterns, and
many real programs, TCO eliminates stack growth entirely.

**Fix:** Detect tail position and trampoline:

```zig
// PROPOSED: transduction.zig applyBounded() — trampoline
fn applyBounded(func: Value, args: []Value, _: *Env, gc: *GC, res: *Resources) Domain {
    var current_func = func;
    var current_args = args;

    while (true) {
        // ... bind params to current_args in child env ...
        // Evaluate all body forms except last
        for (fn_data.body.items[0..fn_data.body.items.len-1]) |form| {
            const result = evalBounded(form, child, gc, res);
            if (!result.isValue()) return result;
        }
        // Last form: check if it's a self-call (recur) or another fn call
        const last = fn_data.body.items[fn_data.body.items.len-1];
        // If tail call: rebind args, loop instead of recurse
        if (isTailCall(last, current_func)) {
            current_args = evalArgs(last, child, gc, res);
            // Reuse child env (rebind params)
            continue;
        }
        return evalBounded(last, child, gc, res);
    }
}
```

**Estimated speedup:** 1.5–2× for tail-recursive programs; ~0% for fib  
**Difficulty:** Medium-Hard — requires tail-position analysis  
**Risk:** Must preserve semantics for non-tail calls.

---

## Combined Speedup Estimate

| # | Optimization | fib(28) speedup | Difficulty | Lines changed |
|---|---|---|---|---|
| 1 | Lazy fork (no fork for sequential) | 3–5× | Easy | ~20 |
| 2 | Precompute depthFuelCost LUT | 1.5–2× | Trivial | ~10 |
| 3 | Symbol-ID special form dispatch | 1.2–1.5× | Easy | ~30 |
| 4 | Flat environment frames | 1.5–2× | Medium | ~60 |
| 5 | Tail-call optimization | ~1× (fib) / 2× (sum) | Medium-Hard | ~80 |

**Multiplicative estimate for fib(28): 4× · 1.7× · 1.3× · 1.7× ≈ 15×**

This would bring fib(28) from 0.29s → ~0.02s, closing the Janet gap to ~2×.
The remaining gap is the fundamental tree-walking vs bytecode-VM difference:
Janet compiles to bytecodes with a tight `switch` loop; nanoclj-zig re-traverses
the AST on every eval, paying pointer-chasing and branch-prediction costs that
a flat bytecode stream avoids.

---

## Implementation Priority

1. **Do #1 + #2 first** (afternoon of work, ~30 lines total, ~6–8× combined speedup)
2. **Then #3** (quick win, ~30 lines, ~1.3× more)
3. **Then #4** (half-day, ~60 lines, ~1.7× more)
4. **#5 only if tail-recursive workloads matter** (not needed for fib benchmark)

After #1–#4, the `fib(28)` gap should be ≤3× vs Janet, which is reasonable for
a tree-walking interpreter vs a bytecode VM.
