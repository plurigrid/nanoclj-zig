# nanoclj-zig: 69 Research Areas for Feature-Complete Implementation

Prioritized by effort/impact. Techniques from **krep** (SIMD grep) and **StringZilla** (SIMD string lib) integrated where applicable.

---

## A. SIMD String Engine (krep + StringZilla learnings)

| # | Area | Technique | Effort | Impact |
|---|------|-----------|--------|--------|
| 1 | **Pseudo-SIMD find** | Broadcast char into u64, XOR+shift match (works on ALL CPUs incl. WASM) | S | High |
| 2 | **SIMD char count** | NEON `vceqq_u8` + popcount per 16B block; Zig `@Vector(16,u8)` | M | High |
| 3 | **Heuristic prefix match** | Compare first 4 bytes at 16 offsets, verify full match only on hit | S | High |
| 4 | **Algorithm-length dispatch** | KMP (<3), SIMD (3-16), Boyer-Moore (>16), Rabin-Karp (>64) | M | High |
| 5 | **mmap file I/O** | `std.os.mmap` for load-file, madvise SEQUENTIAL | S | Medium |
| 6 | **Chunk parallelism** | Split file into N chunks with pattern-length overlap at boundaries | M | Medium |
| 7 | **Radix+quicksort hybrid** | Pack first 4 bytes into sort key, radix to depth 32, then std sort | M | Medium |
| 8 | **Case-insensitive SIMD** | OR 0x20 mask before compare (ASCII lowercase) in vector lane | S | Medium |
| 9 | **SWAR replace** | Pseudo-SIMD scan + memcpy for bulk string/replace | M | Medium |
| 10 | **Count-only mode** | Branchless popcount accumulation for `(count (filter ...))` patterns | S | Low |

## B. Core Language Completions

| # | Area | Description | Effort | Impact |
|---|------|-------------|--------|--------|
| 11 | **Persistent vector (HAMT)** | 32-way trie with tail optimization, structural sharing | L | Critical |
| 12 | **Persistent hash-map** | HAMT with bitmap-indexed nodes, collision lists | L | Critical |
| 13 | **Persistent set** | Thin wrapper over hash-map with set semantics | M | High |
| 14 | **Lazy sequences** | Thunk-based cons cells, realize-on-demand | M | Critical |
| 15 | **Destructuring** | let/fn argument destructuring (sequential + associative) | M | High |
| 16 | **Multi-arity fn** | fn with multiple (args) clauses dispatched by count | M | High |
| 17 | **Varargs (& rest)** | Rest parameter collection into list | S | High |
| 18 | **try/catch/throw** | Exception mechanism with ex-info/ex-data | M | High |
| 19 | **Metadata** | ^{} reader syntax, with-meta, meta, vary-meta | M | Medium |
| 20 | **Namespaces** | ns macro, require, refer, alias | L | Critical |
| 21 | **Protocols** | defprotocol/extend-type/extend-protocol dispatch | L | High |
| 22 | **defmulti/defmethod** | Arbitrary dispatch function multimethod | M | Medium |
| 23 | **Atoms** | atom/deref/swap!/reset!/compare-and-set! | S | High |
| 24 | **Regex literals** | #"pattern" reader, re-find/re-matches/re-seq | M | High |
| 25 | **Transients** | transient/persistent!/conj!/assoc!/dissoc! for batch mutation | M | Medium |

## C. Compiler & VM Enhancements

| # | Area | Description | Effort | Impact |
|---|------|-------------|--------|--------|
| 26 | **Constant folding** | Evaluate pure arithmetic/string ops at compile time | M | Medium |
| 27 | **Register allocation** | Linear scan or graph coloring to minimize register pressure | L | Medium |
| 28 | **Inline caching** | Monomorphic/polymorphic inline caches for builtin dispatch | M | High |
| 29 | **Loop/recur in let** | Support (loop [bindings] ... (recur ...)) in bytecode | S | High |
| 30 | **def/defn compilation** | Compile top-level definitions to bytecode | M | High |
| 31 | **apply compilation** | Emit apply opcode for (apply f args) | S | Medium |
| 32 | **Tail-call between fns** | Full TCO across function boundaries (not just self-recur) | L | Medium |
| 33 | **Debug info / source maps** | Line:col metadata in bytecode for error reporting | M | Medium |
| 34 | **Bytecode serialization** | Dump/load compiled bytecode (skip parsing on reload) | M | Medium |
| 35 | **JIT via LLVM/Cranelift** | Compile hot paths to native machine code | XL | High |

## D. Standard Library Gaps

| # | Area | Key fns | Effort | Impact |
|---|------|---------|--------|--------|
| 36 | **assoc/dissoc/update** | Core map operations | S | Critical |
| 37 | **nth/first/second/last** | Sequence access | S | High |
| 38 | **str/name/keyword/symbol** | Type conversion fns | S | High |
| 39 | **comp/partial/juxt** | Higher-order function combinators | S | Medium |
| 40 | **some/every?/not-any?** | Predicate sequence ops | S | Medium |
| 41 | **mapv/filterv/mapcat** | Eager vector-returning variants | S | Medium |
| 42 | **group-by/frequencies** | Aggregation | M | Medium |
| 43 | **sort/sort-by** | Comparator-based sort (use radix+qsort #7) | M | Medium |
| 44 | **partition/partition-by** | Sequence chunking | S | Medium |
| 45 | **interleave/interpose** | Sequence interleaving | S | Low |
| 46 | **zipmap/select-keys** | Map construction/filtering | S | Medium |
| 47 | **Math fns** | abs/min/max/floor/ceil/sqrt/pow/rand/rand-int | S | Medium |
| 48 | **Bit ops** | bit-and/bit-or/bit-xor/bit-shift-left/bit-shift-right | S | Low |

## E. I/O & Interop

| # | Area | Description | Effort | Impact |
|---|------|-------------|--------|--------|
| 49 | **Reader macros** | #() anonymous fn, @deref, `quote/'unquote | M | High |
| 50 | **EDN reader/writer** | Full EDN spec (tagged literals, #inst, #uuid) | M | High |
| 51 | **File I/O** | slurp/spit with mmap backend (#5) | S | High |
| 52 | **Stdio** | read-line, *in*/*out*/*err* bindings | S | Medium |
| 53 | **JSON reader/writer** | clojure.data.json compatible | M | Medium |
| 54 | **TCP sockets** | Basic socket server/client for nREPL | M | Medium |
| 55 | **nREPL protocol** | Bencode transport, eval/complete/info ops | L | High |
| 56 | **FFI / C interop** | Call C functions from nanoclj (Zig extern) | L | Medium |

## F. Concurrency

| # | Area | Description | Effort | Impact |
|---|------|-------------|--------|--------|
| 57 | **Thread pool** | Zig std.Thread based pool for pmap/future | M | Medium |
| 58 | **Futures/promises** | future/deref with thread pool dispatch | M | Medium |
| 59 | **pmap** | Parallel map using chunk parallelism (#6) | M | Medium |
| 60 | **Channels (CSP)** | core.async-style channels, go blocks | XL | Medium |

## G. Tooling & DX

| # | Area | Description | Effort | Impact |
|---|------|-------------|--------|--------|
| 61 | **REPL completions** | Tab-complete symbols/builtins | S | Medium |
| 62 | **Pretty printer** | pprint with indentation, width control | M | Medium |
| 63 | **Test framework** | deftest/is/are/testing macros | M | High |
| 64 | **Docstrings** | doc/find-doc, docstring on defn | S | Medium |
| 65 | **Profiler** | Time per bytecode region, allocation tracking | M | Medium |
| 66 | **WASM target** | Compile nanoclj-zig to WASM (Zig supports it natively) | L | High |

## H. Domain-Specific (Already Started)

| # | Area | Status | Effort | Impact |
|---|------|--------|--------|--------|
| 67 | **Interaction nets** | inet.zig exists, needs readback/normalization polish | M | Medium |
| 68 | **Jepsen linearizability** | jepsen.zig exists, needs nemesis/partition simulation | M | Medium |
| 69 | **Gorj/Syrup bridge** | gorj_bridge.zig v2 done, needs bidirectional streaming | M | Medium |

---

## Priority Matrix

**Do first** (highest impact, lowest effort):
1, 3, 5, 11, 14, 23, 29, 36, 37, 38, 51

**Do next** (high impact, medium effort):
4, 12, 15, 16, 18, 20, 24, 28, 30, 49, 50, 55, 63

**Strategic bets** (high effort, transformative):
35 (JIT), 60 (CSP channels), 66 (WASM target)

---

## Key krep/StringZilla Takeaways for Zig

1. **Zig `@Vector` maps directly to SIMD** - use `@Vector(16, u8)` for NEON/SSE, `@Vector(32, u8)` for AVX2
2. **Pseudo-SIMD with u64** is the universal fallback (works everywhere including WASM)
3. **Heuristic first-4-bytes** gives 5-10x on substring search with zero preprocessing
4. **Algorithm dispatch by pattern length** is trivial in Zig with comptime branching
5. **mmap + madvise** for file I/O is free performance (Zig has `std.os.mmap`)
6. **Radix sort on first 4 bytes** then finalize with quicksort for string sorting
