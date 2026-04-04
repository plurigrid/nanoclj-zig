# Cognitive Constitution of nanoclj-zig

## Preamble

This document constitutes the invariants, principles, and boundaries
that govern nanoclj-zig as a cognitive system. It is not a software
engineering style guide -- it is the substrate's self-description of
what it will and will not do, what it conserves, and how it knows.

---

## Article I. Conservation

**GF(3) is the only currency.**

Every computation produces a trit in {-1, 0, +1}. The sum across any
closed composition MUST be 0 mod 3. This is not a convention -- it is
the cobordism invariant that makes the system a system rather than a
collection of parts.

- `transitivity.zig` checks post-hoc (Level 0).
- `inet.zig` enforces by construction (Level 4+): annihilation preserves
  trit sum, commutation is trit-neutral, erasure costs exactly kT*ln(2).
- `gorj_bridge.zig` tracks `trit_accumulator` across all eval calls.

Violation of GF(3) conservation is a semantic error, not a runtime error.
The system may produce a result, but that result has no meaning.

## Article II. Termination

**Every eval path is fuel-bounded.**

`Resources.fuel` is a monotonically decreasing counter. When it reaches
zero, evaluation returns `Domain.bottom(.fuel_exhausted)`. There are no
infinite loops, no unbounded recursions, no halting problem.

- `semantics.zig` and `transduction.zig` enforce this for tree-walking.
- `bytecode.zig` VM enforces this for compiled code (100M fuel default).
- `thread_peval.zig` forks fuel across OS threads; join conserves total.

The fuel budget is the system's attention span. It is finite by design.

## Article III. Agreement

**Denotational = Operational.**

`transclusion.zig` defines the denotational semantics: ⟦expr⟧ → Domain.
`transduction.zig` defines the operational semantics: evalBounded → Domain.
`transitivity.zig` provides `checkSoundness` to verify they agree.

If they disagree, the denotational semantics is authoritative. The
operational evaluator is an optimization that MUST NOT change meaning.

The bytecode compiler (`compiler.zig` + `bytecode.zig`) is a third path.
It MUST agree with both. The `(bench ...)` REPL command exists to verify
this by comparing tree-walk and bytecode results on the same expression.

## Article IV. Representation

**Value is 8 bytes. Always.**

NaN-boxing (`value.zig`): nil, bool, int (48-bit), float (64-bit),
symbol, keyword, and string-ref all fit in a single u64. No heap
allocation for these types. Objects (list, vector, map, set, function,
closure, atom, partial, lazy-seq, bc_closure, builtin_ref) are
heap-allocated and GC-managed.

This constraint is non-negotiable. It determines cache behavior,
register allocation strategy, and the interaction net cell size.

## Article V. Self-Hosting

**The system evaluates its own tool definitions.**

`gorj_mcp.zig` defines MCP tool handlers as nanoclj `(fn* ...)` forms
evaluated at startup. The Zig layer is ONLY the JSON-RPC transport.
All tool logic -- dispatch table, argument parsing, result formatting --
lives in the language the server serves.

This is the closure property: the system can describe and modify its
own behavior without leaving its own language.

## Article VI. Compression

**The Solomonoff gradient is the development roadmap.**

Each level of the EXPANDER reduces K(eval) and reveals parallelism:

| Level | K(eval) | Parallelism | Mechanism |
|-------|---------|-------------|-----------|
| 0 | ~900 | 0% | Tree-walking eval |
| 1 | ~820 | 30% | Fuel fork/join |
| 2 | ~850 | 45% | let* DAG analysis |
| 3 | ~700 | 55% | def topological sort |
| 4 | ~200 | 80% | Interaction net cells |
| 5 | ~220 | 92% | Superposition (sigma) |
| 6 | ~150 | 95% | Optimal reduction |

At Level 6, K(eval) = K(language). The evaluator IS the shortest
program. What remains sequential is the irreducible complexity of
Clojure-the-language.

MORE parallel = LESS fuel per step = CLOSER to Landauer limit =
SHORTER program = MORE compressed.

## Article VII. Perception

**Color is identity.**

Every value, every computation, every network node has a deterministic
Gay color derived from SplitMix64. The color is not decoration -- it
is the perceptual hash of the object's identity.

- `substrate.zig`: golden angle spiral HSV generation.
- `color_strip.zig`: terminal rendering of identity strips.
- `gay_skills.zig`: depth-fuel cost function indexed by color.

The color of a composition is determined by the colors of its parts.
This makes the system's state visually inspectable at every scale.

## Article VIII. Openness

**Capability is the only access control.**

The system follows OCapN (Object Capability Network) principles:

- `syrup_bridge.zig`: Syrup serialization for the wire.
- `gorj_bridge.zig`: Braid versioning for causal ordering.
- `mcp_tool.zig` / `gorj_mcp.zig`: MCP protocol for tool exposure.

No global authority decides who can call what. If you have a reference
to a capability, you can invoke it. If you don't, you can't. The
reference IS the permission.

## Article IX. Multiplicity

**Three paths to the same answer.**

For any expression, there exist (at least) three evaluation strategies:

1. **Tree-walking** (`eval.zig` / `transduction.zig`): interpretive, debuggable.
2. **Bytecode** (`compiler.zig` + `bytecode.zig`): compiled, fast.
3. **Interaction nets** (`inet.zig` + `inet_compile.zig`): optimal, parallel.

All three MUST agree on the result for any well-formed input. The
choice between them is a resource allocation decision, not a semantic one.

## Article X. Boundary

**20,526 lines of Zig is the entire cognitive substrate.**

There is no hidden runtime. No JVM. No LLVM. No libc beyond what Zig's
std provides. The system compiles to a single static binary per target.

The boundary of the system IS the boundary of the binary. Everything
inside is introspectable. Everything outside is accessed through
capabilities (HTTP, Syrup, MCP, stdio).

---

## Governance

This constitution is versioned alongside the source code in
`.topos/CONSTITUTION.md`. Amendments require:

1. A demonstration that the invariant still holds after the change.
2. A test in the test suite that would fail if the principle is violated.
3. A commit message referencing the article number.

**Version**: 1.0.0 | **Ratified**: 2026-04-03
