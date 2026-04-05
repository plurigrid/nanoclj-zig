{:name "tropical-algebra"
 :description "Min-plus semiring for shortest-path and cost optimization problems. Use when computing shortest paths, resource allocation, or schedule optimization."
 :trit -1}
---

# Tropical Algebra

## When to use
Use this skill when the user needs shortest-path computation, schedule optimization,
or any min-plus algebraic operation.

## Builtins
- `(tropical-add a b)` — tropical addition = min(a, b)
- `(tropical-mul a b)` — tropical multiplication = a + b
- `(tropical-add a Inf)` = a (Inf is the additive identity)
- `(tropical-mul a Inf)` = Inf (Inf is the absorbing element)

## Examples

```clojure
;; Shortest path: min of two distances
(tropical-add 3 5)  ;=> 3

;; Path composition: sum of edge weights
(tropical-mul 3 5)  ;=> 8

;; Identity elements
(tropical-add 3 ##Inf)  ;=> 3
(tropical-mul 3 ##Inf)  ;=> ##Inf
```

## Edge cases
- Both operands Inf → Inf (no path exists)
- Negative weights are valid (tropical semiring over reals)
