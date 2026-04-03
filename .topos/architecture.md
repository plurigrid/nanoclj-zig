# nanoclj-zig Architecture

## Layer Stack

```
REPL (main.zig)
  ├── reader.zig        — S-expression parser
  ├── eval.zig          — unbounded eval (legacy)
  ├── transduction.zig  — fuel-bounded operational eval
  │     └── thread_peval.zig — OS-thread parallel (peval ...)
  ├── transclusion.zig  — denotational semantics ⟦·⟧ + Domain type
  ├── transitivity.zig  — structural equality, Resources, GF(3) trits
  ├── printer.zig       — value → string
  └── core.zig          — 35+ builtins registered here

MCP Server (mcp_tool.zig)
  └── JSON-RPC 2.0 over stdio, 6 tools

Interaction Nets
  ├── inet.zig           — Cell/Wire/Net, Lafont γ/δ/ε reduction
  ├── inet_builtins.zig  — REPL API (inet-new, inet-cell, inet-wire, ...)
  └── inet_compile.zig   — Lambda → interaction net (Lamping), readback

Supporting
  ├── value.zig      — NaN-boxed Value (u64), Obj union
  ├── gc.zig         — mark-sweep GC
  ├── env.zig        — lexical scope chain
  ├── compat.zig     — 0.15/0.16 compatibility shims
  ├── tree_vfs.zig   — Forester .tree filesystem
  ├── braid.zig      — Braid-HTTP version sync
  ├── http_fetch.zig — HTTP client builtin
  ├── substrate.zig  — SplitMix64, golden ratio
  ├── color_strip.zig — terminal color rendering
  ├── gay_skills.zig  — depth-fuel cost function
  └── llm.zig        — LLM integration (planned)
```

## Key Invariants

1. **GF(3) conservation**: every layer tracks trit balance. Sum must be 0 mod 3.
2. **Fuel termination**: all eval paths bounded by Resources.fuel. No infinite loops.
3. **Denotational = Operational**: `transitivity.checkSoundness` verifies agreement.
4. **NaN-boxing**: Value is always 8 bytes. No heap allocation for nil/bool/int/float/symbol/keyword/string-ref.

## Test Count: 45

Run with `zig build test --summary all`. Must pass on both 0.15.2 and 0.16-dev.
