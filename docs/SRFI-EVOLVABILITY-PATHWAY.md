# SRFI Evolvability Pathway: SectorLisp → SectorClojure → Full Clojure

## Executive Summary

This document maps the SRFI (Scheme Requests for Implementation) catalog into a tiered bootstrap pathway from a minimal SectorLisp-like kernel (9 primitives) through progressively richer capability layers toward a full Clojure implementation (700+ builtins). Each tier identifies the SRFIs that unlock new Clojure capabilities, the nanoclj/ClojureWasm builtins they enable, and the gaps where no SRFI exists and Clojure-specific extensions must be built natively in Zig.

---

## 0. The Primitives: SectorLisp Kernel

SectorLisp (Justine Tunney, 512 bytes) implements McCarthy's meta-circular evaluator with **9 primitives**:

| # | Primitive | Role |
|---|-----------|------|
| 1 | `NIL`     | The empty list / false value |
| 2 | `T`       | Truth value |
| 3 | `QUOTE`   | Prevent evaluation |
| 4 | `COND`    | Conditional branching |
| 5 | `ATOM`    | Type predicate (is it an atom?) |
| 6 | `CAR`     | First element of pair |
| 7 | `CDR`     | Rest of pair |
| 8 | `CONS`    | Construct pair |
| 9 | `EQ`      | Equality test |

**From these 9, the meta-circular evaluator derives**: `EVAL`, `APPLY`, `EVLIS`, `PAIRLIS`, `ASSOC`, `EVCON` — enough to interpret any Lisp program.

**SectorClojure Tier 0 target**: Implement these 9 primitives in Zig, plus `LAMBDA` (anonymous functions) and `DEFINE`/`DEF` (bindings), to create a self-hosting kernel.

---

## 1. SRFI Bootstrap Tiers

### Tier 1: List Library Foundation
**Goal**: Extend `car`/`cdr`/`cons` to a full list processing library

| SRFI | Name | Status | Clojure Mapping |
|------|------|--------|-----------------|
| **SRFI-1** | List Library | Final (1999) | `first`, `rest`, `cons`, `map`, `filter`, `reduce`, `take`, `drop`, `partition`, `every?`, `some`, `flatten`, `zip`, `interleave` |

**SRFI-1 categories → Clojure builtins enabled**:

| SRFI-1 Category | Key Procedures | Clojure Equivalents |
|-----------------|---------------|---------------------|
| Constructors | `cons`, `list`, `cons*`, `make-list`, `iota` | `cons`, `list`, `list*`, `repeat`, `range` |
| Predicates | `pair?`, `null?`, `proper-list?` | `seq?`, `nil?`, `list?` |
| Selectors | `car`, `cdr`, `list-ref`, `take`, `drop` | `first`, `rest`, `nth`, `take`, `drop` |
| Fold/Map | `fold`, `fold-right`, `map`, `for-each` | `reduce`, `map`, `doseq`, `run!` |
| Filtering | `filter`, `partition`, `remove` | `filter`, `partition`, `remove` |
| Searching | `find`, `any`, `every` | `some`, `some`, `every?` |
| Association lists | `assoc`, `alist-cons` | `assoc` (on maps), but alists map to early-stage map-like behavior |
| Set operations | `lset-union`, `lset-intersection`, `lset-difference` | `clojure.set/union`, `intersection`, `difference` (on lists initially) |

**nanoclj builtins unlocked**: ~40 core sequence functions

---

### Tier 2: Structural Types + Multi-arity
**Goal**: Records (foundation for defrecord/deftype) and multi-arity dispatch

| SRFI | Name | Status | Clojure Mapping |
|------|------|--------|-----------------|
| **SRFI-9** | Defining Record Types | Final (1999) | `defrecord`, `deftype` foundation |
| **SRFI-16** | Syntax for procedures of variable arity (`case-lambda`) | Final (1999) | Multi-arity `fn`, `defn` |
| **SRFI-26** | Notation for specializing parameters (`cut`/`cute`) | Final (2002) | `partial`, `#(% ...)` reader macro |
| **SRFI-232** | Flexible curried procedures | Final (2022) | Curried `fn` semantics |
| **SRFI-227** | Optional arguments | Final (2021) | `&rest`, `& {:keys [...]}` |
| **SRFI-240** | Reconciled Records (R7RS-large) | Final (2023) | Enhanced `defrecord` with inheritance |

**SRFI-9 provides**: `define-record-type` → constructor, predicate, field accessors, field modifiers. This is the bedrock for:
- `defrecord` (immutable records with named fields)
- `deftype` (low-level type definition)
- Protocol implementation targets

**SRFI-16 (`case-lambda`) provides**: Multi-arity dispatch, the foundation for Clojure's:
```clojure
(defn greet
  ([name] (str "Hello, " name))
  ([first last] (str "Hello, " first " " last)))
```

**nanoclj builtins unlocked**: `defrecord` family (currently MISSING in nanoclj), multi-arity `fn`/`defn`, `partial`

---

### Tier 3: Core Data Structures
**Goal**: Vectors, hash tables, sets — Clojure's immutable collection quartet

| SRFI | Name | Status | Clojure Mapping |
|------|------|--------|-----------------|
| **SRFI-43** | Vector Library | Final (2004) | `vector`, `vec`, `get`, `assoc`, `subvec`, `mapv` |
| **SRFI-69** | Basic Hash Tables | Final (2005) | Mutable map foundation (bootstrap step) |
| **SRFI-125** | Intermediate Hash Tables | Final (2015) | Richer map operations |
| **SRFI-113** | Sets and Bags | Final (2014) | `#{...}`, `clojure.set/*` |
| **SRFI-128** | Comparators (reduced) | Final (2015) | `compare`, `Comparable` protocol |
| **SRFI-151** | Bitwise Operations | Final (2016) | `bit-and`, `bit-or`, `bit-xor`, `bit-shift-left`, etc. |
| **SRFI-4** | Homogeneous Numeric Vectors | Final (1999) | Primitive arrays (`int-array`, `byte-array`, etc.) |

**Key insight**: SRFI-43 vectors are **mutable** (like Java arrays), while Clojure vectors are **persistent/immutable**. SRFI-43 serves as a bootstrap stepping stone — you implement mutable vectors first, then layer persistence on top.

Similarly, SRFI-69/125 hash tables are mutable. They serve as the implementation substrate for persistent hash maps (HAMTs), which require a Clojure-specific extension (see Tier 7/Gaps).

**nanoclj builtins unlocked**: `vector`, `vec`, `get`, `assoc`, `conj` (for vectors), `hash-map`, `array-map`, `hash-set`, `sorted-set`, `compare`, all bitwise ops

---

### Tier 4: Laziness + Generators
**Goal**: Lazy sequences (Clojure's killer feature) and generator-based iteration

| SRFI | Name | Status | Clojure Mapping |
|------|------|--------|-----------------|
| **SRFI-41** | Streams | Final (2007) | `lazy-seq`, `iterate`, `repeat`, `cycle`, `lazy-cat` |
| **SRFI-158** | Generators and Accumulators | Final (2017) | Iterator protocol, `sequence`, `eduction` |
| **SRFI-196** | Range Objects | Final (2020) | `range` |

**SRFI-41 Streams** are the direct precursor to Clojure's lazy sequences:
- `stream-cons` ↔ `lazy-seq` + `cons`
- `stream-map` ↔ `map` (lazy)
- `stream-filter` ↔ `filter` (lazy)
- `stream-take` ↔ `take` (lazy)
- `stream-fold` ↔ `reduce` (forces evaluation)

**SRFI-158 Generators** provide:
- `generator` / `make-coroutine-generator` → stateful iterators
- `accumulator` → collector/transducer step functions
- Direct pathway to Clojure's `sequence` and `eduction`

**nanoclj builtins unlocked**: `lazy-seq`, `iterate`, `repeat`, `cycle`, `range`, `take` (lazy), `drop` (lazy), `map` (lazy), `filter` (lazy), all lazy sequence operations

**nanoclj note**: nanoclj states "No chunked or buffered lazy sequences" — SRFI-41 would provide the foundation to add proper chunked lazy-seq support.

---

### Tier 5: Transducers + Immutable Mappings (Clojure Idioms)
**Goal**: Clojure's signature abstractions — transducers and persistent mappings

| SRFI | Name | Status | Clojure Mapping |
|------|------|--------|-----------------|
| **SRFI-171** | Transducers | Final (2019) | `transduce`, `map` (transducer), `filter` (transducer), `comp` (of transducers), `into` |
| **SRFI-146** | Mappings | Final (2018) | Immutable/persistent maps → `assoc`, `dissoc`, `update`, `merge`, `select-keys` |
| **SRFI-224** | Integer Mappings (fxmappings) | Final (2021) | Specialized int-keyed persistent maps (optimization for `(sorted-map)` with int keys) |
| **SRFI-250** | Insertion-ordered Hash Tables | Final (2025) | `array-map` (preserves insertion order) |

#### SRFI-171 Transducers ↔ Clojure Transducers (Direct Mapping)

SRFI-171 was explicitly inspired by Clojure's transducers. The mapping is nearly 1:1:

| SRFI-171 | Clojure |
|----------|---------|
| `tmap` | `(map f)` |
| `tfilter` | `(filter pred)` |
| `tremove` | `(remove pred)` |
| `ttake` | `(take n)` |
| `tdrop` | `(drop n)` |
| `ttake-while` | `(take-while pred)` |
| `tdrop-while` | `(drop-while pred)` |
| `tconcatenate` | `cat` |
| `tappend-map` | `(mapcat f)` |
| `tflatten` | `(mapcat flatten)` |
| `tdelete-duplicates` | `(distinct)` |
| `tsegment` | `(partition-all n)` |
| `tpartition` | `(partition-by pred)` |
| `tadd-between` | `(interpose val)` |
| `tenumerate` | `(map-indexed vector)` |
| `rcons` (reducer) | `conj` (as reducer) |
| `rcount` (reducer) | `(completing (fn [n _] (inc n)) identity)` |
| `rany` (reducer) | `(some pred)` pattern |
| `list-transduce` | `(transduce xform f coll)` |
| `compose` | `comp` |

**SRFI-171 depends on**: SRFI-9 (records, for `reduced` wrapper), SRFI-69 (hash tables, for `tdelete-duplicates`)

**Key difference**: SRFI-171 provides `list-transduce`, `vector-transduce`, `string-transduce`, etc. as separate entry points. Clojure uses a single polymorphic `transduce` via `IReduce` protocol.

#### SRFI-146 Immutable Mappings

SRFI-146 is the closest SRFI to Clojure's persistent maps:
- **Pure functional by default** — procedures don't mutate arguments
- **Linear-update variants** (ending in `!`) — allowed to mutate for efficiency (analogous to Clojure's transient maps)
- Provides: `mapping-adjoin` ≈ `assoc`, `mapping-delete` ≈ `dissoc`, `mapping-update` ≈ `update`, `mapping-union` ≈ `merge`, `mapping-fold` ≈ `reduce-kv`

**SRFI-224** (Integer Mappings / fxmappings): Uses **Okasaki-Gill Patricia trees** (big-endian radix trees) for fast merge, intersection, and lookup. Immutable. Keys restricted to fixnums. This is relevant as an optimization for integer-keyed sorted maps.

> **Important correction**: SRFI-224 is "Integer Mappings" (fxmappings), NOT "fectors" (functional vectors). There is no standard SRFI for persistent vectors (see Gaps section).

**nanoclj builtins unlocked**: `transduce`, `into`, `sequence`, `eduction`, `comp` (for transducers), `assoc`, `dissoc`, `update`, `merge`, `select-keys` (persistent versions)

**nanoclj note**: nanoclj explicitly lists "Transducers" as MISSING functionality. SRFI-171 provides the complete blueprint.

---

### Tier 6: Strings, Sorting, Testing
**Goal**: String operations, sorting library, test framework

| SRFI | Name | Status | Clojure Mapping |
|------|------|--------|-----------------|
| **SRFI-13** | String Library | Final (2000) | `clojure.string/*` — `split`, `join`, `trim`, `upper-case`, etc. |
| **SRFI-14** | Character-Set Library | Final (2000) | Character class predicates |
| **SRFI-175** | ASCII Character Library | Final (2019) | String/char ASCII operations |
| **SRFI-95** | Sorting and Merging | Final (2007) | `sort`, `sort-by` |
| **SRFI-132** | Sort Libraries | Final (2016) | Full `sort`, `sort-by`, `sorted-seq` with stable sort |
| **SRFI-64** | A Scheme API for Test Suites | Final (2005) | `clojure.test` foundation |
| **SRFI-236** | Independently Testable Units | (listed in task) | `deftest` pathway |
| **SRFI-269** | Portable Test Definitions | Draft (2026) | Modern `deftest`/`is` — closest to `clojure.test` |

**SRFI-269** (brand new, 2026) is particularly interesting: it defines `is` (assertions), `test` (independently executable units), and `suite` (hierarchies) — very close to Clojure's `deftest`/`is`/`testing`.

**nanoclj note**: nanoclj lists `deftest`, `set-test`, `with-test` as MISSING. SRFI-269 provides a direct blueprint.

**nanoclj builtins unlocked**: `sort`, `sort-by`, `clojure.string/*`, `deftest`, `is`, `testing`

---

### Tier 7: Advanced / Domain-Specific
**Goal**: Pattern matching, continuations, advanced control flow

| SRFI | Name | Status | Clojure Mapping |
|------|------|--------|-----------------|
| **SRFI-241/257/262** | Pattern Matching | Final | `core.match` |
| **SRFI-248** | Minimal Delimited Continuations | Final (2025) | Error handling, `try`/`catch` foundation |
| **SRFI-255** | Restarting Conditions | Final (2024) | Advanced error recovery |
| **SRFI-207** | String-Notations for Non-String Data | Final (2020) | Reader macros pathway |
| **SRFI-252** | Property Testing | Final (2024) | `test.check` / generative testing |
| **SRFI-253** | Data (Type-)Checking | Final (2024) | `spec.alpha` pathway |

---

## 2. SRFI → nanoclj/ClojureWasm Builtin Mapping by Tier

### Consolidated Builtin Unlock Table

| Tier | SRFIs | # Builtins Unlocked | Key Clojure Forms |
|------|-------|--------------------|--------------------|
| **0** | None (kernel) | ~12 | `def`, `fn`, `if`, `quote`, `cons`, `car`/`first`, `cdr`/`rest`, `=`, `atom?` |
| **1** | 1 | ~40 | `map`, `filter`, `reduce`, `take`, `drop`, `partition`, `every?`, `some`, `flatten`, `interleave`, `zip` |
| **2** | 9, 16, 26, 227, 232, 240 | ~25 | `defrecord`, `deftype` (basic), multi-arity `fn`/`defn`, `partial`, `comp` |
| **3** | 4, 43, 69, 113, 125, 128, 151 | ~50 | `vector`, `hash-map`, `hash-set`, `sorted-set`, `compare`, `bit-and`, `bit-or`, `get`, `assoc`, `conj` |
| **4** | 41, 158, 196 | ~30 | `lazy-seq`, `iterate`, `repeat`, `cycle`, `range`, lazy `map`/`filter`/`take`/`drop` |
| **5** | 146, 171, 224, 250 | ~35 | `transduce`, `into`, `sequence`, persistent `assoc`/`dissoc`/`update`/`merge` |
| **6** | 13, 14, 64, 95, 132, 175, 269 | ~30 | `sort`, `sort-by`, `clojure.string/*`, `deftest`, `is`, `testing` |
| **7** | 207, 241, 248, 252, 253, 255, 257, 262 | ~20 | `core.match`, advanced error handling, property testing, specs |
| **Total** | ~35 SRFIs | **~242** | — |

**This leaves ~460+ builtins** from Clojure's 700+ total (ClojureWasm implements 651/706 `clojure.core` vars) that must come from Clojure-specific extensions (see Gaps).

---

## 3. SRFIs That Don't Exist: Clojure-Specific Gaps

The following core Clojure concepts have **NO SRFI equivalent** and must be implemented natively in SectorClojure's Zig runtime:

### 3.1 Persistent Data Structures (HAMTs)
**Gap**: No SRFI defines Hash Array Mapped Tries (HAMTs), the backbone of Clojure's persistent vectors, maps, and sets.

- **Persistent Vectors**: Clojure uses a 32-way branching trie with tail optimization. SRFI-43 provides mutable vectors. SRFI-224 provides immutable integer mappings (Patricia trees), but NOT persistent vectors.
- **Persistent Hash Maps**: Clojure uses Phil Bagwell's HAMT. SRFI-146 provides immutable mappings (closest), but doesn't specify HAMT internals.
- **Persistent Sets**: Built on persistent hash maps. SRFI-113 provides mutable sets.
- **Transient Data Structures**: Clojure's `transient`/`persistent!` for batch mutation. No SRFI equivalent (SRFI-146's `!` variants are similar in concept but different in semantics).

**Implementation strategy for Zig**: Port the HAMT algorithm directly. The RRB-tree (relaxed radix balanced tree) for vectors, and CHAMP (compressed hash-array mapped prefix-tree) for maps/sets.

### 3.2 Protocols and Multimethods
**Gap**: No SRFI defines Clojure-style protocols or multimethods.

- **Protocols** (`defprotocol`/`extend-type`/`extend-protocol`): Type-based polymorphic dispatch. Scheme has SRFI-9 records but no protocol dispatch.
- **Multimethods** (`defmulti`/`defmethod`): Arbitrary dispatch function. No SRFI equivalent.
- **SRFI-263** (Prototype Object System, Draft 2025) provides prototype-based objects (Self-style), which is related but fundamentally different from protocol-based dispatch.

**nanoclj status**: Explicitly lists "Interfaces, Records, StructMaps, Protocols and Multi-methods" as MISSING.

### 3.3 Concurrency Primitives
**Gap**: No SRFI defines Clojure's concurrency model.

- **Atoms** (`atom`, `swap!`, `reset!`, `compare-and-set!`): Lock-free mutable references. No SRFI equivalent.
- **Refs + STM** (`ref`, `dosync`, `alter`, `commute`): Software Transactional Memory. No SRFI equivalent.
- **Agents** (`agent`, `send`, `send-off`): Asynchronous state. No SRFI equivalent.
- **Vars** (`def`, `binding`, dynamic vars): Thread-local bindings. No SRFI equivalent.
- **core.async** (`go`, `chan`, `<!`, `>!`): CSP channels. No SRFI equivalent.

**nanoclj status**: "Refs, Agents, Atoms, Validators" and "Multithreading, transactions, STM and locking" listed as MISSING.

### 3.4 Keywords
**Gap**: Keywords (`:foo`, `:bar/baz`) are Clojure-specific. Scheme has only symbols.

Must be implemented as a distinct interned type in Zig. Keywords are self-evaluating, implement `IFn` (act as lookup functions on maps), and support namespacing.

### 3.5 Destructuring
**Gap**: No SRFI provides Clojure-style destructuring.

- **Sequential destructuring**: `(let [[a b c] [1 2 3]] ...)`
- **Associative destructuring**: `(let [{:keys [a b]} {:a 1 :b 2}] ...)`
- **& rest**: `(let [[a & more] [1 2 3]] ...)`

SRFI-239 (Destructuring Lists) provides basic list destructuring (`list-case`), but not map destructuring or Clojure's full `let`-binding forms.

### 3.6 Namespaces and Vars
**Gap**: Clojure's namespace system (`ns`, `require`, `use`, `import`, `refer`) has no SRFI equivalent.

SRFI-261 (Portable SRFI Library Reference) and SRFI-7 (Feature-based program configuration) address module systems, but nothing close to Clojure's dynamic namespace management with `intern`, `resolve`, `ns-publics`, `ns-map`, etc.

### 3.7 Metadata
**Gap**: Clojure's metadata system (`^{:doc "..."}`, `meta`, `with-meta`, `vary-meta`) has no SRFI equivalent.

### 3.8 Reader Macros / EDN
**Gap**: Clojure's reader (`#{}`, `#()`, `@`, `^`, `#'`, `#"..."`, tagged literals `#inst`, `#uuid`) has no comprehensive SRFI equivalent. SRFI-207 (String-Notations) and SRFI-267 (Raw String Syntax) touch on reader extensions but don't cover Clojure's full reader.

---

## 4. SRFI-224: Integer Mappings (fxmappings) — Deep Dive

### Correction
The task description references "SRFI-224 (fector — functional vectors)". **This is incorrect.** SRFI-224 defines **Integer Mappings** (fxmappings), not functional vectors (fectors).

### What SRFI-224 Actually Provides
- **Immutable** integer-keyed mappings using **Okasaki-Gill Patricia trees** (big-endian radix trees)
- Keys restricted to **fixnums** (at least 24-bit signed integers)
- Rich API: constructors, predicates, accessors, updaters (all pure/functional), traversal, filter, conversion, comparison, set operations, submappings
- **Implementation**: Based on "Fast Mergeable Integer Maps" (Okasaki & Gill, 1998)

### Relevance to SectorClojure
SRFI-224's Patricia tree implementation is relevant for:
1. **`sorted-map`** with integer keys (direct use case)
2. **Internal compiler/runtime data structures** (symbol tables, environment frames indexed by integer IDs)
3. **Foundation pattern** for persistent data structure implementation — the same functional update pattern applies to HAMTs

### Key Operations → Clojure Mapping
| SRFI-224 | Clojure Equivalent |
|----------|-------------------|
| `fxmapping` constructor | `(sorted-map 1 :a 2 :b)` |
| `fxmapping-ref` | `get` |
| `fxmapping-adjoin` | `assoc` (preserves old on conflict) |
| `fxmapping-set` | `assoc` (overwrites) |
| `fxmapping-delete` | `dissoc` |
| `fxmapping-union` | `merge` |
| `fxmapping-intersection` | `select-keys` (subset) |
| `fxmapping-fold` | `reduce-kv` |
| `fxmapping-map` | mapping over entries |
| `fxmapping-filter` | `filter` on map entries |

---

## 5. SRFI-171: Transducers — Deep Dive

### Direct Clojure Heritage
SRFI-171 explicitly acknowledges Rich Hickey and Clojure as the origin of transducers. From the spec:
> "This would not have been done without Rich Hickey, who introduced transducers into Clojure."

### Architecture Mapping

**Clojure transducer protocol**:
```clojure
;; A transducer is a function: (reducing-fn) -> reducing-fn
;; A reducing function has 3 arities:
;;   () -> identity (init)
;;   (result) -> completion
;;   (result, input) -> new-result (step)
```

**SRFI-171 mirrors this exactly**:
```scheme
;; A reducer is a 3-arity function:
;;   () -> identity
;;   (result-so-far) -> completion
;;   (result-so-far input) -> new-result
;; A transducer takes a reducer and returns a reducer
```

### Implementation Dependencies for SectorClojure
SRFI-171 requires:
1. **SRFI-9** (records) — for the `reduced` wrapper type
2. **SRFI-69** (hash tables) — for `tdelete-duplicates`
3. **`case-lambda`** (SRFI-16) — for 3-arity reducers
4. **`compose`** — function composition

This means **Tier 5 (transducers) depends on Tier 2 (records) and Tier 3 (hash tables)**.

### What SectorClojure Needs Beyond SRFI-171
- **Polymorphic `transduce`**: SRFI-171 has separate `list-transduce`, `vector-transduce`, etc. Clojure has one `transduce` that works via `IReduce` protocol.
- **Transducer-returning arities**: In Clojure, `(map f)` returns a transducer. SRFI-171 uses separate `tmap`, `tfilter`, etc. SectorClojure should support both.
- **`into`**: Clojure's `(into [] xform coll)` combines transduction with collection building. Not in SRFI-171 but trivially built on top.
- **`eduction`**: Lazy transducer application. Not in SRFI-171.

---

## 6. The Complete Bootstrap Ladder

```
Tier 0: SectorLisp Kernel (9 primitives + def/fn/if)
  │     QUOTE, COND, ATOM, CAR, CDR, CONS, EQ, NIL, T
  │     + LAMBDA, DEF, IF (Clojure forms)
  │
  ▼  ──── SRFI-1 (List Library) ────
Tier 1: Full List Processing (~40 builtins)
  │     map, filter, reduce, take, drop, every?, some, partition
  │     fold, unfold, zip, append, reverse, flatten
  │
  ▼  ──── SRFI-9 + SRFI-16 + SRFI-26 + SRFI-227 + SRFI-232 ────
Tier 2: Structural Types + Multi-arity (~25 builtins)
  │     defrecord (basic), multi-arity fn/defn
  │     partial, comp, optional/rest args
  │
  ▼  ──── SRFI-43 + SRFI-69/125 + SRFI-113 + SRFI-128 + SRFI-151 ────
Tier 3: Core Data Structures (~50 builtins)
  │     vector, hash-map, hash-set, sorted-set
  │     get, assoc, conj, compare, bitwise ops
  │     [MUTABLE foundation — persistence comes in Tier 5]
  │
  ▼  ──── SRFI-41 + SRFI-158 + SRFI-196 ────
Tier 4: Laziness + Generators (~30 builtins)
  │     lazy-seq, iterate, repeat, cycle, range
  │     Lazy map/filter/take/drop
  │     Generator/accumulator protocol
  │
  ▼  ──── SRFI-171 + SRFI-146 + SRFI-224 + SRFI-250 ────
Tier 5: Transducers + Immutable Mappings (~35 builtins)
  │     transduce, into, sequence
  │     Persistent assoc/dissoc/update/merge
  │     [PERSISTENCE layer on top of Tier 3 mutables]
  │
  ▼  ──── SRFI-13/14 + SRFI-95/132 + SRFI-64/269 + SRFI-175 ────
Tier 6: Strings, Sorting, Testing (~30 builtins)
  │     clojure.string/*, sort, sort-by
  │     deftest, is, testing
  │
  ▼  ──── SRFI-241/257/262 + SRFI-248/255 + SRFI-252/253 ────
Tier 7: Advanced (Pattern Matching, Continuations, Specs) (~20 builtins)
  │     core.match, try/catch, generative testing
  │
  ▼  ──── NO SRFI (Zig-native implementation required) ────
Tier 8: Clojure-Specific Extensions (~460+ builtins)
  │     HAMTs (persistent vectors/maps/sets)
  │     Protocols, Multimethods
  │     Atoms, Refs, Agents, STM
  │     Keywords, Metadata, Namespaces
  │     Destructuring, Reader/EDN
  │     core.async, Vars, Dynamic binding
  │
  ▼
Full Clojure (700+ builtins, ~ClojureWasm's 651/706 core vars)
```

---

## 7. SRFI Reference Table (All Relevant SRFIs)

| SRFI | Name | Year | Status | Tier | Clojure Relevance |
|------|------|------|--------|------|-------------------|
| 0 | Feature-based conditional expansion | 1999 | Final | Infra | `*features*`, conditional compilation |
| 1 | List Library | 1999 | Final | 1 | Core sequence ops |
| 2 | AND-LET* | 1999 | Final | 2 | `when-let` pathway |
| 4 | Homogeneous Numeric Vectors | 1999 | Final | 3 | Primitive arrays |
| 6 | Basic String Ports | 1999 | Final | 6 | `with-out-str` |
| 8 | receive (multiple values) | 1999 | Final | 2 | Destructuring multiple returns |
| 9 | Defining Record Types | 1999 | Final | 2 | `defrecord`/`deftype` |
| 13 | String Library | 2000 | Final | 6 | `clojure.string/*` |
| 14 | Character-Set Library | 2000 | Final | 6 | Char predicates |
| 16 | case-lambda | 1999 | Final | 2 | Multi-arity `fn` |
| 26 | cut/cute | 2002 | Final | 2 | `partial` |
| 41 | Streams | 2007 | Final | 4 | `lazy-seq` |
| 43 | Vector Library | 2004 | Final | 3 | `vector`, `vec` |
| 64 | Test Suites | 2005 | Final | 6 | `clojure.test` |
| 69 | Basic Hash Tables | 2005 | Final | 3 | `hash-map` (mutable base) |
| 95 | Sorting and Merging | 2007 | Final | 6 | `sort` |
| 113 | Sets and Bags | 2014 | Final | 3 | `hash-set`, `clojure.set` |
| 125 | Intermediate Hash Tables | 2015 | Final | 3 | Richer map ops |
| 128 | Comparators (reduced) | 2015 | Final | 3 | `compare` |
| 132 | Sort Libraries | 2016 | Final | 6 | Full `sort`/`sort-by` |
| 146 | Mappings | 2018 | Final | 5 | Immutable maps |
| 151 | Bitwise Operations | 2016 | Final | 3 | `bit-*` ops |
| 158 | Generators and Accumulators | 2017 | Final | 4 | Iterator/generator protocol |
| 171 | Transducers | 2019 | Final | 5 | `transduce`, `into` |
| 175 | ASCII Character Library | 2019 | Final | 6 | ASCII string ops |
| 196 | Range Objects | 2020 | Final | 4 | `range` |
| 207 | String-Notations | 2020 | Final | 7 | Reader macros |
| 224 | Integer Mappings (fxmappings) | 2021 | Final | 5 | `sorted-map` (int keys) |
| 227 | Optional Arguments | 2021 | Final | 2 | `& rest`, `& {:keys}` |
| 232 | Flexible Curried Procedures | 2022 | Final | 2 | Curried `fn` |
| 240 | Reconciled Records | 2023 | Final | 2 | `defrecord` with inheritance |
| 250 | Insertion-ordered Hash Tables | 2025 | Final | 5 | `array-map` |
| 252 | Property Testing | 2024 | Final | 7 | `test.check` |
| 253 | Data (Type-)Checking | 2024 | Final | 7 | `spec.alpha` |
| 257 | Pattern Matcher | 2025 | Final | 7 | `core.match` |
| 269 | Portable Test Definitions | 2026 | Draft | 6 | `deftest`/`is` |

---

## 8. Implementation Priority for SectorClojure (Zig)

### Phase 1: Kernel (Tier 0)
Implement in Zig: `cons`, `car`, `cdr`, `eq`, `atom`, `cond`/`if`, `quote`, `lambda`/`fn`, `def`
- **Lines of Zig**: ~500-1000
- **Enables**: Self-hosting eval/apply

### Phase 2: SRFI-1 Layer (Tier 1)  
Port SRFI-1 reference implementation concepts to Zig builtins
- **Lines of Zig**: ~1500-2000 (many can be self-hosted in Clojure-on-Zig)
- **Enables**: Practical list programming

### Phase 3: Types + Dispatch (Tier 2)
Implement SRFI-9 records and SRFI-16 case-lambda in Zig
- **Lines of Zig**: ~800-1200
- **Enables**: User-defined types, multi-arity functions

### Phase 4: Collections (Tier 3)
Implement mutable vectors (SRFI-43), hash tables (SRFI-69), sets (SRFI-113) in Zig
- **Lines of Zig**: ~2000-3000
- **Enables**: All core data structures (mutable base)

### Phase 5: Persistence (Tiers 3→5 bridge, NO SRFI)
Implement HAMTs for persistent vectors/maps/sets **in Zig** (no SRFI guide)
- **Lines of Zig**: ~3000-5000
- **This is the hardest phase — Clojure-specific, no SRFI guidance**

### Phase 6: Laziness + Transducers (Tiers 4-5)
Port SRFI-41 streams, SRFI-171 transducers
- **Lines of Zig**: ~1500-2000
- **Many can be self-hosted** once persistence exists

### Phase 7: Clojure Extensions (Tier 8)
Protocols, multimethods, atoms, keywords, namespaces, destructuring, metadata
- **Lines of Zig**: ~5000-8000
- **The "last mile" — pure Clojure semantics, no SRFI guidance**

---

## 9. Key Findings

1. **~35 SRFIs cover ~242 builtins** (roughly a third of full Clojure). The remaining ~460+ builtins require Clojure-specific Zig implementation.

2. **SRFI-171 (Transducers) is a near-perfect match** for Clojure transducers, explicitly derived from Clojure. It is the strongest SRFI↔Clojure mapping in the entire catalog.

3. **SRFI-224 is NOT about functional vectors** — it's about integer mappings using Patricia trees. There is no SRFI for persistent vectors (HAMTs). This is the biggest gap.

4. **SRFI-146 (Mappings) is the closest to Clojure's persistent maps**, with pure-functional semantics and linear-update variants analogous to transients.

5. **The biggest gaps** requiring native Zig implementation are: persistent data structures (HAMTs), protocols/multimethods, concurrency (atoms/refs/STM), keywords, destructuring, and namespaces.

6. **nanoclj (C, 922 commits)** provides a comprehensive reference for which builtins are needed and which are hard. Its "Missing functionality" list almost perfectly maps to our Tier 7-8 gaps.

7. **ClojureWasm (Zig)** already implements 651/706 `clojure.core` vars, proving that a Zig-based full Clojure is feasible. It can serve as a reference implementation for the post-SRFI tiers.

8. **The SRFI-based bootstrap tiers form a clean dependency chain**: Tier 1 (lists) → Tier 2 (records, needed by SRFI-171) → Tier 3 (hash tables, needed by SRFI-171) → Tier 4 (laziness) → Tier 5 (transducers + persistence).
