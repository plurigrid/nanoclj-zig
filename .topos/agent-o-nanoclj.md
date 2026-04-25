# agent-o-nanoclj: agent-o-rama primitives in nanoclj-zig

**Purpose:** port the architecture of `redplanetlabs/agent-o-rama` into nanoclj-zig
so that agents/topologies/evaluators/experiments run on top of the existing
propagator + refs/agents + datalog substrate.

**Upstream reference:** `redplanetlabs/agent-o-rama@5829853f` (2026-04-15),
newly synced to `bmorphism/agent-o-shiva`.

---

## 1. Abstraction mapping

| agent-o-rama                       | nanoclj-zig substrate                         | status     |
|------------------------------------|-----------------------------------------------|------------|
| `agent-topology` (module container) | `propagator.Network` + new `agent_topology`   | partial    |
| `new-agent` (declared agent)        | `refs_agents.Agent` + metadata                | extend     |
| agent **node** (unit of comp)       | Propagator `Cell` + nanoclj fn closure        | wrap       |
| `AgentInvoke` (single run)          | cell-activation run + trace buffer            | new        |
| `AgentGraph` / `AgentTopology`      | DAG of agent-nodes via propagator edges       | new        |
| `AgentStream` (streaming results)   | event-stream over scheduler                   | new        |
| `PState` store                      | `refs_agents.PState` (refs-backed)            | new type   |
| key-value store                     | `refs_agents.Kv` + `diskio` backend           | new        |
| document store                      | JSON via `diskio` + schema check              | new        |
| evaluator (scalar score)            | Cell fn reading outputs → score cell          | —          |
| comparative evaluator               | Pair-Cell fn: `(a,b) → preference`            | —          |
| summary evaluator                   | Aggregator Cell over invocation batch         | —          |
| **dataset**                         | EDN/JSON at rest + lazy-loaded `Cell[]`       | new        |
| **experiment**                      | batch of invocations + eval cells over dataset| new        |
| **human feedback**                  | side-channel input Cell + queue               | new        |
| **trace**                           | append-only log of cell activations per-invoke| new        |

---

## 2. Minimal v0.1 implementation ladder

The implementation is layered so each rung passes `zig build test` before the
next one is added.

```
Actual shipped state (as of commit cbfc2e90, 64/64 aor tests):

Rung 0  existing primitives  already on main
  propagator.Cell, latticeMerge, scheduler
  refs_agents.{Ref,Agent,Atom}
  datalog (query engine)

Rung 1  Agent primitive         src/aor_agent.zig        8 tests
  Agent{id, name, body: *fn(ctx, input) !Value, ?state, ?trace_slot}
  invoke / invokeStateless / withState

Rung 2  Trace store             src/aor_trace.zig        8 tests
  TraceEvent{invoke_id, step, agent_id, agent_name, input, ?output,
             ts_mono, tags}
  TraceStore.startInvocation / recordStep / completeStep /
            getInvocation / eventCount

Rung 3  Topology + invoke       src/aor_topology.zig     9 tests
  Topology.newAgent / connect / getAgent
  invoke(topo, trace, start, input) → {final, invoke_id}
  synchronous DFS, cycle cap 1024

Rung 4  Evaluator trio          src/aor_eval.zig         7 tests
  individual(name, f): Value → f32
  comparative(name, f): (Value,Value) → {a-better, tie, b-better}
  summary(name, f): []Value → f32
  scoreOne / scorePair / scoreMany / scoreInvocationSteps

Rung 5a Dataset                 src/aor_dataset.zig      2 tests
  Example{input, ?expected, tags}
  Dataset.init / addExample / len

Rung 5b Experiment              src/aor_experiment.zig   4 tests
  Experiment(topo, trace, dataset, evaluators, start)
  run() → Report{total, pass_count, fail_count, examples, passRate}
  Configurable PassFn predicate

Rung 7  Feedback closure        src/aor_feedback.zig     8 tests
  cycleUntil(single target, user predicate)
  cycleUntilMulti(N targets, shared verdict stream)
  cycleUntilFixedPoint(halt when no agent wants to revise)
  CycleResult.passRateTrajectory / lastDelta / isDiverging(window)

Rung 8  Tools                   src/aor_tool.zig         5 tests
  Tool{name, description, invoke: fn(Value) !Value}
  ToolRegistry.register / get / call / count

Rung 9  Actions + ActionLog     src/aor_action.zig       5 tests
  Action{name, description, body: fn(RunInfo) !ActionResult}
  RunInfo{invoke_id, input, output, latency_ns, step_count}
  ActionLog.forInvocation / runActionsOnInvocation

Rung 10 Telemetry               src/aor_telemetry.zig    6 tests
  Sample{ts_ns, value, tags} / Series / Aggregate
  TelemetrySink.record / aggregate(window) / aggregateAll /
                 ingestVerdicts / ingestRunInfo

Rung 6  persistence + streaming DEFERRED (strictly additive;
                                          loop closes without it)
  Would swap in-memory TraceStore/ActionLog/TelemetrySink for
  disk-backed appenders + streaming subscription hooks.
```

## 3. Wire plumbing

Each rung is added as a `b.addModule(...)` in build.zig and test-gated through
the default `test_step`. This matches the pattern used for the 8 novel
ocapn_* / holy / backward_fiber files integrated earlier this session.

## 4. What we're deliberately NOT porting

- **Java topology** — agent-o-rama has a parallel Java API (`TinyJavaTopologyExample`).
  nanoclj-zig stays Clojure-flavored; no JVM interop.
- **Web UI (cljs)** — 500+ LOC of ClojureScript UI is out of scope. Inspection
  happens via nanoclj REPL + trace queries.
- **Tailwind build pipeline** — #282-then-reverted CDN-vs-buildtime churn is
  irrelevant; no web UI means no stylesheet.
- **Rama-specific dataflow** — agent-o-rama inherits Rama's PState + ETL
  topology model. We rebuild on the lighter propagator substrate.

## 5. Closure — the ultimate feedback loop

Not a demo, not a showcase: Rungs 5 + 7 together are the **world** in which
invocation → evaluation → revision runs as one closed cycle. An agent whose
own state reads its verdict history can **re-plan itself** — which is what
the evaluator/experiment/feedback trio is for.

The primitive cycle after Rung 7:

```
  Agent → invoke → Trace → Evaluator → Verdict → FeedbackSink →
                                                        ↓
         Agent.state  ←  revise(prior_state, verdicts)  ←┘
```

Once both Rung 5 (experiment/dataset) and Rung 7 (feedback) are on main,
the loop is closed inside a single nanoclj runtime — no external
orchestrator. That is the target.

The Clojure-equivalent before-picture (reference only):

```clojure
(let [topo (-> (agent-topology)
               (new-agent :summarize (summarizer-fn))
               (new-agent :score (scorer-fn)))
      ds (load-dataset "test-summaries.json")
      exp (experiment topo ds [(individual-evaluator :score)])]
  (run-experiment exp))
;; → {pass-count …, fail-count …, traces …, scores …}
```

That's a working agent-evaluation harness entirely on nanoclj-zig primitives.

---

## 6. Permanent extension via SDF principles

The loop core is structured for accretion, not modification. Three SDF
moves anchor this — one shipped, two staged.

### 6.1 Skill — generic dispatch on Clojure-callable name (SHIPPED)

`src/loop/skill.zig` defines:

```zig
pub const Skill = struct {
    name: []const u8,
    doc:  []const u8,
    body: SkillFn,   // *const fn ([]Value, *GC, *Env, *Resources) anyerror!Value
};
pub fn combine(comptime a: []const Skill, comptime b: []const Skill) []const Skill;
pub fn lookup (skills: []const Skill, name: []const u8) ?*const Skill;
```

Each `loop/*.zig` submodule declares `pub const skills: []const Skill = &.{...}`.
The umbrella `loop.zig` folds them under `skill.combine`. `core.zig` does
**one** `inline for (loop.skills) |s| { … }` block — adding a new
Clojure-callable is a one-edit affair (touch only the relevant submodule).

This is the SDF move ("predicate-dispatched generics with attached doc",
*Software Design for Flexibility* ch. 3): handlers are first-class data,
combined under a monoid, looked up by predicate.

The categorical anchor is `goblins-adapter/propagator-nash.scm:140`'s
`merge-with-law`: a layered handler keyed by a discriminator. Same shape.

**Adding a skill recipe:**

```zig
// in src/loop/<your-rung>.zig
const skill_lib = @import("skill.zig");
const Skill = skill_lib.Skill;

pub fn myThingFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    // …
}

pub const skills = [_]Skill{
    .{ .name = "loop-my-thing",
       .doc  = "(loop-my-thing arg1 arg2) — short docstring",
       .body = myThingFn },
};
```

Then in `src/loop.zig`:

```zig
pub const skills: []const Skill = skill.combine(
    &builtins.skills,
    &@import("loop/your-rung.zig").skills,
);
```

That is the entire commit. No edit to `core.zig`. No edit to anything else.

### 6.2 Verdict — tagged-union polymorphism (SHIPPED)

`Verdict` was monomorphic `{ evaluator_name, score: f32 }`. Now a
tagged union over five variants in `src/loop/eval.zig`:

- `.scalar`   — Rung 4 (today): `{ evaluator_name, score: f32 }`
- `.trit`     — Rung 5: `{ evaluator_name, trit: i2 }` for GF(3) gates
- `.vector`   — Rung 6: `{ evaluator_name, steps: []const f32 }` for MAGICORE PRM
- `.record`   — Rung 5+: `{ evaluator_name, score: f32, feedback: []const u8 }` for Evaluator-Optimizer
- `.semantic` — Rung 8: `{ evaluator_name, gradient: []const u8 }` for ProTeGi

Three dispatching methods on the union:

```zig
pub fn name         (self: Verdict) []const u8;     // → evaluator_name
pub fn primaryScore (self: Verdict) f32;            // variant-specific projection
pub fn passes       (self: Verdict, threshold: f32) bool;
```

`primaryScore` is defined per variant (no `default`) so a future Rung
that demands a different projection has to think about it explicitly.
`passes` short-circuits on `.semantic` — the natural-language gradient
itself decides revision direction, so a scalar threshold is meaningless
for that variant.

All existing scalar consumers migrated to the dispatch methods (`v.score`
→ `v.primaryScore()`, `v.evaluator_name` → `v.name()`). Construction goes
through `Verdict.makeScalar(name, score)` for the legacy shape. Seven
new tests pin the contract on each variant; `experiment.zig`,
`feedback.zig`, `telemetry.zig`, `world_test.zig` all migrated cleanly.

### 6.3 cycle — combinator unification of cycleUntil* (PARTIALLY SHIPPED)

`src/loop/cycle.zig` lands the unified entry point as an additive
overlay; existing `cycleUntil*` and `cycleByGradient` keep their
signatures and tests, and will reduce to 3-line wrappers as the
combinator absorbs them.

```zig
pub fn cycle(
    allocator,
    experiment: *Experiment,
    step: Step,
    stop: Stop,
    frontier: u32,    // 1 today; ≥2 reserved for beam-search/ProTeGi
    max_iters: u32,
) CycleError!Trajectory;
```

Two orthogonal union axes:

```zig
Step = union(enum) {
    revise:   ReviseSpec,    // SHIPPED — TargetRevision[] + ReviseFn each
    gradient: GradientSpec,  // declared; body returns NotImplemented
    custom:   CustomSpec,    // SHIPPED — caller-supplied closure
};
Stop = union(enum) {
    iters:       u32,        // SHIPPED — exact count
    fixed_point,             // SHIPPED — halt when no revise changes state
    pass_rate:   f32,        // SHIPPED — halt at threshold
    custom:      StopFn,     // SHIPPED — caller-supplied predicate
};
```

`Trajectory` owns its `Reports[]` plus a `stopped_on_predicate` flag
(true iff the stop axis fired vs running out of `max_iters`).

Five tests pin the contract: `.iters` runs exactly N; `.pass_rate`
halts at threshold; `.fixed_point` halts on no-op revise;
`frontier > 1` errors `NotImplemented`; `Step.gradient` errors
`NotImplemented` (until cycleByGradient is folded in).

This is *Software Design for Flexibility*'s combinator-closure pattern
(ch. 1 "Combinators"): a small set of orthogonal axes, closed under
composition, expanding the surface by parameter rather than by function
count.

**Remaining work** (each is a small, isolated edit):

1. Fold `cycleByGradient` into `Step.gradient` (≈40 LOC).
2. Implement `frontier ≥ 2` (beam-search / ProTeGi peer-pool).
3. Reduce existing `cycleUntil` / `cycleUntilMulti` / `cycleUntilFixedPoint`
   to wrappers that just construct (Step, Stop) and call `cycle`.

---

The order of operations is therefore: **Verdict polymorphism (6.2)** →
**cycle combinator (6.3)** → opens the door to MAGICORE/ProTeGi/
beam-search as ≤30-line additions per curriculum (see § curricula in
`.topos/agent-o-nanoclj-curricula.md` once landed).

---

## 7. Embarrassment ledger + skill triads

`.topos/bench/` ran at 2026-04-25T03:50Z. The most embarrassing three:

| # | Bench | Measurement | Target | Embarrassment factor |
|---|---|---|---|---|
| E1 | `fib25_nanoclj` | 79.3 ms + **54.4 MB allocated** | 0 alloc inside fib body (NaN-box) | **667× slower** than Zig + heap leak |
| E2 | `reader_1mb`    | peak_alloc 22.7 MB / src 1.05 MB = **21.7× ratio** | < 5× | reader allocates 21× input size |
| E3 | `loop_tight_n10000` | **356 ns/iter** on integer tight loop | < 50 ns native | ~7× over native |

Honorable mentions sharing E1's NaN-box-failure root cause:
`tak_18_12_6` (14 MB alloc), `ack_3_7` (155 MB alloc),
`binary_trees_d12` (75× per-node overhead).

For each embarrassment we ship a **3-skill triad** under the GF(3)
triadic-load protocol (memory: `feedback_triadic_skill_load`). Each
triad is `play(+1) + witness(0) + coplay(−1) ≡ 0 (mod 3)`. The 9 skills
land in `src/loop/bench_skills.zig` as plain `Skill` records; the §6.1
registry picks them up automatically.

| E | trit | role | skill | what it returns |
|---|---|---|---|---|
| 1 | +1 | play    | `(loop-bench-fib25-allocs)`         | 54_383_840 — the leak in bytes |
| 1 |  0 | witness | `(loop-int-trit n)`                  | n mod 3 — exercises NaN-box but says nothing about elision |
| 1 | −1 | coplay  | `(loop-bench-banner-hex)`           | 0xFF00FF — magenta, no signal |
| 2 | +1 | play    | `(loop-bench-reader-ratio-milli)`   | 21_667 — peak-alloc/src-size × 1000 |
| 2 |  0 | witness | `(loop-bench-reader-forms)`         | 43_690 — top-level forms (could/couldn't correlate) |
| 2 | −1 | coplay  | `(loop-bench-reader-mood)`          | 0 — flat mood trit |
| 3 | +1 | play    | `(loop-bench-tight-ns)`             | 356 — ns/iter |
| 3 |  0 | witness | `(loop-bench-tight-fuel)`           | 7 — fuel/iter (might dominate, might not) |
| 3 | −1 | coplay  | `(loop-bench-tight-batch)`          | 1 — bench batch count |

The play skill is the embarrassment, in literal form — call it from the
REPL, see the offending number. The witness skill is the quiet
correlate: it could implicate a cause or be noise; reading it tells you
where to sample next. The coplay skill is decorative payload; it
balances the trit budget without contributing signal, which is the
point — the GF(3) law forces every honest probe to come bundled with
its non-probe shadow.

The values are static today (captured from the run above). Future
iterations swap them for live calls into `bench/bench_util.zig`'s
harness via the same Skill records — interface stable, body changes.
That is the §6.1 promise paying off: surface stays put while the
implementation accretes.
