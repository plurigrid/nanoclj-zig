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
Rung 0  existing primitives  already on main
  propagator.Cell, latticeMerge, scheduler
  refs_agents.{Ref,Agent,Atom}
  datalog (query engine)

Rung 1  agent/agent-node         src/agent.zig          THIS PATCH
  Agent record: id, name, fn-pointer, state Ref, trace-ptr
  agent-fn signature: (agent: *Agent, in: Value) Value
  stateless invoke helper

Rung 2  trace                    src/agent_trace.zig
  append-only event log per-invoke-id:
    {step, agent-id, in, out, ts_mono, tags}
  replayable; diff-able

Rung 3  topology + invocation    src/agent_topology.zig
  AgentNode = wraps an Agent fn + its input/output cells
  AgentTopology = DAG of AgentNodes via propagator edges
  invoke(topo, input) -> {output, trace_id}

Rung 4  evaluator                src/agent_eval.zig
  Individual(score fn):   Value -> f32
  Comparative(pref fn):   (Value, Value) -> {-1, 0, 1}
  Summary(agg fn):        []Value -> f32

Rung 5  dataset + experiment     src/agent_dataset.zig
                                  src/agent_experiment.zig
  Dataset = EDN/JSON file of {input, expected?, tags}
  Experiment = (topology, dataset, []evaluator) -> Report

Rung 6  persistence + streaming  src/agent_store.zig
                                  src/agent_stream.zig
  PState-like store over refs + diskio
  AgentStream for streaming invocation events

Rung 7  human feedback           src/agent_feedback.zig
  side-channel input queue
  invocation pauses on `hi-request` cell until feedback Ref writes
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

## 5. Success criterion

Once Rung 5 lands, the equivalent of agent-o-rama's
`examples/clj/src/com/rpl/agent/e2e_test_agent.clj` should run on nanoclj-zig:

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
