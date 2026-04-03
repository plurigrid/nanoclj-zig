# Expander Structure: .topos/ → nanoclj-zig implementation

## The Solomonoff Gradient (concrete steps)

Each level compresses K(eval) and reveals parallelism.
The expander maps each compression step to specific file changes.

---

## Level 1: Fuel Fork/Join (K≈820, parallelism≈30%)

**What**: Split `Resources` across independent arg evaluations.
**Where**: `src/transitivity.zig` (Resources) + `src/transduction.zig` (evalBoundedBuiltin)
**From**: `.topos/repos/ringmpsc/` (lock-free channel primitive)
**From**: `papers/resource-bounded-type-theory-graded-modalities.md` (graded comonad)

```zig
// Resources gets fork/join
pub fn fork(self: *Resources, n: usize) [64]Resources { ... }
pub fn join(children: []Resources) Resources { ... }

// evalBoundedBuiltin forks fuel across args
fn evalBoundedBuiltin(...) Domain {
    var child_res = res.fork(raw_args.len);
    // eval each arg with its own fuel budget
    // join results
}
```

**Thermodynamic interpretation**: fork = adiabatic expansion, join = measurement.
Each fork costs 0 (reversible). Join costs kT·ln(n) to merge n results.

---

## Level 2: let* DAG Analysis (K≈850, parallelism≈45%)

**What**: Analyze `let*` bindings for independence, eval independent ones in parallel.
**Where**: `src/transduction.zig` (evalBoundedLet)
**From**: `papers/elixir-lazy-bdds-eager-intersections.md` (lazy BDD dep analysis)

```zig
fn evalBoundedLet(items: []Value, env: *Env, gc: *GC, res: *Resources) Domain {
    // Phase 1: scan bindings, build dependency DAG
    // Phase 2: topological layers — fire each layer in parallel
    // Phase 3: sequential bindings where deps require
}
```

**d s connection**: "segmenting into 256 sections and processing independently"

---

## Level 3: def Topological Sort (K≈900, parallelism≈60%)

**What**: Parse entire .clj file, build def-dependency graph, fire independent layers.
**Where**: `src/main.zig` (add file-eval mode)
**From**: `papers/lattice-hash-forest-repetitive-data.md` (hash-consing for memoization)

```zig
// New: file-eval that reads all forms, builds dep graph, parallelizes
pub fn evalFile(path: []const u8, env: *Env, gc: *GC) !void {
    const forms = readAllForms(path, gc);
    const layers = topoSort(forms, gc); // independent def groups
    for (layers) |layer| {
        // all defs in this layer can eval simultaneously
        for (layer) |form| evalBounded(form, env, gc, &res);
    }
}
```

---

## Level 4: Interaction Net Cells (K≈200, parallelism≈80%)

**What**: Replace tree-walking eval with interaction net reduction.
**Where**: NEW `src/inet.zig`
**From**: `.topos/repos/deltanets/` (reference TypeScript impl)
**From**: `.topos/repos/optiscope/` (reference C impl, Lévy-optimal)
**From**: `.topos/repos/interaction-net-resources/` (theory)

```zig
// 6 cell types, each fits in 64 bits (NaN-box compatible)
const CellTag = enum(u4) {
    lam, app, dup, era, sup, num, op2, sym, con, // constructor
};

const Cell = packed struct {
    tag: CellTag,
    port0: u20,  // principal port → cell index
    port1: u20,  // aux port 1
    port2: u20,  // aux port 2
};

// 6 rewrite rules (the entire evaluator)
fn rewrite(net: *Net, a: CellId, b: CellId) void {
    switch (pairTag(net.cells[a].tag, net.cells[b].tag)) {
        .{.lam, .app} => annihilate(net, a, b),     // β-reduction
        .{.dup, .dup} => annihilate(net, a, b),      // duplication
        .{.dup, .lam} => commute(net, a, b),         // optimal sharing
        .{.dup, .app} => commute(net, a, b),
        .{.era, _}    => erase(net, a, b),           // garbage
        .{.num, .op2} => compute(net, a, b),          // arithmetic
    }
}
```

**Thermodynamic**: annihilate = 2·kT·ln(2). commute = 0 (reversible). erase = kT·ln(2).

---

## Level 5: Superposition (K≈220, parallelism≈92%)

**What**: `if` creates SUP node; both branches reduce in parallel.
**Where**: `src/inet.zig` (add SUP/DUP interaction)
**From**: `papers/linear-logic-negative-connectives.md` (Section 3: parallel rule application)

```zig
// if-then-else becomes:
// SUP(then_branch, else_branch) with condition selecting which port gets ERA'd
fn evalIf_inet(cond: CellId, then_: CellId, else_: CellId) CellId {
    const sup = net.alloc(.sup);
    net.link(sup.port0, then_);
    net.link(sup.port1, else_);
    // condition determines which port annihilates via ERA
    return sup;
}
```

---

## Level 6: Optimal Reduction (K≈150, parallelism≈95%)

**What**: Full Lévy-optimal reduction with bookkeeping.
**From**: `.topos/repos/optiscope/` (the backdoor-to-C approach)
**From**: `papers/cost-of-skeletal-call-by-need.md` (exact cost model)
**From**: `papers/rosetta-stone-interactive-quantitative-semantics.md` (THE unifying paper)

At this level, K(eval) ≈ K(language). The evaluator IS the shortest program
that generates all correct outputs for edge-cases.clj. What remains sequential
is the irreducible Kolmogorov complexity of Clojure-the-language.

---

## Cross-cutting: GF(3) as Thermodynamic Invariant

Every level preserves `trit_balance mod 3 = 0`.
This is the cobordism invariant across compression levels:
- Level 0: checked post-hoc by `transitivity.zig`
- Level 4+: enforced by construction in interaction net rewrite rules
  (every annihilation preserves trit sum; commutation is trit-neutral)

The expander structure is: MORE parallel ⟺ LESS fuel per step ⟺ CLOSER to Landauer limit ⟺ SHORTER program ⟺ MORE compressed.

---

## d s Threads (from beeper DM)

- "splittable de-turdmanism" → Level 2 (let* DAG decomposition)
- "256 independent sections" → Level 3 (def topo-sort)
- "agentic modular automata, infinitely rearrangeable blocks" → Level 4 (interaction net cells)
- "geodesics = minimum-effort paths" → Solomonoff gradient itself
- "ies gay.jl === Siegl jay" → the fixed point naming
