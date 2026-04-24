# Picture Languages Kernel

`nanoclj-zig` now has a small monoidal-diagram kernel in [`src/monoidal_diagram.zig`](../src/monoidal_diagram.zig). The goal is not to implement every graphical language as a separate runtime. The goal is to give them a common typed substrate so multiple notations can lower into one validator and one normalizer.

## What It Covers

The current kernel handles the shared symmetric-monoidal core:

- `:id`
- `:box`
- `:spider`
- `:swap`
- `:seq`
- `:tensor`

That is enough to host a first implementation layer for:

- plain string diagrams
- signal-flow style boxes
- tensor-network style generators
- open-games style forward/backward boxes
- ZX-like spider syntax

It does not yet model compact closure, cups/caps, trace/feedback, or proof-net specific duality. Those are the next extensions once the current IR has real use.

## Runtime Shape

Diagrams are plain Clojure maps and vectors.

```clojure
{:tag :box
 :name "f"
 :dom [:A]
 :cod [:B]}

{:tag :seq
 :parts [d1 d2 d3]}

{:tag :spider
 :wire :q
 :ins 2
 :outs 1
 :attrs {:phase 1/2 :color :green}}
```

The Zig side checks typing and rewrites nested `:seq`/`:tensor` trees into a normalized form.

## Builtins

```clojure
(diagram-id [:A :B])
(diagram-box "f" [:A] [:B])
(diagram-spider :q 2 1)
(diagram-swap [:A] [:B :C])
(diagram-seq d1 d2 d3)
(diagram-tensor d1 d2 d3)
(diagram-well-typed? d)
(diagram-normalize d)
(diagram-summary d)
(open-game-profile)
(open-game-parity)
(open-game-decision "move" :alice [:cooperate :defect] opts)
(open-game-decision-no-obs "move" :alice [:cooperate :defect] opts)
(open-game-dependent-decision "move" :alice [:rain :sun] [:umbrella :none] opts)
(open-game-forward-function "f" [:X] [:Y] opts)
(open-game-backward-function "k" [:Y] [:R] opts)
(open-game-from-functions "lens" [:X] [:Y] opts)
(open-game-nature "weather" dist opts)
(open-game-lift-stochastic "weather" dist opts)
(open-game-discount "gamma" 0.95 opts)
(open-game-add-payoffs "bonus" {:alice 2} opts)
(open-game-seq g1 g2 g3)
(open-game-tensor g1 g2 g3)
(open-game-diagnostics d-or-trace)
(open-game-is-equilibrium? d-or-trace)
(play d)
(evaluate d)
```

`diagram-summary` returns a map like:

```clojure
{:ok true
 :kind :seq
 :dom [:A]
 :cod [:C]
 :nodes 2
 :depth 2
 :normalized {...}}
```

If typing fails, it returns:

```clojure
{:ok false
 :error "domain-mismatch"}
```

`play` and `evaluate` are now the first open-game runtime bridge from the
`.topos` seed profile into the evaluator. They still operate on the shared
diagram kernel, but the explicit `open-game-*` constructors lower into that
kernel and preserve enough metadata for best-response diagnostics when you
provide explicit payoff tables.

`open-game-parity` reports the currently available, partial, and missing
pieces relative to the `open-game-hs` / `open-game-engine` surface.

## Open-Game Parity Slice

The current parity layer focuses on the part of `open-game-hs` that fits the
existing Zig evaluator cleanly:

- atomic constructors for decisions, dependent decisions, forward/backward
  functions, nature, stochastic lifts, discounts, and payoff adjustments
- sequential and simultaneous composition aliases on top of `diagram-seq`
  and `diagram-tensor`
- seeded `play` traces
- `evaluate` / `open-game-diagnostics` best-response checks for games with
  explicit payoff tables

Example:

```clojure
(let [pricing
      (open-game-decision-no-obs
        "pricing"
        :firm
        [:low :high]
        {:payoff-table [{:action :low  :payoff 1}
                        {:action :high :payoff 3}]})
      trace
      (play pricing {:strategies {:firm :low}})
      report
      (evaluate trace)]
  {:equilibrium? (:equilibrium? report)
   :diagnostics  (:diagnostics report)})
```

`open-game-discount` and `open-game-add-payoffs` compose with `open-game-seq`,
so explicit payoff tables can be transformed before diagnostics are reported.

## Why This Shape

The common mistake in “implement every diagram language” projects is to encode each notation directly. That creates five IRs, five validators, and five incompatible extension stories. This kernel goes the other direction:

1. Lower each frontend language into a shared monoidal IR.
2. Validate and normalize once.
3. Attach semantics later via functors or interpreters.

That gives us one place to add:

- traced monoidal structure
- compact closure
- Frobenius algebras
- linear logic proof nets
- tensor contraction semantics
- optics and open-game coplay channels

## Mapping Sketches

### String diagrams

Direct encoding:

```clojure
(diagram-seq
  (diagram-box "f" [:A] [:B])
  (diagram-box "g" [:B] [:C]))
```

### ZX-style fragment

Spiders become `:spider`; phases ride in `:attrs`.

```clojure
(diagram-seq
  (diagram-spider :q 1 2 {:phase 1/2 :basis :z})
  (diagram-spider :q 2 1 {:phase 1/4 :basis :x}))
```

### Open games

Use product boundaries in `:dom`/`:cod`, then layer play/coplay semantics on `:attrs`.

```clojure
(diagram-box
  "pricing-game"
  [[:X :S]]
  [[:Y :R]]
  {:semantics :open-game})
```

### Tensor networks

Each tensor is a box with typed legs.

```clojure
(diagram-tensor
  (diagram-box "A" [:i :j] [:k])
  (diagram-box "B" [:k :l] [:m]))
```

## Next Extensions

The next useful steps are:

1. Add `:trace` for feedback and traced monoidal categories.
2. Add cups/caps for compact closed structure.
3. Add a rewrite-rule layer so ZX fusion, bialgebra, and flow-graph identities can be expressed as first-class rules.
4. Add a semantic interpreter interface so the same normalized diagram can target tensors, relations, circuits, optics, or games.

That sequence keeps the kernel small while still moving toward “every picture language” in a way that composes.
