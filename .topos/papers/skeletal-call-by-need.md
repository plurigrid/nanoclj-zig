# The Cost of Skeletal Call-by-Need, Smoothly

**Authors:** Beniamino Accattoli, Francesco Magliocca, Loic Peyrot, Claudio Sacerdoti Coen
**Source:** https://arxiv.org/abs/2505.09242 (FSCD 2025)

## Contribution

Skeletal call-by-need ("fully lazy sharing") splits duplicated values into a skeleton (duplicated) and flesh (kept shared). This paper provides:

1. First evidence that skeletal CBN can be **exponentially faster** than standard CBN in both time and space.
2. A proof that skeletal CBN can be implemented with **bi-linear overhead** via an abstract machine using the distillation technique.
3. A smooth reconstruction of Shivers-Wand skeleton recovery, plugged into the abstract machine framework.

## Relevance to nanoclj-zig

**Direct applicability -- P0.**

- **Fuel-bounded eval:** The bi-linear overhead result means nanoclj-zig's fuel counter can accurately bound actual work. Skeletal sharing avoids exponential blowup that would make fuel budgets meaningless.
- **Interaction nets:** Skeletal splitting is the lambda-calculus analog of interaction net sharing nodes. The skeleton/flesh decomposition maps directly to how interaction nets handle duplication via fan nodes -- skeleton = fan structure, flesh = shared principal ports.
- **NaN-boxed values:** The skeleton is a structural template that can be represented as a compact NaN-boxed pointer to a shared flesh region, avoiding deep copies.
- **GF(3) connection:** The three-way split (skeleton / flesh / evaluation context) mirrors trit-valued resource accounting: +1 (duplicate skeleton), 0 (shared flesh), -1 (consumed context).
- **Concrete technique:** Implement Shivers-Wand skeleton markers as a tag bit in the NaN-boxing scheme. During duplication, walk the skeleton mask instead of the full term.
