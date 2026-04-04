# The General Class: Partial Evaluation Landscape (2026)

## The Hierarchy

```
Multi-stage computation (collapsing n levels to n-1)
  │
  ├── Partial Evaluation (Futamura 1971)
  │     ├── Online PE  — decides specialization during the pass
  │     ├── Offline PE — binding-time analysis first, then specialize  
  │     └── weval (Fallin & Bernstein, PLDI 2025) — PE on SSA IR, no framework needed
  │
  ├── Supercompilation (Turchin 1986)
  │     └── PE + driving + generalization + homeomorphic embedding for termination
  │
  ├── Normalization by Evaluation (NbE)
  │     └── Evaluate in meta-language, quote back to object language
  │
  ├── Abstract Interpretation (Cousot 1977)
  │     └── Compute fixpoints over abstract lattice domains
  │
  └── Optimal Reduction (Lévy 1978, Lamping 1989)
        └── Share exactly the work β-reduction would duplicate
```

## The Three Projections

1. **spec(interpreter, program) = compiled_program**
   Interflow, Truffle/Graal, weval all implement this.

2. **spec(specializer, interpreter) = compiler**
   Self-application: a specializer that can specialize itself on an interpreter
   produces a compiler. Achieved in practice by Truffle (the specializer IS Graal).

3. **spec(specializer, specializer) = compiler_generator**
   Apply the specializer to itself. Theoretical; rarely practical.

## Key Systems Mapped

### weval (PLDI 2025) — The Breakthrough
- Fallin & Bernstein at F5/Bytecodealliance
- PE on **existing C/C++ interpreters** via Wasm SSA IR
- No framework rewrite needed (unlike Truffle)
- Applied to SpiderMonkey JS: **2.17× speedup**
- Applied to PUC-Rio Lua: **1.84× speedup**  
- Key insight: unroll interpreter loop, PE the dispatch, branch-fold constants
- Context tracking via push/pop annotations (lightweight)
- AOT only — no JIT warmup needed

**Relevance to nanoclj-zig**: Our eval loop in transduction.zig IS the interpreter.
weval's approach = specialize transduction.evalBounded on a known program.
We could do this at Zig compile time via comptime, or at load time via inet.

### Truffle/Graal — The Industrial Standard  
- First Futamura projection as JIT: interpreter + Truffle framework → Graal PE → native
- Requires rewriting interpreter in Truffle's Java framework
- Warmup cost: first executions are slow (interpreting), then PE kicks in
- "Self-optimizing AST interpreter" — nodes rewrite themselves with type specializations

**Relevance**: Truffle needs JIT warmup. We're AOT. Our advantage.

### Optiscope (2025) — State of Optimal Reduction
- Lévy-optimal reducer in C, 44 stars, active development
- Extends Lambdascope with optimizations for scoping operations
- **Honest benchmark result**: 60× slower than unoptimized Haskell on insertion sort
- BOHM (the prior SOTA optimal reducer) also much slower than Haskell/OCaml
- Key quote from Asperti: "we hardly use truly higher-order functionals in
  functional programming... this makes a crucial difference with the pure
  λ-calculus, where all data are eventually represented as functions"
- Conclusion: optimal reduction wins on Church-numeral-heavy code (exponential
  vs polynomial), loses badly on "real world" programs with native data types

**Critical lesson for nanoclj-zig**: Our inet.zig implements Lamping/Lafont
interaction nets. Optiscope's benchmarks prove these are NOT faster for general
computation. They're faster ONLY when sharing prevents exponential blowup.
Use inet as optimization IR for macro expansion and constant folding, NOT as
the primary evaluator. transduction.zig (direct eval) stays the fast path.

### Kombucha (2025) — The Practitioner's Dilemma
- Two-stage language: PE for macros at compile time, bytecode VM at runtime
- Author's PE **doesn't work yet** — stack overflow on recursive partial eval
- Key insight: "partial evaluation isn't just CBV lambda calculus evaluation"
- Recursive PE is hard: when to stop unrolling? Exponential blowup risk.
- Considering restricting to explicitly annotated `comptime` functions

**Relevance**: We face the same dilemma. Our fuel system IS the termination
guarantee that Kombucha lacks. Fuel-bounded PE can't blow up — it just stops.
This is our structural advantage over every PE system that doesn't have fuel.

## The nanoclj-zig Position

```
                    Startup    Throughput   Sharing    Complexity
                    ───────    ──────────   ───────    ──────────
JVM (HotSpot)       slow       fastest*     none       enormous
Truffle/Graal       warm-up    fast         PE         large
weval               instant    good         PE         medium
Scala Native        instant    good         DCE+PE     medium
Optiscope           instant    slow**       optimal    small
nanoclj-zig         instant    good         fuel+inet  small
                                            ↑
                              unique: fuel guarantees termination,
                              inet handles sharing when it matters
```

*after JIT warmup  **on real-world code; wins on Church numerals

## Actionable Architecture

```
Source → Reader → AST (Value)
                    │
                    ├──[hot path]── transduction.evalBounded ──→ result
                    │               (direct eval, fuel-bounded, fast)
                    │
                    └──[cold path]── inet_compile → reduce → readback
                                    (Lévy-optimal PE for macro expansion,
                                     constant folding, sharing-heavy code)
```

The cold path runs at load time on `def` forms. The hot path runs at eval time.
Fuel prevents the cold path from diverging (Kombucha's unsolved problem).
Optiscope's benchmarks tell us: don't use inet for everything, only where
sharing matters (higher-order combinators, Church encodings, macro expansion).

## Category-Theoretic View

All of these are instances of **left Kan extension**:

```
Known ──embed──→ All
  │                │
  │   Lan_embed    │
  ▼                ▼
Result ←─────── Partial Result
```

You extend the computation from the subcategory of "known at compile time"
to the full category of "all possible inputs", computing the best approximation.
The counit of the Kan extension is the residual code — what's left to compute
at runtime.

Fuel adds a **graded monad** structure: Lan_embed becomes fuel-indexed,
and exhaustion maps to ⊥ (bottom) rather than divergence.
