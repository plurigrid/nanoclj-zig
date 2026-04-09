# Embedded Profile Plan for nanoclj-zig

## Goal

`nanoclj-zig` should not try to beat `nanoclj` in C on absolute tiny-footprint minimalism.
It should beat it on embedded safety, deployment, and controllability.

That means:

- deterministic termination for untrusted code
- explicit resource budgets
- cross-compilation to WASM, ARM, and RISC-V from one build graph
- static binaries with small, profile-driven surfaces
- a host API that is easy to embed and reason about

## Competitive frame

### C nanoclj still wins on

- smallest binary
- easiest C ABI
- simplest embedding story for trusted scripts

### nanoclj-zig should win on

- bounded evaluation
- deterministic failure modes
- compile-time feature selection
- portable static deployment
- safer host integration for untrusted code

## Wider runtime pattern

The embedded VM pattern from Lua, Wren, and Ficl is:

- bytecode-VM-first
- host-API-simple
- statically configurable
- allocation-disciplined
- tiny by feature selection, not by generality

`nanoclj-zig` should follow that pattern in its embedded profile while preserving Clojure semantics.

## Profiles

### `full`

Current research runtime:

- tree-walk eval
- bytecode VM
- miniKanren
- MCP
- nREPL
- interaction nets
- partial evaluation

### `embed-min`

Trusted or semi-trusted embedding with minimal surface:

- bytecode VM only
- minimal reader
- NaN-boxed values
- small builtin set
- no kanren
- no MCP
- no nREPL
- no interaction nets
- no partial evaluation
- no semantic debug layers in release

### `embed-safe`

Untrusted embedding with bounded execution:

- everything in `embed-min`
- instruction fuel
- stack/depth bounds
- allocation budget
- deterministic failure results
- total-eval guarantee

## Build flags added

The build now exposes profile metadata to the source tree through `build_options`:

- `embed_min`
- `embed_safe`
- `enable_fuel`
- `enable_depth_limits`
- `enable_allocation_budget`
- `enable_mcp`
- `enable_nrepl`
- `enable_kanren`
- `enable_inet`
- `enable_peval`

These flags currently scaffold the embedded path and drive binary identity. The next implementation step is to use them to gate modules and builtins at source level.

## Feature matrix

| Feature | full | embed-min | embed-safe |
|--------|------|-----------|------------|
| Tree-walk evaluator | yes | no | no |
| Bytecode VM | yes | yes | yes |
| Fuel bounds | yes | no | yes |
| Depth bounds | yes | no | yes |
| Allocation budget | no | no | yes |
| miniKanren | yes | no | no |
| MCP servers | yes | no | no |
| nREPL | yes | no | no |
| Interaction nets | yes | no | no |
| Partial evaluation | yes | no | no |
| Static binary | yes | yes | yes |
| Cross-target build | yes | yes | yes |

## Source-level execution plan

### Phase 1: profile identity

- Add build targets: `zig build embed-min`, `zig build embed-safe`
- Surface compile-time flags to Zig modules
- Print active profile in the REPL banner

### Phase 2: module gating

- Move non-embedded subsystems behind profile gates
- Exclude MCP, nREPL, kanren, inet, and peval from embedded builds
- Split builtin initialization into `core_full` vs `core_embed`

### Phase 3: allocator profiles

- `embed-min`: arena/reset-per-request
- `embed-safe`: arena plus allocation budget accounting
- `full`: current GC plus research/runtime services

### Phase 4: host API

Expose a stable embedding surface:

- `vm_init(config, allocator)`
- `vm_load_bytecode(...)`
- `vm_eval_with_limits(...)`
- `vm_reset(...)`
- `vm_register_native(...)`

### Phase 5: freestanding and WASM polish

- make `wasm_main.zig` a real embedded entry point instead of an echo stub
- align `embed-safe` with freestanding/WASM constraints
- verify identical bounded-failure semantics across native and WASM targets

## OxCaml note

A hypothetical `nanoclj-oxcaml` is still attractive for semantic structure and compile-time invariants:

- `local/global` for escape and stack allocation
- `unique/aliased` for alias control
- `once/many` for closure usage
- `portable/nonportable`, `shared/contended` for cross-thread sharing

Those are excellent tools for interpreter correctness and evolution, but Zig remains the better fit for the small, predictable, static-binary embedded path.

## Success criteria

`nanoclj-zig` has won the embedded niche when:

- `embed-min` is smaller and simpler than the full runtime by construction
- `embed-safe` can safely run untrusted code with explicit budgets
- the same source tree targets native, freestanding, and WASM
- the host embedding API is smaller and easier to reason about than the full REPL/runtime surface

