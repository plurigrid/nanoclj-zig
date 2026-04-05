{:name "color-game"
 :description "GF(3) color-trit system for depth bounding, conservation checking, and Kripke world simulation. Use for recursion budgeting, trit-balanced verification, or color-based computation gating."
 :trit 1}
---

# Color Game

## When to use
Use this skill when depth-bounding recursive computation, verifying GF(3) conservation,
or working with color-seeded deterministic processes.

## Builtins

### Tier 1: Always available (trit +1)
- `(color-at seed idx)` — deterministic color from SplitMix64
- `(color-hex r g b)` — RGB to "#RRGGBB" string
- `(mix64 n)` — SplitMix64 hash

### Tier 2: Activated on demand (trit 0)
- `(color-trit "#RRGGBB")` — hue to trit (-1/0/+1)
- `(gf3-add a b)` — GF(3) addition
- `(gf3-mul a b)` — GF(3) multiplication
- `(gf3-conserved? v)` — check if trit vector sums to 0
- `(trit-balance v)` — rebalance trit vector
- `(world-create seed)` — new Kripke world
- `(world-step w)` — advance world one step

### Tier 3: Deep resources (trit -1)
- `(depth-color depth)` — color assigned to recursion depth
- `(entropy v)` — Shannon entropy of numeric vector
- `(bisim? a b)` — bisimulation equivalence check

## GF(3) Conservation
Every operation preserves trit sum mod 3:
- gamma cells (+1) + delta cells (-1) = 0
- world-step advances trit_sum mod 3
- `(gf3-conserved? [1 0 -1])` => true (sum = 0)
