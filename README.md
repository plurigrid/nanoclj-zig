# nanoclj-zig

A Clojure interpreter in ~8,000 lines of Zig with NaN-boxed values, fuel-bounded evaluation, interaction nets, and a Forester mathematical forest.

```
$ zig build run
nanoclj-zig v0.1.0
GF(3) trit wheel
████████████████████████████████████████████████████████████████████████████████
            +1 (red)                  0 (green)                  -1 (blue)

bob=> (let* [xs [1 2 3 4 5]] (map inc xs))
(2 3 4 5 6)

bob=> (color-at 1069 0)
{:hex "#7D9C76", :r 125, :g 156, :b 118, :trit 1}

bob=> (assoc {:name "bob"} :seed 1069 :trit 1)
{:name "bob", :seed 1069, :trit 1}
```

## Build

Requires [Zig 0.15+](https://ziglang.org/download/).

```sh
git clone https://github.com/plurigrid/nanoclj-zig
cd nanoclj-zig
zig build run          # interactive REPL
zig build test         # run tests
zig build -Doptimize=ReleaseFast run  # optimized build
```

## What works

Clojure-dialect Lisp with vectors, maps, sets, keywords, and closures:

```clojure
(+ 1 2)                              ;=> 3
(* 3 4)                              ;=> 12
(first [10 20 30])                    ;=> 10
(rest [10 20 30])                     ;=> (20 30)
(count [1 2 3 4 5])                   ;=> 5
(conj [1 2] 3)                       ;=> [1 2 3]
(assoc {:a 1} :b 2)                   ;=> {:a 1, :b 2}
(str "hello" " " "world")            ;=> "hello world"
(if true "yes" "no")                  ;=> "yes"
(let* [a 10 b 20] (+ a b))           ;=> 30
(map inc [1 2 3])                     ;=> (2 3 4)
(filter (fn* [x] (> x 2)) [1 2 3 4]) ;=> (3 4)
(reduce + 0 [1 2 3 4 5])             ;=> 15
```

## NaN-boxing

Every value fits in 64 bits. If the bits form a valid IEEE 754 double, it's a float.
Otherwise, we steal the quiet-NaN payload for a 3-bit tag and 48-bit pointer/integer:

```
Float:    any bit pattern that isn't a quiet NaN with our marker
Tagged:   0x7FF8 | tag(3 bits) | payload(48 bits)

tag=0  nil
tag=1  boolean
tag=2  integer (inline i48)
tag=3  symbol (interned ID)
tag=4  keyword (interned ID)
tag=5  string (interned ID)
tag=6  heap object → list | vector | map | set | fn | macro
```

No wrapper structs, no union overhead, no allocation for primitives. An `ArrayList(Value)` is
just a contiguous array of `u64`s.

## Fuel-bounded evaluation

Every eval step costs fuel. Recursion depth is bounded. Untrusted code can't loop forever:

```zig
// from transduction.zig — every eval step decrements fuel
pub fn evalBounded(expr: Value, env: *Env, gc: *GC, res: *Resources) Domain {
    if (res.fuel == 0) return .{ .bottom = .fuel_exhausted };
    res.fuel -= 1;
    if (res.depth > res.limits.max_depth) return .{ .bottom = .depth_exceeded };
    // ...
}
```

Three semantic layers verify agreement:

| Layer | File | Purpose |
|-------|------|---------|
| Denotational | `transclusion.zig` | What an expression *means* (⟦·⟧) |
| Operational | `transduction.zig` | How it *executes* (fuel-bounded) |
| Structural | `transitivity.zig` | Equality, GF(3) trits, soundness checks |

A soundness test confirms both layers agree on every value:

```zig
test "soundness: denotational = operational" {
    // denote(val) == evalBounded(val) for all test values
}
```

## GF(3) trit coloring

Every seed maps deterministically to an RGB color and a trit in {-1, 0, +1} via SplitMix64.
Conservation law: every triad of values sums to 0 mod 3.

```clojure
bob=> (color-at 1069 0)
{:hex "#7D9C76", :r 125, :g 156, :b 118, :trit 1}

bob=> (color-at 1069 1)
{:hex "#61612F", :r 97, :g 97, :b 47, :trit 1}

bob=> (color-at 1069 2)
{:hex "#3056FD", :r 48, :g 86, :b 253, :trit 0}

bob=> (gf3-add 1 1)
-1

bob=> (gf3-add 1 -1)
0
```

The REPL banner renders a 320-cell color fingerprint unique to your username, verified
`trit_sum mod 3 = 0`.

## Forester forest integration

Reads `.tree` files from a [Forester](https://www.jonmsterling.com/jms-005P.xml)
mathematical forest, materializing the transclusion graph at load time:

```clojure
bob=> (count (tree-ids))
1755

bob=> (tree-taxon "dct-0001")
"doctrine"

bob=> (count (tree-by-taxon "doctrine"))
22

bob=> (tree-meta "ologs-2012")
{:doi "10.1371/journal.pone.0024274", :arxiv "1102.1889"}

bob=> (tree-imports "dct-0001")
("macros")

bob=> (tree-chain "hub-doctrines")
("hub-doctrines" "dct-0001" ... )
```

12 builtins: `tree-read`, `tree-title`, `tree-taxon`, `tree-author`, `tree-meta`,
`tree-imports`, `tree-transcluded`, `tree-transcluders`, `tree-ids`, `tree-isolated`,
`tree-chain`, `tree-by-taxon`.

## Interaction nets & partial evaluation

Lamping/Lafont optimal reduction with four cell kinds (γ/δ/ε/ι) and GF(3) charges:

```clojure
bob=> (def net (inet-new))
bob=> (inet-cell net 0 2)   ; γ cell, arity 2
bob=> (inet-reduce net)     ; reduce active pairs
```

At startup, a first Futamura projection partially evaluates constant bindings through
the interaction net, collapsing compile-time-known computation before the REPL starts.

## Architecture

```
src/
  main.zig            145  REPL entry, banner, color strip, peval boot
  value.zig           174  NaN-boxed value representation
  reader.zig          247  S-expression reader/parser
  eval.zig            227  Core evaluator (def!, let*, if, do, fn*, quote)
  printer.zig         101  Value → string
  env.zig              63  Lexical scope chain (string + u48 ID lookup)
  gc.zig              207  Worklist-based mark-sweep garbage collector
  core.zig            545  80+ builtins (arithmetic, collections, color, BCI)
  gay_skills.zig      459  Tropical semiring, world sim, bisimulation
  substrate.zig       396  SplitMix64 engine, GF(3) arithmetic, nREPL stub
  semantics.zig        33  Re-exports the three semantic layers:
    transclusion.zig  447    Denotational semantics (⟦·⟧), domain type
    transduction.zig  457    Fuel-bounded operational eval
    transitivity.zig  453    Structural equality, resource limits, GF(3)
  tree_vfs.zig        547  Forester forest VFS (12 builtins)
  inet.zig            425  Interaction net engine (Lamping/Lafont)
  inet_compile.zig    433  Lambda → interaction net compiler
  inet_builtins.zig   278  Clojure-facing inet API
  peval.zig           258  Partial evaluation (first Futamura projection)
  mcp_tool.zig        563  Model Context Protocol server (JSON-RPC 2.0)
  http_fetch.zig      102  HTTP client builtin
  thread_peval.zig     96  OS-thread parallel eval for peval
  braid.zig           396  Braid-HTTP CRDT state sync
  vcv_bridge.zig      288  VCV Rack shared-memory CV bridge
  ─────────────────────────
  ~8,000 lines across 30 files
```

## Build targets

| Command | Binary | Description |
|---------|--------|-------------|
| `zig build run` | `nanoclj` | Interactive REPL |
| `zig build mcp` | `nanoclj-mcp` | MCP server for AI tool use |
| `zig build world` | `nanoclj-world` | Non-interactive world showcase |
| `zig build strip` | `nanoclj-strip` | Color strip demo |
| `zig build test` | — | Unit tests |

## Emacs integration

`nanoclj-mode.el` provides a full Emacs major mode: comint REPL, rainbow delimiters,
nREPL client, and BCI dashboard.

```elisp
(load "/path/to/nanoclj-zig/nanoclj-mode.el")
(nanoclj-start-repl)
```

## Performance

Benchmarks on Apple Silicon (ReleaseFast, Zig 0.15.2). Compared against Janet 1.40.1.

| Benchmark | nanoclj-zig | Janet 1.40.1 | Ratio |
|-----------|-------------|--------------|-------|
| fib(20) | <0.01s | <0.01s | ~1x |
| fib(25) | 0.02s | <0.01s | ~2x |
| fib(28) | 0.13s | 0.01s | ~13x |
| fib(30) | fuel limit* | 0.04s | — |
| tak(18,12,6) | 0.02s | <0.01s | ~2x |
| startup | <0.01s | <0.01s | ~1x |
| binary size | 1.1 MB | 71 KB | 15x |

\* nanoclj-zig's fuel limit (10B steps) caps very deep recursion.

**Optimizations applied (v0.2):** Lazy fork (sequential eval skips fork/join),
comptime depthFuelCost LUT (eliminates ~10M float ops), symbol-ID special form
dispatch (u48 compare instead of string compare). Combined ~2.2x speedup over v0.1.

The remaining ~13x gap vs Janet is the fundamental tree-walking vs bytecode-VM
difference: Janet compiles to bytecodes with a tight switch loop; nanoclj-zig
re-traverses the AST on every eval.

## Dependencies

- [zig-syrup](https://github.com/plurigrid/zig-syrup) (Syrup binary serialization, path dependency)
- Zig standard library
- Nothing else

## License

MIT
