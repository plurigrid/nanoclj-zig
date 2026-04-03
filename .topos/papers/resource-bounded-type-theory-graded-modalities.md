# Resource-Bounded Type Theory: Compositional Cost Analysis via Graded Modalities

**arXiv:2512.06952** (cs.LO)

**Authors:** Mirco A. Mannucci, Corey Thuro

**Submitted:** 2025-12-07

[View PDF](https://arxiv.org/pdf/2512.06952) | [HTML](https://arxiv.org/html/2512.06952v1) | [TeX Source](https://arxiv.org/src/2512.06952)

## Abstract

We present a compositional framework for certifying resource bounds in typed programs. Terms are typed with synthesized bounds drawn from an abstract resource lattice, enabling uniform treatment of time, memory, gas, and domain-specific costs.

We introduce a graded feasibility modality with co-unit and monotonicity laws. Our main result is a syntactic cost soundness theorem for the recursion-free simply-typed fragment: if a closed term has synthesized bound b under a given budget, its operational cost is bounded by b. We provide a syntactic term model in the topos of presheaves over the lattice -- where resource bounds index a cost-stratified family of definable values -- with cost extraction as a natural transformation. We prove canonical forms via reification and establish initiality of the syntactic model: it embeds uniquely into all resource-bounded models.

A case study demonstrates compositional reasoning for binary search using Lean's native recursion with separate bound proofs.

| | |
|---|---|
| Comments | 20 pages, 2 figures |
| Subjects | Logic in Computer Science (cs.LO); Computational Engineering, Finance, and Science (cs.CE); Logic (math.LO) |
| Cite as | [arXiv:2512.06952](https://arxiv.org/abs/2512.06952) [cs.LO] |
