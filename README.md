# nanoclj-zig

A Clojure interpreter in Zig. Single static binary. Zig 0.16.0 stdlib is the only runtime dependency.

## Install

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
git clone https://github.com/plurigrid/nanoclj-zig
cd nanoclj-zig
zig build run                         # interactive REPL
zig build -Doptimize=ReleaseFast run  # optimized
zig build test                        # unit tests
```

## Use

```
$ zig build run
bob=> (+ 1 2)
3

bob=> (map (fn* [x] (* x x)) [1 2 3 4 5])
(1 4 9 16 25)

bob=> (run* [q] (fresh [x y] (== x :hello) (== y :world) (== q [x y])))
([:hello :world])
```

Clojure forms: `def`, `fn*`, `let*`, `if`, `do`, `quote`, `loop`/`recur`, `defmacro`, `try`/`catch`, `defmulti`/`defmethod`, `defprotocol`/`deftype`, `binding`, `with-redefs`, `defrecord`, reader conditionals.

Data: lists, vectors, maps, sets, keywords, symbols, strings, i48 ints, f64, rationals, regex. Structural sharing.

Concurrency: atoms, refs + `dosync`, agents (`send`/`send-off`/`await`), `:validator`.

miniKanren: `run*`, `run`, `fresh`, `conde`, `==`, `conso`, `appendo`, `membero`, `evalo`.

Zig-unique disk I/O (positional, no seek state — thread-safe):

```clojure
(def f (file/open "/tmp/x" {:write true :create true :truncate true}))
(file/pwrite! f 0 "hello")
(file/fsync! f)                 ;; explicit durability barrier
(file/close! f)

(file/atomic-spit! "/tmp/x" "hi")   ;; tmp + fsync + rename (crash-safe)
(file/read-all-bytes "/tmp/x")      ;; → #bytes[2]<68 69>
```

## Interoperate

### Local `color://trit` resolution

```clojure
(color/resolve "color://trit/1")
;; {:address "color://trit/1" :domain :trit :trit 1
;;  :oklab <native color> :rule :oklch_equal_sectors_v1}
(color-hue (:oklab (color/resolve "color://trit/1"))) ;; approximately 60
(get (color/resolve "color://trit/1") :trit) ;; 1
(color/resolve "color://trit/2")
;; {:address "color://trit/2" :error :InvalidTrit}
```

Only the exact strings `color://trit/-1`, `color://trit/0`, and
`color://trit/1` resolve. `src/color_uri.zig` exposes an allocation-free
`resolve` returning a typed `Resolution` (canonical static address, domain,
`Trit` enum, `colorspace.Color`, and versioned rule) or `ResolveError`.
The evaluator's `:oklab` is the existing native color value, usable with
`color-L`, `color-a`, `color-b`, `color-hue`, and other color operations.
Use `get` for `:trit` lookup: `trit` is also a builtin name, whose keyword
sentinel takes precedence over keyword-as-function lookup in the tree evaluator.

The `oklch_equal_sectors_v1` rule applies `substrate.hueToTrit`'s fixed
120-degree sectors to OKLCH hue. It selects their centers with lightness
0.65, chroma 0.10, and alpha 1:

| Trit | OKLCH hue | Classifier sector |
|---|---|---|
| -1 | 300° | [240°, 360°) |
| 0 | 180° | [120°, 240°) |
| 1 | 60° | [0°, 120°) |

These are chosen display representatives, **not learned perceptual boundaries**.
OKLCH and RGB hue are different coordinates; tests verify agreement for these
three representatives, including an sRGB8 round trip, not for arbitrary colors.

Parsing is case-sensitive with no trimming, percent decoding, numeric coercion,
or normalization. Errors are checked in this order:

| Error | Condition |
|---|---|
| `InvalidScheme` | Missing exact `color://` prefix |
| `MalformedPath` | Missing/empty domain or value, extra slash, whitespace, non-ASCII, percent escape, query, fragment, backslash, or invalid domain syntax |
| `UnsupportedDomain` | Syntactically valid domain other than `trit` |
| `InvalidTrit` | Value other than exact `-1`, `0`, `1` (including `+1`, `01`, `-0`, or `1.0`) |

Domain syntax is `[a-z][a-z0-9-]*`; the value is one nonempty path segment.
URI errors are returned as `{:address <input> :error <keyword>}` so their
classification survives the evaluator's generic builtin-error handling.
Wrong arity or a non-string argument retains the existing invocation-error
behavior (`EvalFailed` through the evaluator).

An address identifies data; its color is a representation. Neither carries or
grants capability authority, and GF(3) balance is not authentication. Resolution
performs no I/O and does not change colorspace focus or bindings.
This is the first route from [issue #20](https://github.com/plurigrid/nanoclj-zig/issues/20),
not the full proposed protocol. Other domains, device adapters, learned
boundaries, a new conservation API, and C-ABI expansion remain deferred.

### Embedding targets

| Target | Binary | Use |
|---|---|---|
| `zig build run` | `nanoclj` | REPL |
| `zig build embed-min` | `nanoclj-embed-min` | Minimal (~870 KB) — scripts nREPL/kanren/inet stripped |
| `zig build embed-safe` | `nanoclj-embed-safe` | Bounded embedded profile |
| `zig build mcp` | `nanoclj-mcp` | MCP server (Syrup framing via zig-syrup) |
| `zig build gorj` | `gorj-mcp` | MCP with Clojure-defined tools |
| `zig build wasm` | `nanoclj.wasm` | WASM (disk I/O stubbed to `Unsupported`) |

Embed from Zig: add this repo as a dependency, `@import("nanoclj")`, call `eval(source)`.

## Dependency

- [zig-syrup](https://github.com/plurigrid/zig-syrup) — Syrup codec + MCP framing + propagator cells

## License

MIT
