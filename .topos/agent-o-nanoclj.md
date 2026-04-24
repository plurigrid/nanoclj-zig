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
