# Molecular Structure Upscaling — Tactics

## Thesis

ESRGAN/chaiNNer operates in pixel space: interpolate, hallucinate, hope.
The zig-syrup stack decomposes first, classifies second, checks third.
Apply the same discipline to molecular coordinates: wavelet by interaction
scale, classify by chemical validity, conserve GF(3) over bond rings.

---

## Tactic 1: Scale-Band Decomposition (Face 1 + Face 8)

**Analog of**: wavelet decomposition in image upscaling.

Molecules have natural interaction scales. Decompose the distance matrix
into sparse graphs filtered by Angstrom range:

| Band | Range (Å) | Physical Meaning | Data Structure |
|------|-----------|------------------|----------------|
| covalent | 0.5–2.0 | bonds | `dense_f64` adjacency |
| hydrogen | 2.5–3.5 | H-bonds, salt bridges | sparse map |
| vdw | 3.0–4.5 | van der Waals contacts | sparse map |
| tertiary | 8.0–50.0 | domain packing | coarse graph |

**Implementation**: `mol-wavelet` builtin in `core.zig`. Input: vector of
`{:element :x :y :z}` maps. Output: map of band → `dense_f64` distance
matrix. Each band is an independent upscale target.

**Interaction net role**: Bands share atoms but not edges. The inet engine
computes shared atom positions once, routes to all band computations via
fan-out (δ cells). Optimal sharing = no redundant coordinate transforms.

**Expander level**: 1 (fork/join). Each band upscales with forked fuel.

---

## Tactic 2: Chemical Validity Classification (Face 5: GF(3))

**Analog of**: perceptual band classification in image space.

Every pairwise interaction gets a trit:

```
+1 = favorable  (bond length/angle in allowed region)
 0 = neutral    (borderline, energy ~0)
-1 = forbidden  (steric clash, impossible geometry)
```

Classification uses known chemistry:
- Covalent band: reference bond lengths ± tolerance (CSD statistics)
- H-bond band: donor-acceptor distance + angle criteria (Baker-Hubbard)
- VdW band: Lennard-Jones minimum ± σ
- Backbone: Ramachandran φ/ψ allowed regions (GF(3) trit per residue)

**Implementation**: `classify-interaction` as a multimethod dispatching
on band keyword. Returns trit. Uses `dense_f64` for batch classification
of all pairs in a band.

**Connection to existing code**: `transitivity.zig` already tracks
`trit_accumulator`. Extend to molecular context: `mol-trit-sum` returns
the GF(3) balance of a molecular graph.

---

## Tactic 3: Ring Conservation Invariant (Face 5 + Face 12)

**Analog of**: GF(3) conservation checking before pixel output.

**The invariant**: for any cycle (ring) of bonded atoms, the sum of
interaction trits around the ring must be 0 mod 3.

Benzene: 6 C-C bonds, each favorable (+1). Sum = 6 ≡ 0 mod 3. Valid.
Strained ring: 4 favorable + 1 neutral + 1 forbidden = 3 ≡ 0. Valid (strained but real).
Impossible ring: 5 favorable + 1 forbidden = 4 ≡ 1 mod 3. **Rejected.**

**Implementation**: `find-rings` via depth-limited DFS on covalent band
graph. `valid-upscale?` checks trit sum over all rings before accepting
new coordinates. This is the molecular analog of the GF(3) check that
`gorj_bridge.zig` runs before emitting any Syrup-encoded result.

**Thermodynamic grounding** (Article I of Constitution): violating
conservation means the result has no meaning. A steric clash that breaks
ring trit-sum is not a warning — it is a semantic error in the molecular
graph. The upscaler must not produce it.

---

## Tactic 4: Per-Band Upscaling via Interaction Nets (Face 1)

**Analog of**: the actual upscale step (ESRGAN convolution).

Each band has its own upscaling strategy:

| Band | Method | inet cell type |
|------|--------|----------------|
| covalent | ideal geometry templates (sp3, sp2, sp) | γ constructor |
| hydrogen | distance geometry + angle constraint | σ superposition |
| vdw | packing optimization (sphere packing) | δ duplicator |
| tertiary | coarse-grained elastic network model | ε eraser (prune) |

The inet engine composes these: a covalent-band γ cell produces ideal
local geometry; a vdw-band δ cell duplicates the result to check all
neighbor contacts; a σ cell selects between alternative conformations
based on the trit classification.

**Optimal sharing**: computing a bond angle affects both covalent and
hydrogen bands. The inet wiring ensures the angle is computed once and
routed to both consumers. This is the molecular analog of computing
`activate(mix)` once and routing to multiple olfactory predicates.

---

## Tactic 5: Syrup Wire Protocol for Pipeline Stages (Face 13)

**Analog of**: zig-syrup encoding between decompose/upscale/check stages.

Each pipeline stage communicates via Syrup records:

```
#mol-band{
  :band :covalent
  :range [0.5 2.0]
  :atoms #dense-f64[...]
  :distances #dense-f64[...]
  :trits #dense-f64[...]     ; +1/0/-1 per pair
  :trit-sum 0                 ; must be 0 mod 3
}
```

Syrup's canonical encoding ensures reproducibility: same molecular input
always produces identical byte-level output. The `gorj-encode`/`gorj-decode`
builtins in `gorj_bridge.zig` handle serialization. Bands can be cached,
transmitted, or verified independently.

**CapTP connection**: a molecular band is a capability object. Possession
of the Syrup-encoded band = authority to upscale it. Different upscale
engines (local Zig, remote GPU, jo_clojure neural net) receive band
capabilities via CapTP, return upscaled coordinates, and the local
nanoclj instance checks GF(3) conservation before accepting.

---

## Tactic 6: Fuel-Bounded Conformational Search (Face 6)

**Analog of**: fuel-bounded eval preventing infinite loops.

Molecular upscaling can involve conformational search (finding valid
3D arrangements). This is NP-hard in general. Fuel bounding prevents
runaway optimization:

```clojure
(transduction/eval-bounded
  {:fuel 10000}
  (mol-upscale structure :method :covalent-ideal))
```

If the upscaler can't find a GF(3)-conserving geometry within fuel
budget, it returns `Domain.bottom(.fuel_exhausted)` — an honest "I
don't know" rather than a hallucinated structure.

**Constitution Article II compliance**: every mol-upscale path terminates.
No infinite minimization loops. The fuel cost of each candidate geometry
evaluation is O(n²) in atoms per band (pairwise distance check).

---

## Tactic 7: miniKanren for Constraint Propagation (Face 15)

**Analog of**: the ZK-intent predicate from GEB/Anoma discussion.

Express molecular constraints as relations:

```clojure
(run* [coords]
  (fresh [d angle]
    ;; Bond length constraint
    (distanceo (nth coords 0) (nth coords 1) d)
    (rangeo d 1.3 1.6)  ; C-C bond
    ;; Angle constraint
    (angleo (nth coords 0) (nth coords 1) (nth coords 2) angle)
    (rangeo angle 109.0 120.0)  ; sp2/sp3
    ;; GF(3) ring conservation
    (ring-conservedo coords)))
```

kanren.zig's substitution-based search propagates constraints without
enumerating all possibilities. The type-directed search (SPJ-style)
prunes impossible geometries early.

**Realizability connection** (Face 15, Heyting Day): a valid molecular
geometry is a realizer for the conjunction of chemical constraints.
The kanren search finds realizers. GF(3) conservation is a topos-level
truth condition — the geometry is "true" in the molecular topos iff
the trit sum is 0 mod 3 on all rings.

---

## Pipeline Summary

```
PDB/MOL input
  │
  ├─[Tactic 1]─ mol-wavelet ─→ 4 bands (dense_f64 each)
  │
  ├─[Tactic 2]─ classify-interaction ─→ trits per pair per band
  │
  ├─[Tactic 3]─ ring-conservation check ─→ validate input trits
  │
  ├─[Tactic 4]─ per-band inet upscale ─→ new coordinates
  │     │
  │     └─[Tactic 6]─ fuel-bounded search if conformational
  │     └─[Tactic 7]─ kanren constraint propagation if relational
  │
  ├─[Tactic 3]─ ring-conservation check ─→ validate output trits
  │
  ├─[Tactic 5]─ Syrup encode result ─→ wire-format molecular bands
  │
  └─ reassemble bands ─→ upscaled structure
```

**What this prevents that ESRGAN can't**:
- Steric clashes (trit = -1, caught by ring conservation)
- Impossible bond angles (caught by classification)
- Hallucinated atoms (no interpolation in coordinate space)
- Non-terminating optimization (fuel-bounded)
- Non-reproducible results (Syrup canonical encoding)

---

## Files to Create

| File | LOC est. | Purpose |
|------|----------|---------|
| `src/mol_wavelet.zig` | ~200 | Band decomposition of distance matrix |
| `src/mol_classify.zig` | ~150 | GF(3) trit classification per interaction |
| `src/mol_rings.zig` | ~100 | Ring detection + trit-sum conservation check |
| `src/mol_upscale.zig` | ~250 | Per-band upscaling via inet cells |

Builtins to register in `core.zig`:
- `mol-wavelet`, `mol-classify`, `mol-rings`, `mol-trit-sum`
- `mol-upscale`, `mol-valid?`, `mol-reassemble`

---

## Expander Face Mapping

| Tactic | Primary Face | Secondary Faces |
|--------|-------------|-----------------|
| 1. Scale decomposition | 8 (Optimal Sharing) | 1 (Interaction Nets) |
| 2. Validity classification | 5 (GF(3)/Trit) | 10 (Denotational=Operational) |
| 3. Ring conservation | 5 (GF(3)/Trit) | 12 (Thermodynamic) |
| 4. inet upscale | 1 (Interaction Nets) | 8 (Optimal Sharing) |
| 5. Syrup wire protocol | 13 (Categorical Semantics) | 9 (Zig Parallel) |
| 6. Fuel-bounded search | 6 (Resource-Aware) | 2 (Solomonoff) |
| 7. kanren constraints | 15 (Realizability) | 14 (Self-Reference) |
