# nanoclj Backend Comparison: OCaml vs Zig vs C

## Executive Summary

Each backend has distinct theoretical advantages based on the properties of the host language.
**OCaml excels at correctness-critical tree transformations and extensible semantics**,
**Zig excels at cache-friendly hot-path execution and zero-overhead resource tracking**,
and **C excels at minimal-overhead embedding and maximal FFI reach**.

---

## Detailed Comparison Table

### 1. Expression Evaluation & AST Dispatch

| Workload | Best Backend | Why |
|----------|-------------|-----|
| **Pattern-match over AST node types** | **OCaml** | Algebraic data types + exhaustiveness checking. OCaml compiles match expressions to jump tables or binary decision trees ([Maranget's algorithm](https://pauillac.inria.fr/~maranget/papers/opat/)). Adding a new node variant → compiler forces you to handle it everywhere. In Zig/C, a missed `switch` arm is a silent bug. |
| **Deeply nested `let*`/closures** | **OCaml** | OCaml's native GC handles closure allocation/deallocation automatically. In Zig, closures require manual arena or GC management (nanoclj-zig's `gc.zig` is ~189 LOC of hand-rolled mark-sweep). OCaml's generational GC promotes short-lived closures cheaply. |
| **NaN-boxed hot-path arithmetic** | **Zig** | nanoclj-zig's NaN-boxing packs every value in 64 bits with zero indirection. Zig's `comptime` generates specialized decode/encode without runtime overhead. OCaml boxes floats by default (heap-allocated 2-word blocks), costing ~2x memory + GC pressure per float. Jane Street's Flambda2 unboxing mitigates this but only for known-static contexts. |
| **Simple eval loop (no resource tracking)** | **C** | nanoclj (C) is a tree-walking interpreter derived from TinyScheme. Minimal overhead: no fuel accounting, no GC write barriers beyond what's needed. Raw `switch`/`goto` dispatch is fastest when you don't need safety guarantees. |

### 2. Garbage Collection & Memory Management

| Workload | Best Backend | Why |
|----------|-------------|-----|
| **Short-lived allocation bursts** (map/filter chains) | **OCaml** | OCaml 5.x has a generational, incremental GC with a minor heap (~256KB nursery). Short-lived allocations are bump-pointer allocated and collected in microseconds. Recent PRs (#13594 generational stack scanning, #13580 mark-delay) further reduce pause times. |
| **Predictable latency** (real-time / VCV bridge) | **Zig** | nanoclj-zig's manual mark-sweep GC gives deterministic control. For the VCV Rack bridge (`vcv_bridge.zig`), you can ban allocation entirely in the audio callback. OCaml's GC, even incremental, introduces ~1-10ms pauses that violate audio deadlines. |
| **Long-running servers** (MCP tool, Braid sync) | **OCaml** | OCaml 5.x's multicore GC with per-domain minor heaps avoids stop-the-world pauses on most collections. For the MCP JSON-RPC server and Braid CRDT sync workloads, OCaml would handle concurrent request allocation without manual arena management. |
| **Minimal memory footprint** (embedded) | **C** | nanoclj (C) runs in constrained environments. No runtime, no GC metadata beyond what the interpreter tracks. Smallest possible binary and resident memory. |

### 3. Type Safety & Correctness

| Workload | Best Backend | Why |
|----------|-------------|-----|
| **Three-layer semantic agreement** (transclusion/transduction/transitivity) | **OCaml** | nanoclj-zig's three semantic layers (denotational, operational, structural) are currently verified by runtime tests. In OCaml, the `Domain` type would be an algebraic type with exhaustive matching — the *type checker* would verify that denotational and operational agree on the *shape* of results at compile time. Polymorphic variants could express the domain lattice (`[> \`Bottom of fuel_reason | \`Value of clj_value]`). |
| **GF(3) conservation invariants** | **OCaml** | OCaml's module system (functors) can parameterize the trit algebra over any field. A functor `GF(N : sig val order : int end)` enforces arithmetic laws at the type level. Zig's `comptime` can do some of this, but type-level proofs are limited to assertions. |
| **Fuel-bounded resource tracking** | **Zig** | Zig's explicit resource passing (`res: *Resources`) with `comptime`-known limits can be fully inlined. The fork/join fuel model in `transduction.zig` benefits from Zig's zero-cost ownership tracking — no hidden allocations in the resource path. |
| **Ad-hoc extensibility** (adding new builtins) | **OCaml** | OCaml's polymorphic variants allow open-ended extension: `type builtin = [\`Inc | \`Dec | \`Add | ...]` can be extended in downstream modules without modifying the core. Module functors enable pluggable evaluator components. In Zig/C, adding a builtin means editing a central switch/enum. |

### 4. Performance Characteristics

| Workload | Best Backend | Why |
|----------|-------------|-----|
| **fib(28) / recursive numeric** | **Zig ≈ C >> OCaml** | With fuel tracking disabled, Zig's NaN-boxed i48 arithmetic avoids all allocation. C's nanoclj does the same with tagged pointers. OCaml would box every intermediate integer (63-bit native ints help but closures still allocate). Benchmark: nanoclj-zig is ~29x slower than Janet *only* because of fork/join fuel overhead, not eval cost. |
| **fib(28) with fuel tracking** | **Zig > OCaml > C** | Zig's `comptime` can specialize the fuel-decrement path. OCaml's optimizer would inline the fuel check but can't eliminate the GC write barrier on the resource record. C requires manual inlining (`static inline`). |
| **Large collection processing** (map/filter/reduce over 10K+ elements) | **OCaml ≈ Zig > C** | OCaml's generational GC makes cons-cell-heavy sequences cheap. Zig's `ArrayList(Value)` gives contiguous memory (cache-friendly). C's nanoclj uses linked lists (cache-unfriendly). |
| **String-heavy workloads** (str, re-find) | **OCaml > Zig ≈ C** | OCaml has optimized string handling with a well-tested standard library + good interning. Zig requires manual string management. C's nanoclj inherits TinyScheme's simple string cells. |
| **Cross-compilation** (WASM, ARM, RISC-V) | **Zig >> C > OCaml** | Zig cross-compiles to 40+ targets from a single machine with `zig build -Dtarget=...`. C requires per-target toolchain setup. OCaml cross-compilation exists but is fragile (opam-cross-* packages). |
| **Startup time** | **C ≈ Zig >> OCaml** | C and Zig produce small static binaries (~1MB). OCaml native binaries are larger (~5-10MB) and load the runtime/GC. |
| **Binary size** | **C < Zig < OCaml** | nanoclj (C) compiles to ~100KB. nanoclj-zig is ~1.1MB. OCaml native typically 5-15MB. |

### 5. Developer Experience & Maintenance

| Aspect | Best Backend | Why |
|--------|-------------|-----|
| **Refactoring safety** | **OCaml** | Exhaustive pattern matching means renaming/adding a variant to the AST type produces compile errors at every unhandled site. In Zig, `switch` on an enum is checked, but the type system is less expressive for nested/recursive types. C has no such checks. |
| **Debugging** | **C > Zig > OCaml** | C has the most mature debugging ecosystem (GDB, LLDB, Valgrind, AddressSanitizer). Zig's LLDB support is improving. OCaml's debugger (ocamldebug) is bytecode-only; native debugging requires gdb with limited support. |
| **Ecosystem / libraries** | **C > OCaml > Zig** | C has the largest library ecosystem. OCaml has opam with ~4000 packages. Zig's ecosystem is nascent. |
| **Onboarding new contributors** | **OCaml ≈ Zig > C** | OCaml and Zig both have strong type checking that guides implementation. C's header-file conventions and manual memory management have a steeper correctness curve. |

### 6. Specific nanoclj-zig Feature Portability

| Feature | OCaml Difficulty | Notes |
|---------|-----------------|-------|
| **NaN-boxing** | Hard | OCaml's runtime assumes a uniform tagged representation. NaN-boxing would require bypassing the standard runtime, losing GC integration. Would need custom `Obj.repr` hacks or a completely custom runtime. |
| **Fuel-bounded eval** | Easy | Natural fit: `eval : expr → env → fuel:int → (value, fuel) result`. Pattern matching makes the fuel-threading explicit and correct. |
| **Fork/join resources** | Medium | OCaml 5.x domains provide real parallelism. Resource splitting maps to domain-local heaps. But OCaml doesn't have Zig's `comptime`-optimized resource structs. |
| **GF(3) trit algebra** | Easy | Module functor over `GF(N)` with `val order = 3`. Phantom types can enforce trit-balanced invariants at compile time. |
| **Three semantic layers** | Easy → Excellent | This is OCaml's *ideal* use case. Each layer is a function from `expr → domain`, with algebraic types ensuring structural compatibility. |
| **MCP JSON-RPC server** | Easy | `yojson` + `cohttp-lwt` provide JSON parsing and HTTP. Better ergonomics than hand-rolled Zig JSON. |
| **Braid CRDT sync** | Medium | OCaml has `irmin` (MirageOS CRDT library). No direct Syrup support — would need a port. |
| **VCV Rack bridge** | Hard | Shared-memory audio bridge requires sub-millisecond latency. OCaml's GC pauses are problematic. Would need `Ctypes` FFI to a C shim. |

---

## Where nanoclj-ocaml Would Theoretically Win

1. **Correctness of the three-layer semantics**: The denotational/operational/structural agreement that nanoclj-zig verifies at runtime would be enforced at compile time by OCaml's type system. Bugs in domain handling become type errors.

2. **Extension & evolution**: Adding new special forms, builtins, or semantic layers would be safer. OCaml's exhaustive matching and module functors prevent "forgot to handle this case" bugs.

3. **Garbage collection for Clojure-idiomatic code**: Clojure's persistent data structures generate many short-lived intermediate values. OCaml's generational GC is specifically optimized for this allocation pattern (bump-pointer minor heap, ~microsecond nursery collections).

4. **Macro/metaprogramming implementation**: Implementing Clojure macros (quote, syntax-quote, macro-expand) maps naturally to OCaml's algebraic types. A macro is `expr → expr`, pattern-matched exhaustively.

5. **REPL server & networking**: OCaml's `lwt` or `eio` (OCaml 5) async libraries are more mature than Zig's nascent async story. The MCP server and Braid sync would be easier to implement correctly.

## Where nanoclj-zig Wins

1. **Raw eval throughput**: NaN-boxing + zero-cost fuel tracking + no GC pauses = fastest possible tight eval loop. When fuel overhead is addressed (e.g., batch fuel deduction), Zig will approach Janet-level speed.

2. **Deterministic resource control**: For VCV Rack audio bridges and real-time applications, Zig's manual memory management guarantees no GC pauses.

3. **Cross-compilation**: Ship to WASM, ARM, RISC-V from one machine. OCaml cross-compilation is possible but painful.

4. **Binary size & startup**: ~1MB static binary vs ~10MB for OCaml. Matters for embedded/edge deployment.

5. **comptime specialization**: Zig can generate specialized eval paths at compile time (e.g., `comptime`-known arity dispatchers, pre-computed lookup tables for builtins).

## Where nanoclj (C) Wins

1. **Embedding**: Smallest footprint, easiest to embed in C/C++ applications. nanoclj's origin as a TinyScheme descendant makes it ideal as a configuration/scripting language.

2. **FFI universality**: Every language can call C. nanoclj can interface with any native library directly.

3. **Debugging & profiling**: Most mature toolchain (Valgrind, ASan, gdb, perf, DTrace).

4. **Minimal dependencies**: No runtime, no package manager, just a C compiler.

5. **Proven simplicity**: Tree-walking + mark-sweep in C is the most understood interpreter architecture. Easy to audit, easy to reason about performance.

---

## Recommendation Matrix

| If your priority is... | Choose |
|------------------------|--------|
| Correctness of semantic layers | **OCaml** |
| Extensible, evolvable interpreter | **OCaml** |
| Fastest possible eval loop | **Zig** |
| Real-time / audio integration | **Zig** |
| Cross-platform deployment | **Zig** |
| Smallest binary / embedding | **C** |
| Widest FFI compatibility | **C** |
| Clojure-idiomatic GC pattern | **OCaml** |
| Developer safety + refactoring | **OCaml** |
| Production debugging | **C** |

---

*Generated 2026-04-03. Based on: OCaml 5.x (multicore GC), Zig 0.15+ (comptime, NaN-boxing), nanoclj (C, tree-walking/TinyScheme heritage). Benchmarks reference nanoclj-zig README (fib(28) ~29x vs Janet).*
