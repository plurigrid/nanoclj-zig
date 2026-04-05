# Linear Logic Using Negative Connectives

**Authors:** Dale Miller
**Source:** https://doi.org/10.4230/LIPIcs.FSCD.2025.29 (FSCD 2025)

## Contribution

Reformulates first-order linear logic using only negative (invertible right-introduction) connectives. Proof search alternates between invertible phases (goal-reduction) and non-invertible phases (backchaining), formalized via **multifocused proofs**. The logic decomposes into three sublogics:

- **L0:** Intuitionistic logic (conjunction, implication, universal quantification)
- **L1:** L0 + linear implication (still intuitionistic)
- **L2:** L1 + multiplicative falsity (full classical linear logic)

Key finding: L2 multifocused proofs support **parallel left-introduction rule applications**, while L0/L1 proofs cannot. This parallelism enables a novel treatment of disjunction and existential quantifiers in natural deduction.

## Relevance to nanoclj-zig

**Foundational -- P1.**

- **Parallelism from logic:** The L2 parallel left-introduction result provides a logical foundation for which evaluation steps in nanoclj-zig can safely proceed in parallel. If the evaluator's resource management is linear (each value consumed exactly once), the multifocused framework tells you exactly where parallel reduction is sound.
- **Interaction nets:** Multifocused proofs are the proof-theoretic counterpart of interaction nets with multiple active pairs. Each focus = one active pair being reduced. L2 parallelism = multiple active pairs reduced simultaneously.
- **Fuel-bounded eval:** The invertible/non-invertible phase distinction maps to deterministic (no fuel cost) vs. non-deterministic (fuel-consuming) evaluation steps. Invertible steps are free; only backchaining burns fuel.
- **Linear resource tracking:** Linear implication (L1) is exactly the discipline needed for safe memory management in a NaN-boxed interpreter without a tracing GC -- each value is used exactly once, with explicit duplication via the exponential modality.
