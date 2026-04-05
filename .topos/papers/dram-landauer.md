# Thermodynamic Constraints in DRAM Cells

**Authors:** Takase Shimizu, Kensaku Chida, Gento Yamahata, Katsuhiko Nishiguchi
**Source:** https://arxiv.org/abs/2505.23087 (Phys. Rev. Lett. 136, 117103, 2026)

## Contribution

Experimentally measures energy efficiency of information erasure in silicon DRAM cells at single-electron resolution. Key finding: **DRAM cannot reach the Landauer limit** (kT ln 2 per bit erased) even with effectively infinite erasure time. The fundamental constraint: inability to prepare the initial state in thermal equilibrium prohibits quasistatic operations. This is structural -- it applies to all electronic circuits sharing DRAM's capacitor-based architecture.

## Relevance to nanoclj-zig

**Physical grounding -- P2.**

- **Fuel model physics:** nanoclj-zig's fuel-bounded evaluation is an abstraction of physical energy cost. This paper shows the actual lower bound per bit operation is strictly above Landauer's limit for real hardware. The practical minimum is set by the non-equilibrium constraint, not the thermodynamic ideal.
- **GC energy cost:** Every mark-and-sweep GC cycle erases information (dead objects). This paper quantifies the minimum energy per erasure. For nanoclj-zig's mark-and-sweep GC, each collected NaN-boxed value costs at least the DRAM constraint (not just Landauer) to erase.
- **NaN-boxing and bit erasure:** NaN-boxing reuses the same 64-bit word for different types by overwriting tag bits. Each tag change is a bit erasure event subject to these thermodynamic constraints. The 7 type tags in nanoclj-zig's value.zig mean frequent tag transitions.
- **Interaction net connection:** Interaction net annihilation (two agents consuming each other) erases information. The DRAM result sets a floor on how cheap annihilation can be in hardware. This matters for energy-aware scheduling of interaction net reductions.
- **Concrete implication:** When estimating wall-clock cost of fuel units, use the DRAM constraint (~100x Landauer at room temperature) rather than the Landauer limit as the per-operation energy floor.
