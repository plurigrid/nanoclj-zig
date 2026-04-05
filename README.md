# nanoclj-zig

A Clojure interpreter written in Zig. 32K lines, zero dependencies beyond the Zig standard library. NaN-boxed values, fuel-bounded evaluation, built-in miniKanren, interaction nets, and a bytecode compiler -- all in a single static binary under 3 MB.

```
$ zig build run
nanoclj-zig v0.1.0

bob=> (+ 1 2)
3

bob=> (map (fn* [x] (* x x)) [1 2 3 4 5])
(1 4 9 16 25)

bob=> (run* [q] (fresh [x y] (== x :hello) (== y :world) (== q [x y])))
([:hello :world])

bob=> (run* [q] (appendo '(1 2) '(3 4) q))
((1 2 3 4))
```

## Build

Requires [Zig 0.15+](https://ziglang.org/download/). No other dependencies.

```sh
zig build run                         # interactive REPL
zig build test                        # run tests
zig build -Doptimize=ReleaseFast run  # optimized build
```

## What's in the box

**A Clojure you can read in a weekend.** The entire language -- reader, evaluator, compiler, GC, 195+ builtins -- is 61 Zig files. No JVM. No runtime linking. Compiles in seconds.

**Two execution engines.** Tree-walk interpreter (eval.zig) for interactive use and a register-based bytecode compiler (compiler.zig + bytecode.zig) for when you need speed. Switch between them in the REPL with `(bc expr)` and compare with `(bench expr)`.

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

**Fuel-bounded evaluation.** Every eval step costs fuel. Untrusted code always terminates. No infinite loops, no stack overflows -- the evaluator returns a bottom value when fuel runs out.

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
├── bytecode.zig        820       Bytecode VM
├── core.zig          4,717       195+ builtins
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

## Build targets

| Command | Binary | What it does |
|---------|--------|--------------|
| `zig build run` | `nanoclj` | Interactive REPL |
| `zig build mcp` | `nanoclj-mcp` | MCP server (AI tool use) |
| `zig build gorj` | `gorj-mcp` | Self-hosted MCP (Clojure-defined tools) |
| `zig build world` | `nanoclj-world` | Non-interactive demo |
| `zig build strip` | `nanoclj-strip` | Color strip visualization |
| `zig build sector` | `sector.bin` | Freestanding x86 boot image |
| `zig build test` | -- | Unit tests |

## Examples

The `examples/` directory contains runnable scripts. Load them in the REPL:

```clojure
(load-file "examples/spj_type_inference.clj")  ;; type inference via miniKanren
(load-file "examples/bumpus_kocsis.clj")        ;; structured decomposition theory
(load-file "examples/evalo_synthesis.clj")       ;; program synthesis (run* backward)
(load-file "examples/brainfloj_flow.clj")        ;; BCI signal processing pipeline
(load-file "examples/realizability.clj")          ;; computability classification
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

The interaction net engine provides optimal sharing -- repeated evaluation of the same subexpression happens at most once, without memoization tables. Combined with partial evaluation at startup, hot paths through constant data are pre-reduced before user code runs.

The `sector` build target produces a freestanding x86 binary that boots on raw hardware (or QEMU) to a Clojure REPL. No OS required.

## Dependencies

- [zig-syrup](https://github.com/plurigrid/zig-syrup) -- Syrup binary serialization (for MCP protocol framing)
- Zig standard library
- Nothing else

## License

MIT
