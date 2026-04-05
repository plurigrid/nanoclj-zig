# LatticeHashForest: Efficient Data Structure for Repetitive Data

**Authors:** Anamitra Ghorui, Uday P. Khedker
**Source:** https://arxiv.org/abs/2510.18496

## Contribution

LatticeHashForest (LHF) is a data structure for eliminating redundant computation and duplicate data in compiler/program-analysis contexts. Key properties:

1. **Immediate deduplication:** Unlike hash-consing, ZDDs, or BDDs, LHF modifies elements so they can be deduplicated at construction time.
2. **Nested deduplication:** Elements can be constructed at multiple nesting levels, each level independently deduplicated, cutting nested computation costs.
3. **Lattice-based:** Operations respect lattice ordering (meet/join), enabling efficient fixpoint computation.

Results: Memory usage reduced to "almost negligible fraction" vs. standard implementations. 4x+ speedup for inputs approaching 10M elements. Full C++ implementation provided as artifact.

## Relevance to nanoclj-zig

**Infrastructure -- P1.**

- **Environment deduplication:** nanoclj-zig's `env.zig` uses a parent-chain for lexical environments. LHF could deduplicate environment frames that share the same bindings -- common in recursive/looping code where most of the environment is unchanged between iterations.
- **Interaction net sharing:** Interaction nets produce massive amounts of duplicate substructure (fan nodes copying the same subgraph). LHF's immediate deduplication at construction time would prevent the combinatorial blowup that makes naive interaction net implementations impractical.
- **Hash-consing for S-expressions:** nanoclj-zig's `reader.zig` produces S-expressions that often share structure. LHF generalizes hash-consing with lattice operations, enabling not just structural sharing but also efficient set operations (union/intersection) on shared S-expression sets.
- **GC optimization:** If values are deduplicated via LHF, the GC's mark phase visits fewer unique objects. The nested deduplication means even compound structures (lists of lists) benefit.
- **GF(3) lattice:** GF(3) = {-1, 0, +1} forms a lattice under the ordering -1 < 0 < +1. LHF over this lattice would deduplicate trit vectors efficiently, relevant for the propagator/continuation stack.
- **Concrete technique:** Implement LHF as a Zig generic over the value type (NaN-boxed u64). Use it as the backing store for all heap-allocated collections, getting deduplication for free.
