# Lazy BDDs with Eager Literal Intersections

**Authors:** Jose Valim
**Source:** https://elixir-lang.org/blog/2026/02/26/eager-literal-intersections/

## Contribution

Describes optimizations to Elixir's set-theoretic type system, which moved from DNFs to lazy BDDs in v1.19. The key insight for v1.20: **eager literal intersections** -- when intersecting two BDDs, compute literal-level intersections immediately rather than lazily. This prunes empty subtrees early, reducing a pathological 10-second type check to 25ms. The optimization is restricted to closed types (where intersections frequently yield empty) to avoid cartesian blowup on open types.

Lazy BDD node structure: `{literal, constrained, uncertain, dual}` semantically = `(a and C) or U or (not a and D)`.

## Relevance to nanoclj-zig

**Direct applicability -- P0.**

- **Type representation for nanoclj-zig:** If nanoclj-zig evolves a type checker (for optimization or gradual typing), lazy BDDs with eager literal intersections are the state-of-the-art representation. The 4-tuple BDD node fits in 4 NaN-boxed words.
- **Interaction nets:** BDD nodes are natural interaction net agents -- each node has 3 auxiliary ports (constrained, uncertain, dual) plus the literal. Intersection becomes an interaction rule between two BDD agents.
- **Parallelism:** The eager/lazy distinction maps to interaction net evaluation strategy: eager literal intersections = active pairs reduced immediately; lazy BDD structure = deferred interactions. This is exactly the annihilation/commutation distinction in interaction nets.
- **GF(3) connection:** The three branches (constrained=+1, uncertain=0, dual=-1) of a BDD node are a natural trit. Empty intersection = annihilation to 0.
- **Practical technique:** Implement BDD-based set operations for nanoclj-zig's collection types, using the open/closed distinction to control eagerness.
