# nanoclj-zig

A Clojure interpreter written in Zig 0.16. Single static binary, NaN-boxed values, fuel-bounded evaluation, bytecode compiler, miniKanren, interaction nets. Zig 0.16 standard library is the only runtime dependency.

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

## Build

Requires [Zig 0.16](https://ziglang.org/download/).

```sh
zig build run                         # interactive REPL
zig build test                        # unit tests
zig build -Doptimize=ReleaseFast run  # optimized build
zig build embed-min                   # minimal embedded profile
zig build embed-safe                  # bounded embedded profile
```

Binary sizes (aarch64-macos, debug): `nanoclj` ≈ 7.0 MB; `nanoclj-embed-{min,safe}` ≈ 870 KB.

## Language

Forms: `def`, `fn*`, `let*`, `if`, `do`, `quote`, `loop`/`recur`, `defmacro`, `macroexpand`, `try`/`catch`/`throw`, `defmulti`/`defmethod`, `defprotocol`/`deftype`, `binding` (dynamic vars), `with-redefs`, `defrecord`, reader conditionals (`#?`), metadata.

Data: lists, vectors, hash maps, sets, keywords, symbols, strings, i48 integers, f64 floats, rationals, booleans, nil, regex. Persistent vectors and maps use structural sharing.

Concurrency primitives (single-threaded semantics): atoms (`atom`/`deref`/`swap!`/`reset!`), refs + `dosync`/`alter`/`commute`, agents (`agent`/`send`/`send-off`/`await`/`agent-error`/`restart-agent`), `:validator` on atoms and agents.

Regex: `re-pattern`, `re-find`, `re-matches`, `re-seq`, plus stateful matcher (`re-matcher`, `re-matcher-find`, `re-groups`).

miniKanren: `run*`, `run`, `fresh`, `conde`, `==`, `conso`, `appendo`, `membero`, `evalo`.

## Execution

Two engines:

- **Tree-walk interpreter** (`eval.zig`) — interactive use, metered via `transduction.zig` (fuel-bounded total function).
- **Register-based bytecode** (`compiler.zig` + `bytecode.zig`) — 22 opcodes. `(bc expr)` compiles; `(bench expr)` compares.

## NaN-boxing

Every value is 64 bits. IEEE 754 double, or a quiet NaN with a 3-bit tag and 48-bit payload:

```
Float:  any normal IEEE 754 double
nil:    0x7FF8_0000_0000_0000  (tag=0)
bool:   tag=1, payload=0|1
int:    tag=2, payload=i48
symbol: tag=3, interned string id
keyword:tag=4, interned string id
string: tag=5, interned string id
object: tag=6, pointer to heap
```

Symbols and keywords are interned at read time. Integers in `[-2^47, 2^47)` stay unboxed. A vector of `Value` is a contiguous `u64` array.

## Architecture

96 `.zig` files, ~51K lines total. Key modules:

| File | LOC | Role |
|------|-----|------|
| `value.zig` | 374 | NaN-boxed 64-bit representation |
| `reader.zig` | 968 | S-expression reader, reader conditionals |
| `eval.zig` | 1,863 | Tree-walk evaluator |
| `compiler.zig` | 1,720 | Expression → register bytecode |
| `bytecode.zig` | 820 | Bytecode VM (22 opcodes) |
| `core.zig` | 5,522 | Builtins |
| `env.zig` | 157 | Lexical scope chain |
| `gc.zig` | 320 | Mark-sweep GC |
| `kanren.zig` | 1,036 | miniKanren: unification, goals, streams |
| `inet.zig` | 541 | Interaction net engine (Lamping/Lafont) |
| `transduction.zig` | 1,263 | Fuel-bounded operational semantics |
| `transitivity.zig` | 780 | Structural equality + soundness |

Three semantic layers:

| Layer | File | What it does |
|-------|------|----------------|
| Denotational | `transclusion.zig` | Meaning of an expression |
| Operational | `transduction.zig` | Fuel-bounded execution |
| Structural | `transitivity.zig` | Cross-layer equality checks |

## Build targets

| Command | Binary | What it does |
|---------|--------|--------------|
| `zig build run` | `nanoclj` | Interactive REPL |
| `zig build embed-min` | `nanoclj-embed-min` | Minimal embedded profile |
| `zig build embed-safe` | `nanoclj-embed-safe` | Bounded embedded profile |
| `zig build mcp` | `nanoclj-mcp` | MCP server |
| `zig build gorj` | `gorj-mcp` | MCP with Clojure-defined tools |
| `zig build world` | `nanoclj-world` | Persistent world |
| `zig build strip` | `nanoclj-strip` | Color strip visualization |
| `zig build sector` | `sector.bin` | Freestanding x86 boot image |
| `zig build test` | — | Unit tests |

Embedded profiles strip subsystems at compile time via `profile.zig` (nREPL, kanren, inet, peval, MCP).

## Examples

```clojure
(load-file "examples/spj_type_inference.clj")     ;; Hindley-Milner via miniKanren
(load-file "examples/evalo_synthesis.clj")        ;; program synthesis (run* backward)
(load-file "examples/street_fighting_kanren.clj") ;; dimensional analysis
(load-file "examples/bumpus_kocsis.clj")          ;; structured decomposition
(load-file "examples/realizability.clj")          ;; computable sets + hierarchy
(load-file "examples/brainfloj_flow.clj")         ;; BCI signal pipeline
(load-file "examples/topos.clj")                  ;; effective topos playground
```

miniKanren runs relations forward, backward, or sideways:

```clojure
(run* [q] (appendo '(1 2) '(3 4) q))
;=> ((1 2 3 4))

(run 5 [x y] (appendo x y '(1 2 3 4)))
;=> ((() (1 2 3 4)) ((1) (2 3 4)) ((1 2) (3 4)) ((1 2 3) (4)) ((1 2 3 4) ()))
```

## Docs

- [docs/COLOR.md](docs/COLOR.md) — red/blue/purple dispatch boundary
- [docs/PICTURE-LANGUAGES.md](docs/PICTURE-LANGUAGES.md) — monoidal diagram kernel
- [docs/EMBEDDED-PROFILE.md](docs/EMBEDDED-PROFILE.md) — embedded profile plan

## Dependencies

- [zig-syrup](https://github.com/plurigrid/zig-syrup) — Syrup binary serialization (MCP framing)
- Zig 0.16 standard library

## License

MIT
