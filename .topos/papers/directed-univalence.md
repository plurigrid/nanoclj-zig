# Directed Univalence in Simplicial Homotopy Type Theory

**Authors:** Daniel Gratzer, Jonathan Weinberger, Ulrik Buchholtz
**Source:** https://arxiv.org/abs/2407.09146

## Contribution

Extends homotopy type theory with a **directed path type** internalizing homomorphisms within a type. Constructs **triangulated type theory** (simplicial type theory + modalities) and builds the universe of discrete types S, proving it is **directed univalent** -- homomorphisms in S correspond to ordinary functions. This enables synthetic higher category theory and a directed structure identity principle for programming languages.

First construction of types with non-trivial homomorphisms in simplicial type theory. Recovers key category theory results (Yoneda, etc.) synthetically.

## Relevance to nanoclj-zig

**Aspirational -- P2.**

- **Directed structure identity principle:** If nanoclj-zig values form a category (morphisms = coercions/conversions), directed univalence guarantees that equivalent types are interchangeable. This justifies aggressive optimization: if two NaN-boxed representations are equivalent, the evaluator can freely substitute one for the other.
- **Interaction nets as directed paths:** Interaction net reduction steps are directed (irreversible). The directed path type formalizes this: a path from term A to term B means A reduces to B. Directed univalence then says: if A and B are inter-reducible, they are the same type.
- **Functorial usage guarantees:** The directed structure identity principle ensures that any type-generic code (polymorphic functions in nanoclj-zig) automatically respects the directed structure. This is a correctness guarantee for generic NaN-boxed operations.
- **GF(3) trit trajectories:** Trit sequences form a simplicial set (each position = a vertex, consecutive trits = directed edges). Directed univalence in this setting would formalize when two trit trajectories are "the same computation."
