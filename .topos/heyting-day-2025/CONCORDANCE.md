# Heyting Day 2025 — Concordance with nanoclj-zig / bmorphism / Plurigrid

**14 March 2025, KNAW Trippenhuis, Amsterdam**
Symposium in honour of Jaap van Oosten (Utrecht, retired Dec 2024).
Organized by Benno van den Berg, Tom de Jong, Albert Visser. ~100 attendees.

---

## Materials

| Speaker | Title | Transcript | Slides/Report |
|---|---|---|---|
| Andrew Pitts (Cambridge) | *Heyting Algebras and Higher-Order Logic* | `pitts-transcript.txt` (11,657 words) | `pitts-slides.txt` (41 slides) |
| Andrej Bauer (Ljubljana) | *Turing Degrees in Synthetic Computability* | `bauer-transcript.txt` (10,715 words) | — |
| Sebastiaan Terwijn (Radboud) | *Embeddings and Completions in PCAs* | `terwijn-transcript.txt` (1,876 words) | — |
| Sebastiaan Terwijn (Radboud) | — | — | `terwijn-slides.txt` (26 slides, extracted) |
| Jaap van Oosten (Utrecht) | Heyting Lecture: "PCAs and Oracles" | (no auto-captions) | `van-oosten-summary.txt` (Exa extraction) |
| — | NAW Report on the event | — | `naw-report.txt` (3 pages) |

Videos: [Pitts](https://youtube.com/watch?v=LJUww3H7Pos) · [Bauer](https://youtube.com/watch?v=qjhDheSXv18) · [Terwijn](https://youtube.com/watch?v=8ozZPOFYZqw) · [van Oosten](https://youtube.com/watch?v=_RQY17CmyNA)

---

## Core Results and Their nanoclj-zig / Plurigrid Resonances

### 1. Pitts: The Open Question

**∀H, ∃? E with H ≅ E(1,Ω)**
Is every Heyting algebra the algebra of truth values of some topos?

Three models of truth:
- **Classical**: ⟦φ⟧ ⊆ {∗} (two subsets) → topos **Set**
- **Continuous**: ⟦φ⟧ ⊆ ℝ (open subsets) → sheaf topos over ℝ
- **Kleene-realizable**: ⟦φ⟧ ⊆ ℕ (all subsets) → Hyland's **Effective Topos**

Pitts' uniform interpolation: ∀IPL formula ψ, ∃ Apψ (right adjoint to weakening)
and Epψ (left adjoint). Computable! Verified by Férée & van Gool (CPP 2023).

**nanoclj-zig resonance**:
- `kanren.zig` unification IS the adjoint: `(== x y)` as the right adjoint to
  weakening (adding a fresh variable to the substitution context)
- `fresh` = the left adjoint (existential quantification in a hyperdoctrine)
- `conde` = coproduct in the fiber of the Lawvere hyperdoctrine
- The free Heyting algebra F[X] on variables X = the set of all miniKanren goals
  on those variables, modulo logical equivalence
- `GF(3)` conservation (CONSTITUTION.md Art. I) lives in a 3-element Heyting algebra
  {-1, 0, +1} with →  defined by GF(3) implication

**Plurigrid resonance**:
- The open question matters for Plurigrid because the effective topos is the
  "computable universe" where all functions are computable by nature. If every
  Heyting algebra arises from some topos, then every lattice of constraints
  (including energy market clearing constraints) has a "computable universe"
  backing it.
- Pitts' Ap/Ep = uniform interpolation = the ability to project out variables
  while preserving all logical relationships. This is exactly what marginalizing
  out participants in an energy market does.

### 2. Bauer: Synthetic Computability and Turing Degrees

**Key insight**: The effective topos is a world where everything is computable
by construction. No Turing machines needed — just axioms:
- CT (Church's Thesis): every function ℕ→ℕ is computable
- MP (Markov's Principle): ¬¬∃ → ∃ for decidable predicates
- CT + MP + IHOL = synthetic computability theory

**Oracles as domain theory**: A partial oracle = pair (A₀, A₁) of disjoint
subsets of ℕ. Total oracles = maximal elements. The domain O is ω-algebraic.
Turing reductions = Scott-continuous maps on O.

**New result (with Swan)**: Kleene-Post theorem synthetically — there exist
incomparable Turing degrees. Uses a domain-theoretic Baire category argument
inside the effective topos.

**nanoclj-zig resonance**:
- `computable_sets.zig` arithmetical hierarchy (Σ⁰ₙ, Π⁰ₙ, Δ⁰ₙ) = the
  stratification of truth values in the effective topos
- `kanren.zig` `run*` with no bound = Σ⁰₁ search (enumerable)
- `kanren.zig` `run 1` = finding a witness = realizability
- Bauer's oracles ↔ `church_turing.zig` substrate comparison: tree-walk vs inet
  are two "oracles" that may give different answers on the same input
- The `walk` function in kanren.zig IS Scott-continuous: it preserves directed
  suprema of substitution chains (extending a substitution is monotone,
  walk follows the chain)

**Plurigrid resonance**:
- Parametric realizability (Bauer-Hanson) where Dedekind reals are countable
  connects to Plurigrid's energy markets: prices are "countable" (discrete bids)
  even though the underlying physical quantity (energy) is continuous
- Van Oosten's construction of adjoining an oracle to a PCA = adding a new
  data source (smart meter, weather forecast) to a market clearing computation
- Turing degrees = computational hardness of market clearing problems.
  Easy markets are Δ⁰₁ (decidable). Hard markets are Σ⁰₁ (enumerable but not
  decidable). The structure of degrees IS the structure of market difficulty.

### 3. Terwijn: PCAs — Embeddings and Completions

**Key insight**: A PCA (Partial Combinatory Algebra) is the minimal algebraic
structure needed for realizability. Just K and S combinators with partial
application. Completability: can every PCA be extended to a total one?

- Feferman's system: terms with K, S, application. Equality only on closed terms.
- Weak vs strong embeddings between PCAs
- Not all PCAs are completable (Klop's 1980s counterexample)
- Ordered PCAs (introduced by van Oosten) are a richer class
- Isomorphism problem for c.e. PCAs: Σ¹₁ upper bound

**nanoclj-zig resonance**:
- The NaN-boxed value system IS a PCA: K = `(fn [x] (fn [y] x))`,
  S = `(fn [x] (fn [y] (fn [z] ((x z) (y z)))))`, partial application via eval
- `eval.zig` tree-walk = one PCA. `compiler.zig`+`bytecode.zig` VM = another PCA.
  The question "do they compute the same functions?" = PCA embedding question
- `kanren.zig` substitution walk = the application operation of a PCA where
  logic variables are the "programs" and values are the "results"
- Completability question for nanoclj-zig: can every partial computation
  (fuel-bounded eval) be extended to a total one? No — halting problem.
  The fuel system (CONSTITUTION.md Art. II) is exactly the acknowledgment
  that our PCA is not completable.

**Plurigrid resonance**:
- Ordered PCAs ↔ Plurigrid's preference orderings over energy allocations
- PCA embeddings ↔ protocol translations (OCapN, A2A, MCP — the agentic
  protocol research in memory). A simulation between PCAs = a bisimulation
  between protocol implementations.
- `passport.gay` bisimulation oracle: identity claims → trit trajectory → LTS →
  Paige-Tarjan is EXACTLY the PCA isomorphism problem restricted to
  identity-relevant computations

### 4. Van Oosten: "PCAs and Oracles" (Heyting Lecture)

**Key insight**: Hyland's embedding of Turing degrees into Lawvere-Tierney
topologies is order-reversing and far from bijective. The structure of
computability (what can compute what) maps to the structure of modal operators
on the effective topos (what is "forced" to be true).

**Kihara's game-theoretic characterization**: Oracle computation = Merlin-Arthur-Diane
three-player games. Bilayer reducibility is equivalent to the Lawvere-Tierney
topology preorder. This is a GAME SEMANTICS for computability — connecting
directly to open games and the Clairambault Rosetta Stone (Face 13).

**nanoclj-zig resonance**:
- Van Oosten's oracle adjunction to PCAs = the construction Bauer-Hanson used
  for countable reals, and = adding a new builtin to nanoclj-zig's core.zig
  (each new builtin is "adjoining a non-representable function to the PCA")
- Kihara's three-player game ↔ boris-hedges ParaLens 6-wire architecture:
  Merlin = proposer, Arthur = verifier, Diane = environment/oracle.
  The bilayer = the double category structure in boris-hedges.
- Scott's graph model P(ω) = the power set of natural numbers with continuous
  function space. NaN-boxed values with 48-bit payload = a finite approximation
  to P(ω) — each value is a "finite element" in the Scott domain.

**Plurigrid resonance**:
- Lawvere-Tierney topologies = modalities = different "views" of the same
  market. Each participant sees a different subtopos (their local information).
  The topology preorder = information ordering between participants.
- Oracle adjunction = adding a new data source to the market. Van Oosten showed
  this is a systematic categorical construction, not ad hoc.

---

## The Concordance Map

```
Pitts (Heyting algebras)          Bauer (synthetic computability)
        |                                    |
   Ap/Ep = uniform                   CT + MP + IHOL
   interpolation                     = effective topos axioms
        |                                    |
        v                                    v
   kanren.zig                        computable_sets.zig
   fresh = ∃ (Ep)                    Σ⁰₁ = run* search
   == = adjoint                      arithmetical hierarchy
   conde = ∨                         oracle = substrate
        |                                    |
        +----------+   +-------------------+
                   |   |
                   v   v
            CONSTITUTION.md
            GF(3) = 3-element Heyting algebra
            fuel = non-completable PCA
            trit conservation = cobordism invariant
                   |
                   v
        Plurigrid / bmorphism
        energy market = Heyting algebra of constraints
        protocol bisimulation = PCA embedding
        passport.gay = realizability witness
        Weihrauch degree = market clearing difficulty
```

Terwijn (PCAs)                    Van Oosten (realizability)
        |                                    |
   K,S combinators                   tripos → topos
   embeddings                        oracle adjunction
        |                                    |
        v                                    v
   eval.zig = PCA₁                   effective topos =
   bytecode.zig = PCA₂              "everything computable"
   fuel = incompleteness             van Oosten's book =
                                     standard reference

---

## Key Papers (from talks + adjacent)

1. Pitts, "Quantifiers and Sheaves" JSL 57(1992) — Ap/Ep uniform interpolation
2. Férée & van Gool, CPP 2023 — verified algorithms for Ap/Ep
3. Hyland, "The Effective Topos" (1982) — the foundation
4. Van Oosten, *Realizability* (Elsevier 2008) — the textbook
5. Bauer & Hanson, "The Countable Reals" arXiv:2404.01256
6. Swan, "Oracle Modalities" arXiv:2406.05818
7. Ahman & Bauer, "Sheaves as Oracle Computations" arXiv:2602.22135 (FSCD 2026)
8. Maschio & Trotta, "A Topos for Extended Weihrauch Degrees" arXiv:2505.08697
9. Bonchi, Di Giorgio & Trotta, "When Lawvere Meets Peirce" arXiv:2404.18795
10. Forster, "Synthetic Mathematics for Mechanisation" LIPIcs.CSL.2025.3
11. Cohen et al., "From Partial to Monadic: Combinatory Algebra with Effects" FSCD 2025

## Conference Orbit

| Event | Date | Location |
|---|---|---|
| Heyting Day 2025 | 14 Mar 2025 | Amsterdam |
| TYPES 2025 | 9-13 Jun 2025 | Strathclyde |
| CiE 2025 | 14-18 Jul 2025 | Lisbon |
| CCC 2025 | 1-3 Sep 2025 | Swansea |
| miniKanren'25 | 17 Oct 2025 | Singapore |
| CCC 2026 | 27-30 May 2026 | Kyoto |
| FSCD 2026 | 2026 | Lisbon |
| ACT 2026 | 6-10 Jul 2026 | Tallinn |
| CiE 2026 | 27-31 Jul 2026 | Trier |
| miniKanren'26 | TBA | USA |
