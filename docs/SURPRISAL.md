# Contextual surprisal in nanoclj-zig

The `surprisal/*` namespace exposes a finite integer-weight probability model
through nanoclj's existing Clojure reader and evaluators. The native kernel
computes event probability, event information, and information gained by
refinement. The full core registers the namespace automatically.

This is a native extension to nanoclj-zig. It does not implement Babashka/SCI
compatibility, Babashka pods, a JVM, or a new Clojure evaluator.

## Run

Use the repository's Zig 0.16.0 toolchain:

```sh
zig build surprisal-test -Doptimize=Debug --summary all
zig build surprisal-test -Doptimize=ReleaseSafe --summary all
zig build surprisal -- examples/surprisal.clj
zig build surprisal -- -e '(surprisal/bits (surprisal/event (surprisal/model :v1 [1 3]) [0]))'
```

The `surprisal` host loads a file or expression and prints its last value. It
registers only the twelve functions below, alongside evaluator special forms
such as `def`, `let*`, and `if`. It requires no Syrup source, sockets, clocks,
RNG, MCP, nREPL, or full-core initialization. The host itself reads the source
file and writes stdout; evaluated code has no file or network builtins.
It uses the existing bounded evaluator with one million fuel units and depth
64. This is not a new sandbox or a claim about the interpreter's allocation
limits. Each namespace operation inspects at most 128 weights/indices.

## Model identity and records

```clojure
(def area (surprisal/model :area/v1 [15 15 15 15 15 15 15 15]))
(def carucate (surprisal/whole area))
(def virgate (surprisal/event area [0 1]))
(def oxgang (surprisal/event area [0]))

(surprisal/score oxgang)
;; {:surprisal/type :score
;;  :event {:surprisal/type :event
;;          :model {:surprisal/type :model
;;                  :context :area/v1
;;                  :weights [15 15 15 15 15 15 15 15]}
;;          :atoms [0]}
;;  :probability 0.125 :bits 3.0}
```

The context must be a keyword or string. Give each semantic context and model
revision a distinct name. Compatibility requires the same context value,
the same number of atoms, and exactly the same ordered weights. A keyword and
a string with the same spelling remain different contexts. Reconstructing the
same context and weights reconstructs the same model; names are not fresh
identities or secrets.

The original standalone Zig API used compile-time scope types. Runtime Clojure
models instead carry their complete model description and are checked at every
operation. Constructors copy the weight and atom vectors into their results.
Events have sorted, deduplicated indices; they are sets, not samples with
multiplicity. Refinements carry both endpoint events, including their models.
No process-global model registry, pointer identity, hash collision assumption,
or cached probability is needed.

These ordinary data records are not sealed certificates or capabilities. A
caller can reconstruct or edit them, and every consumer validates them anew.
Descriptions do not authenticate who selected a context or supplied weights.
Use `score` when retaining context with a measurement; `bits`, `probability`,
and `refinement-bits` explicitly extract unscoped scalar values.

## API

| Form | Result |
| --- | --- |
| `(surprisal/model context weights)` | Validated model with 1–128 weights |
| `(surprisal/event model indices)` | Event; an empty vector denotes the empty event |
| `(surprisal/whole model)` | Event containing every atom |
| `(surprisal/probability event)` | Sum of event weights divided by total weight |
| `(surprisal/bits event)` | `-log2(P(event))` |
| `(surprisal/score event)` | Event/model snapshot, probability, and bits |
| `(surprisal/union a b)` | Set union within one model |
| `(surprisal/intersection a b)` | Set intersection within one model |
| `(surprisal/subset? a b)` | Whether `a` is a subset of `b`, after context validation |
| `(surprisal/refine coarse fine)` | Validated path with `fine` contained in `coarse` |
| `(surprisal/refinement-bits path)` | `-log2(P(fine)/P(coarse))` |
| `(surprisal/compose first second)` | Path from first coarse to second fine; middle events must match |

Weights must be nonnegative nanoclj integers, each at most `2^47-1`, with a
positive total. Zero-weight atoms are allowed. Vectors of indices accept at
most 128 entries, including duplicates, and each index must be in range.
Floats and booleans are not silently converted to integers. The standalone
native distribution accepts `u64` weights and rejects total overflow.

Containment is literal inclusion of atom sets, including zero-weight atoms.
It is not equality modulo probability-zero sets. Composition compares the
middle atom sets, not just their probabilities.

## Refinement and sampling

```clojure
(def first-step (surprisal/refine carucate virgate))
(def second-step (surprisal/refine virgate oxgang))
(surprisal/refinement-bits first-step)                  ; 2.0
(surprisal/refinement-bits second-step)                 ; 1.0
(surprisal/refinement-bits
  (surprisal/compose first-step second-step))            ; 3.0
```

The land example uses the supplied idealized 120/30/15-acre convention and
uniform sampling per acre. Multiplying every weight by the same positive
constant leaves scores unchanged. Weighting the first oxgang twice as heavily
gives weights `[30 15 15 15 15 15 15 15]`, probability `2/9`, and about
`2.169925001442312` bits. This changes the sampling measure. Use a different
context such as `:work/v1`; combining its events with area events is an error.

The kernel uses exact integer masses and subtracts the numerator from the
denominator before floating conversion, then evaluates `log1p(delta/n)/ln(2)`.
This preserves small positive gains when two large masses would round to the
same floating-point number. Output probabilities and bit counts are `f64`
approximations. A zero-mass event has probability zero and positive-infinite
bits; conditioning on zero mass is invalid. Positive mass refining to zero
mass is valid and yields positive-infinite information.

## Failure values

Domain failures return a map such as:

```clojure
(surprisal/refine oxgang virgate)
;; {:surprisal/error :NonNested}

(if (:surprisal/error (surprisal/model :bad [0]))
  :rejected
  :accepted)
```

Named errors include `ModelMismatch`, `NonNested`, `ZeroCondition`,
`EndpointsDoNotMatch`, `AtomOutOfRange`, `NegativeWeight`, `ZeroTotal`,
`InvalidModel`, `TooManyAtoms`, `InvalidContext`, `ExpectedVector`,
`ExpectedIntegerWeight`, `ExpectedIntegerIndex`, `InvalidRecord`, and
`ArityError`. Out-of-memory remains a host/evaluator error. Returning domain
errors as data preserves their names across the existing evaluators, which
otherwise collapse arbitrary builtin errors.

Check `:surprisal/error` before treating a result as a score or Boolean. Maps
are truthy, including error maps. The focused CLI stops on a top-level error
map and exits unsuccessfully; errors nested inside a user-built collection
remain visible data for the script to handle.

## Validation and limits

The focused tests execute Clojure forms through both the legacy and bounded
evaluators. They cover model mismatches, invalid and forged records, vector
snapshots, script-visible errors, reconstruction across interpreter lifetimes,
overlap, inclusion direction, zero mass, 128 atoms, and maximal i48 weights.
Native tests exhaust all 256 event pairs and 175 positive nested chains on a
four-atom model, and check u64 overflow and tiny positive information gains.

Locally verified with Zig 0.16.0 on Linux: 12/12 focused tests in both Debug and
ReleaseSafe, plus eight CLI cases covering the file example, scalar output,
domain failure, incomplete input, unbound input, recursive depth exhaustion,
trailing comments, and stopping at the first top-level domain error. A separate
CI job runs the focused tests and example in both modes without Syrup.

Before this change, `zig build test -Doptimize=ReleaseSafe` on Linux with Zig
0.16.0 and zig-syrup `b06fb6f2802e6c737f9ba7ba3ae755b3e3d6d4f9` fails in
the full suite: Syrup references `@fromBackingInt`, and nREPL's C import fails
on fortified glibc declarations. The independent loop and flow suites pass
240 tests. The focused surprisal target avoids those subsystems; it does not
repair or validate the full application build.

This patch does not implement online learning, empirical calibration,
UUID generation or causal inference, global compatibility optimization,
Babashka compatibility, or new authority checks. It measures specified finite
events under specified finite models. WASM and physical-device integration of
this Clojure bridge require separate validation.
