# Adversarial Security Audit: nanoclj-zig

**Threat model**: xbow-level adversary with full source visibility, crafting
inputs to escape the interpreter sandbox, exfiltrate data, achieve RCE, or
deny service beyond fuel bounds.

## Attack Surface Map

```
                    ┌─────────────┐
   stdin/nREPL ───►│   reader.zig │──► S-expr AST
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
   builtins ◄──────│transduction  │──► Domain{value|⊥|err}
   (core.zig)      │  .zig eval   │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        http_fetch    nrepl (TCP)    tree_vfs
        (outbound)    (inbound)     (fs read)
```

---

## CRITICAL VULNERABILITIES (P0)

### CVE-1: nREPL has NO fuel bounding — infinite eval
**File**: `substrate.zig:310-320`
**Severity**: Critical
**Vector**: Network-accessible eval with no resource limits

The nREPL listener calls `eval_mod.eval()` (the OLD unbounded eval) instead
of `semantics.evalBounded()`. An attacker connecting to the nREPL port gets
**unbounded computation** — infinite loops, infinite allocation, stack
overflow, everything the fuel system was designed to prevent.

```zig
// substrate.zig:311 — UNBOUNDED EVAL
const result = eval_mod.eval(form, ctx.env, ctx.gc) catch { ... };
//                     ^^^^
// Should be: semantics.evalBounded(form, ctx.env, ctx.gc, &res)
```

**Impact**: Full DoS (100% CPU forever), potential OOM kill, stack overflow
crash with attacker-controlled data on stack.

### CVE-2: http-fetch is SSRF oracle with no URL validation
**File**: `http_fetch.zig:17-55`
**Severity**: Critical
**Vector**: `(http-fetch "http://169.254.169.254/latest/meta-data/")`

No URL allowlist/denylist. Attacker can:
- Hit cloud metadata endpoints (AWS/GCP/Azure IMDSv1)
- Scan internal networks (`http://10.0.0.1:8080/`)
- Exfiltrate data via DNS (`http://secret.attacker.com/`)
- Read local files if zig's HTTP client follows `file://` URIs

The response body is returned verbatim as a nanoclj string.

### CVE-3: Reader has no depth bound — stack overflow via nested parens
**File**: `reader.zig:62-76`
**Severity**: Critical
**Vector**: `(((((((((((...10000 levels...)))))))))))`

`readForm()` → `readList()` → `readForm()` is unbounded recursion on the
**Zig call stack**. The `Resources.read_depth` counter exists in
`transitivity.zig` but is **never checked in the reader**. The reader has
no reference to Resources at all.

A 50KB string of `(` characters will overflow the 8MB default stack.

**Impact**: Segfault/SIGBUS (crash, no graceful recovery). If nREPL is
exposed, this is a remote crash.

---

## HIGH VULNERABILITIES (P1)

### V-4: Bytecode VM has no bounds check on register access
**File**: `bytecode.zig:186`
**Severity**: High
**Vector**: Crafted bytecode (currently only via compiler, but if bytecode
serialization is added...)

`reg(idx)` does `stack[base + idx]` with no upper bound check. If
`base + idx >= 256*64`, this is an out-of-bounds array access. In
ReleaseFast this is undefined behavior (memory corruption). In Debug/
ReleaseSafe, it's a panic (crash).

Currently the compiler bounds `num_registers` to u8 (max 255), and
frames are bounded to 64, so `base + 255 < 256*64 = 16384`. But the
frame's `base` calculation in CALL doesn't validate that `new_base +
num_registers` fits in the stack:

```zig
const new_base = base + self.currentFrame().closure.def.num_registers;
// No check: new_base + callee.def.num_registers <= 256 * 64
```

### V-5: @intCast on attacker-controlled values — panic in safe, UB in fast
**File**: `bytecode.zig:232`, `core.zig:353,514,515,554`
**Severity**: High
**Vector**: `(nth [1 2 3] 9999999999999)` or `(subs "abc" -1)`

`@intCast` on `args[n].asInt()` will panic on overflow. In `core.zig:353`:
```zig
const idx: usize = @intCast(args[1].asInt()); // panic if negative or > usize max
```

Every `@intCast` from `i48` to narrower types without range checking is a
potential panic-crash vector.

### V-6: GC mark doesn't trace bc_closure upvalues
**File**: `gc.zig:167`
**Severity**: High (latent — activates when upvalue capture is implemented)

```zig
.bc_closure => {}, // FuncDef + upvalues managed by allocator, not GC
```

When upvalue capture is implemented, if upvalues reference GC-managed
Values (which they will — that's the whole point), the GC won't mark
them. This is a use-after-free waiting to happen.

### V-7: tree_vfs reads arbitrary filesystem paths
**File**: `tree_vfs.zig:188`
**Severity**: High
**Vector**: Set `$HOME` or forest path to `/etc/` or `/proc/`

`scanDir` opens whatever `dir_path` is passed. While currently hardcoded
to `$HOME/trees`, the path comes from `std.process.getEnvVarOwned("HOME")`
which is attacker-controlled if they can set environment variables.

Also: `peval.zig:157` does `std.fs.cwd().openFile(path, .{})` where
`path` comes from the boot sequence. If boot scripts are attacker-
controlled, this is arbitrary file read.

---

## MEDIUM VULNERABILITIES (P2)

### V-8: NaN-box pointer truncation — 48-bit address space assumption
**File**: `value.zig:97`
**Severity**: Medium (architecture-dependent)

```zig
pub fn makeObj(ptr: *Obj) Value {
    return fromTagPayload(.object, @truncate(@intFromPtr(ptr)));
}
```

On x86-64, user-space addresses fit in 47 bits (canonical form). On
aarch64 with Top Byte Ignore (TBI) or Memory Tagging Extension (MTE),
the upper bits may be non-zero. `@truncate` silently discards them.
If the allocator returns a pointer with bits 48+ set, `asObj()` will
reconstruct a different pointer → UB.

macOS on Apple Silicon uses 47-bit VA space today but this is a ticking
time bomb as address spaces grow.

### V-9: String interning has no length bound at intern site
**File**: `gc.zig:51`
**Severity**: Medium
**Vector**: `"AAAA...1MB...AAAA"`

The `Limits.max_string_len = 1MB` exists but is only checked in... nowhere
in the reader. A single `(def x "...1GB...")` will `allocator.dupe` the
entire string. The interning deduplication doesn't help because each unique
string is stored once.

### V-10: Thread peval shares GC/Env across threads with coarse lock
**File**: `thread_peval.zig:39-42`
**Severity**: Medium
**Vector**: `(peval (def x 1) (def x 2))` — data race on env

The Mutex serializes entire eval calls. But `def` mutates the **parent**
env (not the forked child). Two concurrent `def`s writing to the same
parent env can corrupt the StringHashMap. The lock is on the SharedContext
but the `env` pointer chains are shared without copy-on-write.

### V-11: No allocation limit — OOM via data structure inflation
**Severity**: Medium
**Vector**: `(def x (range 0 1000000))` then `(map (fn [_] (range 0 1000000)) x)`

The `max_live_objects = 1_000_000` limit exists but is only checked during
GC sweep, not during allocation. An attacker can allocate 1M objects between
GC cycles. Each Obj is ~64 bytes → 64MB per burst. Chaining these in a loop
can exhaust memory before GC triggers.

### V-12: MCP tool server has no authentication
**File**: `mcp_tool.zig`
**Severity**: Medium (depends on deployment — if exposed on network, critical)

The MCP JSON-RPC server reads from stdin with no auth tokens, no rate
limiting, no request size limits beyond `MAX_LINE_SIZE = 1MB`. A co-located
process can inject arbitrary eval via the MCP protocol.

---

## LOW VULNERABILITIES (P3)

### V-13: Braid HTTP server has no TLS, no auth
**File**: `braid.zig` — currently stub/incomplete
**Severity**: Low (not wired in yet)

### V-14: Fuel cost is deterministic — attacker can compute exact budget
**Severity**: Low
**Impact**: Not a vulnerability per se, but an adversary with source can
craft inputs that use exactly max_fuel - 1 steps, maximizing resource
consumption while staying under the limit. The SplitMix64 color-game
"seasons" add unpredictability but the seed is known.

### V-15: Symbol interning is unbounded
**File**: `gc.zig:51`
**Vector**: `(eval (symbol (str "x" (rand-int 1000000))))`
Creates 1M unique interned symbols. The `max_interned_strings = 100_000`
limit exists but isn't enforced at the interning site.

---

## ESCAPE PATHS SUMMARY

| Path | Bounded? | Escape? |
|------|----------|---------|
| CPU (tree-walk eval) | Yes (fuel) | No |
| CPU (bytecode VM) | Yes (vm.fuel) | No |
| CPU (nREPL eval) | **NO** | **YES** |
| Stack (eval depth) | Yes (max_depth=1024) | No |
| Stack (reader depth) | **NO** | **YES** |
| Stack (GC mark) | Yes (worklist) | No |
| Memory (objects) | Partial (GC, not alloc) | Partial |
| Memory (strings) | **NO** (no enforcement) | **YES** |
| Network (outbound) | **NO** (http-fetch) | **YES (SSRF)** |
| Network (inbound) | **NO** (nREPL unauthd) | **YES** |
| Filesystem | Partial (tree_vfs) | Partial |
| Bytecode registers | **NO** (no bounds) | **YES** |

---

## RECOMMENDED FIXES (priority order)

1. **nREPL: Switch to bounded eval** — replace `eval_mod.eval` with
   `semantics.evalBounded` in `nreplThreadFn`
2. **Reader: Add depth counter** — thread read_depth through Reader,
   check against max_read_depth on each `readList/readVector/readMap`
3. **http-fetch: Add URL allowlist** — deny private IPs, metadata
   endpoints, file:// URIs
4. **Bytecode VM: Bounds-check stack access** — validate
   `new_base + num_registers <= stack.len` before CALL
5. **@intCast: Add range checks** — wrap attacker-reachable @intCast
   in bounds checks returning Domain.fail
6. **String interning: Enforce max_string_len** — check in reader's
   readString() and in gc.internString()
7. **GC bc_closure: Trace upvalues** — when upvalue capture is
   implemented, update mark phase
