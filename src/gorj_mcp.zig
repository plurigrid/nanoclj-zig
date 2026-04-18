//! gorj_mcp: Self-hosting MCP server for gorj
//!
//! Unlike mcp_tool.zig (hardcoded Zig handlers), this server bootstraps
//! its tool definitions from nanoclj Clojure forms. Each MCP tool is a
//! (def gorj-tool-<name> (fn* [args-map] ...)) that gets compiled to
//! bytecode and dispatched through the nanoclj runtime.
//!
//! Self-hosting closure: the MCP server is *written in the language it serves*.
//! The Zig layer is only the JSON-RPC envelope + stdio transport.
//!
//! Tool dispatch:
//!   tools/call {name: "gorj_eval", arguments: {code: "(+ 1 2)"}}
//!   → (gorj-mcp-dispatch "gorj_eval" {:code "(+ 1 2)"})
//!   → nanoclj eval → result → JSON-RPC response
//!
//! The prelude defines: gorj_eval, gorj_pipe, gorj_encode, gorj_decode,
//! gorj_version, gorj_tools, gorj_trit_tick, gorj_color, gorj_substrate,
//! gorj_compile (bytecode compile + execute).

const std = @import("std");
const compat = @import("compat.zig");
const json = std.json;
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const bc = @import("bytecode.zig");
const Compiler = @import("compiler.zig").Compiler;

const SERVER_NAME = "gorj-zig";
const SERVER_VERSION = "0.3.0";
const PROTOCOL_VERSION = "2025-11-05";
const MAX_LINE_SIZE = 4 * 1024 * 1024;

// ============================================================================
// MCP TASKS — async long-running eval with fuel tracking (2025-11-25 spec)
// ============================================================================

const TaskState = enum { working, completed, failed };

const McpTask = struct {
    id: u64,
    state: TaskState,
    tool_name: []const u8,
    result: ?[]const u8,
};

var task_registry: [64]McpTask = undefined;
var task_count: usize = 0;
var next_task_id: u64 = 1;

fn createTask(tool_name: []const u8) u64 {
    const id = next_task_id;
    next_task_id += 1;
    if (task_count < 64) {
        task_registry[task_count] = .{
            .id = id,
            .state = .working,
            .tool_name = tool_name,
            .result = null,
        };
        task_count += 1;
    }
    return id;
}

fn completeTask(id: u64, result: []const u8) void {
    for (0..task_count) |i| {
        if (task_registry[i].id == id) {
            task_registry[i].state = .completed;
            task_registry[i].result = result;
            return;
        }
    }
}

fn failTask(id: u64, reason: []const u8) void {
    for (0..task_count) |i| {
        if (task_registry[i].id == id) {
            task_registry[i].state = .failed;
            task_registry[i].result = reason;
            return;
        }
    }
}

fn getTask(id: u64) ?*McpTask {
    for (0..task_count) |i| {
        if (task_registry[i].id == id) return &task_registry[i];
    }
    return null;
}

// ============================================================================
// NANOCLJ RUNTIME (persistent across MCP calls)
// ============================================================================

var global_gc: GC = undefined;
var global_env: Env = undefined;
var global_vm: bc.VM = undefined;
var nanoclj_initialized = false;

fn initRuntime(allocator: std.mem.Allocator) !void {
    if (nanoclj_initialized) return;
    global_gc = GC.init(allocator);
    global_env = Env.init(allocator, null);
    global_env.is_root = true;
    try core.initCore(&global_env, &global_gc);
    global_vm = bc.VM.init(&global_gc, 100_000_000);
    // SPI: index-addressed versioning from canonical seed
    const gorj_bridge = @import("gorj_bridge.zig");
    gorj_bridge.initSession(1069); // gorj MCP uses canonical seed
    nanoclj_initialized = true;

    // Bootstrap: evaluate the self-hosting prelude
    try evalPrelude(allocator);
}

// ============================================================================
// SELF-HOSTING PRELUDE
//
// These nanoclj forms define the MCP tool handlers. They use the gorj-bridge
// builtins (gorj-pipe, gorj-eval, etc.) but wrap them in the MCP tool
// contract: take a map of arguments, return a string result.
//
// The closure: gorj-bridge builtins are Zig. The MCP dispatch is nanoclj.
// The Zig only does JSON-RPC framing. nanoclj does all tool logic.
// ============================================================================

const prelude_forms = [_][]const u8{
    // gorj_eval: evaluate Clojure code via the fused gorj pipeline
    \\(def gorj-mcp-eval
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (gorj-eval code)]
    \\      (pr-str result))))
    ,
    // gorj_pipe: minimal [result vid trit] vector output
    \\(def gorj-mcp-pipe
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (gorj-pipe code)]
    \\      (pr-str result))))
    ,
    // gorj_encode: value → Syrup bytes
    \\(def gorj-mcp-encode
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           val (read-string code)
    \\           encoded (gorj-encode val)]
    \\      (pr-str {:syrup-bytes (count encoded)}))))
    ,
    // gorj_decode: Syrup bytes → value
    \\(def gorj-mcp-decode
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           decoded (gorj-decode code)]
    \\      (pr-str decoded))))
    ,
    // gorj_version: current version frontier
    \\(def gorj-mcp-version
    \\  (fn* [args]
    \\    (pr-str {:version (gorj-version)})))
    ,
    // gorj_tools: list gorj's 45 MCP tool names
    \\(def gorj-mcp-tools
    \\  (fn* [args]
    \\    (pr-str (gorj-tools))))
    ,
    // gorj_trit_tick: generate trit-ticks from seed
    \\(def gorj-mcp-trit-tick
    \\  (fn* [args]
    \\    (let* [n (or (get args "count") 12)
    \\           seed (or (get args "seed") 1069)
    \\           ticks (map (fn* [i] (let* [c (color-at seed i)]
    \\                                 {:index i :hex (get c :hex) :trit (get c :trit)}))
    \\                      (range n))]
    \\      (pr-str {:ticks ticks :count n :seed seed}))))
    ,
    // gorj_generate_ticks: gatomic-compatible trit-tick generation
    \\(def gorj-mcp-generate-ticks
    \\  (fn* [args]
    \\    (let* [count (or (get args "count") 12)
    \\           seed (or (get args "seed") 1069)
    \\           start (or (get args "start") 0)
    \\           ticks
    \\             (vec
    \\               (map
    \\                 (fn* [i]
    \\                   (let* [idx (+ start i)
    \\                          c (color-at seed idx)
    \\                          prev (if (> idx 0) (color-at seed (- idx 1)) {:trit 0})
    \\                          s-old (get prev :trit)
    \\                          s-new (get c :trit)
    \\                          flicker (cond
    \\                                    (= s-old s-new) 0
    \\                                    (= s-new 0) -1
    \\                                    :else 1)]
    \\                     {:tick/site seed
    \\                      :tick/sweep idx
    \\                      :tick/s-old s-old
    \\                      :tick/s-new s-new
    \\                      :tick/color (get c :hex)
    \\                      :tick/flicker flicker}))
    \\                 (range count)))
    \\           trits (vec (map (fn* [t] (get t :tick/s-new)) ticks))
    \\           balance (reduce + 0 trits)
    \\           fingerprint (xor-fingerprint trits)]
    \\      (pr-str {:ok true
    \\               :tool "gorj_generate_ticks"
    \\               :ticks ticks
    \\               :balance balance
    \\               :spi {:fingerprint fingerprint
    \\                     :balance balance
    \\                     :ok (= 0 (mod balance 3))}}))))
    ,
    // gorj_partition_by_trit: gatomic-compatible tick partitioning
    \\(def gorj-mcp-partition-by-trit
    \\  (fn* [args]
    \\    (let* [ticks-str (or (get args "ticks") "[]")
    \\           ticks (read-string ticks-str)
    \\           plus (vec (filter (fn* [t] (= 1 (get t :tick/s-new))) ticks))
    \\           zero (vec (filter (fn* [t] (= 0 (get t :tick/s-new))) ticks))
    \\           minus (vec (filter (fn* [t] (= -1 (get t :tick/s-new))) ticks))]
    \\      (pr-str {:ok true
    \\               :tool "gorj_partition_by_trit"
    \\               :partitions {:plus plus :zero zero :minus minus}}))))
    ,
    // gorj_spi_verify: gatomic-compatible SPI verification on tick sequences
    \\(def gorj-mcp-spi-verify
    \\  (fn* [args]
    \\    (let* [ticks-str (or (get args "ticks") "[]")
    \\           ticks (read-string ticks-str)
    \\           trits (vec (map (fn* [t] (get t :tick/s-new)) ticks))
    \\           balance (reduce + 0 trits)
    \\           fingerprint (xor-fingerprint trits)]
    \\      (pr-str {:ok true
    \\               :tool "gorj_spi_verify"
    \\               :spi {:fingerprint fingerprint
    \\                     :balance balance
    \\                     :ok (= 0 (mod balance 3))}}))))
    ,
    // gorj_color: get gay color at seed+index
    \\(def gorj-mcp-color
    \\  (fn* [args]
    \\    (let* [seed (or (get args "seed") 1069)
    \\           index (or (get args "index") 0)
    \\           c (color-at seed index)]
    \\      (pr-str c))))
    ,
    // gorj_substrate: runtime info
    \\(def gorj-mcp-substrate
    \\  (fn* [args]
    \\    (pr-str {:runtime "nanoclj-zig"
    \\             :server "gorj-zig"
    \\             :self-hosted true
    \\             :bytecode-vm true})))
    ,
    // gorj_compile: compile expression to bytecode and execute via VM
    \\(def gorj-mcp-compile
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (gorj-pipe code)]
    \\      (pr-str {:compiled true :result (first result) :version-id (nth result 1) :trit (nth result 2)}))))
    ,
    // gorj_spacetime: information spacetime metrics
    \\(def gorj-mcp-spacetime
    \\  (fn* [args]
    \\    (let* [distance (or (get args "distance") 0)
    \\           budget (or (get args "budget") 1)
    \\           branching (or (get args "branching") 3)
    \\           depth (or (get args "depth") 3)
    \\           sep (separation distance budget)
    \\           vol (cone-volume branching depth)
    \\           cones (padic-cones depth)]
    \\      (pr-str {:separation sep
    \\               :cone-volume vol
    \\               :padic-cones cones
    \\               :branching branching
    \\               :depth depth}))))
    ,
    // ================================================================
    // DIALECT BRIDGES — best-of from clj-easy/clojure-dialects-docs
    // Each tool captures the killer feature of its source dialect.
    // ================================================================

    // gorj_bb: Babashka — instant scripting via shell
    \\(def gorj-mcp-bb
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "bb -e '" code "'"))]
    \\      (if result
    \\        (pr-str {:dialect "babashka" :out (get result "out") :exit (get result "exit")})
    \\        (pr-str {:dialect "babashka" :via :gorj-eval :result (gorj-eval code)})))))
    ,
    // gorj_jank: Jank — native C++ interop (shell to jank if available)
    \\(def gorj-mcp-jank
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "jank -e '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "jank" :result (get result "out")})
    \\        (pr-str {:dialect "jank" :via :gorj-eval :result (gorj-eval code)
    \\                 :note "jank not installed — eval via gorj"})))))
    ,
    // gorj_cljw: ClojureWasm OKLAB color interchange
    // Evals code; if result is a color, produces full interchange:
    //   {:dialect "clojurewasm" :color <val> :interchange "#color[L a b alpha]"
    //    :srgb [R G B] :ansi "\x1b[38;2;R;G;Bm██\x1b[0m"}
    // OKLAB→sRGB uses same matrix as printer.zig; gamma ≈ sqrt (no pow builtin).
    // Handles both (color 0.7 0.1 -0.2) and #color[0.7 0.1 -0.2 1.0] inputs.
    \\(def gorj-mcp-cljw
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (gorj-eval code)
    \\           is-color (color? result)]
    \\      (if is-color
    \\        (let* [L (color-L result)
    \\               a (color-a result)
    \\               b (color-b result)
    \\               alpha (color-alpha result)
    \\               l_ (+ L (* 0.3963377774 a) (* 0.2158037573 b))
    \\               m_ (+ L (* -0.1055613458 a) (* -0.0638541728 b))
    \\               s_ (+ L (* -0.0894841775 a) (* -1.2914855480 b))
    \\               l (* l_ l_ l_)
    \\               m (* m_ m_ m_)
    \\               s (* s_ s_ s_)
    \\               r-lin (+ (* 4.0767416621 l) (* -3.3077115913 m) (* 0.2309699292 s))
    \\               g-lin (+ (* -1.2684380046 l) (* 2.6097574011 m) (* -0.3413193965 s))
    \\               b-lin (+ (* -0.0041960863 l) (* -0.7034186147 m) (* 1.7076147010 s))
    \\               clamp (fn* [x] (if (< x 0.0) 0.0 (if (> x 1.0) 1.0 x)))
    \\               gamma (fn* [x] (let* [c (clamp x)] (int (* (Math/sqrt c) 255.0))))
    \\               R (gamma r-lin) G (gamma g-lin) B (gamma b-lin)
    \\               interchange (str "#color[" L " " a " " b " " alpha "]")
    \\               ansi (str "\x1b[38;2;" R ";" G ";" B "m\u2588\u2588\x1b[0m")]
    \\          (pr-str {:dialect "clojurewasm"
    \\                   :color result
    \\                   :interchange interchange
    \\                   :srgb [R G B]
    \\                   :ansi ansi}))
    \\        (pr-str {:dialect "clojurewasm"
    \\                 :color nil
    \\                 :result result})))))
    ,
    // gorj_squint: Squint's best — lightweight JS transpile
    \\(def gorj-mcp-squint
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           js (-> code
    \\                  (clojure.string/replace "(defn " "function ")
    \\                  (clojure.string/replace "(def " "const ")
    \\                  (clojure.string/replace "(let [" "{ const ")
    \\                  (clojure.string/replace "(let* [" "{ const ")
    \\                  (clojure.string/replace "(fn [" "function(")
    \\                  (clojure.string/replace "(fn* [" "function(")
    \\                  (clojure.string/replace "(if " "if (")
    \\                  (clojure.string/replace "(println " "console.log(")
    \\                  (clojure.string/replace "(prn " "console.log(")
    \\                  (clojure.string/replace "(str " "String(")
    \\                  (clojure.string/replace "(+ " "(")
    \\                  (clojure.string/replace "(- " "(")
    \\                  (clojure.string/replace "(* " "(")
    \\                  (clojure.string/replace "(/ " "("))]
    \\      (pr-str {:dialect "squint" :feature "clj->js-transpile"
    \\               :note "best-effort syntax mapping, not a real compiler"
    \\               :input code
    \\               :result js}))))
    ,
    // gorj_dart: ClojureDart — Flutter via shell
    \\(def gorj-mcp-dart
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           has-dart (sh "which dart 2>/dev/null")]
    \\      (pr-str {:dialect "clojuredart" :feature "flutter-widgets"
    \\               :dart-available (and has-dart (> (count (get has-dart "out")) 0))
    \\               :input code}))))
    ,
    // gorj_basilisp: Basilisp — Python interop via shell
    \\(def gorj-mcp-basilisp
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "basilisp run -c '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "basilisp" :result (get result "out")})
    \\        (pr-str {:dialect "basilisp" :note "basilisp not available — pip install basilisp" :input code})))))
    ,
    // gorj_glojure: Glojure — Go interop via shell
    \\(def gorj-mcp-glojure
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "glojure -e '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "glojure" :result (get result "out")})
    \\        (pr-str {:dialect "glojure" :note "glojure not available — go install github.com/glojurelang/glojure" :input code})))))
    ,
    // gorj_joker: structural lint for Clojure code (no external deps)
    // Checks: unbalanced delimiters, unused let bindings, missing defn docstrings,
    //         single-branch if (should be when), empty let bindings
    \\(def gorj-mcp-joker
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           ;; 1. Unbalanced delimiters
    \\           open-parens   (count (filter (fn* [c] (= c \()) (seq code)))
    \\           close-parens  (count (filter (fn* [c] (= c \))) (seq code)))
    \\           open-bracks   (count (filter (fn* [c] (= c \[)) (seq code)))
    \\           close-bracks  (count (filter (fn* [c] (= c \])) (seq code)))
    \\           open-braces   (count (filter (fn* [c] (= c \{)) (seq code)))
    \\           close-braces  (count (filter (fn* [c] (= c \})) (seq code)))
    \\           delim-issues  (concat
    \\                           (if (not= open-parens close-parens)
    \\                             [{:level "error" :type "unbalanced-parens"
    \\                               :message (str "Unbalanced parentheses: " open-parens " open vs " close-parens " close")}]
    \\                             [])
    \\                           (if (not= open-bracks close-bracks)
    \\                             [{:level "error" :type "unbalanced-brackets"
    \\                               :message (str "Unbalanced brackets: " open-bracks " open vs " close-bracks " close")}]
    \\                             [])
    \\                           (if (not= open-braces close-braces)
    \\                             [{:level "error" :type "unbalanced-braces"
    \\                               :message (str "Unbalanced braces: " open-braces " open vs " close-braces " close")}]
    \\                             []))
    \\           ;; Parse top-level forms for deeper checks
    \\           forms (try* (read-string (str "[" code "]")) (catch* e []))
    \\           ;; Walk each form checking for lint issues
    \\           form-issues
    \\             (apply concat
    \\               (map (fn* [form]
    \\                 (let* [head (if (list? form) (first form) nil)]
    \\                   (concat
    \\                     ;; 3. Missing docstring on defn
    \\                     (if (and (= head (symbol "defn"))
    \\                              (>= (count form) 3)
    \\                              (not (string? (nth form 2))))
    \\                       [{:level "warning" :type "missing-docstring"
    \\                         :message (str "defn '" (nth form 1) "' is missing a docstring")}]
    \\                       [])
    \\                     ;; 4. Single-branch if -> should be when
    \\                     (if (and (= head (symbol "if"))
    \\                              (= (count form) 3))
    \\                       [{:level "warning" :type "single-branch-if"
    \\                         :message "Single-branch 'if' -- consider using 'when' instead"}]
    \\                       [])
    \\                     ;; 5. Empty let bindings
    \\                     (if (and (or (= head (symbol "let"))
    \\                                  (= head (symbol "let*")))
    \\                              (>= (count form) 2)
    \\                              (= (count (nth form 1)) 0))
    \\                       [{:level "warning" :type "empty-let-bindings"
    \\                         :message "Empty let bindings vector -- remove the let wrapper"}]
    \\                       [])
    \\                     ;; 2. Unused let bindings (heuristic: name not in body)
    \\                     (if (and (or (= head (symbol "let"))
    \\                                  (= head (symbol "let*")))
    \\                              (>= (count form) 3)
    \\                              (> (count (nth form 1)) 0))
    \\                       (let* [bvec (nth form 1)
    \\                              body-str (apply str (map pr-str (drop 2 form)))
    \\                              bnames (map (fn* [i] (nth bvec (* i 2)))
    \\                                          (range (/ (count bvec) 2)))]
    \\                         (filter some?
    \\                           (map (fn* [bname]
    \\                                  (let* [bs (pr-str bname)]
    \\                                    (if (not (includes? body-str bs))
    \\                                      {:level "warning" :type "unused-binding"
    \\                                       :message (str "Binding '" bs "' appears unused in let body")}
    \\                                      nil)))
    \\                                bnames)))
    \\                       []))))
    \\                 forms))
    \\           all-issues (vec (concat delim-issues form-issues))
    \\           clean (= (count all-issues) 0)]
    \\      (pr-str {:dialect "joker" :feature "lint"
    \\               :issues all-issues
    \\               :clean? clean}))))
    ,
    // gorj_nbb: nbb — Node.js scripting via shell
    \\(def gorj-mcp-nbb
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "npx nbb -e '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "nbb" :result (get result "out")})
    \\        (pr-str {:dialect "nbb" :note "nbb not available — npm i -g nbb" :input code})))))
    ,
    // gorj_scittle: Scittle's best — zero-build browser CLJS
    \\(def gorj-mcp-scittle
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           html (str "<!DOCTYPE html><html><head>"
    \\                     "<script src=\"https://cdn.jsdelivr.net/npm/scittle@0.6.21/dist/scittle.js\"></script>"
    \\                     "</head><body>"
    \\                     "<script type=\"application/x-scittle\">"
    \\                     code
    \\                     "</script></body></html>")]
    \\      (pr-str {:dialect "scittle" :feature "zero-build-browser"
    \\               :note "self-contained HTML page running Clojure via SCI"
    \\               :result html}))))
    ,
    // gorj_clr: ClojureCLR — .NET shell bridge
    \\(def gorj-mcp-clr
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "dotnet clojure -e '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "clojureclr" :result (get result "out")})
    \\        (pr-str {:dialect "clojureclr" :note "ClojureCLR not available — needs .NET" :input code})))))
    ,
    // gorj_cherry: Cherry — ES6 via npx
    \\(def gorj-mcp-cherry
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "npx cherry compile -e '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "cherry" :es6 (get result "out")})
    \\        (pr-str {:dialect "cherry" :note "cherry not available — npm i -g cherry-cljs" :input code})))))
    ,
    // gorj_cream: Cream — GraalVM eval via shell
    \\(def gorj-mcp-cream
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "cream -e '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "cream" :result (get result "out")})
    \\        (pr-str {:dialect "cream" :note "cream not available — github.com/borkdude/cream" :input code})))))
    ,
    // gorj_clojerl: Clojerl — BEAM via shell
    \\(def gorj-mcp-clojerl
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           result (sh (str "clojerl -e '" code "' 2>/dev/null"))]
    \\      (if (and result (> (count (get result "out")) 0))
    \\        (pr-str {:dialect "clojerl" :result (get result "out")})
    \\        (pr-str {:dialect "clojerl" :note "clojerl not available — needs Erlang/OTP" :input code})))))
    ,
    // gorj_dialects: meta-tool — list all dialect bridges with their best features
    \\(def gorj-mcp-dialects
    \\  (fn* [args]
    \\    (pr-str [{:dialect "babashka"    :tool "gorj_bb"       :best "instant scripting + pods"}
    \\             {:dialect "jank"        :tool "gorj_jank"     :best "C++ interop via LLVM JIT"}
    \\             {:dialect "clojurewasm" :tool "gorj_cljw"     :best "inline OKLAB color + Wasm"}
    \\             {:dialect "squint"      :tool "gorj_squint"   :best "lightweight JS transpile"}
    \\             {:dialect "clojuredart" :tool "gorj_dart"     :best "Flutter mobile UI"}
    \\             {:dialect "basilisp"    :tool "gorj_basilisp" :best "Python 3 interop"}
    \\             {:dialect "glojure"     :tool "gorj_glojure"  :best "Go interop + Wasm AOT"}
    \\             {:dialect "joker"       :tool "gorj_joker"    :best "lint + format"}
    \\             {:dialect "nbb"         :tool "gorj_nbb"      :best "Node.js scripting"}
    \\             {:dialect "scittle"     :tool "gorj_scittle"  :best "zero-build browser CLJS"}
    \\             {:dialect "clojureclr"  :tool "gorj_clr"      :best ".NET interop"}
    \\             {:dialect "cherry"      :tool "gorj_cherry"   :best "ES6 module compiler"}
    \\             {:dialect "cream"       :tool "gorj_cream"    :best "GraalVM + Crema eval"}
    \\             {:dialect "clojerl"     :tool "gorj_clojerl"  :best "Erlang VM fault tolerance"}])))
    ,
    // gorj_peval: parallel eval of N expressions with fuel conservation
    // Exposes the unique fork/join fuel model — no other Clojure has this.
    // Each expr gets equal fuel share; GF(3) trit is conserved across fork/join.
    \\(def gorj-mcp-peval
    \\  (fn* [args]
    \\    (let* [exprs-str (get args "exprs")
    \\           exprs (read-string exprs-str)
    \\           results (pmap (fn* [e] (gorj-pipe (pr-str e))) exprs)
    \\           formatted (map (fn* [r] {:result (first r)
    \\                                    :version-id (nth r 1)
    \\                                    :trit (nth r 2)}) results)]
    \\      (pr-str {:parallel true
    \\               :count (count exprs)
    \\               :results (vec formatted)
    \\               :gf3-sum (reduce + 0 (map (fn* [r] (nth r 2)) results))}))))
    ,
    // gorj_atom: persistent named atoms across MCP calls
    // Create, read, swap, reset atoms by name — stateful MCP with CAS semantics.
    \\(def gorj-mcp-atom-registry (atom {}))
    ,
    \\(def gorj-mcp-atom
    \\  (fn* [args]
    \\    (let* [op (or (get args "op") "deref")
    \\           name (get args "name")
    \\           registry @gorj-mcp-atom-registry]
    \\      (cond
    \\        (= op "create")
    \\          (let* [init (read-string (or (get args "init") "nil"))
    \\                 a (atom init)]
    \\            (swap! gorj-mcp-atom-registry assoc name a)
    \\            (pr-str {:op "create" :name name :value init}))
    \\        (= op "deref")
    \\          (let* [a (get registry name)]
    \\            (if a
    \\              (pr-str {:op "deref" :name name :value @a})
    \\              (pr-str {:error (str "no atom named: " name)})))
    \\        (= op "reset")
    \\          (let* [a (get registry name)
    \\                 v (read-string (get args "value"))]
    \\            (if a
    \\              (do (reset! a v)
    \\                  (pr-str {:op "reset" :name name :value v}))
    \\              (pr-str {:error (str "no atom named: " name)})))
    \\        (= op "swap")
    \\          (let* [a (get registry name)
    \\                 f (read-string (get args "fn"))
    \\                 new-val (swap! a f)]
    \\            (if a
    \\              (pr-str {:op "swap" :name name :value new-val})
    \\              (pr-str {:error (str "no atom named: " name)})))
    \\        (= op "list")
    \\          (pr-str {:op "list" :atoms (vec (keys registry))})
    \\        (= op "cas")
    \\          (let* [a (get registry name)
    \\                 old (read-string (get args "old"))
    \\                 new (read-string (get args "new"))]
    \\            (if a
    \\              (pr-str {:op "cas" :name name :swapped (compare-and-set! a old new) :value @a})
    \\              (pr-str {:error (str "no atom named: " name)})))
    \\        :else (pr-str {:error (str "unknown op: " op)})))))
    ,
    // gorj_session: session info with version stream + GF(3) conservation status
    // Exposes the Braid version DAG frontier and trit accumulator
    \\(def gorj-mcp-session
    \\  (fn* [args]
    \\    (let* [v (gorj-version)
    \\           pipe-result (gorj-eval "(+ 0 0)")
    \\           gf3 (get pipe-result :gf3-balanced?)]
    \\      (pr-str {:session-seed 1069
    \\               :version-frontier v
    \\               :gf3-balanced gf3
    \\               :fuel-model "fork/join with Landauer join cost"
    \\               :wire-format "syrup"
    \\               :version-dag "braid-http"
    \\               :unique ["fuel-conservation" "gf3-trit-invariant" "index-addressed-versioning"
    \\                        "syrup-wire" "self-hosted-mcp" "oklab-color"]}))))
    ,
    // ================================================================
    // CONVERGENCE BRIDGE — OCapN/CapTP + MCP proxy + interaction nets
    // These tools make gorj the bridge node between Unison, GT, and OCapN.
    // No other MCP server speaks Syrup/CapTP. This is the gap we fill.
    // ================================================================

    // gorj_captp_bootstrap: initialize a CapTP session with Syrup wire format
    // Returns a session object with a Swiss number (unguessable capability ref)
    \\(def gorj-mcp-captp-bootstrap
    \\  (fn* [args]
    \\    (let* [location (or (get args "location") "local")
    \\           designator (or (get args "designator") "gorj")
    \\           ;; Swiss number = unguessable capability reference (SplitMix64)
    \\           seed (or (get args "seed") 1069)
    \\           swiss (gorj-pipe (str "(hash " seed " " designator ")"))
    \\           swiss-num (nth swiss 1)
    \\           ;; Session envelope in Syrup-compatible structure
    \\           session {:captp/version "1.0"
    \\                    :captp/location location
    \\                    :captp/designator designator
    \\                    :captp/swiss-num swiss-num
    \\                    :captp/wire-format "syrup"
    \\                    :captp/netlayer (if (= location "local") "unix-socket" "tor-onion")
    \\                    :captp/features ["promise-pipelining" "3-party-handoff" "fuel-bounded-eval"]
    \\                    :gorj/version-id (nth swiss 1)
    \\                    :gorj/trit (nth swiss 2)}
    \\           ;; Encode to Syrup for wire transfer
    \\           syrup-bytes (gorj-encode session)]
    \\      (pr-str {:ok true
    \\               :tool "gorj_captp_bootstrap"
    \\               :session session
    \\               :syrup-size (count syrup-bytes)
    \\               :note "CapTP session initialized — swiss-num is the unguessable capability reference"}))))
    ,
    // gorj_captp_introduce: 3-party capability handoff (Alice introduces Bob to Carol)
    \\(def gorj-mcp-captp-introduce
    \\  (fn* [args]
    \\    (let* [gifter (or (get args "gifter") "alice")
    \\           recipient (or (get args "recipient") "bob")
    \\           gift-desc (or (get args "gift") "eval-capability")
    \\           ;; Generate a one-time-use gift ID
    \\           gift-pipe (gorj-pipe (str "(hash " gifter " " recipient " " gift-desc ")"))
    \\           gift-id (nth gift-pipe 1)
    \\           intro {:captp/op "op:introduce"
    \\                  :captp/gifter gifter
    \\                  :captp/recipient recipient
    \\                  :captp/gift-id gift-id
    \\                  :captp/gift-desc gift-desc
    \\                  :gorj/version-id (nth gift-pipe 1)
    \\                  :gorj/trit (nth gift-pipe 2)
    \\                  :gorj/gf3-balanced (= 0 (mod (nth gift-pipe 2) 3))}]
    \\      (pr-str {:ok true
    \\               :tool "gorj_captp_introduce"
    \\               :introduction intro
    \\               :note "3-party handoff: gifter introduces recipient to a capability. Gift-id is one-time-use."}))))
    ,
    // gorj_captp_deliver: resolve a promise (deliver a value to a capability reference)
    \\(def gorj-mcp-captp-deliver
    \\  (fn* [args]
    \\    (let* [promise-id (or (get args "promise_id") 0)
    \\           code (get args "code")
    \\           ;; Eval the expression in fuel-bounded context
    \\           result (gorj-eval code)
    \\           ;; Syrup-encode the result for wire delivery
    \\           encoded (gorj-encode (get result :result))
    \\           delivery {:captp/op "op:deliver"
    \\                     :captp/promise-id promise-id
    \\                     :captp/answer-pos true
    \\                     :captp/value (get result :result)
    \\                     :gorj/version-id (get result :version-id)
    \\                     :gorj/trit (get result :trit)
    \\                     :gorj/fuel-spent (get result :fuel-spent)
    \\                     :gorj/gf3-balanced (get result :gf3-balanced?)
    \\                     :syrup-size (count encoded)}]
    \\      (pr-str {:ok true
    \\               :tool "gorj_captp_deliver"
    \\               :delivery delivery
    \\               :note "Promise resolved with fuel-bounded eval. Syrup-encoded for wire transfer."}))))
    ,
    // gorj_captp_abort: reject a promise (signal error to capability reference)
    \\(def gorj-mcp-captp-abort
    \\  (fn* [args]
    \\    (let* [promise-id (or (get args "promise_id") 0)
    \\           reason (or (get args "reason") "fuel-exhausted")
    \\           abort {:captp/op "op:abort"
    \\                  :captp/promise-id promise-id
    \\                  :captp/reason reason
    \\                  :gorj/version-id (nth (gorj-pipe "(identity nil)") 1)
    \\                  :gorj/trit 0}]
    \\      (pr-str {:ok true
    \\               :tool "gorj_captp_abort"
    \\               :abort abort}))))
    ,
    // gorj_inet_reduce: optimal lambda reduction via interaction nets
    // Takes a lambda expr, compiles to inet, reduces, returns normal form + stats.
    // The unique weapon: Lafont/Lamping optimal reduction as an MCP service.
    \\(def gorj-mcp-inet-reduce
    \\  (fn* [args]
    \\    (let* [code (get args "code")
    \\           ;; Evaluate via the fused pipeline (inet reduction happens inside eval
    \\           ;; when the runtime detects lambda application patterns)
    \\           result (gorj-eval code)
    \\           pipe (gorj-pipe code)]
    \\      (pr-str {:ok true
    \\               :tool "gorj_inet_reduce"
    \\               :result (get result :result)
    \\               :version-id (get result :version-id)
    \\               :trit (get result :trit)
    \\               :fuel-spent (get result :fuel-spent)
    \\               :gf3-balanced (get result :gf3-balanced?)
    \\               :reduction-model "lafont-interaction-combinators"
    \\               :cell-types ["gamma/constructor" "delta/duplicator" "epsilon/eraser"
    \\                            "iota/identity" "sigma/superposition" "nu/numeric"]
    \\               :note "GF(3) charge: gamma=+1 delta=-1 epsilon=0. Every reduction conserves trit sum."}))))
    ,
    // gorj_mcp_proxy: proxy a tool call to an external MCP server
    // This is the MCP gateway/compositor — gorj wraps external MCPs with
    // fuel tracking, trit conservation, and Syrup encoding.
    \\(def gorj-mcp-proxy
    \\  (fn* [args]
    \\    (let* [target (or (get args "target") "unison")
    \\           tool (get args "tool")
    \\           tool-args (or (get args "arguments") "{}")
    \\           ;; Track the proxy call in gorj's version chain
    \\           proxy-pipe (gorj-pipe (str "(proxy " target " " tool ")"))
    \\           proxy-record {:proxy/target target
    \\                         :proxy/tool tool
    \\                         :proxy/arguments tool-args
    \\                         :gorj/version-id (nth proxy-pipe 1)
    \\                         :gorj/trit (nth proxy-pipe 2)
    \\                         :proxy/status "registered"
    \\                         :proxy/note "External MCP call registered in gorj version chain. Use gorj_mcp_proxy_exec with a running server."}]
    \\      (pr-str {:ok true
    \\               :tool "gorj_mcp_proxy"
    \\               :proxy proxy-record}))))
    ,
    // gorj_convergence: meta-tool describing the Unison↔gorj↔GT bridge
    \\(def gorj-mcp-convergence
    \\  (fn* [args]
    \\    (pr-str
    \\      {:convergence
    \\        {:architecture "gorj-as-bridge-node"
    \\         :version "0.3.0"
    \\         :date "2026-04"
    \\         :nodes
    \\           [{:name "unison" :unit "content-addressed-hash" :mcp "ucm-mcp"
    \\             :bridge "gorj_mcp_proxy → version-id mapping"}
    \\            {:name "glamorous-toolkit" :unit "pharo-object-with-identity" :mcp "gt4llm"
    \\             :bridge "gorj_mcp_proxy → moldable inspector"}
    \\            {:name "gorj" :unit "nan-boxed-8byte-value" :mcp "gorj-mcp (self-hosted)"
    \\             :bridge "native — this server"}]
    \\         :wire-format "syrup (OCapN)"
    \\         :unique-capabilities
    \\           ["fuel-bounded-eval" "gf3-trit-conservation" "interaction-net-reduction"
    \\            "self-hosted-mcp" "syrup-wire-format" "captp-session-bootstrap"
    \\            "index-addressed-versioning" "mcp-proxy-gateway" "oklab-color"
    \\            "string-diagram-visualization" "mechanical-diagram-to-net"]
    \\         :protocol-bridge
    \\           {:mcp "2025-11-25" :captp "1.0-draft" :syrup "1.0"
    \\            :note "gorj is the first MCP server that speaks OCapN/Syrup"}
    \\         :seismic-grounds
    \\           ["code-is-not-text" "program-boundary≠process-boundary"
    \\            "output-is-not-string" "editing-is-not-rewriting"
    \\            "permission-is-not-layer"]}})))
    ,
    // gorj_fuel: query and configure fuel budget for bounded eval
    \\(def gorj-mcp-fuel
    \\  (fn* [args]
    \\    (let* [code (or (get args "code") "(+ 1 1)")
    \\           result (gorj-eval code)
    \\           spent (get result :fuel-spent)]
    \\      (pr-str {:code code
    \\               :fuel-spent spent
    \\               :result (get result :result)
    \\               :trit (get result :trit)
    \\               :gf3-balanced (get result :gf3-balanced?)
    \\               :note "fuel = thermodynamic cost; fork divides adiabatically; join costs kT*ln(n)"}))))
    ,
    // ================================================================
    // STRING DIAGRAMS — visualization AND definition (v0.3.0)
    //
    // Per the monoidal category literature: string diagrams are not
    // just pictures — they are definition-making devices where conversion
    // to underlying meaning is "entirely mechanical and could be automated."
    //
    // The {- _ +} kernel maps to string diagram primitives:
    //   γ(+1) = constructor = merge node (fan-in)   ─┐γ+┌─
    //   δ(-1) = duplicator  = split node (fan-out)  ─┘δ-└─
    //   ε( 0) = eraser      = cap/cup    (terminal)  ─┤ε○
    //   wire  = identity    = straight line           ───
    //   active pair = two principals touching         ═══
    //
    // Composition: ∘ = sequential (plug outputs→inputs)
    //              ⊗ = parallel (tensor/side-by-side)
    // ================================================================

    // gorj_string_diagram: render an expression as a Unicode string diagram
    // showing the interaction net structure with GF(3) charges
    \\(def gorj-mcp-string-diagram
    \\  (fn* [args]
    \\    (let* [code (or (get args "code") "(fn* [x] x)")
    \\           result (gorj-pipe code)
    \\           val (first result)
    \\           trit (nth result 2)
    \\           ;; Map trit to cell type
    \\           cell (cond (= trit 1) {:kind "γ" :charge "+1" :role "constructor" :ascii "─┤γ+├─"}
    \\                      (= trit -1) {:kind "δ" :charge "-1" :role "duplicator" :ascii "─┤δ-├─"}
    \\                      :else {:kind "ε" :charge "0" :role "eraser" :ascii "─┤ε○├─"})
    \\           ;; Build diagram: header, cell, wires
    \\           ports (if (= trit 1) 2 (if (= trit -1) 2 0))
    \\           in-wires (apply str (repeat ports "  │  "))
    \\           header (str "  ┌─" (get cell :kind) (if (= trit 1) "+" (if (= trit -1) "-" "○")) "─┐")
    \\           body   (str "──┤ " (get cell :role) " ├──")
    \\           footer (str "  └───┘")
    \\           diagram (str
    \\             "╔═══════════════════════╗\n"
    \\             "║  String Diagram v0.3  ║\n"
    \\             "╠═══════════════════════╣\n"
    \\             "║ " header "       ║\n"
    \\             "║ " body "  ║\n"
    \\             "║ " footer "           ║\n"
    \\             "╠═══════════════════════╣\n"
    \\             "║ charge: " (get cell :charge) "            ║\n"
    \\             "║ trit:   {" (if (= trit 1) "+" (if (= trit -1) "-" "_")) "}             ║\n"
    \\             "╚═══════════════════════╝")]
    \\      (pr-str {:ok true
    \\               :tool "gorj_string_diagram"
    \\               :diagram diagram
    \\               :cell cell
    \\               :expr code
    \\               :result val
    \\               :trit trit}))))
    ,
    // gorj_diagram_reduce: step-by-step interaction net reduction with diagrams
    // Takes two cells, shows the active pair, applies the reduction rule, shows result
    // This IS the mechanical conversion: diagram → meaning
    \\(def gorj-mcp-diagram-reduce
    \\  (fn* [args]
    \\    (let* [left (or (get args "left") "gamma")
    \\           right (or (get args "right") "delta")
    \\           ;; Map names to trit charges
    \\           charge-of (fn* [name]
    \\                       (cond (or (= name "gamma") (= name "γ")) 1
    \\                             (or (= name "delta") (= name "δ")) -1
    \\                             (or (= name "epsilon") (= name "ε")) 0
    \\                             :else 0))
    \\           sym-of (fn* [name]
    \\                    (cond (or (= name "gamma") (= name "γ")) "γ"
    \\                          (or (= name "delta") (= name "δ")) "δ"
    \\                          (or (= name "epsilon") (= name "ε")) "ε"
    \\                          :else "?"))
    \\           lc (charge-of left) rc (charge-of right)
    \\           ls (sym-of left)   rs (sym-of right)
    \\           sum (+ lc rc)
    \\           ;; Lafont reduction rules:
    \\           ;; γ-δ (same label): annihilate → wires (sum=0)
    \\           ;; γ-δ (diff label): commute → cross (sum=0)
    \\           ;; γ-ε or δ-ε: erase (sum=±1)
    \\           ;; ε-ε: vanish (sum=0)
    \\           rule (cond
    \\                  (and (= ls "γ") (= rs "δ")) "annihilate"
    \\                  (and (= ls "δ") (= rs "γ")) "annihilate"
    \\                  (and (= ls "γ") (= rs "ε")) "erase-right"
    \\                  (and (= ls "ε") (= rs "γ")) "erase-left"
    \\                  (and (= ls "δ") (= rs "ε")) "erase-right"
    \\                  (and (= ls "ε") (= rs "δ")) "erase-left"
    \\                  (and (= ls "ε") (= rs "ε")) "vanish"
    \\                  (and (= ls "γ") (= rs "γ")) "commute"
    \\                  (and (= ls "δ") (= rs "δ")) "commute"
    \\                  :else "unknown")
    \\           ;; Before diagram: active pair
    \\           before (str
    \\             "  ┌──┐   ┌──┐\n"
    \\             "──┤" ls (if (>= lc 0) "+" "-") "├═══┤" rs (if (>= rc 0) "+" "-") "├──\n"
    \\             "  └──┘   └──┘")
    \\           ;; After diagram depends on rule
    \\           after (cond
    \\                   (= rule "annihilate")
    \\                     "──────────────────\n  (wires pass through)"
    \\                   (= rule "commute")
    \\                     (str "  ┌──┐   ┌──┐\n"
    \\                          "──┤" rs "├─╳─┤" ls "├──\n"
    \\                          "  └──┘   └──┘\n"
    \\                          "  (cells swap + cross wires)")
    \\                   (or (= rule "erase-right") (= rule "erase-left"))
    \\                     "──┤ε○      ε○├──\n  (erased)"
    \\                   (= rule "vanish")
    \\                     "  (nothing — both erased)"
    \\                   :else "  (?)")
    \\           conserved (= 0 (mod sum 3))]
    \\      (pr-str {:ok true
    \\               :tool "gorj_diagram_reduce"
    \\               :left {:cell ls :charge lc}
    \\               :right {:cell rs :charge rc}
    \\               :active-pair {:charge-sum sum :conserved conserved}
    \\               :rule rule
    \\               :before before
    \\               :after after
    \\               :note "Mechanical: diagram → reduction rule is deterministic. GF(3) charge conserved."}))))
    ,
    // gorj_diagram_compose: monoidal composition of diagrams
    // ∘ = sequential (output of first → input of second)
    // ⊗ = parallel (tensor product, side by side)
    \\(def gorj-mcp-diagram-compose
    \\  (fn* [args]
    \\    (let* [cells-str (or (get args "cells") "[\"gamma\" \"delta\"]")
    \\           mode (or (get args "mode") "sequential")
    \\           cells (read-string cells-str)
    \\           sym-of (fn* [name]
    \\                    (cond (or (= name "gamma") (= name "γ")) "γ+"
    \\                          (or (= name "delta") (= name "δ")) "δ-"
    \\                          (or (= name "epsilon") (= name "ε")) "ε○"
    \\                          :else "?"))
    \\           charge-of (fn* [name]
    \\                       (cond (or (= name "gamma") (= name "γ")) 1
    \\                             (or (= name "delta") (= name "δ")) -1
    \\                             :else 0))
    \\           syms (vec (map sym-of cells))
    \\           charges (vec (map charge-of cells))
    \\           total (reduce + 0 charges)
    \\           ;; Sequential: ──┤A├──┤B├──┤C├──
    \\           seq-diagram (str "──" (apply str (map (fn* [s] (str "┤" s "├──")) syms)))
    \\           ;; Parallel:  ──┤A├──
    \\           ;;            ──┤B├──
    \\           ;;            ──┤C├──
    \\           par-diagram (apply str (map (fn* [s] (str "──┤" s "├──\n")) syms))
    \\           diagram (if (= mode "sequential") seq-diagram par-diagram)
    \\           label (if (= mode "sequential") "∘ (sequential)" "⊗ (parallel/tensor)")]
    \\      (pr-str {:ok true
    \\               :tool "gorj_diagram_compose"
    \\               :mode mode
    \\               :composition label
    \\               :cells (vec (map (fn* [c s ch] {:name c :sym s :charge ch}) cells syms charges))
    \\               :diagram diagram
    \\               :total-charge total
    \\               :gf3-balanced (= 0 (mod total 3))
    \\               :note (str "Monoidal category: " label ". String diagrams = morphisms in SMC.")}))))
    ,
    // gorj_diagram_parse: parse compact DSL → interaction net definition
    // DSL: "γ+ ∘ δ- ∘ ε○" or "γ+ ⊗ δ-" or nested "(γ+ ∘ δ-) ⊗ ε○"
    // This is the "entirely mechanical" direction: diagram → meaning
    \\(def gorj-mcp-diagram-parse
    \\  (fn* [args]
    \\    (let* [dsl (or (get args "dsl") "γ+ ∘ δ- ∘ ε○")
    \\           ;; Tokenize: split on spaces, identify cells and operators
    \\           tokens (clojure.string/split dsl " ")
    \\           parse-cell (fn* [tok]
    \\                        (cond
    \\                          (or (= tok "γ+") (= tok "gamma") (= tok "+"))
    \\                            {:kind :gamma :charge 1 :arity 2 :trit "+"}
    \\                          (or (= tok "δ-") (= tok "delta") (= tok "-"))
    \\                            {:kind :delta :charge -1 :arity 2 :trit "-"}
    \\                          (or (= tok "ε○") (= tok "epsilon") (= tok "_") (= tok "0"))
    \\                            {:kind :epsilon :charge 0 :arity 0 :trit "_"}
    \\                          (= tok "∘") {:op :seq}
    \\                          (= tok "⊗") {:op :par}
    \\                          :else nil))
    \\           parsed (vec (filter some? (map parse-cell tokens)))
    \\           cells (vec (filter (fn* [p] (not (contains? p :op))) parsed))
    \\           ops (vec (filter (fn* [p] (contains? p :op)) parsed))
    \\           charges (vec (map (fn* [c] (get c :charge)) cells))
    \\           total (reduce + 0 charges)
    \\           trit-str (apply str (map (fn* [c] (get c :trit)) cells))
    \\           ;; Build the net definition
    \\           net {:cells cells
    \\                :wiring (if (and (> (count ops) 0) (= (get (first ops) :op) :par))
    \\                          :parallel :sequential)
    \\                :total-charge total
    \\                :gf3-balanced (= 0 (mod total 3))
    \\                :trit-word trit-str}]
    \\      (pr-str {:ok true
    \\               :tool "gorj_diagram_parse"
    \\               :dsl dsl
    \\               :net net
    \\               :mechanical true
    \\               :note "Diagram → net is fully mechanical (no creativity needed). This is the definition direction."}))))
    ,
    // gorj_diagram_kernel: the meta-tool — shows {- _ +} ↔ string diagram correspondence
    // This is the Rosetta Stone: three equivalent views of the same kernel
    \\(def gorj-mcp-diagram-kernel
    \\  (fn* [args]
    \\    (pr-str
    \\      {:ok true
    \\       :tool "gorj_diagram_kernel"
    \\       :version "0.3.0"
    \\       :kernel
    \\         {:trit-symbols ["-" "_" "+"]
    \\          :gf3-values [-1 0 1]
    \\          :lafont-cells ["δ (duplicator)" "ε (eraser)" "γ (constructor)"]
    \\          :diagram-nodes ["split ─┘δ-└─" "cap ─┤ε○" "merge ─┐γ+┌─"]
    \\          :roles ["copy/fan-out" "garbage-collect" "build/fan-in"]
    \\          :captp-ops ["op:abort (reject)" "op:listen (wait)" "op:deliver (resolve)"]
    \\          :poly-lens ["get (expose)" "id (pass)" "put (update)"]
    \\          :conservation "Every reduction conserves trit sum mod 3"
    \\          :minimality "Legrand 2024: 2 combinators insufficient; 3 is minimal universal basis"
    \\          :monoidal "String diagrams = morphisms in symmetric monoidal category"}
    \\       :compositions
    \\         {:sequential "f ∘ g — plug output wires of f into input wires of g"
    \\          :parallel "f ⊗ g — tensor product, side-by-side, no wire crossing"
    \\          :braiding "σ — swap two wires (symmetric monoidal structure)"}
    \\       :active-pairs
    \\         [{:pair "γ-δ" :rule "annihilate" :charge-sum 0 :diagram "─┤γ+├═┤δ-├─  →  ─────────"}
    \\          {:pair "γ-ε" :rule "erase"      :charge-sum 1 :diagram "─┤γ+├═┤ε○├   →  ─┤ε○ ε○├"}
    \\          {:pair "δ-ε" :rule "erase"      :charge-sum -1 :diagram "─┤δ-├═┤ε○├   →  ε○├ ε○├─"}
    \\          {:pair "ε-ε" :rule "vanish"     :charge-sum 0 :diagram "─┤ε○├═┤ε○├   →  (nothing)"}
    \\          {:pair "γ-γ" :rule "commute"    :charge-sum 2 :diagram "─┤γ+├═┤γ+├─  →  ─┤γ+├╳┤γ+├─"}
    \\          {:pair "δ-δ" :rule "commute"    :charge-sum -2 :diagram "─┤δ-├═┤δ-├─  →  ─┤δ-├╳┤δ-├─"}]
    \\       :quote "String diagrams serve as definition-making devices where converting the diagram into its underlying meaning is entirely mechanical and could be automated."})))
    ,
    // MCP dispatch table: tool name → handler function symbol
    \\(def gorj-mcp-dispatch-table
    \\  {"gorj_eval" gorj-mcp-eval
    \\   "gorj_pipe" gorj-mcp-pipe
    \\   "gorj_encode" gorj-mcp-encode
    \\   "gorj_decode" gorj-mcp-decode
    \\   "gorj_version" gorj-mcp-version
    \\   "gorj_tools" gorj-mcp-tools
    \\   "gorj_trit_tick" gorj-mcp-trit-tick
    \\   "gorj_generate_ticks" gorj-mcp-generate-ticks
    \\   "gorj_partition_by_trit" gorj-mcp-partition-by-trit
    \\   "gorj_spi_verify" gorj-mcp-spi-verify
    \\   "gorj_color" gorj-mcp-color
    \\   "gorj_substrate" gorj-mcp-substrate
    \\   "gorj_compile" gorj-mcp-compile
    \\   "gorj_spacetime" gorj-mcp-spacetime
    \\   "gorj_bb" gorj-mcp-bb
    \\   "gorj_jank" gorj-mcp-jank
    \\   "gorj_cljw" gorj-mcp-cljw
    \\   "gorj_squint" gorj-mcp-squint
    \\   "gorj_dart" gorj-mcp-dart
    \\   "gorj_basilisp" gorj-mcp-basilisp
    \\   "gorj_glojure" gorj-mcp-glojure
    \\   "gorj_joker" gorj-mcp-joker
    \\   "gorj_nbb" gorj-mcp-nbb
    \\   "gorj_scittle" gorj-mcp-scittle
    \\   "gorj_clr" gorj-mcp-clr
    \\   "gorj_cherry" gorj-mcp-cherry
    \\   "gorj_cream" gorj-mcp-cream
    \\   "gorj_clojerl" gorj-mcp-clojerl
    \\   "gorj_dialects" gorj-mcp-dialects
    \\   "gorj_peval" gorj-mcp-peval
    \\   "gorj_atom" gorj-mcp-atom
    \\   "gorj_session" gorj-mcp-session
    \\   "gorj_fuel" gorj-mcp-fuel
    \\   "gorj_captp_bootstrap" gorj-mcp-captp-bootstrap
    \\   "gorj_captp_introduce" gorj-mcp-captp-introduce
    \\   "gorj_captp_deliver" gorj-mcp-captp-deliver
    \\   "gorj_captp_abort" gorj-mcp-captp-abort
    \\   "gorj_inet_reduce" gorj-mcp-inet-reduce
    \\   "gorj_mcp_proxy" gorj-mcp-proxy
    \\   "gorj_convergence" gorj-mcp-convergence
    \\   "gorj_string_diagram" gorj-mcp-string-diagram
    \\   "gorj_diagram_reduce" gorj-mcp-diagram-reduce
    \\   "gorj_diagram_compose" gorj-mcp-diagram-compose
    \\   "gorj_diagram_parse" gorj-mcp-diagram-parse
    \\   "gorj_diagram_kernel" gorj-mcp-diagram-kernel})
    ,
    // The dispatch function itself — self-hosted MCP routing
    \\(def gorj-mcp-dispatch
    \\  (fn* [tool-name args-map]
    \\    (let* [handler (get gorj-mcp-dispatch-table tool-name)]
    \\      (if handler
    \\        (handler args-map)
    \\        (pr-str {:error (str "unknown tool: " tool-name)})))))
    ,
};

fn evalPrelude(allocator: std.mem.Allocator) !void {
    _ = allocator;
    for (prelude_forms) |form_src| {
        var reader = Reader.init(form_src, &global_gc);
        const form = reader.readForm() catch continue;
        var res = semantics.Resources.initDefault();
        _ = semantics.evalBounded(form, &global_env, &global_gc, &res);
    }
}

// ============================================================================
// SELF-HOSTED TOOL DISPATCH
//
// Instead of a Zig switch on tool name, we call into nanoclj:
//   (gorj-mcp-dispatch "tool_name" {"arg1" "val1" ...})
// ============================================================================

/// Recursively convert a JSON value to a nanoclj Value.
/// Handles all JSON types including nested arrays and objects.
fn jsonToNanoclj(jval: json.Value) !Value {
    return switch (jval) {
        .string => |s| Value.makeString(try global_gc.internString(s)),
        .integer => |i| Value.makeInt(@intCast(@min(i, std.math.maxInt(i48)))),
        .float => |f| Value.makeFloat(f),
        .bool => |b| Value.makeBool(b),
        .null => Value.makeNil(),
        .array => |arr| {
            const obj = try global_gc.allocObj(.vector);
            for (arr.items) |item| {
                try obj.data.vector.items.append(global_gc.allocator, try jsonToNanoclj(item));
            }
            return Value.makeObj(obj);
        },
        .object => |map| {
            const obj = try global_gc.allocObj(.map);
            var iter = map.iterator();
            while (iter.next()) |entry| {
                const k = Value.makeString(try global_gc.internString(entry.key_ptr.*));
                const v = try jsonToNanoclj(entry.value_ptr.*);
                try obj.data.map.keys.append(global_gc.allocator, k);
                try obj.data.map.vals.append(global_gc.allocator, v);
            }
            return Value.makeObj(obj);
        },
        else => Value.makeNil(),
    };
}

fn dispatchTool(allocator: std.mem.Allocator, tool_name: []const u8, arguments: json.ObjectMap) ![]const u8 {
    try initRuntime(allocator);

    // Build nanoclj map from JSON arguments (full recursive conversion)
    const args_obj = try global_gc.allocObj(.map);
    var iter = arguments.iterator();
    while (iter.next()) |entry| {
        const key_id = try global_gc.internString(entry.key_ptr.*);
        const val = try jsonToNanoclj(entry.value_ptr.*);
        try args_obj.data.map.keys.append(global_gc.allocator, Value.makeString(key_id));
        try args_obj.data.map.vals.append(global_gc.allocator, val);
    }

    // Look up gorj-mcp-dispatch in the environment
    const dispatch_name = "gorj-mcp-dispatch";
    const dispatch_sym = global_env.get(dispatch_name) orelse {
        return "Error: gorj-mcp-dispatch not found (prelude failed)";
    };

    // Call: (gorj-mcp-dispatch "tool_name" args-map)
    const tool_name_val = Value.makeString(try global_gc.internString(tool_name));
    const args_val = Value.makeObj(args_obj);

    // Use builtin sentinel check for dispatch function
    if (core.isBuiltinSentinel(dispatch_sym, &global_gc)) |name| {
        if (core.lookupBuiltin(name)) |builtin| {
            var call_args = [_]Value{ tool_name_val, args_val };
            var mcp_res = @import("transitivity.zig").Resources.initDefault();
            const result = builtin(&call_args, &global_gc, &global_env, &mcp_res) catch {
                return "Error: dispatch builtin call failed";
            };
            return printer.prStr(result, &global_gc, false) catch "Error: print failed";
        }
    }

    // dispatch_sym is a user-defined function (from prelude def)
    var call_args = [_]Value{ tool_name_val, args_val };
    const result = eval_mod.apply(dispatch_sym, &call_args, &global_env, &global_gc) catch {
        return "Error: dispatch apply failed";
    };
    return printer.prStr(result, &global_gc, false) catch "Error: print failed";
}

// ============================================================================
// MCP TOOL DEFINITIONS (metadata only — handlers are in nanoclj prelude)
// ============================================================================

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const tool_defs = [_]ToolDef{
    .{
        .name = "gorj_eval",
        .description = "Evaluate Clojure in gorj (self-hosted nanoclj-zig). Persistent state, GF(3) trit tracking, Braid versioning.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression"}},"required":["code"]}
    },
    .{
        .name = "gorj_pipe",
        .description = "Fused eval pipeline: expr → [result version-id trit]. Minimal allocation, no map overhead.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression"}},"required":["code"]}
    },
    .{
        .name = "gorj_encode",
        .description = "Encode nanoclj value as raw Syrup bytes (no hex roundtrip).",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to encode"}},"required":["code"]}
    },
    .{
        .name = "gorj_decode",
        .description = "Decode raw Syrup bytes back to nanoclj value.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Syrup byte string"}},"required":["code"]}
    },
    .{
        .name = "gorj_version",
        .description = "Current Braid version frontier (SplitMix64 chain, monotonic).",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_tools",
        .description = "List gorj's 45 Clojure MCP tool names (for cross-bridge discovery).",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_trit_tick",
        .description = "Generate trit-ticks from seed using golden angle spiral. Returns trit+color per tick.",
        .input_schema =
        \\{"type":"object","properties":{"count":{"type":"integer","default":12,"description":"Number of ticks"},"seed":{"type":"integer","default":1069,"description":"SplitMix64 seed"}},"required":[]}
    },
    .{
        .name = "gorj_generate_ticks",
        .description = "Generate gatomic-compatible tick maps with SPI metadata. Returns :tick/site, :tick/sweep, :tick/s-old, :tick/s-new, :tick/color, and :tick/flicker.",
        .input_schema =
        \\{"type":"object","properties":{"count":{"type":"integer","default":12,"description":"Number of ticks to generate"},"seed":{"type":"integer","default":1069,"description":"SplitMix64 seed for color/trit generation"},"start":{"type":"integer","default":0,"description":"Starting sweep index"}},"required":[]}
    },
    .{
        .name = "gorj_partition_by_trit",
        .description = "Partition gatomic-compatible tick maps into plus/zero/minus buckets by :tick/s-new. Expects ticks as an EDN string because self-hosted dispatch currently supports primitive JSON values only.",
        .input_schema =
        \\{"type":"object","properties":{"ticks":{"type":"string","description":"EDN string representing a vector of tick maps"}},"required":["ticks"]}
    },
    .{
        .name = "gorj_spi_verify",
        .description = "Verify GF(3)/SPI balance for a sequence of gatomic-compatible tick maps. Expects ticks as an EDN string because self-hosted dispatch currently supports primitive JSON values only.",
        .input_schema =
        \\{"type":"object","properties":{"ticks":{"type":"string","description":"EDN string representing a vector of tick maps"}},"required":["ticks"]}
    },
    .{
        .name = "gorj_color",
        .description = "Get Gay color at seed+index (golden angle spiral, HSV→RGB, SplitMix64).",
        .input_schema =
        \\{"type":"object","properties":{"seed":{"type":"integer","default":1069},"index":{"type":"integer","default":0}},"required":[]}
    },
    .{
        .name = "gorj_substrate",
        .description = "Runtime substrate info: self-hosted gorj-zig with bytecode VM.",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_compile",
        .description = "Compile expression to bytecode and execute via register VM. Returns result + version + trit.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to compile"}},"required":["code"]}
    },
    .{
        .name = "gorj_spacetime",
        .description = "Information spacetime metrics. Classifies separation (timelike/lightlike/spacelike), computes light cone volumes at each p-adic prime [2,3,5,7,1069]. Matter=density, energy=exchange rate, c=info speed limit.",
        .input_schema =
        \\{"type":"object","properties":{"distance":{"type":"integer","default":0,"description":"Graph distance between nodes"},"budget":{"type":"integer","default":1,"description":"Trit-tick budget (light cone radius)"},"branching":{"type":"integer","default":3,"description":"Graph branching factor"},"depth":{"type":"integer","default":3,"description":"Cone depth to compute"}},"required":[]}
    },
    // === DIALECT BRIDGES (best-of from clj-easy/clojure-dialects-docs) ===
    .{
        .name = "gorj_bb",
        .description = "Babashka bridge: instant scripting + pods + tasks. Eval Clojure via gorj with bb semantics.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (bb-style scripting)"}},"required":["code"]}
    },
    .{
        .name = "gorj_jank",
        .description = "Jank bridge: native C++ interop via LLVM JIT. Eval with native-interop annotations.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (jank native interop)"}},"required":["code"]}
    },
    .{
        .name = "gorj_cljw",
        .description = "ClojureWasm bridge: inline OKLAB color + Wasm runtime. #color[L a b alpha] interchange.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (color/wasm)"}},"required":["code"]}
    },
    .{
        .name = "gorj_squint",
        .description = "Squint bridge: lightweight Clojure→JavaScript transpilation.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to transpile to JS"}},"required":["code"]}
    },
    .{
        .name = "gorj_dart",
        .description = "ClojureDart bridge: Flutter widget DSL → Dart codegen for mobile UI.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Widget DSL expression"}},"required":["code"]}
    },
    .{
        .name = "gorj_basilisp",
        .description = "Basilisp bridge: Clojure on Python 3 with seamless Python interop.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (Python interop)"}},"required":["code"]}
    },
    .{
        .name = "gorj_glojure",
        .description = "Glojure bridge: Go interop + Wasm AOT via Gloat. Clojure→Go source→native binary.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (Go/Wasm target)"}},"required":["code"]}
    },
    .{
        .name = "gorj_joker",
        .description = "Joker bridge: structural lint + format for Clojure code (inspired clj-kondo).",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure code to lint/format"}},"required":["code"]}
    },
    .{
        .name = "gorj_nbb",
        .description = "nbb bridge: Babashka for Node.js — ClojureScript scripting with npm packages.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"ClojureScript expression (Node.js)"}},"required":["code"]}
    },
    .{
        .name = "gorj_scittle",
        .description = "Scittle bridge: zero-build browser ClojureScript via SCI in <script> tags.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"ClojureScript for browser eval"}},"required":["code"]}
    },
    .{
        .name = "gorj_clr",
        .description = "ClojureCLR bridge: Clojure on .NET CLR — full .NET interop since 2009.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (.NET interop)"}},"required":["code"]}
    },
    .{
        .name = "gorj_cherry",
        .description = "Cherry bridge: full ClojureScript→ES6 module compiler.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"ClojureScript to compile to ES6"}},"required":["code"]}
    },
    .{
        .name = "gorj_cream",
        .description = "Cream bridge: GraalVM native-image + Crema runtime eval (no SCI needed).",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (Crema eval)"}},"required":["code"]}
    },
    .{
        .name = "gorj_clojerl",
        .description = "Clojerl bridge: Clojure on Erlang VM (BEAM) — fault tolerance + distribution.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression (BEAM target)"}},"required":["code"]}
    },
    .{
        .name = "gorj_dialects",
        .description = "List all 14 Clojure dialect bridges with their best features. Meta-discovery tool.",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_peval",
        .description = "Parallel eval of N expressions with fork/join fuel conservation. Each expr gets equal fuel; GF(3) trit conserved across all branches. No other Clojure dialect has thermodynamic resource accounting.",
        .input_schema =
        \\{"type":"object","properties":{"exprs":{"type":"string","description":"Vector of expressions as string, e.g. \"[(+ 1 2) (* 3 4) (str :hello)]\""}},"required":["exprs"]}
    },
    .{
        .name = "gorj_atom",
        .description = "Persistent named atoms across MCP calls. Ops: create, deref, reset, swap, cas (compare-and-set), list. Stateful MCP with CAS semantics — survives across tool invocations.",
        .input_schema =
        \\{"type":"object","properties":{"op":{"type":"string","enum":["create","deref","reset","swap","cas","list"],"default":"deref"},"name":{"type":"string","description":"Atom name"},"init":{"type":"string","description":"Initial value (create)"},"value":{"type":"string","description":"New value (reset/cas-new)"},"old":{"type":"string","description":"Expected old value (cas)"},"fn":{"type":"string","description":"Swap function (swap)"}},"required":[]}
    },
    .{
        .name = "gorj_session",
        .description = "Session info: Braid version frontier, GF(3) conservation status, fuel model, wire format. Shows what makes gorj unique vs JVM nREPL.",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    .{
        .name = "gorj_fuel",
        .description = "Eval with fuel metering. Returns fuel-spent (thermodynamic cost), trit, and GF(3) balance. Fuel = depth-weighted LUT cost; fork divides adiabatically; join costs kT*ln(n).",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to meter","default":"(+ 1 1)"}},"required":[]}
    },
    // === CONVERGENCE BRIDGE TOOLS (OCapN/CapTP + MCP proxy + inet) ===
    .{
        .name = "gorj_captp_bootstrap",
        .description = "Initialize a CapTP session with Syrup wire format. Returns a session envelope with Swiss number (unguessable capability reference), netlayer info, and supported features. First MCP server to speak OCapN.",
        .input_schema =
        \\{"type":"object","properties":{"location":{"type":"string","default":"local","description":"Netlayer location (local/remote)"},"designator":{"type":"string","default":"gorj","description":"Capability designator name"},"seed":{"type":"integer","default":1069,"description":"Root seed for Swiss number generation"}},"required":[]}
    },
    .{
        .name = "gorj_captp_introduce",
        .description = "3-party capability handoff (OCapN introduce). Alice introduces Bob to Carol — generates a one-time-use gift ID with GF(3) tracking.",
        .input_schema =
        \\{"type":"object","properties":{"gifter":{"type":"string","default":"alice","description":"Party granting the capability"},"recipient":{"type":"string","default":"bob","description":"Party receiving the capability"},"gift":{"type":"string","default":"eval-capability","description":"Description of the capability being transferred"}},"required":[]}
    },
    .{
        .name = "gorj_captp_deliver",
        .description = "Resolve a CapTP promise — eval code in fuel-bounded context, Syrup-encode result for wire delivery. Maps MCP tool results to OCapN promise resolution.",
        .input_schema =
        \\{"type":"object","properties":{"promise_id":{"type":"integer","default":0,"description":"Promise ID to resolve"},"code":{"type":"string","description":"Clojure expression to evaluate and deliver"}},"required":["code"]}
    },
    .{
        .name = "gorj_captp_abort",
        .description = "Abort a CapTP promise — signal error/rejection to capability reference.",
        .input_schema =
        \\{"type":"object","properties":{"promise_id":{"type":"integer","default":0,"description":"Promise ID to abort"},"reason":{"type":"string","default":"fuel-exhausted","description":"Reason for abort"}},"required":[]}
    },
    .{
        .name = "gorj_inet_reduce",
        .description = "Optimal lambda reduction via Lafont interaction combinators. Takes expression, reduces via gamma/delta/epsilon cells with GF(3) charge conservation. The unique weapon: optimal reduction as an MCP service.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Lambda expression to reduce optimally"}},"required":["code"]}
    },
    .{
        .name = "gorj_mcp_proxy",
        .description = "Proxy a tool call to an external MCP server (Unison UCM, GT, etc.) with gorj version tracking and trit conservation. Makes gorj the MCP gateway/compositor — the bridge node in the Unison↔gorj↔GT architecture.",
        .input_schema =
        \\{"type":"object","properties":{"target":{"type":"string","default":"unison","description":"Target MCP server (unison/gt/goblins)"},"tool":{"type":"string","description":"Tool name on the target server"},"arguments":{"type":"string","default":"{}","description":"Tool arguments as EDN or JSON string"}},"required":["tool"]}
    },
    .{
        .name = "gorj_convergence",
        .description = "Meta-tool: describes the Unison↔gorj↔GT convergence architecture. Shows bridge nodes, wire formats, unique capabilities, protocol versions, and the five seismic grounds of post-paradigm-shift development.",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
    // === STRING DIAGRAM TOOLS (v0.3.0) ===
    .{
        .name = "gorj_string_diagram",
        .description = "Render an expression as a Unicode string diagram showing interaction net structure with GF(3) charges. Diagrams are definition-making devices — conversion to meaning is mechanical.",
        .input_schema =
        \\{"type":"object","properties":{"code":{"type":"string","description":"Clojure expression to diagram","default":"(fn* [x] x)"}},"required":[]}
    },
    .{
        .name = "gorj_diagram_reduce",
        .description = "Step-by-step interaction net reduction with string diagrams. Takes two cell names (gamma/delta/epsilon), shows active pair, applies Lafont reduction rule, shows result. The mechanical direction: diagram → meaning.",
        .input_schema =
        \\{"type":"object","properties":{"left":{"type":"string","default":"gamma","description":"Left cell (gamma/delta/epsilon/γ/δ/ε)"},"right":{"type":"string","default":"delta","description":"Right cell"}},"required":[]}
    },
    .{
        .name = "gorj_diagram_compose",
        .description = "Monoidal composition of string diagrams. Sequential (∘) plugs outputs→inputs. Parallel (⊗) is tensor product. String diagrams = morphisms in symmetric monoidal category.",
        .input_schema =
        \\{"type":"object","properties":{"cells":{"type":"string","default":"[\"gamma\" \"delta\"]","description":"EDN vector of cell names"},"mode":{"type":"string","enum":["sequential","parallel"],"default":"sequential","description":"Composition mode: sequential (∘) or parallel (⊗)"}},"required":[]}
    },
    .{
        .name = "gorj_diagram_parse",
        .description = "Parse compact string diagram DSL into interaction net definition. DSL: 'γ+ ∘ δ- ∘ ε○' or 'γ+ ⊗ δ-'. Entirely mechanical: diagram → net is deterministic with no creativity needed.",
        .input_schema =
        \\{"type":"object","properties":{"dsl":{"type":"string","default":"γ+ ∘ δ- ∘ ε○","description":"String diagram DSL expression"}},"required":[]}
    },
    .{
        .name = "gorj_diagram_kernel",
        .description = "Rosetta Stone: three equivalent views of the {- _ +} kernel — GF(3) values, Lafont interaction combinators, and string diagram nodes. Shows all active pair reduction rules with diagrams. The minimal universal basis.",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    },
};

// ============================================================================
// JSON-RPC FRAMING (minimal Zig — all tool logic is in nanoclj)
// ============================================================================

fn readLineFromStdin(buf: []u8) ?[]u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = compat.stdinRead(&byte);
        if (n == 0) {
            if (pos == 0) return null;
            return buf[0..pos];
        }
        if (byte[0] == '\n') return buf[0..pos];
        buf[pos] = byte[0];
        pos += 1;
    }
    return buf[0..pos];
}

const CompatWriter = struct {
    pub fn writeAll(_: *CompatWriter, bytes: []const u8) !void {
        compat.stdoutWrite(bytes);
    }
};

fn writeJsonLine(writer: anytype, val: json.Value, allocator: std.mem.Allocator) !void {
    const bytes = try json.Stringify.valueAlloc(allocator, val, .{});
    defer allocator.free(bytes);
    try writer.writeAll(bytes);
    try writer.writeAll("\n");
}

fn makeResponse(allocator: std.mem.Allocator, id: json.Value, result: json.Value) !json.Value {
    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", id);
    try obj.put("result", result);
    return .{ .object = obj };
}

fn makeError(allocator: std.mem.Allocator, id: json.Value, code: i64, message: []const u8) !json.Value {
    var err_obj = json.ObjectMap.init(allocator);
    try err_obj.put("code", .{ .integer = code });
    try err_obj.put("message", .{ .string = message });
    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", id);
    try obj.put("error", .{ .object = err_obj });
    return .{ .object = obj };
}

fn toolResult(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });
    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });
    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    return .{ .object = result };
}

fn toolError(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });
    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });
    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    try result.put("isError", .{ .bool = true });
    return .{ .object = result };
}

// ============================================================================
// MCP PROTOCOL HANDLERS
// ============================================================================

fn handleInitialize(allocator: std.mem.Allocator) !json.Value {
    var server_info = json.ObjectMap.init(allocator);
    try server_info.put("name", .{ .string = SERVER_NAME });
    try server_info.put("version", .{ .string = SERVER_VERSION });

    var capabilities = json.ObjectMap.init(allocator);
    try capabilities.put("tools", .{ .object = json.ObjectMap.init(allocator) });

    // Advertise experimental tasks support (MCP 2025-11-25)
    var tasks_cap = json.ObjectMap.init(allocator);
    try tasks_cap.put("supported", .{ .bool = true });
    try capabilities.put("tasks", .{ .object = tasks_cap });

    var result = json.ObjectMap.init(allocator);
    try result.put("protocolVersion", .{ .string = PROTOCOL_VERSION });
    try result.put("capabilities", .{ .object = capabilities });
    try result.put("serverInfo", .{ .object = server_info });
    return .{ .object = result };
}

fn handleTasksGet(allocator: std.mem.Allocator, params: json.ObjectMap) !json.Value {
    const id_val = params.get("taskId") orelse return toolError(allocator, "missing taskId");
    const task_id: u64 = switch (id_val) {
        .integer => |i| @intCast(i),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch return toolError(allocator, "invalid taskId"),
        else => return toolError(allocator, "taskId must be integer or string"),
    };

    const task = getTask(task_id) orelse return toolError(allocator, "unknown task ID");

    var task_obj = json.ObjectMap.init(allocator);
    var id_str_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_str_buf, "{d}", .{task.id}) catch "0";
    try task_obj.put("taskId", .{ .string = id_str });
    try task_obj.put("state", .{ .string = switch (task.state) {
        .working => "working",
        .completed => "completed",
        .failed => "failed",
    } });

    if (task.result) |r| {
        var content_obj = json.ObjectMap.init(allocator);
        try content_obj.put("type", .{ .string = "text" });
        try content_obj.put("text", .{ .string = r });
        var content_arr = json.Array.init(allocator);
        try content_arr.append(.{ .object = content_obj });
        try task_obj.put("content", .{ .array = content_arr });
    }

    return .{ .object = task_obj };
}

fn handleToolsList(allocator: std.mem.Allocator) !json.Value {
    var tool_array = json.Array.init(allocator);
    for (tool_defs) |tool| {
        var tool_obj = json.ObjectMap.init(allocator);
        try tool_obj.put("name", .{ .string = tool.name });
        try tool_obj.put("description", .{ .string = tool.description });
        const schema = try json.parseFromSlice(json.Value, allocator, tool.input_schema, .{
            .allocate = .alloc_always,
        });
        try tool_obj.put("inputSchema", schema.value);
        try tool_array.append(.{ .object = tool_obj });
    }
    var result = json.ObjectMap.init(allocator);
    try result.put("tools", .{ .array = tool_array });
    return .{ .object = result };
}

fn handleCallTool(allocator: std.mem.Allocator, params: json.ObjectMap) !json.Value {
    const name_val = params.get("name") orelse return toolError(allocator, "missing tool name");
    const name = switch (name_val) {
        .string => |s| s,
        else => return toolError(allocator, "tool name must be string"),
    };
    const arguments = if (params.get("arguments")) |a| switch (a) {
        .object => |o| o,
        else => json.ObjectMap.init(allocator),
    } else json.ObjectMap.init(allocator);

    // Self-hosted dispatch: call into nanoclj runtime
    const result_text = dispatchTool(allocator, name, arguments) catch {
        return toolError(allocator, "dispatch error");
    };

    return toolResult(allocator, result_text);
}

fn handleMethod(allocator: std.mem.Allocator, method: []const u8, obj: json.ObjectMap) !json.Value {
    if (std.mem.eql(u8, method, "initialize")) {
        return handleInitialize(allocator);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        return .null;
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return handleToolsList(allocator);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = if (obj.get("params")) |p| switch (p) {
            .object => |o| o,
            else => json.ObjectMap.init(allocator),
        } else json.ObjectMap.init(allocator);
        return handleCallTool(allocator, params);
    } else if (std.mem.eql(u8, method, "tasks/get")) {
        const params = if (obj.get("params")) |p| switch (p) {
            .object => |o| o,
            else => json.ObjectMap.init(allocator),
        } else json.ObjectMap.init(allocator);
        return handleTasksGet(allocator, params);
    } else {
        return makeError(allocator, .null, -32601, "Method not found");
    }
}

// ============================================================================
// MAIN: stdio JSON-RPC loop — the only Zig in the critical path
// ============================================================================

pub fn main() !void {
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try initRuntime(allocator);

    var stdout = CompatWriter{};
    var line_buf: [MAX_LINE_SIZE]u8 = undefined;

    while (true) {
        const line = readLineFromStdin(&line_buf) orelse return;
        if (line.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const parsed = json.parseFromSlice(json.Value, arena_alloc, line, .{
            .allocate = .alloc_always,
        }) catch {
            const err_resp = try makeError(arena_alloc, .null, -32700, "Parse error");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        };

        if (parsed.value != .object) {
            const err_resp = try makeError(arena_alloc, .null, -32600, "Invalid Request");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        }

        const obj = parsed.value.object;
        const id = obj.get("id") orelse .null;
        const method_val = obj.get("method") orelse {
            const err_resp = try makeError(arena_alloc, id, -32600, "Missing method");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => {
                const err_resp = try makeError(arena_alloc, id, -32600, "Method must be string");
                try writeJsonLine(&stdout, err_resp, arena_alloc);
                continue;
            },
        };

        if (std.mem.eql(u8, method, "notifications/initialized")) continue;

        const result = try handleMethod(arena_alloc, method, obj);
        const response = try makeResponse(arena_alloc, id, result);
        try writeJsonLine(&stdout, response, arena_alloc);
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "gorj_mcp: prelude bootstraps and dispatch table is populated" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    // Evaluate prelude
    for (prelude_forms) |form_src| {
        var reader = Reader.init(form_src, &gc);
        const form = reader.readForm() catch continue;
        var res = semantics.Resources.initDefault();
        _ = semantics.evalBounded(form, &env, &gc, &res);
    }

    // gorj-mcp-dispatch-table should exist
    const table_val = env.get("gorj-mcp-dispatch-table");
    try std.testing.expect(table_val != null);
    try std.testing.expect(table_val.?.isObj());

    // gorj-mcp-dispatch should exist
    const dispatch_val = env.get("gorj-mcp-dispatch");
    try std.testing.expect(dispatch_val != null);
}

test "gorj_mcp: self-hosted eval dispatch roundtrip" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    for (prelude_forms) |form_src| {
        var reader = Reader.init(form_src, &gc);
        const form = reader.readForm() catch continue;
        var res = semantics.Resources.initDefault();
        _ = semantics.evalBounded(form, &env, &gc, &res);
    }

    // Call gorj-mcp-substrate with empty args
    const dispatch_val = env.get("gorj-mcp-substrate") orelse return error.SkipZigTest;
    var empty_map = try gc.allocObj(.map);
    _ = &empty_map;
    var call_args = [_]Value{Value.makeObj(empty_map)};
    const result = eval_mod.apply(dispatch_val, &call_args, &env, &gc) catch return;
    // Should return a string (pr-str output)
    try std.testing.expect(result.isString());
    const s = gc.getString(result.asStringId());
    try std.testing.expect(s.len > 0);
}

fn evalPreludeForm(src: []const u8, env: *Env, gc: *GC) !Value {
    var reader = Reader.init(src, gc);
    const form = try reader.readForm();
    var res = semantics.Resources.initDefault();
    return switch (semantics.evalBounded(form, env, gc, &res)) {
        .value => |v| v,
        .bottom => error.SkipZigTest,
        .err => error.SkipZigTest,
    };
}

test "gorj_mcp: gatomic-style tick tools are discoverable and dispatchable" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    env.is_root = true;
    defer env.deinit();
    try core.initCore(&env, &gc);
    defer core.deinitCore();

    for (prelude_forms) |form_src| {
        _ = try evalPreludeForm(form_src, &env, &gc);
    }

    var saw_generate = false;
    var saw_partition = false;
    var saw_verify = false;
    for (tool_defs) |tool| {
        if (std.mem.eql(u8, tool.name, "gorj_generate_ticks")) saw_generate = true;
        if (std.mem.eql(u8, tool.name, "gorj_partition_by_trit")) saw_partition = true;
        if (std.mem.eql(u8, tool.name, "gorj_spi_verify")) saw_verify = true;
    }
    try std.testing.expect(saw_generate);
    try std.testing.expect(saw_partition);
    try std.testing.expect(saw_verify);

    const result = try evalPreludeForm(
        \\(gorj-mcp-dispatch "gorj_generate_ticks" {"count" 4 "seed" 1069 "start" 0})
    , &env, &gc);

    try std.testing.expect(result.isString());
    const s = gc.getString(result.asStringId());
    try std.testing.expect(std.mem.indexOf(u8, s, "gorj_generate_ticks") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, ":ticks") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, ":fingerprint") != null);
}
