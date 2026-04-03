# Lessons from Scala Native for nanoclj-zig

## Origin Story (GitHub GraphQL archaeology)

Created 2014-11-27, first public commits ~2016-03. 3191 commits, v0.2→v0.5.10.
Key architect: Denys Shabalin (densh). Core team: Wojciech Mazur, João Costa, Lorenzo Gabriele.

## The 7 Architectural Decisions That Make It Fast

### 1. NIR: Custom Intermediate Representation (#77, 2016-05)

Scala → scalac → **NIR** (Native IR) → LLVM IR → native binary.

NIR is a **typed, SSA-form IR** custom-designed for AOT. Not LLVM IR directly — 
NIR captures Scala semantics (traits, closures, exceptions) that LLVM can't express,
then lowers to LLVM IR after optimization.

**Lesson for nanoclj-zig**: Our Value NaN-boxing IS our NIR equivalent. But we lack
an optimization IR between parsing and eval. The interaction net (inet.zig) could
serve this role: Clojure → inet → reduce → readback → eval.

### 2. Whole-Program Reachability Analysis (linker/Reach.scala)

The linker does **transitive closure** from entry points. Everything unreachable
is dead-code-eliminated BEFORE codegen. This is why startup is fast: the binary
only contains code that can actually execute.

Key data structures:
- `enqueued`, `todo`, `done` — worklist algorithm
- `from` — tracks WHY each symbol was reached (debugging DCE)
- `dyncandidates` — dynamic dispatch candidates per signature

**Lesson**: Our `tree_vfs.zig` transclusion graph already does reachability. Extend
to Clojure code: trace from `main` to find all reachable `def`s, prune the rest.

### 3. Interflow: Whole-Program Partial Evaluator (interflow/)

The secret weapon. `Eval.scala` is a **compile-time interpreter** that:
- Partially evaluates constant expressions
- Propagates types through control flow
- Inlines aggressively (with bail-out for complexity)
- Devirtualizes calls when receiver type is known
- Uses `ThreadLocal` state for parallel optimization

22 files, mixes traits: `Visit`, `Opt`, `NoOpt`, `Eval`, `Combine`, `Inline`, 
`PolyInline`, `Intrinsics`.

**Lesson**: Our `semantics.zig` already does fuel-bounded eval. Add a **compile-time
partial eval pass**: evaluate `(def x (+ 1 2))` to `(def x 3)` before runtime.
The inet compile→reduce→readback pipeline IS partial evaluation for lambda calculus.

### 4. Smi (Small Integer) Optimization (#18, 2016-03)

Pack integers into pointer values without allocation. Dart/V8 technique.
Delayed in Scala Native because of Boehm GC complications.

**Lesson**: We ALREADY do this. NaN-boxing packs i48 integers directly in the
Value u64 without any heap allocation. We're ahead of where they started.

### 5. Stack Allocation (#115, 2016-05)

Stack-allocate objects that don't escape the function. Avoids GC pressure entirely.
C++ and Rust do this by default; Scala/Java don't.

**Lesson**: Our `Value` is already 8 bytes on the stack. But `Obj` (list, vector, map)
always heap-allocates via GC. For small, non-escaping collections, we could use
arena/stack allocation. The `Resources.fork` already models this — each forked child
could get a bump allocator that dies with the fork.

### 6. Parallel Toolchain (#506, 2017-02)

Three-level parallelism:
- NIR transformations in optimizer: parallel in batches of `NCPU * 4`
- CodeGen: parallel per class package
- LLVM compilation: parallel per class package

**Lesson**: Our `thread_peval.zig` does expression-level parallelism. But the
compile pipeline itself (read→eval→print) is serial. When we add the inet
optimization pass, it should reduce in parallel (inet reduction is inherently
parallel — non-overlapping active pairs can reduce simultaneously).

### 7. GC Progression: Boehm → Immix → Commix

- **Boehm** (v0.1-0.3): conservative, stop-the-world. Simple but slow.
- **Immix** (v0.4+): mark-region collector. Fast allocation (bump pointer into
  blocks), good locality. Written in C (~20 files).
- **Commix** (v0.5+): concurrent Immix. Mutator threads continue during marking.

**Lesson**: Our mark-sweep GC (gc.zig, ~190 LOC) is simpler than Boehm.
Path: current → bump-allocator nursery (young gen) → Immix-style block allocator.
The Immix block structure (Block.c, Allocator.c) is ~500 LOC C — portable to Zig.

## Startup Speed: Why Scala Native Beats JVM

JVM startup: load classfiles → verify bytecode → interpret → JIT compile hot paths.
~100-500ms before first useful work.

Scala Native startup: load binary → initialize GC → run `main`.
~1-5ms. The work was done at compile time by Interflow + DCE.

**nanoclj-zig startup**: load binary → init GC → init env → init builtins → REPL.
Already fast (Zig AOT), but we register 35+ builtins eagerly. Lazy registration
would shave the constant factor.

## Benchmark Targets

Scala Native tracks against JVM on:
- Binary size (typically 5-20MB vs JVM's 200MB+ runtime)
- Startup time (1-5ms vs 100-500ms)
- Steady-state throughput (80-120% of JVM depending on optimization level)
- Memory footprint (10-50MB vs JVM's 100MB+ baseline)

nanoclj-zig advantages over Scala Native:
- No LLVM dependency (Zig is the entire toolchain)
- Simpler value representation (NaN-boxing vs full object headers)
- Smaller binary (currently ~100KB vs Scala Native's 5MB+)
- Interaction nets as optimization IR (Lafont > LLVM for lambda calculus)

## Actionable Items for nanoclj-zig

1. **Compile-time partial eval**: inet compile→reduce→readback before runtime eval
2. **Reachability-based DCE**: trace from entry, drop unreachable defs
3. **Bump allocator nursery**: young-gen fast alloc, promote to GC heap
4. **Parallel inet reduction**: non-overlapping active pairs reduce simultaneously
5. **Lazy builtin registration**: don't intern all 35 builtin strings at startup
6. **Profile-guided optimization**: collect call-site stats, devirtualize (like #745)
