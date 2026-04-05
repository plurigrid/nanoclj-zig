# HolyZig Convergence: Path-Invariance of Systems Programming

**Thesis**: HolyC and Zig are homotopic paths in the space of systems languages.
They connect the same endpoints through different routes, and the homotopy
equivalence is *witnessed* by the five HolyC files in this directory — each
demonstrating a concept that converges to the same computational substance
regardless of which path you take.

## The Gwern Framework

Gwern's three essays provide the empirical backbone:

1. **Garden of Forking Paths** (`gwern.net/forking-path`): Technology is
   *disjunctive* — it needs to succeed in only one way. HolyC and Zig are
   two forks that both succeed at "C without the lies." The function is the
   attractor; the path is contingent.

2. **Timing** (`gwern.net/timing`): Ideas are worthless; timing is everything.
   HolyC arrived in 2003 (too early, wrong packaging). Zig arrived in 2016
   (LLVM mature, safety discourse peaked). Same design point, different epoch.
   Gwern's model: startups as Thompson sampling. Terry Davis was a sample
   from the same distribution as Andrew Kelley, drawn earlier.

3. **Convergence** (Kevin Kelly ch.7, hosted by Gwern): Independent, equivalent,
   simultaneous invention is the *norm*. The greater the inevitability, the
   more parallel inventors. Both HolyC and Zig independently arrived at:
   - No hidden control flow
   - Allocator as explicit parameter
   - Comptime/JIT as first-class
   - Hostility toward implicit behavior
   - The compiler IS the build system

   This is Kelly's "convergent evolution" — different lineages, same phenotype.

## The Homotopy Reading

In HoTT, two paths p, q : A → B are *homotopic* if there exists a continuous
deformation H : [0,1] → (A → B) with H(0) = p and H(1) = q.

```
Type Space of Systems Languages
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  A = "C with full hardware control"
  B = "Safe, explicit, no-hidden-cost systems programming"

  Path p (HolyC):  A ──[ring 0]──[JIT shell]──[DolDoc]──[single-pass]──> B
  Path q (Zig):    A ──[LLVM]──[comptime]──[allocators]──[safety]──────> B

  Homotopy H(t):   The five lesson files, parameterized by t ∈ [0,1]
                    At t=0, the concept is expressed in HolyC
                    At t=1, the concept is expressed in Zig
                    For all t, the computational content is preserved
```

### The five paths and their deformations

| Lesson | t=0 (HolyC) | t=1 (Zig) | Path-invariant content |
|--------|-------------|-----------|----------------------|
| 00-Eval | `ExePrint(src)` | bytecode VM default | Eval = compile. No interpreter. |
| 01-Direct | Single-pass JIT | Reader → bytecode | Source → executable in one pass |
| 02-Symbol | `HashFind` global table | `(env)` returns map | Environment is first-class data |
| 03-AbcGc | ABC copy collector | `abcCollect()` in gc.zig | Acyclic data needs only pointer reset |
| 04-DolDoc | `$RED$...$FG$` | `\x1b[31m...\x1b[0m` | Output carries its own rendering |

The **path-invariant content** (rightmost column) is the *type* — it doesn't
depend on whether you took the HolyC path or the Zig path. This is exactly
what homotopy type theory means by "transport along a path."

## Path-Invariance as GF(3) Conservation

The existing `homotopy.zig` in zig-syrup already tracks paths with GF(3) trits:

```zig
pub const PathStatus = enum {
    tracking,   // trit  0 (ergodic — still moving)
    success,    // trit +1 (plus — reached target)
    diverged,   // trit -1 (minus — path failed)
    singular,   // trit -1
    min_step,   // trit -1
};
```

The HolyC → Zig homotopy has the same structure:

| Path segment | Status | Trit |
|---|---|---|
| HolyC concept works in HolyC | tracking | 0 |
| Concept translates to Zig | success | +1 |
| Concept DOESN'T translate (ring 0, DolDoc native) | diverged | -1 |

Conservation: for every concept that translates (+1), there's a HolyC-specific
artifact that doesn't (-1), and the concept itself is the ergodic center (0).
Sum = 0 mod 3.

## Alternative Histories (Gwern's Counterfactuals)

**What if HolyC had been developed after LLVM?**
Terry Davis with LLVM backends would have produced something like Zig with
a more radical UX (DolDoc, 640×480 covenant). The JIT-as-shell would remain.
The single-pass compiler might have become multi-pass with optimization.
Convergence: the *concepts* (eval=compile, env=data, rich output) survive.

**What if Zig had no safety guarantees?**
Remove safety checks, you get closer to HolyC. The allocator-as-parameter
pattern is already HolyC's `MAlloc`/`Free` made explicit. Without `@panic`
on buffer overflow, Zig code is HolyC code with different syntax.
Convergence: safety is the *parameterization* of the homotopy (the t value),
not the substance.

**What if nanoclj-zig had been written in HolyC?**
The five files in this directory ARE that alternative history. Every concept
translates. The value representation changes (tagged I64 vs NaN-boxed f64),
the GC strategy changes (manual vs mark-sweep), but the forms — def, env,
list, first, rest, +, *, eval — are identical.

## The Homotopy Continuation Connection

`zig-syrup/src/homotopy.zig` solves polynomial systems by deforming a known
system G(x) into an unknown system F(x) along the path:

```
H(x, t) = (1-t)·γ·G(x) + t·F(x)
```

The HolyZig convergence is the *same operation* applied to programming languages:

```
H(concept, t) = (1-t)·HolyC(concept) + t·Zig(concept)
```

At t=0, concepts are expressed in HolyC (00-Eval.HC through 05-AllTogether.HC).
At t=1, concepts are expressed in Zig (main.zig, gc.zig, core.zig, repl.zig).
The path tracker follows each concept from t=0 to t=1, checking that:
- The concept doesn't diverge (PathStatus.diverged → trit -1)
- The concept reaches the target (PathStatus.success → trit +1)
- The Jacobian (how sensitive the implementation is to the language choice)
  remains non-singular along the path

The `gamma` factor (random complex rotation for regularity) corresponds to
the *style* differences — HolyC's `$RED$` vs Zig's `\x1b[31m` — that
rotate the solution without changing the root.

## Implementation: `holyzig_homotopy.zig`

To make this concrete in code, extend `homotopy.zig` with a language-pair tracker:

```zig
pub const LanguagePath = struct {
    concept: []const u8,       // "eval", "gc", "env", "direct", "rich-output"
    holyc_file: []const u8,    // "holyc/00-Eval.HC"
    zig_target: []const u8,    // "main.zig" 
    status: PathStatus,        // did the concept survive transport?
    invariant: []const u8,     // what's preserved: "compile=eval"
    trit: continuation.Trit,   // GF(3) classification
};
```

Five paths. Each tracked from t=0 (HolyC) to t=1 (Zig). The path-invariant
content is the computational substance that survives transport — the *type*
in HoTT terms, the *convergent phenotype* in Kelly/Gwern terms.

## The Forester Tree

This analysis belongs at `bci.horse` as a theory tree linking:
- bcf-0046 (Git vs Pijul type erasure — path-dependence of VCS)
- bcf-0047 (jj workspaces — recovering commutation)
- bcf-0018 (GLIMPSE_HZ — structurally forced constants)
- The ternary tower (path-invariant thresholds)

All four are instances of the same phenomenon: *the computational content is
path-invariant; only the representation depends on the route.*
