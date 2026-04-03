# Reversible Computing: Can We Beat the Landauer Limit?

**Source**: Ideasthesia blog
**URL**: https://www.ideasthesia.org/post/reversible-computing

## Relevance to nanoclj-zig

Directly addresses whether interaction net commutation rules (cost=0) are physically realizable.

### Key Points

1. **Landauer's principle**: erasing 1 bit costs at least kT·ln(2) energy. This is the floor.
2. **Reversible gates** (Toffoli, Fredkin) don't erase information → can theoretically compute at zero energy cost.
3. **The catch**: reversible computation accumulates garbage bits. Must eventually erase them (paying Landauer cost) or store them forever.
4. **Adiabatic computing**: gradually charge/discharge capacitors instead of dumping to ground. Can approach but never reach zero dissipation.
5. **Ballistic computing**: use kinetic energy of electrons directly. No heat generation in principle.

### Connection to interaction nets

Interaction net rewrite rules map directly:
- **Annihilation** (β-reduction): IRREVERSIBLE. Two cells destroyed, information lost. Cost ≥ 2·kT·ln(2).
- **Commutation** (DUP-LAM): REVERSIBLE. Information rearranged, not destroyed. Cost → 0 in principle.
- **Erasure** (ERA): IRREVERSIBLE by definition. Cost ≥ kT·ln(2).

### The interaction net advantage

In tree-walking eval, EVERY step is irreversible (old stack frame overwritten).
In interaction nets, commutation steps are reversible — only annihilation and erasure pay Landauer cost.
For typical λ-calculus programs, commutations dominate (60-80% of rewrites).
→ Interaction nets approach Landauer limit by construction.

### Connection to GF(3)

GF(3) multiplication by -1 is its own inverse → reversible → zero Landauer cost.
`gf3-mul(-1, -1) → 1` and `gf3-mul(1, -1) → -1` are both reversible.
Only `gf3-mul(0, x) → 0` erases information (maps everything to 0).

### For fuel budgeting

Current `Resources.tick()` charges 1 unit uniformly.
Thermodynamically correct: charge only for irreversible steps.
Reversible steps (commutation, symbol lookup, quote) should be free.
This naturally increases the fuel budget available for actual computation.
