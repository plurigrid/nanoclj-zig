{:name "rosetta-decomp"
 :description "Bumpus structured decompositions meets Clairambault's Rosetta Stone. Sheaves on presheaves over interaction nets. Use for compositional algorithm design on decomposed data."
 :trit 0}
---

# Rosetta Decompositions

## When to use
Use this skill when designing algorithms that exploit graph decomposition structure,
need sheaf-theoretic correctness guarantees, or want to bridge game semantics / GoI /
quantitative semantics on decomposed data.

## The Bumpus-Clairambault Bridge

Structured decomposition (Bumpus) = presheaf F: T^op → C.
Interactive semantics (Clairambault) = GoI on the colimit of F.
Deciding sheaves = checking whether local game strategies glue globally.

## Clairambault's Rosetta Stone
\transclude{rosetta-stone-interactive-quantitative-semantics}

## Categorical Foundations
\transclude{thy-0001}

## BCI Cofunctors (control as decomposition)
\transclude{bci-0003}

## GF(3) Conservation Analysis
\transclude{gf3-conservation}

## Builtins

### Decomposition (backed by inet)
- `(decompose graph)` — tree decomposition as inet of γ-bags
- `(decomp-bags net-id)` — extract bag payloads
- `(decomp-width net-id)` — treewidth
- `(decomp-adhesions net-id)` — shared vertices between adjacent bags
- `(decomp-glue net-id)` — colimit via inet reduction
- `(decomp-map f net-id)` — functorial lift
- `(decomp-decide sheaf net-id)` — sheaf section existence
- `(decomp-skeleton net-id)` — tree shape only

### Sheaves
- `(sheaf stalk-fn glue-fn)` — constructor
- `(section sheaf open-set)` — evaluate stalk
- `(restrict section subset)` — restrict to subset
- `(extend-section sheaf sections covering)` — glue locally to globally
