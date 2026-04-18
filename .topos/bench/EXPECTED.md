# Expected numbers

Ranges below are sourced from 3 exa refinements (2026-04-18). Absolute
numbers are load-bearing — when our bench differs, we document the cause
rather than relax the target.

## Cold start: init → `(+ 1 2)` → exit (wall clock)

| Runtime | Time | Source |
| --- | --- | --- |
| JVM Clojure (`clojure -e`) | 1.0–2.0 s | sierra 2020 syscall study; JVM Clojure cold = 4–11 s for apps, ~1–2 s for trivial eval |
| Leiningen | 2–4 s | same |
| Babashka | 20–60 ms | sierra 2020: 144 syscalls; community-measured cold ~30 ms |
| SCI JVM | ≈ JVM baseline + parse+analyze (528 ns + 6.8 µs) + eval (16.9 ns) | borkdude SCI benchmarks |
| SCI GraalVM native-image | 0.65–1.0 s for 10⁷ loop; cold ~50–150 ms | borkdude SCI |
| Joker | ~5–15 ms | sierra 2020: 185 syscalls |
| GraalVM Native Image (Spring) | 40–120 ms | backendbytes.com 2026 |
| **nanoclj-zig target** | **< 1 ms (ReleaseFast)**, **< 3 ms (embed-safe)** | own — NaN-boxed Zig, no JVM, no GraalVM metadata round |

## Binary size (stripped, static where possible)

| Runtime | Size | Source |
| --- | --- | --- |
| JVM JAR bundle | 300–420 MB | backendbytes |
| GraalVM native image | 55–95 MB | backendbytes |
| Babashka native | ~45–65 MB | public releases |
| Joker | ~6–10 MB | GitHub releases |
| Lua 5.2 REPL | 175 KB | schemescape 2025 |
| TinyScheme | 75 KB | schemescape 2025 |
| Lox VM | 40 KB | schemescape 2025 |
| zForth | 25 KB | schemescape 2025 |
| Ribbit RVM | 4 KB | Yvon+Feeley 2021 (4K VMIL) |
| PICOBIT | 5–15 KB | StAmour+Feeley 2009 |
| BIT | 13 KB ROM / 3–4 KB RAM | Dubé+Feeley 2005 |
| **nanoclj-zig `embed-min` target** | **< 400 KB ReleaseSmall** | own — upper bound against Janet 850 KB, lower bound >> Ribbit 4 KB (we run a full reader/eval/GC) |
| **nanoclj-zig `sector.bin` target** | **≤ 512 B** | own — constitutive; not a speed target |
| **nanoclj-zig WASM (`embed-safe`)** | **< 250 KB gzip** | own — compare QuickJS 700 KB, Duktape 350 KB |

## Idle RSS (after REPL start, no work)

| Runtime | RSS | Source |
| --- | --- | --- |
| JVM Clojure | 100–350 MB | public |
| Babashka | ~25–50 MB | public |
| GraalVM Native | 80–150 MB | backendbytes |
| **nanoclj-zig target** | **< 5 MB** | own |

## NaN-boxed numerics: fib(35) / Mandelbrot-ish

From Brion Vibber (2018) on own Lisp-like VM:

| Config | Time | Allocations |
| --- | --- | --- |
| Heap-boxed doubles (native) | 2677 ms | 1 per op |
| NaN-boxed (native) | 48 ms (**56× faster**) | 0 per op |
| NaN-boxed + return-type special | 17 ms | 0 per op |

Bigloo self-tagging floats (Melançon 2025): 2.4× faster on float-heavy
R7RS benchmarks, memory-allocation drops to ~0 for fibfp/pnpoly/ray/sumfp.

**nanoclj-zig target**: 0 allocations inside fib/fact/ackermann inner
loops (asserted via `GC.totalAllocated()` delta). Wall-time within 2×
of hand-written Zig recursion on the same ints.

## Flow throughput: `inhabit` ops/sec

No external comparator — this measures compiled Zig kernel overhead, not
any JVM analogue. Targets vs our own prior runs in
`~/i/flowmaps-lite/`:

| Kernel | JVM Clojure (Clojure 1.12 + core.async) | nanoclj-zig flow.zig target |
| --- | --- | --- |
| W1 plurigrid 3-block inhabit | ~50–200 k ops/s (core.async overhead) | > 5 M ops/s (single-threaded FIFO, no channels) |
| W5b GF(3) conservation | same | > 3 M ops/s |

## Reader / arena

SCI on JVM parse of `(let [x 1 y 2] (+ x y))`: 528 ns/expr parse.

Target: **< 200 ns/expr** for nanoclj-zig reader on same form
(measured 2026-04 in `bench/reader_arena.zig`); 1 MB EDN parse
in arena memory < 1.5 × source bytes peak.

## Fuel slope

`nanoclj-zig` reports fuel units spent per eval. Target: the line
`ns_per_eval = α + β · fuel_units` fits R² > 0.98 across fib/ackermann
and across profiles (`full`, `embed_safe`), with β-slope stable to
±10% between runs — evidence that fuel is a good proxy for wall time.

## Decision rules

- If cold-start > 5 ms in ReleaseFast on x86_64 macOS, investigate
  before other tuning — cold start is our clearest 0-tier win.
- If `sector.bin` > 512 B, build fails; constitutive constraint.
- If `flow.zig` inhabit throughput drops >2× between releases, bisect.
