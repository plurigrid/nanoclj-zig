# IMELL Cut Elimination with Linear Overhead

**Authors:** Beniamino Accattoli, Claudio Sacerdoti Coen
**Source:** https://arxiv.org/abs/2405.03669 (FSCD 2024)

## Contribution

Introduces an abstract machine for the Exponential Substitution Calculus (ESC) -- untyped proof terms for Intuitionistic Multiplicative Exponential Linear Logic (IMELL). The "good strategy" for cut elimination achieves polynomial overhead (Accattoli's prior result); this paper refines it to **linear overhead** via the abstract machine.

The ESC uses rewriting rules at-a-distance for cut elimination. The abstract machine implements the good strategy (a specific scheduling of cuts) and computes cut-free proofs within O(n) overhead of the number of cut-elimination steps.

## Relevance to nanoclj-zig

**Direct applicability -- P0.**

- **Abstract machine design:** This is literally a blueprint for nanoclj-zig's evaluator. The ESC abstract machine maps directly to a Zig implementation: states are NaN-boxed values, transitions are pattern matches on type tags, and the linear overhead guarantee means the machine's step count is a faithful cost model.
- **Interaction nets:** ESC cut elimination IS interaction net reduction for the IMELL fragment. Each cut = active pair. The "good strategy" = optimal scheduling of active pair reductions. The linear overhead = interaction net evaluation with at most O(n) bookkeeping per net reduction step.
- **Fuel-bounded eval:** Linear overhead means fuel = actual work (up to a constant). This is the strongest possible guarantee for a fuel-based resource limiter. Set fuel = k, get at most O(k) real machine steps.
- **Exponential modality = sharing:** The ! modality in IMELL corresponds to sharing/duplication in the evaluator. The ESC's at-a-distance rules handle this without copying, which maps to nanoclj-zig's GC-managed shared heap.
- **Concrete technique:** Implement the good strategy as a priority queue of pending cuts, ordered by the ESC's scheduling discipline. Each NaN-boxed value carries its cut-priority as part of the tag.
