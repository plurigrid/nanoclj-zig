# Benchmark Research for nanoclj-zig

## Sources Surveyed
- [Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/)
- [drujensen/fib](https://github.com/drujensen/fib) — Recursive Fibonacci across 40+ languages (908★)
- [bddicken/languages](https://github.com/bddicken/languages) — In-process micro-benchmarks (1.8k★)
- [Wren performance benchmarks](https://muxup.com/2023q2/updating-wrens-benchmarks) — Interpreter-class comparisons
- [hanabi1224/Programming-Language-Benchmarks](https://programming-language-benchmarks.vercel.app/) — Cross-language benchmarks
- [rekola/nanoclj](https://github.com/rekola/nanoclj) — Original C nanoclj (the upstream)
- Existing `bench.sh` in this repo

---

## Known Timing Data for Comparable Interpreters

### Recursive Fibonacci fib(47) — drujensen/fib (Dec 2024, Intel Xeon 3.1GHz)

| Interpreter | Time (s) | Notes |
|---|---|---|
| Clojure (JVM) | 17.8 | `clojure -M fib.cljc` |
| LuaJIT 2.1 | 37.8 | JIT disabled: ~3× faster with JIT on |
| Scheme (Guile 3.0) | 102.9 | |
| Php 8.4 | 157.3 | |
| Lua 5.4 | 203.7 | |
| Ruby 3.3 | 393.6 | |
| Python 3.12 | 423.4 | |
| Janet 1.36 | 479.7 | |
| Perl 5.40 | 1490.4 | |
| Tcl 9.0 | 2230.9 | |

### Wren Interpreter Benchmarks (AMD Ryzen 9 5950X, 2023)

**Recursive Fibonacci:**

| Interpreter | Time (s) |
|---|---|
| LuaJIT 2.1 -joff | 0.055 |
| Lua 5.4 | 0.090 |
| Ruby 2.7 | 0.109 |
| Wren 0.4 | 0.148 |
| Python 3.11 | 0.157 |
| mruby | 0.185 |

**Method Call:**

| Interpreter | Time (s) |
|---|---|
| Wren 0.4 | 0.079 |
| LuaJIT 2.1 -joff | 0.090 |
| Ruby 2.7 | 0.102 |
| Lua 5.4 | 0.123 |
| Python 3.11 | 0.170 |

**Binary Trees:**

| Interpreter | Time (s) |
|---|---|
| LuaJIT 2.1 -joff | 0.073 |
| Ruby 2.7 | 0.113 |
| Python 3.11 | 0.137 |
| Lua 5.4 | 0.138 |
| Wren 0.4 | 0.144 |

### bddicken/languages — Levenshtein (Apple M4 Max, Jan 2025)

| Language | Mean (ms) | Runs in 10s |
|---|---|---|
| C | 31.9 | 314 |
| Clojure JVM | 57.3 | 175 |
| Java | 55.2 | 182 |
| Babashka | 23376.0 | 1 |

---

## Recommended Benchmarks (8 total)

### 1. Recursive Fibonacci (`fib`)
**Tests:** Function call overhead, recursion, integer arithmetic
**Why:** The single most common interpreter benchmark. Present in every benchmark suite surveyed. Directly stresses the interpreter dispatch loop.
**Standard input:** fib(35) for quick tests, fib(40) for serious benchmarks

```clojure
(def fib (fn* [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2))))))
(fib 35)  ;; => 9227465
```

### 2. Tak (Takeuchi Function)
**Tests:** Deep mutual/triple recursion, conditional branching, argument passing
**Why:** Classic Lisp benchmark since 1978. Tests function call overhead more aggressively than fib because it passes 3 args and makes 4 recursive calls per invocation.

```clojure
(def tak (fn* [x y z]
  (if (<= x y)
    z
    (tak (tak (- x 1) y z)
         (tak (- y 1) z x)
         (tak (- z 1) x y)))))
(tak 18 12 6)  ;; => 7
```

### 3. Ackermann Function
**Tests:** Extreme recursion depth, stack management, overflow handling
**Why:** Grows much faster than exponential. Tests whether the interpreter can handle very deep call stacks without crashing. Good stress test for GC under recursion.

```clojure
(def ack (fn* [m n]
  (if (= m 0)
    (+ n 1)
    (if (= n 0)
      (ack (- m 1) 1)
      (ack (- m 1) (ack m (- n 1)))))))
(ack 3 9)  ;; => 4093
```

### 4. Reduce-Sum (Iterative Accumulator)
**Tests:** Loop/recursion tail performance, integer accumulation at scale
**Why:** Measures overhead of tight loops without branching. In interpreters without TCO, tests stack depth limits. The non-recursive alternative tests `reduce` if available.

```clojure
;; Recursive version (tests stack depth)
(def sum (fn* [n]
  (if (<= n 0)
    0
    (+ n (sum (- n 1))))))
(sum 10000)  ;; => 50005000

;; Reduce version (if reduce is supported)
;; (reduce + (range 10001))
```

### 5. Binary Trees
**Tests:** Memory allocation, garbage collection pressure, tree construction/traversal
**Why:** Present in Benchmarks Game, Wren suite, and hanabi1224 suite. The definitive GC stress test. Creates millions of small objects.

```clojure
(def make-tree (fn* [depth]
  (if (= depth 0)
    (list 1 nil nil)
    (list 1
      (make-tree (- depth 1))
      (make-tree (- depth 1))))))

(def check-tree (fn* [tree]
  (if (nil? (first (rest tree)))
    (first tree)
    (+ (first tree)
       (+ (check-tree (first (rest tree)))
          (check-tree (first (rest (rest tree)))))))))

(check-tree (make-tree 15))  ;; => 65535
```

### 6. Map-Filter Pipeline
**Tests:** Higher-order function overhead, closure creation, sequence processing
**Why:** Tests the functional programming core of a Clojure interpreter. If `map`/`filter`/`reduce` are available, this is the idiomatic Clojure workload. Falls back to manual recursion.

```clojure
;; If HOFs available:
;; (reduce + (filter odd? (map (fn [x] (* x x)) (range 1 10001))))

;; Manual equivalent:
(def sum-odd-squares (fn* [n acc i]
  (if (> i n)
    acc
    (let* [sq (* i i)]
      (if (= (mod sq 2) 1)
        (sum-odd-squares n (+ acc sq) (+ i 1))
        (sum-odd-squares n acc (+ i 1)))))))
(sum-odd-squares 10000 0 1)  ;; => 166716670000
```

### 7. Levenshtein Distance
**Tests:** Nested iteration, vector/array random access, dynamic programming
**Why:** Used by bddicken/languages. The only benchmark that tests 2D array access patterns. Tests practical algorithm performance rather than pure recursion.

```clojure
(def levenshtein (fn* [s t]
  (let* [slen (count s)
         tlen (count t)]
    (if (= slen 0) tlen
      (if (= tlen 0) slen
        (let* [cost (if (= (nth s (- slen 1)) (nth t (- tlen 1))) 0 1)]
          (min
            (+ (levenshtein (subs s 0 (- slen 1)) t) 1)
            (+ (levenshtein s (subs t 0 (- tlen 1))) 1)
            (+ (levenshtein (subs s 0 (- slen 1)) (subs t 0 (- tlen 1))) cost))))))))
;; Note: recursive version is O(3^n), only suitable for small inputs
(levenshtein "kitten" "sitting")  ;; => 3
```

### 8. Startup Time (Hello World)
**Tests:** Interpreter initialization, reader/evaluator bootstrap overhead
**Why:** Critical for scripting use case. Babashka's main selling point is 10ms startup vs Clojure JVM's 300ms+. Measured wall-clock with `time`.

```clojure
(println "hello world")
```

**Reference startup times:**
| Interpreter | Startup |
|---|---|
| Lua 5.4 | ~1.4 ms |
| LuaJIT | ~1.4 ms |
| Python 3.13 | ~13 ms |
| Babashka | ~10-20 ms |
| Clojure JVM | ~300+ ms |

---

## Existing nanoclj-zig Benchmarks (from bench.sh)

The repo already tests:
- `fib(20)` → 6765
- `fib(25)` → 75025
- `sum(10000)` → 50005000

These are good quick-check benchmarks but the inputs are too small for meaningful timing comparisons. Recommend scaling up to fib(35) and adding tak/ack/binary-trees.

---

## Fastest Interpreter Baselines (targets to beat)

For a ~5K-line interpreter, the competitive field is:

| Interpreter | Size | Language | fib(35) est. | Notes |
|---|---|---|---|---|
| **LuaJIT (bytecode only)** | ~60K LOC | C | ~55ms | Gold standard for interpreter speed |
| **Lua 5.4** | ~30K LOC | C | ~90ms | Clean reference interpreter |
| **Wren 0.4** | ~12K LOC | C | ~148ms | Closest size competitor |
| **mruby** | ~50K LOC | C | ~185ms | Embedded Ruby |
| **Python 3.11** | ~400K LOC | C | ~157ms | After speedup work |
| **Janet 1.36** | ~25K LOC | C | ~480ms* | Lisp, similar target audience |
| **Guile 3.0 (Scheme)** | ~200K LOC | C | ~103ms* | Full Scheme |

(*fib(47) scaled estimates; actual fib(35) will vary)

**Realistic target for nanoclj-zig at ~5K LOC:** Between Wren and Janet speed class. If the Zig implementation can match Lua 5.4 dispatch efficiency, that would be exceptional.
