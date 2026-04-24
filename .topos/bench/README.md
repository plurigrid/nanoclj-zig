# nanoclj-zig benchmark harness

Classified in GF(3) form:

- **+1 Incomparable** — benches other Clojure dialects physically cannot run:
  - `sector_size.bb` — assert `sector.bin ≤ 512 B` (MBR-bootable Clojure)
  - `arch_matrix.bb` — cross-compile on 6 archs, emit per-target JSON
  - (future) Cortex-M4 `embed-min` footprint via `arm-none-eabi-size`

- **0 Head-to-head** — directly comparable with JVM/Babashka/SCI-native/Joker:
  - `cold_start.zig` — init → eval `(+ 1 2)` → exit
  - `nanbox_fib.zig` — `(fib 35)` wall-time + allocations (GC.totalAllocated())
  - `reader_arena.zig` — 1 MB EDN parse throughput, peak arena bytes

- **−1 Dialect-profile** — only meaningful vs our own prior runs:
  - `flow_throughput.zig` — `flow.Flow(V).inhabit` ops/sec on W1..W5b
  - `fuel_slope.zig` — fuel-units → ns regression (slope = per-unit cost)

See `EXPECTED.md` for target ranges sourced from public measurements.

## Build step

`zig build bench` runs all benches and prints one JSON line per result to
stdout. A follow-up babashka comparator can ingest that and slot into the
`.topos/bench/` report pipeline.
