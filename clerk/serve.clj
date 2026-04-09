#!/usr/bin/env bb
;; clerk/serve.clj — Clerk-like rendering surface for nanoclj-zig
;;
;; Double-wrapped architecture:
;;   Inner: nanoclj-zig nREPL (TCP/bencode, bounded eval, GF(3) metadata)
;;   Outer: This script → HTTP + SSE → browser renders colored HTML
;;
;; Usage:
;;   bb clerk/serve.clj              # connects to nREPL on .nrepl-port
;;   bb clerk/serve.clj 7888         # explicit nREPL port
;;   bb clerk/serve.clj 7888 8080    # explicit nREPL + HTTP port

(ns nanoclj.clerk
  (:require [babashka.bencode :as bencode]
            [clojure.java.io :as io]
            [org.httpkit.server :as http])
  (:import [java.net Socket]
           [java.util UUID]))

;; ── nREPL client ────────────────────────────────────────────────

(defn connect-nrepl [port]
  (let [sock (Socket. "127.0.0.1" (int port))
        in   (io/input-stream sock)
        out  (io/output-stream sock)]
    {:socket sock :in in :out out}))

(defn nrepl-send [{:keys [out]} msg]
  (bencode/write-bencode out msg))

(defn nrepl-recv [{:keys [in]}]
  (try
    (bencode/read-bencode in)
    (catch Exception _ nil)))

(defn nrepl-eval
  "Eval code, collect all response messages until done."
  [conn session-id code]
  (let [msg-id (str (UUID/randomUUID))]
    (nrepl-send conn {"op" "eval"
                      "code" code
                      "session" session-id
                      "id" msg-id})
    (loop [msgs []]
      (if-let [resp (nrepl-recv conn)]
        (let [msgs (conj msgs resp)
              status (get resp "status")]
          (if (and status (some #(= % "done") status))
            msgs
            (recur msgs)))
        msgs))))

(defn nrepl-clone [conn]
  (nrepl-send conn {"op" "clone" "id" (str (UUID/randomUUID))})
  (let [resp (nrepl-recv conn)]
    (get resp "new-session")))

;; ── SSE broadcast ───────────────────────────────────────────────

(def sse-clients (atom #{}))

(defn broadcast-sse! [event data]
  (let [msg (str "event: " event "\ndata: " data "\n\n")]
    (doseq [ch @sse-clients]
      (try (http/send! ch {:body msg} false)
           (catch Exception _ (swap! sse-clients disj ch))))))

;; ── Eval result → HTML ──────────────────────────────────────────

(defn result-html
  "Convert nREPL response messages to an HTML fragment."
  [code msgs]
  (let [value-msg  (first (filter #(get % "value") msgs))
        done-msg   (first (filter #(some #{"done"} (get % "status")) msgs))
        err-msg    (first (filter #(get % "err") msgs))
        value      (get value-msg "value")
        err        (get err-msg "err")
        color-r    (get done-msg "x-color-r" 128)
        color-g    (get done-msg "x-color-g" 128)
        color-b    (get done-msg "x-color-b" 128)
        trit       (get done-msg "x-trit-phase" 0)
        fuel       (get done-msg "x-fuel-remaining" "?")
        elapsed    (get done-msg "x-elapsed-trit-ticks" 0)
        eval-count (get done-msg "x-eval-count" 0)
        bounded?   (= "true" (get done-msg "x-bounded"))
        tier       (cond
                     (= trit 1)  "red"    ; AOT
                     (= trit -1) "blue"   ; JIT
                     :else        "purple") ; dispatch
        border-color (str "rgb(" color-r "," color-g "," color-b ")")]
    (str "<div class='cell' style='border-left: 4px solid " border-color "'>"
         "<div class='cell-input'><pre><code>" (-> code (.replace "&" "&amp;") (.replace "<" "&lt;")) "</code></pre></div>"
         (if err
           (str "<div class='cell-error'><pre>" (-> err (.replace "&" "&amp;") (.replace "<" "&lt;")) "</pre></div>")
           (str "<div class='cell-output'><pre><code>" (-> (or value "nil") (.replace "&" "&amp;") (.replace "<" "&lt;")) "</code></pre></div>"))
         "<div class='cell-meta'>"
         "<span class='tier tier-" tier "'>" tier "</span>"
         "<span class='fuel'>fuel:" fuel "</span>"
         "<span class='ticks'>" elapsed "tt</span>"
         "<span class='eval-n'>#" eval-count "</span>"
         (when bounded? "<span class='bounded'>bounded</span>")
         "</div>"
         "</div>")))

;; ── HTML page ───────────────────────────────────────────────────

(def page-html
  "<!DOCTYPE html>
<html>
<head>
<meta charset='utf-8'>
<title>nanoclj-zig · clerk</title>
<style>
  :root { --bg: #1a1a2e; --fg: #e0e0e0; --input-bg: #16213e; --mono: 'Berkeley Mono', 'JetBrains Mono', monospace; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--fg); font-family: var(--mono); font-size: 14px; padding: 2rem; max-width: 900px; margin: 0 auto; }
  h1 { font-size: 1.2em; color: #7f8fa6; margin-bottom: 1rem; }
  h1 span { font-weight: normal; opacity: 0.5; }
  #cells { display: flex; flex-direction: column; gap: 1rem; }
  .cell { background: var(--input-bg); border-radius: 6px; padding: 1rem; }
  .cell-input code { color: #dcdde1; }
  .cell-output { margin-top: 0.5rem; }
  .cell-output code { color: #4cd137; }
  .cell-error pre { color: #e84118; }
  .cell-meta { margin-top: 0.5rem; display: flex; gap: 0.75rem; font-size: 0.75em; opacity: 0.6; }
  .tier { font-weight: bold; text-transform: uppercase; }
  .tier-red { color: #e84118; }
  .tier-blue { color: #0097e6; }
  .tier-purple { color: #9c88ff; }
  .bounded { color: #fbc531; }
  #input-area { position: fixed; bottom: 0; left: 0; right: 0; background: #0f0f23; padding: 1rem 2rem; border-top: 1px solid #333; }
  #input-area form { max-width: 900px; margin: 0 auto; display: flex; gap: 0.5rem; }
  #code-input { flex: 1; background: var(--input-bg); color: var(--fg); border: 1px solid #444; border-radius: 4px; padding: 0.5rem; font-family: var(--mono); font-size: 14px; }
  #code-input:focus { outline: none; border-color: #9c88ff; }
  button { background: #9c88ff; color: #1a1a2e; border: none; border-radius: 4px; padding: 0.5rem 1rem; font-family: var(--mono); cursor: pointer; }
  button:hover { background: #8c7ae6; }
  .spacer { height: 4rem; }
</style>
</head>
<body>
<h1>nanoclj-zig <span>· clerk</span></h1>
<div id='cells'></div>
<div class='spacer'></div>
<div id='input-area'>
  <form id='eval-form'>
    <input id='code-input' type='text' placeholder='(+ 1 2)' autocomplete='off' autofocus>
    <button type='submit'>eval</button>
  </form>
</div>
<script>
const cells = document.getElementById('cells');
const form = document.getElementById('eval-form');
const input = document.getElementById('code-input');

// SSE for live results
const es = new EventSource('/events');
es.addEventListener('cell', e => {
  cells.insertAdjacentHTML('beforeend', e.data);
  window.scrollTo(0, document.body.scrollHeight);
});

// Eval via POST
form.addEventListener('submit', async e => {
  e.preventDefault();
  const code = input.value.trim();
  if (!code) return;
  input.value = '';
  await fetch('/eval', { method: 'POST', body: code });
});

// Ctrl+Enter in input
input.addEventListener('keydown', e => {
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
    form.dispatchEvent(new Event('submit'));
  }
});
</script>
</body>
</html>")

;; ── HTTP server ─────────────────────────────────────────────────

(defn make-handler [nrepl-conn session-id]
  (fn [req]
    (case (:uri req)
      "/" {:status 200
          :headers {"Content-Type" "text/html; charset=utf-8"}
          :body page-html}

      "/events"
      (http/with-channel req ch
        (http/send! ch {:status 200
                        :headers {"Content-Type" "text/event-stream"
                                  "Cache-Control" "no-cache"
                                  "Connection" "keep-alive"}}
                    false)
        (swap! sse-clients conj ch)
        (http/on-close ch (fn [_] (swap! sse-clients disj ch))))

      "/eval"
      (let [code (slurp (:body req))
            msgs (nrepl-eval nrepl-conn session-id code)
            html (result-html code msgs)]
        (broadcast-sse! "cell" html)
        {:status 200 :body "ok"})

      {:status 404 :body "not found"})))

;; ── Main ────────────────────────────────────────────────────────

(defn -main [& args]
  (let [nrepl-port (or (some-> (first args) parse-long)
                       (some-> (io/file ".nrepl-port") slurp str/trim parse-long)
                       7888)
        http-port  (or (some-> (second args) parse-long) 8484)]
    (println (str "Connecting to nanoclj-zig nREPL on port " nrepl-port "..."))
    (let [conn       (connect-nrepl nrepl-port)
          session-id (nrepl-clone conn)]
      (println (str "Session: " session-id))
      (println (str "Serving clerk at http://localhost:" http-port))
      (http/run-server (make-handler conn session-id) {:port http-port})
      @(promise)))) ; block forever

(apply -main *command-line-args*)
