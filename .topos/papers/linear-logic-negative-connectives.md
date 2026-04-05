# Linear Logic Using Negative Connectives

**Authors:** Dale Miller
**Source:** https://doi.org/10.4230/LIPIcs.FSCD.2025.29 (FSCD 2025)

## Contribution

Presents first-order linear logic using only negative connectives (those with invertible right-introduction rules). Proof search alternates between invertible phases (goal-reduction) and non-invertible phases (backchaining), formalized via multifocused proofs. Decomposes linear logic into three sublogics: L0 (intuitionistic), L1 (+linear implication), L2 (classical with multiplicative falsity). Key finding: L2 proofs admit **parallel applications of left-introduction rules**, while L0/L1 proofs cannot.

## Relevance to nanoclj-zig

- **Parallelism via linear logic:** The parallel left-introduction in L2 provides a principled basis for parallel reduction in nanoclj-zig's evaluator. Each parallel rule application = independent interaction net rewrite.
- **Resource tracking:** Linear logic's resource-awareness maps directly to nanclj-zig's fuel system. Each linear resource consumed = one fuel unit. The negative-connective presentation simplifies the implementation: invertible rules need no backtracking, reducing fuel waste.
- **Focusing as evaluation strategy:** The alternating focused/unfocused phases correspond to strict/lazy evaluation phases. nanclj-zig's evaluator could implement call-by-push-value (mentioned in paper via Levy) by switching between focused (eager) and unfocused (lazy) modes.
- **Interaction nets:** Multifocused proofs = parallel interaction net rewrites. The paper's L2 parallelism criterion tells you exactly when two net rewrites are independent and can proceed simultaneously.
