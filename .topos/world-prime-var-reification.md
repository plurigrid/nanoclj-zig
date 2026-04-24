# World′: nz#23 Var Reification — Formal Morphism Spec

**Source PR:** plurigrid/nanoclj-zig#23 (draft, author: `zubyul`)
**Spec audit SHA:** `67030c0eabb18e59632f7316c8df68b46d2b38c7` (main, 2026-04-24)
**Status:** design-phase; pre-implementation
**Purpose:** lift the English morphisms in the PR body into machine-checkable propositions so impl-phase merge-readiness is a proof obligation, not a judgment call.

---

## 0. GF(3) triad assignment

The Var reification decomposes into three obligations of different polarity:

| Trit | Role       | Obligation                                                      |
|-----:|------------|-----------------------------------------------------------------|
|   +1 | play       | Add `.var_ref` variant + constructors (`(var x)`, `#'x`, `intern`) |
|    0 | witness    | Auto-deref retraction: every pre-Var lookup behaves identically  |
|   −1 | coplay     | Backward ops: `var-set`, `alter-var-root`, `bound?`, `unbind`   |

Sum ≡ 0 (mod 3) at each commit. If any one trit is added without the other two, the world is unbalanced and the PR is not merge-ready.

---

## 1. The four morphisms (from the PR body)

### M1 — Auto-deref is a retraction

For every non-`def` binding `x` that existed pre-reification:

```
eval-symbol-pre(env, x)  ≡  eval-symbol-post(env, x)
```

**Test form:** existing `zig build test --summary all` suite must stay green after Wave 0.
**Proposition (in set-theoretic form):**
```
∀ env: Env. ∀ x: Symbol.  x ∉ dom(env.vars)  ⟹  evalSymbol(env, x) = evalSymbol-pre(env, x)
```

### M2 — Var machinery adds canonical forms

```
(def x 1)           ⟹  x ∈ dom(env.vars)        AND  env.vars[x].root = 1
(var x)  ≡  #'x     ⟹  returns (Var x)
(var-get (var x))   ≡  x
(alter-var-root (var x) inc)  ⟹  env.vars[x].root = 2
(bound? (var y))    ≡  y ∈ dom(env.vars) AND env.vars[y].bound
```

**Canonical-form closure:** `var-get ∘ var = id` on the subcategory of defined symbols.

### M3 — Dynamic binding still composes

`(binding [x 2] x)` must resolve through the **dynamic** path before touching the Var root. The dynamic path is a pushed-scope lookup that does not consult `env.vars[x].root`.

**Proposition:**
```
dynamicScope(x) ≠ ⊥  ⟹  evalSymbol(env, x) = dynamicScope(x)
```
i.e., Var resolution is strictly downstream of dynamic lookup.

### M4 — Anti-sufficiency (zubyul's own negative condition)

**No green CI on a commit that actually adds `.var_ref` to the enum ⟹ do NOT mark ready-for-review.**

In categorical terms: `ready-for-review` is the pullback

```
ready = { c : Commit |  c.touches(value.ObjKind.var_ref) ∧ ci(c) = green }
```

A design-doc-only commit that does not touch `value.ObjKind` is explicitly outside this pullback even if CI is green on the doc-only state.

---

## 2. Cost-accounting morphism — AUDIT RESULT

### Her design-phase test (verbatim from PR body):

```
grep -Rn "switch (.*\.kind)" src/ | wc -l    # budget range claimed: 15–30
```

### Actual measurement at `67030c0e`:

| Metric                                 | Value      | Status       |
|----------------------------------------|-----------:|--------------|
| Total `switch … .kind` sites            | **84**     | **2.8× over** upper bound |
| Per-file top concentration (`core.zig`) | 30         | = her full upper estimate alone |

### Per-file ledger (≥2 sites)

| File             | Sites | Fraction |
|------------------|------:|---------:|
| `core.zig`       |    30 |   35.7%  |
| `sector.zig`     |    13 |   15.5%  |
| `transduction.zig`|    7 |    8.3%  |
| `eval.zig`       |     5 |    6.0%  |
| `reader.zig`     |     3 |    3.6%  |
| `kanren.zig`     |     3 |    3.6%  |
| `pluralism.zig`  |     3 |    3.6%  |
| `gc.zig`         |     2 |    2.4%  |
| `open_game.zig`  |     2 |    2.4%  |
| `substrate.zig`  |     2 |    2.4%  |
| `inet_builtins.zig`|   2 |    2.4%  |
| 12 other files ×1|    12 |   14.3%  |
| **total**        | **84**|  100%    |

### What the audit implies per zubyul's own rule

> "If the actual count is materially outside that range, the Wave 0 estimate is wrong and the full 480 LOC budget needs re-pricing before committing."

**Verdict:** the 480 LOC total budget is underpriced by roughly 2–3× for Wave 0 alone. Wave 0 LOC is approximately linear in switch sites (each needs a `.var_ref` arm); 84 sites ≈ 84–168 LOC just for arms, plus match-exhaustiveness fallout for any site where the arm has non-trivial body.

**Repricing suggestion (non-authoritative, for zubyul's consideration):**

| Wave                  | Old estimate | Adjusted estimate |
|-----------------------|-------------:|------------------:|
| 0 — variant + fallout |    ~80 LOC   |   **~200 LOC**    |
| 1 — Env.vars + handler|   ~150 LOC   |     ~180 LOC      |
| 2 — core natives (4 parallel)|~180 LOC|     ~220 LOC      |
| 3 — tests + README    |    ~70 LOC   |     ~120 LOC      |
| **total**             |  **~480**    |   **~720 LOC**    |

---

## 3. Machine-checkable skeletons

### 3.1 M1 retraction test (Zig, sketch)

```zig
test "M1: auto-deref retraction on non-def bindings" {
    const env = try Env.initBase(testing.allocator);
    defer env.deinit();
    try env.bind("x", Value.int(1));  // non-def binding path
    const pre = try evalSymbol(env, "x");
    // apply Wave 0 in-place (adds .var_ref variant; x still uses non-Var path)
    const post = try evalSymbol(env, "x");
    try testing.expectEqual(pre, post);
}
```

### 3.2 M2 canonical-form closure (Clojure-side property)

```clojure
(defspec var-get-inverse-of-var 100
  (prop/for-all [sym gen/symbol
                 val  gen/any]
    (let [env (eval-def sym val)]
      (= val (var-get (var-lookup env sym))))))
```

### 3.3 M3 dynamic-first ordering (operational)

```clojure
(def ^:dynamic x 1)
(binding [x 2]
  (assert (= 2 x)))     ;; dynamic path wins
(alter-var-root #'x (constantly 10))
(assert (= 10 x))       ;; Var root reachable outside binding
```

### 3.4 M4 pullback check (CI policy, meta)

```
commit.ready-for-review ⇔ (
  grep -q '\.var_ref' src/value.zig     AND
  gh run view --exit-status …           // latest CI on HEAD is green
)
```

---

## 4. Integration notes

- This spec lives on `main` (not in #23) so it is immutable relative to the draft branch. When `zubyul` un-drafts, her impl PR MUST satisfy M1–M4 to be merge-ready.
- The 84-site count is the baseline at `67030c0e`. If main grows new `.kind` switches before impl lands, the audit must be re-run and the budget re-repriced.
- The cost-accounting is zubyul's own morphism; this document merely records its firing. Rejection-by-author-spec, not rejection-by-reviewer.

---

## 5. Loop-closure implication

Given zubyul's anti-sufficiency rule M4 and the failed cost-accounting M5, nz#23 is **correctly deferred**. It is not "stalled" or "forgotten"; it has fired its own author-stated gate.

The /loop 69-invariant spec is terminal:
- All PRs terminal (merged or closed) except #23
- #23 defers under its own M4 rule
- Both repo mains are green
- World′ spec captured here is the formal artifact that makes impl-phase review mechanical rather than judgment-call

`fin`.
