# Color in nanoclj-zig

Color is not decoration. Color is the **first observable** — it tells you which
runtime owns a sub-expression, which compilation strategy produced it, and
whether the system is conserved.

## The three colors

Every parenthesis pair in a nanoclj-zig program has a color. The color is
determined by which compilation/execution strategy owns that sub-expression:

```
red(  ... )    nanoclj-zig incremental AOT    static, fast, no eval
blue( ... )    jank-lang JIT                  eval, defmacro, reify
purple( ... )  dispatch boundary              spread-combine / FFI cell
```

### Why three

A sub-expression either:
- **can be fully resolved at compile time** → red (nanoclj-zig AOT)
- **requires runtime code generation** → blue (jank JIT)
- **dispatches between the two** → purple (boundary)

This is not a design choice. It is a consequence of the halting problem:
some expressions are decidable at compile time, some are not, and something
must decide which is which.

## Trit assignment

Colors map to GF(3) trits:

| Color | Trit | Role | Runtime | Compilation |
|-------|------|------|---------|-------------|
| Red | +1 | Generator | nanoclj-zig | Incremental AOT (Zig 0.16 LLVM backend) |
| Purple | 0 | Coordinator | dispatch | spread-combine boundary |
| Blue | -1 | Validator | jank-lang | JIT (Cling/ClangJIT) |

**Conservation law**: for any three nested paren pairs, the trit sum is 0 mod 3.

```
purple(                              trit = 0
  blue( let [f (eval expr)] )        trit = -1
  red(  (f (aot-vec data))  )        trit = +1
purple)                              sum  = 0 ✓
```

## How color is assigned

### Step 1: Entropy — drand beacon

Every session starts from a [drand](https://drand.love) beacon round.
Never hardcode seeds. Never use static values.

```bash
curl -s https://drand.cloudflare.com/public/latest | jq .randomness
```

### Step 2: Derivation — unworld seed chain

The beacon becomes a genesis seed. All subsequent colors derive deterministically
via SplitMix64 chaining:

```
genesis = drand_beacon()
seed₀ = genesis
seed₁ = (seed₀ ⊕ γ) × MIX mod 2⁶⁴
seed₂ = (seed₁ ⊕ γ) × MIX mod 2⁶⁴
```

Same beacon → same coloring. Different beacon → different coloring.
Reproducible but never static.

### Step 3: Classification — tree-sitter + predicate dispatch

Each AST node is classified by predicate dispatch (SDF Chapter 9):

```
needs-eval?         →  blue   (defmacro, eval, reify, dynamic protocol extension)
pure-computation?   →  red    (map, reduce, arithmetic, pattern match, let, fn*)
mixed-expr?         →  purple (split into blue half + red half)
```

The drand seed decides *exploration* of borderline cases. The predicates
decide the *ground truth*. Scala Native's lesson applies: **most of the
tree ends up red.** Only `eval`, runtime reflection, and dynamic class
loading are truly blue.

## The compiler as color source

`compiler.zig` contains the actual classification. Each `compile*` method
corresponds to a Clojure special form and an implicit color:

### Red (AOT — nanoclj-zig owns these)

| Method | Form | Why red |
|--------|------|---------|
| `compileLet` | `let` | Pure binding, no runtime dispatch |
| `compileDef` | `def` | Global definition, resolved at compile |
| `compileFnStar` | `fn*` | Closure creation, static |
| `compileIf` | `if` | Conditional, static branch |
| `compileCond` | `cond` | Multi-branch conditional |
| `compileWhen` | `when` | Single-branch conditional |
| `compileLoop` | `loop` | Tail-recursive loop |
| `compileRecur` | `recur` | Tail call, static |
| `compileDo` | `do` | Sequential execution |
| `compileAnd` | `and` | Short-circuit, static |
| `compileOr` | `or` | Short-circuit, static |
| `compileThreadFirst` | `->` | Macro-like rewriting, compile-time |
| `compileThreadLast` | `->>` | Macro-like rewriting, compile-time |
| `compileTry` | `try` | Exception handling, structured |
| `compileCase` | `case` | Dispatch table, static |
| `compileVariadicArith` | `+`,`-`,`*`,`/` | Arithmetic, emits opcodes directly |
| `compileVariadicCmp` | `=`,`<`,`<=` | Comparison, emits opcodes directly |
| `compileNegate` | `(- x)` | Unary negate |

### Purple (dispatch boundary)

| Method | Form | Why purple |
|--------|------|------------|
| `compileCall` | `(f args...)` | General function call — could resolve to red (known fn) or blue (eval'd fn) |
| `compileDefn` | `defn` | Defines + installs — the definition is red, the installation touches global state |

### Blue (would need JIT — not yet in nanoclj-zig)

| Form | Why blue | Status |
|------|----------|--------|
| `eval` | Runtime code generation | Tree-walk only, not compiled |
| `defmacro` (at runtime) | Macro expansion after compile | Handled in tree-walk interpreter |
| `reify` | Runtime protocol implementation | Not yet implemented |
| `Class/forName` | Runtime class loading | Not applicable (no JVM) |

## The bytecode as color proof

The 22 opcodes in `bytecode.zig` are **all red**. Every opcode is statically
dispatched, fixed-width (32 bits), and fuel-bounded. There is no `EVAL` opcode.
There is no `LOAD_CLASS` opcode. The bytecode VM is a pure AOT artifact.

```
Opcodes by color:

  RED (all 22):
    ret, ret_nil                          control flow
    jump, jump_if, jump_if_not            branching
    load_nil, load_true, load_false       constants
    load_int, load_const                  immediates
    add, sub, mul, div, quot, rem         arithmetic
    eq, lt, lte                           comparison
    call, tail_call                       function dispatch
    closure                               closure creation
    move, get_upvalue                     data movement

  BLUE (0):
    — none —
    (eval is in the tree-walk interpreter, not the bytecode VM)
```

This is the Scala Native lesson made concrete: nanoclj-zig's bytecode VM
is **entirely AOT**. The blue territory exists only in `eval.zig` (the
tree-walk interpreter), which is the escape hatch for dynamic evaluation.

## Tree-sitter verification

Both parsers are available and confirmed working:

| Parser | Extension | Status | Use |
|--------|-----------|--------|-----|
| tree-sitter-zig | `.zig` | Available (needs explicit language hint) | Parse compiler, bytecode, bridge |
| tree-sitter-clojure | `.clj` | Available | Parse nanoclj source, examples |
| tree-sitter-clojure | `.hy` | Works (95% coverage) | Parse Hy as Clojure dialect |

### Hy as the purple runtime

Hy (`.hy` files) is Python with Lisp syntax. tree-sitter-clojure parses it
correctly for all forms except:

| Hy form | Gap | Semantic meaning |
|---------|-----|-----------------|
| `#** kwargs` | Reader macro mismatch | Splat kwargs (Python) |
| `(setv x 1)` | Parsed as generic list | Mutation (Python semantics) |
| `(import x :as y)` | Parsed as generic list | Python import |
| `(with [f (open)] ...)` | Parsed as generic list | Context manager |

These 4 forms are the **semantic boundary** between Clojure (blue) and
Python (purple). `setv` is mutation; `def` is binding. The color should
reflect which runtime's semantics own the form:

```
;; trit_ticks.hy — purple throughout
;; "There is no house. You're already on the street."

purple( setv MASK64 0xFFFFFFFFFFFFFFFF )purple    ;; mutation = Python
purple( import datetime :as dt )purple              ;; Python import
purple( defn color-at [seed index] ... )purple      ;; defn compiles to Python def
```

## The ordered pair

Every sub-expression is an ordered pair `(runtime, expression)`:

```
purple( blue( defmacro my-transform [x] ... )blue   ← jank: needs eval
        red(  (map inc (range 1000000))       )red   ← nanoclj-zig: AOT hot loop
purple)                                               ← dispatch: spread-combine
```

The left half of the pair (runtime) is the color. The right half (expression)
is the code. The nesting of colored parens IS the computation's Markov blanket:
you can read the boundary between dynamic and static from the colors alone.

## Five competing models

Color assignment can be viewed through five lenses (SDF Chapter 8 — Degeneracy):

| Model | Boundary | Strength |
|-------|----------|----------|
| **Propagators** | Cell merge lattice at FFI boundary | Handles partial-dynamic expressions |
| **Interaction nets** | Agent principal ports, pairwise | Confluent, no GC at boundary |
| **Chromatic walk** | Seed-derived prime geodesic | Deterministic from drand, non-backtracking |
| **Concatenative** | Stack effect annotation per word | Maximally compositional |
| **SDF dispatch** | Predicate match on AST node | Color follows from semantics, not annotation |

The recommended stack:
- **Propagators** for the runtime (cells at the C ABI boundary)
- **Chromatic walk** for the editor (seed-derived paren coloring)
- **SDF dispatch** for the compiler (predicate → color)

```
propagators (+1) ⊗ chromatic-walk (0) ⊗ sdf-dispatch (-1) = 0 ✓
```

## Connection to the bytecode

The 22 opcodes map to SplitMix64 color indices. For a given drand seed,
each opcode gets a deterministic color from `color_at(seed, opcode_index)`.
Since all 22 are red (AOT), this produces a **red palette** — 22 shades
of the same trit, varying only in hue. The palette is the visual signature
of the compilation session.

```zig
// From nanoclj_bridge.zig — the same SplitMix64 used in trit_ticks.hy
export fn ncz_color_at(seed: u64, index: u64) u64 {
    var state = seed;
    for (0..index + 1) |_| {
        state +%= 0x9e3779b97f4a7c15;
    }
    const z = splitmix64_mix(state);
    const r = (z >> 40) & 0xFF;
    const g = (z >> 24) & 0xFF;
    const b = (z >> 8) & 0xFF;
    return (r << 16) | (g << 8) | b;
}
```

## Summary

```
                    drand beacon (contextual entropy)
                         │
                    unworld chain (deterministic derivation)
                         │
         ┌───────────────┼───────────────┐
         │               │               │
    tree-sitter-zig  tree-sitter-clj  tree-sitter-clj
    parses .zig      parses .clj      parses .hy
         │               │               │
     red (+1)        blue (-1)       purple (0)
     nanoclj-zig     jank JIT        Hy/Python
     22 opcodes      eval/macros     street semantics
     AOT             JIT             AOT (Python)
         │               │               │
         └───────────────┼───────────────┘
                         │
                    GF(3) = 0 ✓
```
