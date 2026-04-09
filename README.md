# nanoclj-zig

A Clojure interpreter written in Zig 0.16. 32K lines, zero dependencies beyond the Zig standard library. NaN-boxed values, fuel-bounded evaluation, built-in miniKanren, interaction nets, and a bytecode compiler — all in a single static binary under 3 MB.

Zig 0.16's incremental compilation with the LLVM backend means editing a function and re-entering the world takes under a second. No JVM startup. No JIT warmup. The REPL feel comes from incremental AOT.

```
$ zig build run
nanoclj-zig v0.1.0

bob=> (+ 1 2)
3

bob=> (map (fn* [x] (* x x)) [1 2 3 4 5])
(1 4 9 16 25)

bob=> (run* [q] (fresh [x y] (== x :hello) (== y :world) (== q [x y])))
([:hello :world])
```

## Color

Every parenthesis has a color. The color tells you which runtime owns that sub-expression. See **[docs/COLOR.md](docs/COLOR.md)** for the full theory.

```
red(  ... )    nanoclj-zig AOT     static, fast, 22 opcodes, no eval
blue( ... )    jank-lang JIT       eval, defmacro, reify
purple( ... )  dispatch boundary   spread-combine / Hy / FFI cell
```

The compiler (`compiler.zig`) is almost entirely red. The tree-walk interpreter (`eval.zig`) is the blue escape hatch. Hy (`.hy`) files are purple — Python semantics in Lisp syntax.

## Build

Requires [Zig 0.16](https://ziglang.org/download/).

```sh
zig build run                         # interactive REPL
zig build test                        # run tests
zig build -Doptimize=ReleaseFast run  # optimized build
zig build embed-min                   # minimal embedded profile
zig build embed-safe                  # bounded embedded profile
```

Incremental compilation is on by default. After the first build, `zig build run` recompiles only changed functions through the LLVM backend. Edit `core.zig`, save, re-run — sub-second.

## What's in the box

**A Clojure you can read in a weekend.** The entire language — reader, evaluator, compiler, GC, 450+ builtins — is 61 Zig files. No JVM. No runtime linking. Compiles in seconds, recompiles in milliseconds.

**Two execution engines.** Tree-walk interpreter (`eval.zig`) for interactive use and a register-based bytecode compiler (`compiler.zig` + `bytecode.zig`) for when you need speed. Switch between them in the REPL with `(bc expr)` and compare with `(bench expr)`.

**miniKanren.** Relational programming baked into the runtime. Write a relation once, run it forward, backward, or sideways:

```clojure
;; Forward: compute append
(run* [q] (appendo '(1 2) '(3 4) q))
;=> ((1 2 3 4))

;; Backward: what lists append to (1 2 3 4)?
(run 5 [x y] (appendo x y '(1 2 3 4)))
;=> ((() (1 2 3 4)) ((1) (2 3 4)) ((1 2) (3 4)) ((1 2 3) (4)) ((1 2 3 4) ()))

;; Type inference as search (SPJ-style)
(run* [result]
  (fresh [a b1 b2 c]
    (== [:Bool :-> :String] [b1 :-> c])
    (== [:Int :-> :Bool] [a :-> b2])
    (== b1 b2)
    (== result [a :-> c])))
;=> ([:Int :-> :String])
```

**Fuel-bounded evaluation.** Every eval step costs fuel. Untrusted code always terminates. No infinite loops, no stack overflows — the evaluator returns a bottom value when fuel runs out.

**Interaction nets.** Lamping/Lafont optimal beta-reduction with four cell kinds. The first Futamura projection runs at startup: partially evaluate constant bindings through the interaction net before the REPL even starts.

**NaN-boxing.** Every value is 64 bits. IEEE 754 double, or a quiet NaN with a 3-bit tag and 48-bit payload:

```
Float:  any normal IEEE 754 double
nil:    0x7FF8_0000_0000_0000  (tag=0)
bool:   tag=1, payload=0|1
int:    tag=2, payload=i48 (inline, no heap alloc)
symbol: tag=3, interned string id
keyword:tag=4, interned string id
string: tag=5, interned string id
object: tag=6, pointer to heap → list|vector|map|set|fn|macro
```

No wrapper structs. An `ArrayList(Value)` is a contiguous `u64` array. Symbols and keywords are interned at read time. Integers up to +/-2^47 never touch the heap.

## Architecture

```
src/
├── value.zig           357 loc   NaN-boxed 64-bit representation
├── reader.zig          525       S-expression reader
├── eval.zig          1,410       Tree-walk evaluator
├── compiler.zig      1,720       Expression → register bytecode
├── bytecode.zig        820       Bytecode VM (22 irreducible opcodes)
├── core.zig          4,717       450+ builtins
├── env.zig             132       Lexical scope chain
├── gc.zig              290       Mark-sweep garbage collector
├── kanren.zig        1,033       miniKanren: unification, goals, streams
├── inet.zig            506       Interaction net engine (Lamping/Lafont)
├── inet_compile.zig    455       Lambda → interaction net compiler
├── peval.zig           258       Partial evaluation (Futamura)
├── pattern.zig         552       Pattern matching
├── persistent_*.zig    743       Persistent vectors and maps
├── regex.zig           367       Regex engine
├── simd_str.zig        160       SIMD string operations
├── sector.zig        1,515       Sector-based evaluation kernel
├── sector_boot.zig     ...       Freestanding x86 boot image (boots to a REPL)
├── transclusion.zig    447       Denotational semantics
├── transduction.zig  1,061       Fuel-bounded operational semantics
├── transitivity.zig    767       Structural equality + soundness
├── nrepl.zig           ...       nREPL server (GF(3) session coloring)
├── mcp_tool.zig        583       Model Context Protocol server
├── gorj_mcp.zig        597       Self-hosted MCP (tools defined in Clojure)
└── ...                           61 files, 32K lines total
```

Three semantic layers verify that evaluation is sound:

| Layer | File | What it checks |
|-------|------|----------------|
| Denotational | transclusion.zig | What an expression *means* |
| Operational | transduction.zig | How it *executes* (with fuel) |
| Structural | transitivity.zig | That the two agree |

## Incremental compilation

Zig 0.16 ships incremental compilation with the LLVM backend. This changes what "interpreted language" means:

| | JVM Clojure | nanoclj-zig |
|---|---|---|
| First start | 2-5s JVM boot | 0ms (static binary) |
| Edit → run | Instant (JIT) | Sub-second (incremental AOT) |
| Hot path perf | JIT-optimized | LLVM-optimized (whole program LTO) |
| Cold path perf | Interpreted bytecode | Same LLVM-optimized code |
| Binary size | 200+ MB (JRE) | < 3 MB |

The REPL loop is: edit a `.zig` file → `zig build run` → only changed functions recompile through LLVM → the world resumes. This is not interpretation. This is incremental native compilation fast enough to feel like interpretation.

For Clojure-level iteration (editing `.clj` files loaded via `load-file`), the tree-walk interpreter and bytecode VM provide instant feedback without any recompilation.

## Build targets

| Command | Binary | What it does |
|---------|--------|--------------|
| `zig build run` | `nanoclj` | Interactive REPL |
| `zig build embed-min` | `nanoclj-embed-min` | Minimal embedded profile |
| `zig build embed-safe` | `nanoclj-embed-safe` | Bounded embedded profile |
| `zig build mcp` | `nanoclj-mcp` | MCP server (AI tool use) |
| `zig build gorj` | `gorj-mcp` | Self-hosted MCP (Clojure-defined tools) |
| `zig build world` | `nanoclj-world` | Persistent world |
| `zig build strip` | `nanoclj-strip` | Color strip visualization |
| `zig build sector` | `sector.bin` | Freestanding x86 boot image |
| `zig build test` | -- | Unit tests |

## Worlds

`worlds/` has persistent, seed-derived environments. `test/` has regression suites. Load in the REPL:

```clojure
(load-file "examples/spj_type_inference.clj")     ;; Hindley-Milner via miniKanren
(load-file "examples/evalo_synthesis.clj")         ;; program synthesis (run* backward)
(load-file "examples/street_fighting_kanren.clj")  ;; dimensional analysis as constraints
(load-file "examples/bumpus_kocsis.clj")           ;; structured decomposition theory
(load-file "examples/realizability.clj")            ;; computability classification
(load-file "examples/brainfloj_flow.clj")           ;; BCI signal processing pipeline
(load-file "examples/topos.clj")                    ;; effective topos
```

## Language features

Implemented: `def`, `fn*`, `let*`, `if`, `do`, `quote`, `loop`/`recur`, `defmacro`, `macroexpand`, `try`/`catch`/`throw`, `defmulti`/`defmethod`, `defprotocol`/`deftype`, atoms (`atom`/`deref`/`swap!`/`reset!`), lazy sequences, transducers, destructuring, variadic args, metadata.

Data structures: lists, vectors, hash maps, sets, keywords, symbols, strings, integers (i48), floats (f64), rationals, booleans, nil, regex.

Persistent data structures: vectors and maps with structural sharing.

miniKanren: `run*`, `run`, `fresh`, `conde`, `==`, `conso`, `appendo`, `membero`, `evalo`.

## What's unusual

Most Clojure implementations target the JVM, CLR, or JavaScript. nanoclj-zig targets bare metal. The entire runtime is one static binary with no runtime dependencies.

The NaN-boxing means there is no object header overhead for primitives. A vector of 1M integers is a contiguous 8 MB array of `u64`. No indirection, no boxing tax.

Fuel-bounded evaluation means the interpreter is a total function: given finite fuel, it always returns. This makes it suitable for sandboxed execution, LLM tool use (via MCP), and embedding in systems where runaway computation is unacceptable.

The interaction net engine provides optimal sharing — repeated evaluation of the same subexpression happens at most once, without memoization tables. Combined with partial evaluation at startup, hot paths through constant data are pre-reduced before user code runs.

The `sector` build target produces a freestanding x86 binary that boots on raw hardware (or QEMU) to a Clojure REPL. No OS required.

## Realizability topos

nanoclj-zig is building toward an **effective topos** — a universe where "true" means "has a computable witness."

The pieces that exist today:

- **Computable sets** (`computable_sets.zig`): characteristic functions over i48, many-one reductions, Weihrauch degrees. Every set is decidable by construction — the classifier Omega_eff is Sigma^0_1 truth values.
- **Arithmetical hierarchy** (`computable_sets.zig`): Sigma/Pi/Delta classification of 16 problems, morphism detection between them, obstruction witnesses when reductions fail.
- **Chromatic hyperdoctrine** (`hyperdoctrine.zig`): Heyting algebra on predicates indexed by chromatic types. Substitution functors, existential/universal quantifiers as adjoints, Beck-Chevalley verification.
- **Logical pluralism** (`pluralism.zig` → `eval.zig`): `(set-logic! :intuitionistic)` changes the evaluator's truth mode. In intuitionistic mode, double negation doesn't eliminate — matching the internal logic of a topos.
- **Interaction nets** (`inet.zig`): Lamping/Lafont optimal reduction. The first Futamura projection at startup partially evaluates through the net. This is the computational substrate realizability lives on.
- **Fuel-bounded evaluation** (`transduction.zig`): the evaluator is a total function. Every computation either returns a value or a bottom. This is the operational content of "every morphism in the effective topos is computable."

What connects them: the subobject classifier of the effective topos is not {true, false} but the set of all r.e. sets. `computable_sets.zig` builds these sets. `hyperdoctrine.zig` organizes predicates over them into a Heyting algebra. `pluralism.zig` makes the evaluator respect intuitionistic logic. The interaction net provides optimal sharing for the realizers. Fuel bounds guarantee totality.

What's missing: the actual topos construction (pullbacks, exponentials, the subobject classifier as a first-class object), sheaf-theoretic gluing, and a proof that the pieces compose into a valid topos. These are research goals, not shipped features.

```clojure
;; What works today:
(load-file "examples/realizability.clj")   ;; computable sets + Mobius + hierarchy
(load-file "examples/topos.clj")           ;; realizability + Gorard tower + Stacks

;; The punchline from realizability.clj:
;; color trit balance (Pi) + Mertens inclusive trit (Sigma) = 0 mod 3
;; The subobject classifier's two faces conserve GF(3).
```

## Embedded direction

The repo includes an explicit embedded-profile plan in [docs/EMBEDDED-PROFILE.md](docs/EMBEDDED-PROFILE.md).

The strategy is:

- do not try to beat the C version on absolute minimal footprint
- beat it on bounded execution, deployment portability, and host-side controllability
- split the runtime into `full`, `embed-min`, and `embed-safe` profiles

The `embed-min` and `embed-safe` build targets use source-level feature gating (`profile.zig`) to strip subsystems at compile time. Flags gate nREPL, kanren, inet, peval, and MCP — embedded builds only include what's needed.

## Dependencies

- [zig-syrup](https://github.com/plurigrid/zig-syrup) — Syrup binary serialization (for MCP protocol framing)
- Zig 0.16 standard library
- Nothing else

## License

MIT
