#!/usr/bin/env bb
;; clerk/serve.clj — Clerk-style HTTP bridge to a nanoclj nREPL.
;;
;; Usage:  bb clerk/serve.clj [nrepl-port] [http-port]
;;         Defaults: nrepl-port=7888  http-port=8484

(require '[bencode.core :as b]
         '[org.httpkit.server :as http]
         '[cheshire.core :as json])

(import '[java.net Socket]
        '[java.io PushbackInputStream BufferedOutputStream])

(def nrepl-port (Integer/parseInt (or (first *command-line-args*) "7888")))
(def http-port  (Integer/parseInt (or (second *command-line-args*) "8484")))

;; ── nREPL client ──────────────────────────────────────────────────────

(defn nrepl-eval
  [code]
  (let [sock (Socket. "localhost" nrepl-port)
        in   (PushbackInputStream. (.getInputStream sock))
        out  (BufferedOutputStream. (.getOutputStream sock))
        id   (str (java.util.UUID/randomUUID))]
    (try
      (b/write-bencode out {"op" "eval" "code" code "id" id})
      (.flush out)
      (loop [acc {:value nil :out "" :err "" :status nil :extras {}}]
        (let [resp (b/read-bencode in)]
          (if (nil? resp)
            acc
            (let [resp-map (into {} (map (fn [[k v]]
                                          [(if (bytes? k) (String. ^bytes k) (str k))
                                           (if (bytes? v) (String. ^bytes v) v)])
                                        resp))
                  acc (cond-> acc
                        (get resp-map "value")  (assoc :value (get resp-map "value"))
                        (get resp-map "out")    (update :out str (get resp-map "out"))
                        (get resp-map "err")    (update :err str (get resp-map "err"))
                        (get resp-map "ex")     (assoc :error (get resp-map "ex")))]
              (let [extras (reduce-kv (fn [m k v]
                                        (if (.startsWith ^String k "x-")
                                          (assoc m k (if (bytes? v) (String. ^bytes v) v))
                                          m))
                                      (:extras acc)
                                      resp-map)
                    acc (assoc acc :extras extras)
                    status (get resp-map "status")]
                (if (and status (some #(= "done" (if (bytes? %) (String. ^bytes %) (str %)))
                                      (if (sequential? status) status [status])))
                  (assoc acc :status "done")
                  (recur acc)))))))
      (finally
        (.close sock)))))

;; ── HTML page ─────────────────────────────────────────────────────────

(def index-html
  "<!DOCTYPE html>
<html><head>
<meta charset='utf-8'>
<title>nanoclj clerk</title>
<style>
  body { font-family: 'Berkeley Mono', 'Iosevka', monospace; background: #0e0e12; color: #e0e0e0; margin: 2em; }
  h1 { color: #b0f0b0; }
  textarea { width: 100%; height: 6em; background: #1a1a22; color: #f8f8f8; border: 1px solid #444; padding: 0.5em; font-family: inherit; font-size: 1em; }
  button { margin-top: 0.5em; padding: 0.4em 1.2em; background: #2a6a3a; color: #fff; border: none; cursor: pointer; font-size: 1em; }
  button:hover { background: #3a8a4a; }
  #result { white-space: pre-wrap; background: #12121a; padding: 1em; margin-top: 1em; border: 1px solid #333; min-height: 2em; }
  .extras { color: #888; font-size: 0.85em; margin-top: 0.5em; }
</style>
</head><body>
<h1>nanoclj clerk</h1>
<textarea id='code'>(+ 1 2)</textarea>
<br><button onclick='evalCode()'>Eval</button>
<div id='result'></div>
<script>
async function evalCode() {
  const code = document.getElementById('code').value;
  const res = await fetch('/eval', {method: 'POST', body: code});
  const data = await res.json();
  let out = '';
  if (data.out) out += data.out;
  if (data.value !== null) out += data.value;
  if (data.error) out += '\\nERROR: ' + data.error;
  if (data.err) out += '\\nSTDERR: ' + data.err;
  if (data.extras && Object.keys(data.extras).length > 0) {
    out += '\\n\\n' + JSON.stringify(data.extras, null, 2);
  }
  document.getElementById('result').textContent = out;
}
document.addEventListener('keydown', e => { if ((e.ctrlKey||e.metaKey) && e.key==='Enter') evalCode(); });
</script>
</body></html>")

;; ── HTTP handler ──────────────────────────────────────────────────────

(defn handler [req]
  (case [(:request-method req) (:uri req)]
    [:get "/"]
    {:status 200 :headers {"Content-Type" "text/html; charset=utf-8"} :body index-html}

    [:post "/eval"]
    (let [body (slurp (:body req))
          result (nrepl-eval body)]
      {:status 200
       :headers {"Content-Type" "application/json; charset=utf-8"}
       :body (json/generate-string result)})

    {:status 404 :body "not found"}))

;; ── Main ──────────────────────────────────────────────────────────────

(println (str "clerk bridge: nREPL localhost:" nrepl-port " -> HTTP localhost:" http-port))
(http/run-server handler {:port http-port})
(println (str "Serving at http://localhost:" http-port "/"))

@(promise)
