# Reified Vars — Design & Implementation Plan

**Branch**: `feat/var-reification` (off `chore/zig-0.16.0`)
**Status**: design complete, implementation pending
**Motivation**: Single highest-leverage addition to Clojure completeness. Unlocks `defonce`, `defn-`, `clojure.spec` registry, `with-local-vars`, richer `alter-var-root`, full `resolve`/`intern`/`ns-resolve`, and provides the substrate `reify` will eventually build on.

## Current state

- Reader already produces `(var x)` for `#'x` (`src/reader.zig:238`) — the form is constructed but has **no eval handler**; it currently falls through to the general apply path and errors.
- `@x` / `deref` exist (`src/core.zig:328`) but only operate on `atom` kind; there is no Var case.
- `Env` (`src/env.zig`) is flat: `bindings: StringHashMap(Value)` + fast-path `id_bindings: AutoHashMapUnmanaged(u48, Value)`. No namespace abstraction; `def` stores the raw value.
- No reified Var exists anywhere in `ObjKind` (`src/value.zig`).
- `meta`/`with-meta`/`vary-meta` are fully present and attach to `Obj`; so the Var object gets metadata for free once it is an `Obj`.

## API surface to add

### New ObjKind + data shape

```zig
// src/value.zig — ObjKind enum
.var_ref,  // reified Clojure Var: {ns, sym, value, thread_binding_stack}

// src/value.zig — ObjData union
var_ref: struct {
    ns_id: u48,             // interned ns name (e.g. "user")
    sym_id: u48,            // interned bare sym (e.g. "foo")
    root_value: Value,      // the bound value (or Value.makeNil() if unbound)
    bound: bool,            // false = declared but unbound (for (declare x))
    // thread-local binding stack lives on Env, not here — Env's dynamic_ids
    // already exists; bindings flow through env chain per ^:dynamic semantics.
},
```

`Obj.meta` already holds `^:private`, `^:dynamic`, `^:doc`, `^:arglists`, `^:file`, `^:line` — nothing new needed there.

### Env changes

```zig
// src/env.zig — Env struct (root only uses this)
vars: std.AutoHashMapUnmanaged(u48, *Obj) = .empty,  // sym_id → *Obj(var_ref)

// Namespaces: add `ns_name: u48` on Env (defaults to intern("user") on root)
ns_name: u48 = 0,
// Multi-ns support: root env holds a ns_table: AutoHashMapUnmanaged(u48, *Env)
// mapping ns_id → per-namespace Env. Keep flat model for user ns only in pass 1.
```

**Pass 1**: single `user` namespace only. Skip ns_table. `defonce`/`defn-`/`alter-var-root` all work in `user`. `ns`/`in-ns` still parse but no-op on ns switching.

**Pass 2** (separate PR): multi-ns, `ns_table`, `in-ns` actually switches, `ns-resolve` cross-ns.

### Special forms (`src/eval.zig`)

| Form | Dispatch | Behavior |
|---|---|---|
| `(var x)` | `evalVarSpecial` | Look up `env.rootEnv().vars[sym_id(x)]` → return `Value.fromObj(var_obj)`. Error `UnresolvedVar` if absent. |
| `(def x v)` | **modified** `evalDef` | If `vars[sym_id]` exists → mutate its `root_value` + merge `meta`. Else → allocate new `.var_ref` Obj, insert into `vars` AND `id_bindings` (the Var itself is the binding so `x` evaluates to the value via deref-on-lookup, see below). |
| `(defonce x v)` | new `evalDefonce` | If `vars[sym_id]` exists AND `bound == true` → return existing Var. Else → behave like `def`. |
| `(defn- x [..] ...)` | new `evalDefnDash` | Calls `evalDefn` then sets `^:private true` in the new Var's `meta`. |
| `(with-local-vars [x v ...] body)` | new `evalWithLocalVars` | Creates transient Vars scoped to the body. Defer to pass 2. |

**Important**: symbol lookup in `evalSymbol` must auto-deref Vars. Pattern:

```zig
const v = env.getById(id) orelse return error.UnresolvedSymbol;
if (v.isObj() and v.asObj().kind == .var_ref) {
    // dynamic binding lookup via env.dynamic_ids walks + thread-local stack
    if (isDynamicallyBound(id, env)) return currentBinding(id, env);
    return v.asObj().data.var_ref.root_value;
}
return v;
```

Dereferencing on symbol-eval preserves Clojure semantics: `x` evaluates to the value, `#'x` / `(var x)` evaluates to the Var.

### Core natives (`src/core.zig`)

```zig
.{ "var-get",         &varGetFn },         // (var-get #'x)          → root_value
.{ "var-set",         &varSetFn },         // (var-set! #'x v)       → v, via thread-local stack
.{ "alter-var-root",  &alterVarRootFn },   // (alter-var-root #'x f args...) → (f root args...)
.{ "intern",          &internFn },         // (intern 'ns 'sym v)    → Var
.{ "resolve",         &resolveFn },        // (resolve 'sym)         → Var | nil
.{ "ns-resolve",      &nsResolveFn },      // (ns-resolve 'ns 'sym)  → Var | nil (pass 2)
.{ "var?",            &varPFn },           // (var? x)               → bool
.{ "bound?",          &boundPFn },         // (bound? #'x)           → bool (Var.bound)
.{ "find-var",        &findVarFn },        // (find-var 'ns/sym)     → Var | nil
.{ "defonce*",        null },              // handled as special form
.{ "defn-*",          null },              // handled as special form
```

**deref on Var** — extend existing `derefFn`:

```zig
if (target.isObj() and target.asObj().kind == .var_ref) {
    return target.asObj().data.var_ref.root_value;
}
```

### GC

`src/gc.zig` mark-sweep: in the `markObj` switch, add:

```zig
.var_ref => {
    markValue(obj.data.var_ref.root_value);
},
```

`Obj.meta` is already marked generically.

### Reader

No changes. `#'x` → `(var x)` already works. `@(resolve 'x)` → `(deref (resolve 'x))` works via existing `deref`.

### Tests (`test-full.clj`)

```clojure
;; Basic var reification
(def x 1)
(assert (var? #'x))
(assert (= 1 @#'x))
(assert (= 1 (var-get #'x)))

;; alter-var-root
(alter-var-root #'x inc)
(assert (= 2 x))

;; defonce
(defonce y 10)
(defonce y 99)  ; should NOT rebind
(assert (= 10 y))

;; defn- privacy meta
(defn- private-helper [] :private)
(assert (:private (meta #'private-helper)))

;; resolve / intern
(assert (var? (resolve 'x)))
(assert (nil? (resolve 'nonexistent-sym)))
(intern 'user 'z 42)
(assert (= 42 z))

;; bound?
(declare undef-var)  ; if (declare) present; else skip
(assert (not (bound? #'undef-var)))
(def undef-var 1)
(assert (bound? #'undef-var))
```

## Implementation order (waves)

### Wave 0 — prerequisites (single commit)

1. Add `.var_ref` to `ObjKind` **plus** a branch in every exhaustive switch statement that lists kinds. Grep: `grep -rn 'case .list' src/ | wc -l` for the count up front; estimate ~15-30 switches based on similar kinds. Where the switch has `else =>`, nothing to do. Where it doesn't, add `.var_ref => {}` or route to appropriate handler.
2. Add `var_ref` union variant in `ObjData`.
3. Confirm `zig build` passes (Var not yet used; just compiles).

### Wave 1 — substrate (single commit)

1. `src/env.zig`: add `vars: AutoHashMapUnmanaged(u48, *Obj) = .empty` to `Env`; add `fn getVar(id) ?*Obj`, `fn internVar(id, ns_id, init) !*Obj`.
2. `src/gc.zig`: mark `var_ref.root_value` in `markObj`.
3. Modify `evalDef` to route through `env.rootEnv().internVar(...)` and store the **Var** as the binding (in `id_bindings` too). Auto-deref in `evalSymbol`.
4. Add `(var x)` handler in `eval.zig` dispatch.
5. Add `derefFn` branch for `.var_ref`.
6. Run all existing tests — **must stay green** (symbol lookup transparently auto-derefs so Clojure semantics unchanged).

### Wave 2 — core natives (parallelizable: 4 agents, one per group)

- A: `var?`, `bound?`, `find-var` (pure predicates, tiny)
- B: `resolve`, `intern` (single-ns scope; ns arg accepted and ignored or validated)
- C: `alter-var-root`, `var-get`, `var-set` (thread-local stack wiring via `dynamic_ids`)
- D: `defonce` special form + `defn-` macro/special

### Wave 3 — tests + docs (single commit)

- Append the `test-full.clj` block above.
- Update `README.md` to bump the "supported" surface.
- Close this doc with a completion note.

## Out of scope (deferred)

- `reify` / `proxy` — anonymous protocol impls. Separate PR. Requires runtime method-table allocation; non-trivial.
- Multi-namespace (`ns_table`, real `in-ns`, `ns-publics`, `ns-refers`, `require`/`use`). Pass 2.
- Full `clojure.spec` library — depends on `intern` (this PR) + `core.cache` (not here) + a lot of predicate library. Separate multi-PR effort.
- `future` / `promise` / `deliver` — self-contained, orthogonal; split PR.
- `go`-macro / full `core.async` CPS transform. Orthogonal; split PR.

## Risk register

| Risk | Mitigation |
|---|---|
| Exhaustive-switch fallout on adding `.var_ref` | Wave 0 is dedicated to adding the variant + stub branches; fully-audited before any behavior change. |
| Existing `id_bindings` fast-path performance regression when symbols auto-deref on lookup | `var_ref` check is a single branch + field load; <1ns amortized. If regression appears, add a `direct_value` fast slot to `Var` that skips the indirection for non-dynamic, non-rebound vars. |
| Breaking `with-redefs` (already present, compile-time listed) | `with-redefs` currently mutates the env binding directly; once bindings are Vars, adapt it to push/pop on the Var's thread stack. Verify test-full.clj's with-redefs tests stay green. |
| Eval cost of auto-deref on every symbol read | Benchmark `bench.sh` before and after Wave 1; acceptable threshold <3% regression. |

## Definition of done

- [ ] `feat/var-reification` branch passes `zig build`, `zig fmt --check .`, and `zig build test` locally.
- [ ] All existing tests in `test-full.clj`, `test-skills.clj`, `test-decomp.clj` pass.
- [ ] New tests above added and passing.
- [ ] `bench.sh` shows <3% regression on hot paths.
- [ ] PR open against `chore/zig-0.16.0` (will rebase onto `main` once `#22` merges).
- [ ] README's "Clojure forms" list updated to mention `defonce`, `defn-`, var reification.

## File-by-file change estimate

| File | LOC change | Kind |
|---|---|---|
| `src/value.zig` | +30 | enum + union variant |
| `src/env.zig` | +60 | `vars` map + `internVar` + `getVar` |
| `src/gc.zig` | +10 | mark var_ref |
| `src/eval.zig` | +120 | evalDef refactor + `(var x)` + `evalDefonce` + `evalDefnDash` + auto-deref in evalSymbol |
| `src/core.zig` | +180 | 9 native fns |
| Exhaustive-switch fallout across repo | +30 | stub branches |
| `test-full.clj` | +50 | tests |
| `README.md` | +3 | mention new forms |
| **Total** | **~480** | |
