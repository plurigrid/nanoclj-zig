# Boot Semantics: SectorLisp → HolyC → nanoclj-zig

**Research Date:** 2026-04-04
**Purpose:** Map the minimal-to-maximal bootup pathway from bare metal to full Clojure.

---

## 1. SectorLisp: The Lower Bound

### Sources
- https://justine.lol/sectorlisp/ (Justine Tunney, Oct 2021)
- https://justine.lol/sectorlisp2/ (SectorLisp v2: GC in 436 bytes, Dec 2021)
- https://github.com/jart/sectorlisp (source code)
- McCarthy 1960: "Recursive Functions of Symbolic Expressions"

### How it fits in 512 bytes (one boot sector)

SectorLisp v2 uses **436 bytes** of i8086 assembly (223 lines) to implement a complete Lisp with garbage collection. The 512-byte boot sector includes padding + the `0xAA55` boot signature. Key techniques:

1. **Redefine NULL**: The boot address `0x7c00` itself serves as NULL. The program image doubles as the interned strings table — `NIL`, `T`, and other atom names are stored as the first bytes of the binary. The CPU harmlessly executes `NIL` and `T` as x86 instructions (`dec %si; dec %cx; dec %sp; add %dl,(%si)`) before jumping to the real entry point.

2. **`%fs` segment register as monotonic allocator**: Cons cells grow upward from `INT_MIN` (or from 0 via `%fs`), atoms are interned in positive memory. No malloc, no heap metadata.

3. **Overlapping functions**: x86's variable-length encoding allows functions to physically overlap in memory — the same bytes decode as different instructions depending on the instruction pointer offset. `Assoc`, `Cadr`, `Cdr`, and `Car` share bytes.

4. **ABC Garbage Collector** (40 bytes): Save cons pointer before eval (A), after eval (B), then recursively copy the result downward (C). Memcpy B→C up to A. Perfect defragmentation with zero overhead, enabled by Lisp's acyclic data guarantee.

5. **Character hacks**: `isspace(c)` → `c <= ' '`; paren check → `c <= ')'`. Dot notation replaced with bullet character `∙` from Code Page 437 to save 2 bytes.

### The 8 Primitives

SectorLisp provides exactly **7 native primitives** (plus `QUOTE` and `COND` as special forms):

| Primitive | Type | Description |
|-----------|------|-------------|
| `CAR` | function | First element of cons cell |
| `CDR` | function | Second element of cons cell |
| `CONS` | function | Construct a new cons cell |
| `ATOM` | function | Test if value is an atom (not cons) |
| `EQ` | function | Test equality of two atoms |
| `QUOTE` | special form | Return expression unevaluated |
| `COND` | special form | Conditional branching |
| `LAMBDA` | special form | Anonymous function construction |

These are the **irreducible kernel** of computation. McCarthy proved in 1960 that `eval` can be written in terms of these primitives alone (the metacircular evaluator).

### The Bootstrap Pathway

```
BIOS loads 512 bytes at 0x7C00
  → ljmp to _begin (set up segments, clear BSS)
    → Initialize atom string table (NIL, T, QUOTE, COND, ATOM, CAR, CDR, CONS, EQ)
      → REPL loop: GetToken → GetObject → Eval → PrintObject
        → User can load the metacircular evaluator (LISP-in-LISP)
          → "Double LISP": evaluator running inside evaluator
            → "Triple LISP": three nested evaluators
```

The metacircular evaluator is ~40 lines of LISP that implements `eval`, `apply`, `evcon`, `evlis`, `pairlis`, and `assoc` — using only the 8 primitives. This is the "Maxwell's equations of software" (Alan Kay).

### The Reflection Connection (McCarthy 1960 → SectorLisp 2020)

McCarthy's original 1960 paper defined LISP as a mathematical formalism, not a programming language. Steve Russell realized you could implement `eval` on a real machine. SectorLisp closes the loop: the smallest possible machine implementation of McCarthy's formalism, 60 years later, running on the same x86 architecture family. The project proves that LISP's core is **genuinely irreducible** — you cannot make a complete evaluator smaller.

---

## 2. HolyC / TempleOS: JIT as Shell

### Sources
- http://www.codersnotes.com/notes/a-constructive-look-at-templeos/ (Richard Mitton, 2015)
- https://templeos.net/holyc/
- https://en.wikipedia.org/wiki/TempleOS
- https://tinkeros.github.io/WbGit/Doc/HolyC.html

### Boot Sequence

```
BIOS POST
  → Custom bootloader (written by Terry Davis)
    → Kernel load (64-bit long mode setup)
      → HolyC compiler initialization (JIT)
        → Kernel startup scripts (#include'd HolyC source)
          → Adam task (PID 1) with DolDoc shell
            → HolyC REPL ready (the shell IS the compiler)
```

**Boot time: ~1 second** from power-on to interactive shell. No paging, instant usability.

### Key Architectural Decisions

| Feature | Design Choice | Rationale |
|---------|---------------|-----------|
| **Ring level** | Ring 0 only | Single user = no protection needed. Like C64. |
| **Memory model** | Flat, no virtual memory | Everything accessible. "Mapping the Commodore 64" philosophy. |
| **Language** | HolyC = C + JIT + shell | No distinction between "compiled program" and "shell command" |
| **Linker** | Dynamic only, no object files | Symbol table always live at runtime |
| **Threading** | Processes = threads (single address space) | No memory protection → no distinction needed |
| **Files** | DolDoc hypertext (unified format) | Replaces HTML, JSON, XML, scripts, source, text |
| **Resolution** | 640×480, 16 colors | "God's covenant of perfection" — deliberate constraint |

### HolyC as Shell

The critical insight: **the shell IS the compiler**. When you type `5+7` at the prompt, it's compiled and executed. When you type `Dir;`, it compiles and runs the `Dir()` function. There is no separate "scripting language" vs "system language" — they are identical.

- `#include` from command line = run a program (JIT compiled on demand)
- F5 in editor = compile + run + stay in REPL within your task's namespace
- `Uf("Foo")` = disassemble function, with hyperlinked symbols in the shell
- System-wide autocomplete (Ctrl-F1) across all source code
- No `main()` — top-level code executes as the compiler processes it

The compiler processes **50,000 lines per second**. Combined with the JIT architecture, this means "compilation" and "interpretation" are the same act.

### The Theology

Terry Davis described TempleOS as "God's third temple" — a 640×480 covenant. The theology maps to computation:
- **Ring 0 = direct communion**: No abstraction layers between programmer and machine
- **Oracle (`God()` function)**: Random word generator, "God talks through randomness"
- **Hymns**: Playable music integrated into the OS via PC speaker
- **Simplicity as divine**: Commodore 64-level directness as spiritual ideal

---

## 3. nanoclj-zig: The Actual Boot Sequence

### Source: `/Users/bob/i/nanoclj-zig/src/main.zig`

### Boot Sequence (from `pub fn main()` to REPL ready)

```
1. ALLOCATOR INIT
   └─ compat.makeDebugAllocator() → general purpose allocator

2. GARBAGE COLLECTOR INIT
   └─ GC.init(allocator)
   └─ Worklist-based mark-sweep (gc.zig, 291 lines)
   └─ String interning table (StringHashMap → u48 IDs)

3. ROOT ENVIRONMENT
   └─ Env.init(allocator, null) → lexical scope chain
   └─ env.is_root = true

4. CORE BUILTINS REGISTRATION (core.zig, 4364 lines)
   └─ core.initCore(&env, &gc)
   └─ Registers 195+ builtins into builtin_table (StringHashMap)
   └─ Categories:
      ├─ Arithmetic: +, -, *, /, mod, inc, dec
      ├─ Comparison: =, <, >, <=, >=
      ├─ Collections: list, vector, hash-map, first, rest, cons, count, nth, get, assoc, conj
      ├─ Predicates: nil?, number?, string?, keyword?, symbol?, list?, vector?, map?, fn?, empty?, set?, seq?
      ├─ String ops: str, subs, split, join, replace, index-of, starts-with?, ends-with?, trim, upper-case, lower-case
      ├─ IO: println, pr-str, read-string, load-file
      ├─ Higher-order: apply, take, drop, reduce, range, map, filter, concat, reverse, into
      ├─ GF(3) trit arithmetic: gf3-add, gf3-mul, gf3-conserved?, trit-balance
      ├─ Color/substrate: color-at, color-seed, colors, hue-to-trit, mix64
      ├─ Tree VFS (Forester): 12 builtins for mathematical forest
      ├─ Interaction nets: inet-new, inet-cell, inet-wire, inet-reduce, inet-compile, inet-eval
      ├─ Partial evaluation: peval (first Futamura projection)
      ├─ miniKanren: run*, run, fresh (logic programming)
      ├─ Pattern matching: re-match, peg-match, match-all
      ├─ IBC/crypto: ibc-denom, ibc-trit, noble-usdc-on
      ├─ Church-Turing: ill-posed
      ├─ HTTP: http-fetch
      ├─ BCI: bci-channels, bci-read, bci-trit, bci-entropy
      └─ Jepsen: linearizability testing builtins

5. PARTIAL EVALUATION (First Futamura Projection)
   └─ peval.pevalEnv(&env, &gc)
   └─ Constant bindings collapsed through interaction net at startup

6. WORLD IDENTITY
   └─ Read $USER env var → world_name
   └─ SplitMix64 hash of world_name → world_seed
   └─ Bind *world* and *seed* into environment

7. GORJ SESSION INIT
   └─ gorj_bridge.initSession(world_seed)

8. COLOR STRIP BANNER
   └─ Print "nanoclj-zig v0.1.0" + GF(3) trit wheel + named color strip

9. BYTECODE VM INIT
   └─ bc.VM.init(&gc, 100_000_000)  — 100M fuel ticks
   └─ 22-opcode register-based VM (32-bit fixed-width instructions)
   └─ Opcodes: ret, jump, jump_if, load_nil/true/false/int/const,
   │           add, sub, mul, div, quot, rem, eq, lt, lte,
   │           call, tail_call, closure, move, get_upvalue,
   │           get_global, set_global, cons, first, rest, make_list, count, nth
   └─ WASM-targetable (no OS-specific calls in VM loop)

10. MACRO PRELUDE (loaded as tree-walk eval'd Clojure source)
    └─ loadMacroPrelude(&env, &gc)
    └─ 13 macros defined:
       when, when-not, cond, ->, ->>, and, or, doto,
       if-let, when-let, run*, run, fresh

11. BYTECODE PRELUDE (compiled to bytecode, stored as VM globals)
    └─ loadBcPrelude(&gc, allocator, &vm, &env)
    └─ 9 HOFs: reverse, map, filter, reduce, range, take, drop, concat, apply

12. REPL LOOP
    └─ Prompt: "{world_name}=> "
    └─ Multi-line support (paren balancing)
    └─ Dispatch:
       ├─ (quit)/(exit) → exit
       ├─ (colors)/(wheel)/(gap) → color strip rendering
       ├─ (bc <expr>) → bytecode compile + VM execute
       ├─ (bench <expr>) → tree-walk vs bytecode comparison
       ├─ (time-bc <expr>) → bytecode timing
       ├─ (disasm <expr>) → bytecode disassembly
       └─ default → fuel-bounded tree-walk eval (semantics.evalBounded)
```

### Eval Architecture (3 semantic layers)

| Layer | File | Purpose |
|-------|------|---------|
| Denotational | `transclusion.zig` | What an expression *means* (⟦·⟧) |
| Operational | `transduction.zig` | How it *executes* (fuel-bounded) |
| Structural | `transitivity.zig` | Equality, GF(3) trits, soundness checks |

Soundness invariant: `denote(val) == evalBounded(val)` for all values.

### Special Forms in eval.zig

The tree-walk evaluator handles **~35 special forms**:
`quote`, `def`, `let*`, `if`, `do`, `fn*`, `defn`, `deftest`, `testing`, `ns`, `in-ns`, `defmacro`, `macroexpand-1`, `defmulti`, `defmethod`, `defprotocol`, `extend-type`, `->`, `->>`, `some->`, `some->>`, `as->`, `doto`, `for`, `doseq`, `dotimes`, `loop`, `when-let`, `if-let`, `when-not`, `if-not`, `cond->`, `cond->>`, `condp`, `case`, `letfn`, `colorspace`, `blend`, `try`, `throw`, `recur`

### Value Representation

NaN-boxed 64-bit values (no allocation for primitives):
```
Float:    valid IEEE 754 double
Tagged:   0x7FF8 | tag(3 bits) | payload(48 bits)

tag=0  nil          tag=1  boolean       tag=2  integer (inline i48)
tag=3  symbol       tag=4  keyword       tag=5  string (interned ID)
tag=6  heap object → list | vector | map | set | fn | macro | bc_closure | ...
```

15 heap object kinds including: `list`, `vector`, `map`, `set`, `function`, `macro_fn`, `atom`, `bc_closure`, `lazy_seq`, `partial_fn`, `multimethod`, `protocol`, `dense_f64`, `trace`.

---

## 4. Comparative Analysis: The Boot Pathway

### Primitive Count Progression

| System | Primitives | Bytes | Boot Target |
|--------|-----------|-------|-------------|
| **SectorLisp** | 8 (car, cdr, cons, atom, eq, quote, cond, lambda) | 436 | BIOS → REPL |
| **HolyC/TempleOS** | Full C + extensions + JIT | ~120,000 LOC | BIOS → JIT shell |
| **nanoclj-zig** | 195+ builtins + 35 special forms + 22 bytecode ops + 13 macros | ~8,000 LOC Zig | OS process → REPL |

### What is the MINIMAL evaluator needed to bootstrap a Clojure?

**SectorLisp gives the lower bound**: 8 primitives + `eval` + `apply` + `evcon` + `evlis` + `pairlis` + `assoc` = a complete Lisp in 436 bytes. From this, you can build everything else in Lisp itself (the metacircular evaluator proves this).

**nanoclj-zig's actual kernel** is larger because Clojure requires:
1. **Rich literal syntax**: vectors `[]`, maps `{}`, sets `#{}`, keywords `:kw`, strings — SectorLisp has only atoms and lists
2. **Persistent data structures**: Clojure's identity model requires structural sharing — SectorLisp uses mutable cons cells
3. **Numeric tower**: integers, floats — SectorLisp has no numbers at all
4. **String operations**: Clojure is practical; SectorLisp is purely symbolic
5. **Macros**: `defmacro` with code-as-data — SectorLisp has lambda only
6. **Namespaces/modules**: Clojure's `ns` system — SectorLisp has a single flat namespace

The **irreducible Clojure kernel** would need approximately:
- SectorLisp's 8 + `def` + `let*` + `if` + `do` + `fn*` + `defmacro` + `loop/recur` = **~15 special forms**
- Minimal builtins: `+`, `-`, `*`, `/`, `=`, `<`, `cons`, `first`, `rest`, `count`, `list`, `vector`, `hash-map`, `assoc`, `get`, `str`, `println`, `nil?`, `keyword`, `symbol`, `read-string` = **~20 builtins**
- Everything else (threading macros, `when`, `cond`, `and`, `or`, `map`, `filter`, `reduce`) can be bootstrapped from macros and functions written in Clojure itself.

### Pathway: SectorLisp's 8 Primitives → nanoclj-zig's 195+ Builtins

```
Layer 0: McCarthy's 8 primitives (SectorLisp)
  car, cdr, cons, atom, eq, quote, cond, lambda
  │
  ├─ + eval, apply, evcon, evlis, pairlis, assoc
  │   = Complete Lisp (metacircular evaluator possible)
  │
Layer 1: Scheme additions
  │ + define, set!, if (replaces cond), begin (= do)
  │ + numbers (integer, float), strings, booleans
  │ + arithmetic: +, -, *, /
  │ + comparison: <, >, <=, >=
  │   = Minimal practical Lisp
  │
Layer 2: Clojure structural
  │ + let*, fn*, def, defn, loop/recur
  │ + vectors [], maps {}, sets #{}, keywords
  │ + persistent data structures (structural sharing)
  │ + NaN-boxed values (nanoclj-zig's representation)
  │ + destructuring: [a b & rest], {:keys [x y]}
  │   = Minimal Clojure
  │
Layer 3: Clojure macro system
  │ + defmacro, macroexpand-1
  │ + Bootstrap: when, when-not, cond, and, or
  │ + Threading: ->, ->>, some->, some->>
  │ + Control: if-let, when-let, doto, for, doseq, dotimes
  │   = nanoclj-zig's macro prelude (13 macros)
  │
Layer 4: Higher-order functions
  │ + map, filter, reduce, reverse, range, take, drop, concat
  │ + apply, partial, comp, juxt
  │   = nanoclj-zig's bytecode prelude (9 HOFs)
  │
Layer 5: Domain builtins (nanoclj-zig specific)
  │ + GF(3) trit arithmetic, color substrate
  │ + Interaction nets (Lamping/Lafont)
  │ + Forester mathematical forest (12 tree-vfs builtins)
  │ + miniKanren logic programming
  │ + Partial evaluation (first Futamura projection)
  │ + Bytecode VM (22-opcode register machine)
  │ + Protocols, multimethods
  │ + IBC denominations, HTTP fetch, BCI, Jepsen
  │   = Full nanoclj-zig (195+ builtins)
```

### HolyC "JIT as Shell" vs nanoclj-zig "Eval as REPL"

| Aspect | HolyC | nanoclj-zig |
|--------|-------|-------------|
| **Compilation** | JIT to x86-64 machine code | Tree-walk eval + optional bytecode VM |
| **Shell** | The compiler IS the shell | The evaluator IS the shell |
| **Type at prompt** | C expressions compiled & executed | Clojure s-expressions evaluated |
| **No main()** | Top-level code runs immediately | Top-level code runs immediately |
| **Namespace** | Global symbol table (runtime) | Lexical scope chain + global env |
| **Fuel/safety** | None (ring 0, crash = crash) | Fuel-bounded + depth-bounded eval |
| **Metacircular** | Not pursued | Possible (Clojure-in-Clojure via macros) |
| **Boot** | BIOS → kernel → JIT → shell | OS → allocator → GC → env → builtins → peval → REPL |

The fundamental parallel: both systems eliminate the distinction between "compile time" and "run time." In HolyC, typing at the shell feeds the JIT compiler. In nanoclj-zig, typing at the REPL feeds the evaluator. The key difference is that HolyC compiles to native code (fast, unsafe), while nanoclj-zig evaluates through a bounded semantic layer (slower, safe).

### What Would "SectorClojure" Look Like in 512 Bytes of Zig?

A hypothetical 512-byte Clojure in Zig would need to sacrifice most of what makes Clojure Clojure:

**What you'd keep** (from SectorLisp's template):
- `cons`, `car`/`first`, `cdr`/`rest`, `atom?`, `eq`
- `quote`, `if`, `lambda`/`fn*`
- A reader that handles `()` only (no `[]`, `{}`, `#{}`)
- An eval/apply pair

**What you'd lose**:
- All data structures except lists (no vectors, maps, sets)
- All numbers (encode as Church numerals or symbols)
- All strings (atoms only, like SectorLisp)
- Keywords, namespaces, destructuring
- Macros (implement in the metacircular evaluator layer)
- Garbage collection (or: use SectorLisp's 40-byte ABC collector adapted to Zig)
- Fuel bounding (trust the user, like SectorLisp does)

**Estimated size**: Zig compiles to native code with zero runtime overhead. A minimal eval+apply+read+print+GC in Zig targeting x86 freestanding could plausibly fit in 512 bytes, since:
- Zig's `@import("std")` is not needed (freestanding)
- NaN-boxing is unnecessary (just use 16-bit words like SectorLisp)
- The GC is 40 bytes in x86 assembly; Zig would emit similar
- The challenge: Zig's codegen may emit larger instruction sequences than hand-tuned x86 assembly. SectorLisp exploits overlapping functions and variable-length x86 encoding tricks that a compiler cannot.

**Realistic estimate**: ~1KB in Zig (vs 436 bytes hand-assembled). A 512-byte version would likely require inline assembly for the critical path, making it "Zig-flavored assembly" rather than pure Zig.

---

## 5. Key Insights

### 1. The Eval Bottleneck
SectorLisp proves that `eval` is the irreducible kernel. Everything else — macros, data structures, standard library — is sugar built on top. nanoclj-zig's 195+ builtins are performance optimizations and ergonomic additions to what could theoretically be 8 primitives.

### 2. The Bootstrap Ladder
```
SectorLisp (8 primitives, 436 bytes)
  → can run its own metacircular evaluator
    → which can implement define, numbers, strings
      → which can implement macros
        → which can implement Clojure's standard library
          → which is what nanoclj-zig pre-loads at startup
```

nanoclj-zig's boot sequence (steps 4-11 in the sequence above) is the **materialization of this bootstrap ladder** in Zig, hardcoded for performance rather than derived from first principles.

### 3. The JIT Parallel
HolyC and nanoclj-zig both eliminate the compile/run boundary, but at different levels:
- HolyC: `source text → machine code → execute` (no intermediate representation)
- nanoclj-zig tree-walk: `source text → AST → walk` (no compilation)
- nanoclj-zig bytecode: `source text → AST → bytecode → VM execute` (two-phase, like Java)

SectorLisp is purest: `source text → cons cells → eval` (the AST IS the data structure IS the code).

### 4. Safety vs Power Tradeoff
| System | Safety Model | Consequence |
|--------|-------------|-------------|
| SectorLisp | None (bare metal, no GC in v1) | Can crash, but also: perfect simplicity |
| SectorLisp v2 | GC only (ABC collector) | Memory safe, still no bounds checking |
| HolyC | None (ring 0, no protection) | "Motorbike" — lean too far, you fall off |
| nanoclj-zig | Fuel-bounded + depth-bounded + type-checked | Guaranteed termination, safe for untrusted code |

### 5. The Futamura Connection
nanoclj-zig's startup includes a **first Futamura projection** (partial evaluation of constant bindings through the interaction net). This is conceptually the same operation as SectorLisp's interning — collapsing known values at load time so eval doesn't have to recompute them. The difference is that nanoclj-zig does it through Lamping/Lafont optimal reduction, while SectorLisp does it through a simple string table.

---

## 6. Summary Table

| Dimension | SectorLisp | HolyC/TempleOS | nanoclj-zig |
|-----------|-----------|----------------|-------------|
| **Size** | 436 bytes | ~120K LOC | ~8K LOC |
| **Language** | i8086 assembly | HolyC (C variant) | Zig |
| **Boot from** | BIOS (bare metal) | BIOS (bare metal) | OS process |
| **Eval model** | Recursive eval/apply | JIT to native | Tree-walk + bytecode VM |
| **GC** | ABC (40 bytes, copying) | Manual (ring 0) | Mark-sweep (worklist) |
| **Values** | Atoms + cons cells | C types + classes | NaN-boxed 64-bit (15 types) |
| **Data structures** | Lists only | C structs/arrays | Lists, vectors, maps, sets, keywords |
| **Metacircular** | Yes (40 lines LISP) | No | Possible via macros |
| **Safety** | None | None (ring 0) | Fuel + depth bounded |
| **Primitives** | 8 | Full C + OS API | 195+ builtins + 35 special forms |
| **Time to REPL** | ~10ms (on 4.77MHz 8088) | ~1s | ~1ms (modern hardware) |
| **Prelude** | None (everything from scratch) | Kernel scripts | 13 macros + 9 bytecode HOFs |
| **Key insight** | Eval IS the language | Compile IS the shell | Three semantic layers agree |
