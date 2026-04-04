# nanoclj-zig .topos/ — Skill Topology Map

## Scope

This map grounds runtime skills in current source code and ties them to the 14-face expander model.

Source of truth for exposed REPL builtins: `src/core.zig` (`initCore` builtin table).

Verification snapshot (current tree):
- Exposed builtins in `src/core.zig`: **84**
- Non-builtin special forms in evaluator: `quote`, `def`, `let*`, `if`, `do`, `fn*`, `peval`
- Cross-version shim present: `src/compat.zig` (Zig 0.15 ↔ 0.16 support)

---

## Skill Clusters → Faces

## 1) Core language skills (execution substrate)

| Cluster | Builtins | Implementation | Faces |
|---|---|---|---|
| Arithmetic + comparison | `+ - * / = < > <= >= mod` | `src/core.zig` | 10 (denotational-operational agreement) |
| Collections + access | `list vector hash-map first rest cons count nth get assoc conj` | `src/core.zig` | 10 |
| Predicates + utility | `nil? number? string? keyword? symbol? list? vector? map? fn? not apply` | `src/core.zig` | 10 |
| Reader/Printer loop | `read-string pr-str str println subs` | `src/core.zig`, `src/reader.zig`, `src/printer.zig` | 10 |

## 2) Fuel/semantic safety skills

| Skill | Interface | Implementation | Faces |
|---|---|---|---|
| Fuel-bounded evaluation | internal `evalBounded` | `src/transduction.zig`, `src/transitivity.zig` | 6, 10 |
| Fuel fork/join budget split | internal `Resources.fork/join` | `src/transitivity.zig` | 6, 12 |
| Parallel-eval form (stage-1) | `peval` (special form) | `src/transduction.zig` | 6, 9 |
| Soundness check | internal `checkSoundness` | `src/transitivity.zig` | 10 |

## 3) Color/GF(3)/world/BCI skill stack (17-skill axis)

| Skill family | Builtins | Implementation | Faces |
|---|---|---|---|
| SplitMix + color identity | `mix64 color-at color-seed colors hue-to-trit color-hex color-trit depth-color` | `src/substrate.zig`, `src/gay_skills.zig`, `src/color_strip.zig` | 5, 12 |
| GF(3) algebra + conservation | `gf3-add gf3-mul gf3-conserved? trit-balance` | `src/substrate.zig`, `src/transitivity.zig` | 5, 12 |
| Tropical/propagator algebra | `tropical-add tropical-mul propagate` | `src/gay_skills.zig` | 8, 11 |
| World stepping + bisimulation | `world-create world-step bisim? entropy xor-fingerprint` | `src/gay_skills.zig`, `src/substrate.zig` | 8, 10, 14 |
| BCI synthetic channels | `bci-channels bci-read bci-trit bci-entropy` | `src/substrate.zig` | 6, 9 |

## 4) Tree/forest transclusion skills

| Builtins | Implementation | Faces | Purpose |
|---|---|---|---|
| `tree-read tree-title tree-transcluded tree-transcluders tree-ids tree-isolated tree-chain` | `src/tree_vfs.zig` | 7, 13 | Content graph introspection + transclusion topology |

## 5) Interaction-net skills

| Builtins | Implementation | Faces | Purpose |
|---|---|---|---|
| `inet-new inet-cell inet-wire inet-reduce inet-live inet-pairs inet-trit inet-from-forest inet-dot` | `src/inet_builtins.zig`, `src/inet.zig` | 1, 5, 13 | Net construction, reduction, GF(3) monitoring, graph export |
| `inet-compile inet-readback inet-eval` | `src/inet_compile.zig` | 1, 8, 10 | Compile/readback bridge from Lisp values to nets |

## 6) Runtime integration skills

| Surface | Entry | Faces |
|---|---|---|
| MCP tool server | `src/mcp_tool.zig` | 6, 9, 13 |
| nREPL bridge | `nrepl-start` (`src/substrate.zig`) | 9 |
| HTTP fetch builtin | `http-fetch` (`src/http_fetch.zig`) | 9 |
| Braid sync + CRDT | `src/braid.zig` | 9, 13 |
| VCV bridge | `src/vcv_bridge.zig` | 9 |

## 7) Compatibility skills (toolchain continuity)

| Capability | Implementation | Faces | Purpose |
|---|---|---|---|
| ArrayList compatibility | `compat.emptyList(T)` | 9 | Smooth 0.15/0.16 container init differences |
| Mutex compatibility | `compat.Mutex` | 9 | Unified lock API across stdlib mutex changes |

---

## Skill-to-Community Routing (current)

| Community served | Best skill clusters |
|---|---|
| Clojure learners | Core language skills, reader/printer, bounded eval |
| Zig systems devs | NaN-boxing + GC + resource semantics + runtime integration |
| Semantics researchers | Denotational/operational/transitivity layers + soundness + interaction nets |
| Creative coding/media | Color/GF(3)/world/entropy stack + strip/world demos |
| Agent tooling users | MCP + nREPL + tree/inet graph operations |

---

## Compression-Level Fit (EXPANDER alignment)

| Level | Skill status in code |
|---|---|
| Level 1 (fuel fork/join) | Present (`fork/join`, `peval`) with sequential execution semantics |
| Level 2 (`let*` DAG) | Not implemented |
| Level 3 (`def` topo-sort/file DAG) | Not implemented |
| Level 4 (interaction-net core path) | In progress via `inet*` builtins and net runtime |
| Level 5 (superposition branching) | Not implemented |
| Level 6 (Lévy-optimal) | Not implemented |
