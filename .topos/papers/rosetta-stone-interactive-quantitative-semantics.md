# A Rosetta Stone of Interactive and Quantitative Semantics

**Authors**: Pierre Clairambault (CNRS/ENS Lyon)
**Venue**: CSL 2026 (invited paper)
**URL**: https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.CSL.2026.2

## Relevance to nanoclj-zig

THE unifying paper for the .topos/ cobordism. Connects all 14 faces.

### Key Thesis

Three major semantic frameworks for programming languages are secretly the same thing viewed from different angles:

1. **Game Semantics** — programs as strategies in a two-player game
2. **Geometry of Interaction (GoI)** — programs as token-passing automata on graphs
3. **Quantitative/Relational Semantics** — programs as weighted relations (linear algebra)

### The Rosetta Stone

| Concept | Game Semantics | GoI | Quantitative |
|---------|---------------|-----|-------------|
| Program | Strategy | Execution graph | Weighted relation |
| Composition | Interaction + hiding | Path composition | Matrix multiplication |
| Types | Arenas | Interfaces | Objects |
| Linear logic | Tensor = parallel | Tensor = parallel wires | Tensor = Kronecker product |

### Connection to interaction nets (Level 4-6)

Interaction nets ARE the GoI column made computational:
- Each cell = a node in the execution graph
- Each rewrite rule = a step of token passing
- Optimal reduction = following the GoI token through the graph

### Connection to GF(3)

Quantitative semantics uses weighted relations over a semiring.
GF(3) = the semiring {-1, 0, 1} with mod-3 arithmetic.
`trit_balance` conservation = the trace of the quantitative interpretation is preserved.

### Connection to thin concurrent games

Clairambault's own "thin concurrent games" (Face 13) are the game-semantic column
restricted to the concurrent fragment — exactly what interaction nets compute.
Thin = no unnecessary causal dependencies = maximal parallelism.

### For the Solomonoff gradient

The Rosetta Stone says: compressing the evaluator (GoI column) automatically
discovers parallelism (game column) and gives exact cost models (quantitative column).
K(eval) decrease = parallelism increase = cost precision increase. All three move together.
