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
