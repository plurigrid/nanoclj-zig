# nanoclj-zig .topos/ — Expander Structure Index

## Cobordism: NaN-boxed Clojure interpreter → maximally parallel via Solomonoff compression

15 faces, 160 artifacts. Universal joint: Clairambault's "Rosetta Stone of Interactive & Quantitative Semantics" (CSL 2026).

Solomonoff gradient: K(eval)≈800 LOC → K≈150 LOC, parallelism 0%→95%.
Thermodynamic floor: kT·ln(3) per trit, kT·ln(2) per bit (Landauer).

---

## Skill Maps (`.topos/`)

- `SKILL_MAP.md` — runtime builtin/skill topology mapped to expander faces, levels, and communities served.

---

## Repos (`.topos/repos/`)

| Repo | Face | Signal |
|------|------|--------|
| `deltanets/` | 1: Interaction Nets | Δ-Nets optimal parallel λ-reduction (TypeScript) |
| `optiscope/` | 1: Interaction Nets | Lévy-optimal reducer with C backdoor |
| `interaction-net-resources/` | 1: Interaction Nets | Curated reading list (48★) |
| `strong-reduction-tests/` | 1: Interaction Nets | ~3500 tests for strong β-reduction |
| `Ternary-NanoCore/` | 5: GF(3)/Trit | FPGA ternary NN accelerator (Artix-7) |
| `lambda-RLM/` | 2: Solomonoff | RL on lambda calculus for long context |
| `supertensor_lean/` | 8: Optimal Sharing | Verified tensor graph optimization (Lean 4) |
| `ringmpsc/` | 9: Zig Parallel | Lock-free MPSC, 180B+ msg/sec |
| `optisat/` | 8: Optimal Sharing | Equality saturation in Lean 4, 248 theorems |

## Papers (`.topos/papers/`)

### Face 1: Interaction Nets & Optimal Reduction
- `hitrees-higher-order-interaction-trees.md` — Fadaei Ayyam & Sammler (ISTA/Sharif)
- `generic-reduction-based-interpreters.md` — arxiv 2508.11297

### Face 2: Solomonoff / MDL / Program Synthesis
- `deep-learning-as-program-synthesis.md` — Furman (LessWrong 2026)
- `arc-agi-2025-research-review.md` — lewish.io
- `alternative-trajectory-generative-ai.md` — Princeton (arxiv 2603.14147)

### Face 3: NaN-Boxing & Packed Values
- `nanval-rust-nan-boxing.md` — docs.rs/nanval

### Face 5: GF(3) / Ternary Hardware
- `transcending-forbidden-ternary-logic.md` — Fellouri & Adjailia (HAL)

### Face 6: Fuel-Bounded / Resource-Aware Semantics
- `gas-fueled-languages-challenges.md` — Zhirkov (rubber-duck-typing)
- `resource-bounded-type-theory-graded-modalities.md` — arxiv 2512.06952
- `entropy-programming-language-resource-aware-lambda.md` — λᴿᴬ (Academia)
- `proof-carrying-skills-gas-metered.md` — Gas-metered predicates (Academia)
- `soteria-symbolic-execution.md` — Ayoun et al. (Imperial)
- `securing-mcp-adversarial-attacks.md` — Jamshidi et al. (Polytechnique Montréal)
- `chopchop-constrained-lm-output.md` — UCSD

### Face 7: Cobordism / TQFT / HoTT
- `directed-univalence-simplicial-hott.md` — Gratzer, Weinberger, Buchholtz
- `semantics-to-syntax-comprehension-categories.md` — Najmaei et al.
- `effective-kan-fibrations-w-types.md` — Dagstuhl TYPES 2024
- `fqh-anyons-algebraic-topology.md` — Sati & Schreiber (nLab)

### Face 8: Optimal Sharing & Lazy Evaluation
- `cost-of-skeletal-call-by-need.md` — Accattoli et al. (FSCD 2025)
- `elixir-lazy-bdds-eager-intersections.md` — Valim (Elixir 2026)
- `elixir-lazier-bdds-set-theoretic-types.md` — Valim (Elixir 2025)
- `lattice-hash-forest-repetitive-data.md` — Ghorui (arxiv 2510.18496)

### Face 9: Zig Parallel Runtime
- (ringmpsc repo; Zig async plan articles not scraped — lobste.rs duplicates)

### Face 10: Denotational-Operational Agreement
- `mechanising-bohm-trees-lambda-eta.md` — Tian & Norrish (ITP 2025)
- `barendregt-lambda-calculus-formalized.md` — Lancelot, Accattoli (ITP 2025)
- `compositional-soundness-abstract-interpreters.md` — Keidel et al.
- `denotational-semantics-gradual-typing-guarded.md` — Giovannini et al.
- `formal-semantics-program-logics-ocaml.md` — Seassau et al. (INRIA)
- `mpi-sws-semantics-type-systems-lecture-notes.md` — Dreyer et al.
- `lazy-concurrent-convertibility-checker.md` — Courant & Leroy (INRIA)
- `imell-cut-elimination-linear-overhead.md` — Accattoli & Sacerdoti Coen
- `semantic-bounds-multi-types.md` — Accattoli (INRIA)

### Face 11: Linear Logic & Proof Nets
- `linear-logic-negative-connectives.md` — Miller (FSCD 2025)
- `modal-mu-calculus-linear-logic-rescue.md` — Bauer & Saurin
- `uniform-cut-elimination-linear-logics-fixed-points.md` — arxiv 2506.14327
- `yeo-theorem-sequentialization-linear-logic.md` — Di Guardia et al.
- `curry-howard-linear-reversible-computation.md` — LMCS

### Face 12: Thermodynamic Computing
- `thermodynamic-constraints-dram-landauer.md` — arxiv 2505.23087
- `minimally-dissipative-multi-bit-operations.md` — arxiv 2506.24021
- `reversible-computing-beat-landauer.md` — Ideasthesia
- `gas-fueled-languages-compiler-correctness.md` — Zhirkov
- `thermodynamic-cost-recurrent-erasure.md` — Nature Comms Physics 2025. **KEY**: recurrent erasure cost depends on inter-step correlation; interaction nets minimize this by construction

### Face 13: Categorical Semantics of Interaction
- `rosetta-stone-interactive-quantitative-semantics.md` — Clairambault (CSL 2026)
- `categorical-continuation-semantics-concurrency.md` — Breuvart (FSCD 2025)
- `thin-concurrent-games-generalized-species.md` — Clairambault et al.
- `abstract-certified-operational-game-semantics.md` — Springer

### Face 14: Self-Reference & Fixed Points
- (covered by edge-cases.clj sections 15-16: quine, Y-combinator, self)

### Face 15: Realizability & Synthetic Computability (Heyting Day 2025)
- `heyting-day-2025/CONCORDANCE.md` — full concordance with nanoclj-zig/bmorphism/Plurigrid
- `heyting-day-2025/pitts-transcript.txt` — Pitts: Heyting Algebras and Higher-Order Logic (11,657 words)
- `heyting-day-2025/bauer-transcript.txt` — Bauer: Turing Degrees in Synthetic Computability (10,715 words)
- `heyting-day-2025/terwijn-transcript.txt` — Terwijn: Embeddings and Completions in PCAs (1,876 words)
- `heyting-day-2025/pitts-slides.txt` — Pitts slides (41 pages, extracted)
- `heyting-day-2025/naw-report.txt` — Nieuw Archief voor Wiskunde report (3 pages)
- **Open question**: ∀H, ∃? E with H ≅ E(1,Ω) — is every Heyting algebra a topos truth algebra?
- **Concordance**: kanren.zig = hyperdoctrine (fresh=∃, ==adjoint, conde=∨), computable_sets.zig = arithmetical hierarchy in eff. topos, GF(3) = 3-element Heyting algebra, fuel = non-completable PCA

---

## Key People (Accattoli Cluster)
- **Beniamino Accattoli** (INRIA/LIX): appears in faces 1,8,10,11. The bridge between linear logic cost models and optimal reduction.
- **Pierre Clairambault** (CNRS/ENS Lyon): face 13. The Rosetta Stone unifying GoI, games, quantitative semantics.
- **Dale Miller** (INRIA): face 11. Linear logic negative connectives = parallel rule application.
- **Xavier Leroy** (INRIA/Collège de France): face 10. Lazy concurrent convertibility = parallel β-equivalence.

## Key People (Realizability Cluster — Face 15)
- **Andrej Bauer** (Ljubljana): synthetic computability, effective topos, countable reals. Oracle modalities = substrate comparison.
- **Andrew Pitts** (Cambridge): triposes, uniform interpolation Ap/Ep, Heyting algebra open question.
- **Jaap van Oosten** (Utrecht, ret.): *Realizability* textbook, oracle adjunction to PCAs, categorical realizability.
- **Sebastiaan Terwijn** (Radboud): PCA embeddings/completions, computable model theory.
- **Andrew Swan** (various): oracle modalities in HoTT, Turing degrees as subtoposes.
- **Yannick Forster** (mechanized synthetic computability in Coq, CSL 2025).

## Action Items (by compression level)
1. **Level 1** (fuel fork/join): Use ringmpsc for lock-free dispatch. Graded comonad from arxiv 2512.06952 for static fuel partitioning.
2. **Level 2** (let* DAG): Elixir lazy BDD technique for dependency analysis.
3. **Level 3** (def topo-sort): LatticeHashForest for memoized eval.
4. **Level 4** (interaction nets): Port deltanets 6-cell model to Zig. Use optiscope as reference. Validate with strong-reduction-tests.
5. **Level 5** (superposition): Miller's negative connectives Section 3 for parallel branching.
6. **Level 6** (optimal): Accattoli's IMELL linear overhead + Yeo's sequentialization = exact parallelism bound.
