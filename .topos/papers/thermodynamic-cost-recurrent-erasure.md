# Thermodynamic Cost of Recurrent Erasure

**Source**: Nature Communications Physics, Aug 2025
**URL**: https://www.nature.com/articles/s42005-025-02277-w

## Relevance to nanoclj-zig

The paper analyzes the thermodynamic cost of **repeatedly** erasing and rewriting the same memory cell — exactly what happens at each `res.tick()` in `transduction.zig`.

### Key insight for interaction nets

One-shot Landauer: kT·ln(2) per bit erased.
Recurrent erasure: cost structure depends on the **correlation between successive states**.

For interaction net reduction:
- Each active pair annihilation erases 2 cells → creates new cells
- If the new cells are **uncorrelated** with the old (independent redexes), cost = 2·kT·ln(2)
- If new cells are **correlated** (e.g., DUP creating two copies of same structure), cost < 2·kT·ln(2)

### Connection to GF(3) conservation

- GF(3) operations: kT·ln(3) per trit
- `trit_balance: i8` in `Resources` tracks cumulative entropy
- Conservation (`sum mod 3 = 0`) means the GF(3) substrate is thermodynamically closed
- Reversible GF(3) operations (like `gf3-mul -1 -1 → 1`) have zero net erasure cost

### Connection to d s's "splittable de-turdmanism"

Decomposing computation into independent components (interaction net active pairs)
means each component's erasure cost is independent — no cross-component dissipation.
This is Landauer limit **by construction**: the topology guarantees minimum dissipation.

### For `transduction.zig`

`Resources.tick()` currently burns 1 fuel unit uniformly.
Thermodynamically correct version would cost:
- kT·ln(2) for bit operations (+, -, *, /)
- kT·ln(3) for trit operations (gf3-add, gf3-mul)
- 0 for reversible operations (quote, symbol lookup)
- The fuel budget IS the entropy budget
