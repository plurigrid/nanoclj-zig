# nanoclj-zig

A Clojure interpreter in Zig that compresses the trajectory from NaN-boxed values through miniKanren to realizability toposes. 28K LOC, 52 files. The language kernel is itself a compression target: every layer added must reduce, not increase, the Kolmogorov complexity of what the system can express.

```
$ zig build run
nanoclj-zig v0.1.0
GF(3) trit wheel
████████████████████████████████████████████████████████████████████████████████
            +1 (red)                  0 (green)                  -1 (blue)

bob=> (run* [q] (fresh [x y] (== x :hello) (== y :world) (== q [x y])))
([:hello :world])

bob=> (run* [q] (appendo '(1 2) '(3 4) q))
((1 2 3 4))

bob=> (color-at 1069 0)
{:hex "#7D9C76", :r 125, :g 156, :b 118, :trit 1}
```

## The trajectory

```
Level 0: Values                    Level 4: Realizability
  NaN-boxed u64                      kanren.zig = Lawvere hyperdoctrine
  3-bit tag + 48-bit payload         fresh = ∃ (left adjoint)
  value.zig (317 LOC)                == = right adjoint to weakening
       |                             conde = coproduct in fiber
       v                             computable_sets.zig = Σ⁰ₙ/Π⁰ₙ/Δ⁰ₙ
Level 1: Evaluation                  church_turing.zig = substrate comparison
  tree-walk (eval.zig, 1410)              |
  bytecode VM (compiler+bytecode)         v
  fuel-bounded (transduction.zig)    Level 5: Effective topos (.topos/)
  GF(3) conservation                   15 faces, 160 artifacts
       |                               Heyting Day 2025 transcripts
       v                               Pitts: ∀H, ∃?E with H≅E(1,Ω)
Level 2: Structure                     Bauer: Turing degrees synthetically
  interaction nets (inet.zig)          Terwijn: PCA embeddings/completions
  partial evaluation (peval.zig)       Van Oosten: oracles as LT topologies
  persistent vectors/maps              Kihara: bilayer games = oracle computation
       |                                    |
       v                                    v
Level 3: Relations                   Level 6: Concordance
  kanren.zig (714 LOC)                kanren = hyperdoctrine
  run*/fresh/conde/==                  fuel = non-completable PCA
  appendo/membero/conso                GF(3) = 3-element Heyting algebra
  SPJ type inference as search         walk = Scott-continuous
  street fighting dimensional analysis run* = Σ⁰₁ enumeration
```

Each level compresses the one below it:
- Level 1 compresses Level 0 (eval gives meaning to raw bits)
- Level 2 compresses Level 1 (inet reduces redexes optimally, peval eliminates known computation)
- Level 3 compresses Level 2 (relations run forward/backward/sideways from one definition)
- Level 4 compresses Level 3 (the arithmetical hierarchy classifies what search can find)
- Level 5 compresses Level 4 (synthetic computability eliminates encoding — computability is axiomatic)
- Level 6 compresses Level 5 (the concordance is a fixed point: the system describes itself)

## Build

Requires [Zig 0.15+](https://ziglang.org/download/).

```sh
git clone https://github.com/plurigrid/nanoclj-zig
cd nanoclj-zig
zig build run          # interactive REPL
zig build test         # run tests
zig build -Doptimize=ReleaseFast run  # optimized build
```

## miniKanren

Relational programming via Robinson unification. The street fighting move: instead of computing a result from inputs, state relationships and let the system find satisfying assignments.

```clojure
;; Forward: what is (append '(1 2) '(3 4))?
(run* [q] (appendo '(1 2) '(3 4) q))
;=> ((1 2 3 4))

;; SPJ type inference: compose (Bool->String) with (Int->Bool)
(run* [result]
  (fresh [a b1 b2 c]
    (== [:Bool :-> :String] [b1 :-> c])
    (== [:Int :-> :Bool] [a :-> b2])
    (== b1 b2)
    (== result [a :-> c])))
;=> ([:Int :-> :String])

;; Dimensional analysis: type error = units don't match
(run* [result]
  (fresh [a b1 b2 c]
    (== [:Int :-> :Bool] [b1 :-> c])
    (== [:String :-> :Bool] [a :-> b2])
    (== b1 b2)
    (== result [a :-> c])))
;=> ()  ; empty — String ≠ Int, like meters ≠ seconds

;; Relational witness: what states can an epoch have?
(run* [q]
  (fresh [sub-ok cls-ok diagnosis]
    (conde
      [(== sub-ok true) (== cls-ok true) (== diagnosis :well-posed)]
      [(== sub-ok false) (== cls-ok true) (== diagnosis :church-turing)]
      [(== sub-ok true) (== cls-ok false) (== diagnosis :classifier-divergence)]
      [(== sub-ok false) (== cls-ok false) (== diagnosis :double-ill-posed)])
    (== q {:substrate sub-ok :classifier cls-ok :diagnosis diagnosis})))
```

Builtins: `run*`, `run`, `fresh`, `conde`, `==`, `conso`, `appendo`, `membero`, `lvar`, `lvar?`, `unify`, `walk*`, `conj-goal`, `run-goal`.

## NaN-boxing

Every value fits in 64 bits. IEEE 754 double or quiet-NaN with 3-bit tag + 48-bit payload:

```
tag=0  nil       tag=3  symbol (interned)
tag=1  boolean   tag=4  keyword (interned)
tag=2  integer   tag=5  string (interned)
  (inline i48)   tag=6  heap object → list|vector|map|set|fn|macro
```

No wrapper structs. `ArrayList(Value)` = contiguous `u64` array. This is a PCA: K and S are definable, application is partial (fuel-bounded), and the interned string table is a countable base — an ω-algebraic domain in Bauer's sense.

## Fuel-bounded evaluation

Every eval step costs fuel. Recursion depth is bounded. Untrusted code terminates:

```zig
if (res.fuel == 0) return .{ .bottom = .fuel_exhausted };
res.fuel -= 1;
```

Three semantic layers verify agreement:

| Layer | File | Role |
|-------|------|------|
| Denotational | `transclusion.zig` | What an expression *means* (⟦·⟧) |
| Operational | `transduction.zig` | How it *executes* (fuel-bounded) |
| Structural | `transitivity.zig` | Equality, GF(3) trits, soundness |

The fuel bound makes the PCA non-completable (Terwijn, Heyting Day 2025): not every partial computation extends to a total one. This is CONSTITUTION.md Article II — the halting problem as design constraint.

## GF(3) trit coloring

Every seed → RGB color + trit in {-1, 0, +1} via SplitMix64. Conservation: closed compositions sum to 0 mod 3. The trit lattice {-1, 0, +1} with min/max/GF(3)-implication forms a 3-element Heyting algebra (Pitts, Heyting Day 2025: the subobject classifier Ω of a topos is always a Heyting algebra).

## Interaction nets & partial evaluation

Lamping/Lafont optimal reduction with four cell kinds (γ/δ/ε/ι) and GF(3) charges. First Futamura projection at startup: partially evaluate constant bindings through the inet.

## Architecture (52 files, 28K LOC)

```
KERNEL (the PCA)
  value.zig           317   NaN-boxed representation (the domain)
  reader.zig          525   S-expression reader
  eval.zig          1,410   Tree-walk evaluator
  compiler.zig      1,720   Bytecode compiler
  bytecode.zig        820   VM execution
  core.zig          4,382   100+ builtins
  env.zig             132   Lexical scope chain
  gc.zig              290   Mark-sweep GC

SEMANTICS (denotational-operational agreement)
  transclusion.zig    447   ⟦·⟧ denotational
  transduction.zig    902   fuel-bounded operational
  transitivity.zig    766   structural equality, GF(3)
  semantics.zig        35   re-exports

RELATIONS (the hyperdoctrine)
  kanren.zig          714   miniKanren: unification, goals, streams
  computable_sets.zig 1,598  Σ⁰ₙ/Π⁰ₙ/Δ⁰ₙ, Weihrauch degrees
  church_turing.zig   857   substrate comparison (tree-walk vs inet)
  pattern.zig         552   pattern matching

NETS (optimal reduction)
  inet.zig            506   interaction net engine
  inet_compile.zig    455   λ → inet compiler
  inet_builtins.zig   296   Clojure-facing API
  peval.zig           258   partial evaluation

SUBSTRATE (the world)
  substrate.zig       564   SplitMix64, GF(3), nREPL
  gay_skills.zig      459   tropical semiring, bisimulation
  colorspace.zig      460   color system
  tree_vfs.zig        491   Forester mathematical forest

BRIDGES (protocol)
  mcp_tool.zig        583   Model Context Protocol server
  gorj_mcp.zig        597   gorj MCP bridge
  gorj_bridge.zig     349   gorj eval pipeline
  braid.zig           396   Braid-HTTP CRDT sync
  syrup_bridge.zig    103   Syrup serialization
  http_fetch.zig      138   HTTP client
  vcv_bridge.zig      289   VCV Rack CV bridge

INFRASTRUCTURE
  main.zig            625   REPL, macro prelude, banner
  printer.zig         138   Value → string
  sector.zig        1,515   sector-based evaluation
  jepsen.zig          616   linearizability testing
  persistent_*.zig    743   persistent data structures
  regex.zig           367   regex engine
  simd_str.zig        160   SIMD string operations
  transcendental.zig  453   math functions
  ibc_denom.zig       298   IBC denomination parsing
```

## .topos/ — the expander

15 faces mapping the codebase to its mathematical context. 160 artifacts across papers, repos, transcripts. The Solomonoff gradient: K(eval) ≈ 800 LOC → K ≈ 150 LOC with full parallelism.

Face 15 (Heyting Day 2025) contains transcripts and slides from Pitts, Bauer, Terwijn, and van Oosten, with a concordance mapping each talk to nanoclj-zig primitives and Plurigrid's energy market semantics.

## Build targets

| Command | Binary | Description |
|---------|--------|-------------|
| `zig build run` | `nanoclj` | Interactive REPL |
| `zig build mcp` | `nanoclj-mcp` | MCP server for AI tool use |
| `zig build world` | `nanoclj-world` | Non-interactive world showcase |
| `zig build test` | — | Unit tests |

## Dependencies

- [zig-syrup](https://github.com/plurigrid/zig-syrup) (Syrup binary serialization)
- Zig standard library
- Nothing else

## License

MIT
