#!/usr/bin/env bb
;;; Parallel runtime comparison harness.
;;;
;;; Runs the same Clojure form against each available runtime and reports
;;; cold-start wall time. Maintains a slot for `jank` (jank-lang.org) — set
;;; JANK_BIN to the binary path to populate it.
;;;
;;; Usage:
;;;   bb .topos/bench/parallel.bb
;;;   JANK_BIN=/path/to/jank bb .topos/bench/parallel.bb
;;;
;;; Output: stdout table + .topos/bench/parallel-snapshot.edn

(require '[clojure.java.shell :as sh]
         '[clojure.string :as str]
         '[clojure.edn :as edn])

(def NANOCLJ "/Users/bob/i/nanoclj-zig/zig-out/bin/nanoclj")
(def JANK    (System/getenv "JANK_BIN")) ; nil unless caller sets it

(defn time-cmd [argv input]
  (let [t0 (System/nanoTime)
        r  (apply sh/sh (concat argv [:in input]))
        ms (/ (- (System/nanoTime) t0) 1e6)]
    {:ms ms :raw (or (:out r) "") :err (or (:err r) "") :exit (:exit r)}))

(defn ansi-strip [s] (str/replace s #"\x1b\[[0-9;]*[A-Za-z]" ""))
(defn ok? [r expected] (str/includes? (ansi-strip (:raw r)) (str expected)))

;;; Forms — wrap in (do …) so single-form runners (clojure -M -e) see one expr.
(def FORMS
  [{:name "fib25"
    :code "(do (defn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (println (fib 25)))"
    :expected "75025"}
   {:name "tight-loop-10k"
    :code "(do (println (loop [i 0 acc 0] (if (= i 10000) acc (recur (inc i) (+ acc i))))))"
    :expected "49995000"}
   {:name "reduce-+-range-10k"
    :code "(do (println (reduce + (range 10000))))"
    :expected "49995000"}])

(defn run-row [{:keys [name code expected]}]
  (let [bb   (time-cmd ["bb" "-e" code] "")
        clj  (time-cmd ["clojure" "-M" "-e" code] "")
        nano (time-cmd [NANOCLJ] code)
        jank (when JANK (time-cmd [JANK "run" "-e" code] ""))]
    (cond-> {:name name :expected expected
             :bb-ms (:ms bb) :bb-ok (ok? bb expected)
             :clj-ms (:ms clj) :clj-ok (ok? clj expected)
             :nano-ms (:ms nano) :nano-ok (ok? nano expected)}
      jank (merge {:jank-ms (:ms jank) :jank-ok (ok? jank expected)})
      (not jank) (assoc :jank :NOT_INSTALLED))))

(defn -main [& _]
  (println "=== parallel runtime comparison (cold-start wall ms) ===")
  (let [rows (mapv run-row FORMS)]
    (doseq [r rows]
      (printf "%-22s exp=%-9s bb=%6.0fms[%s] clj=%6.0fms[%s] nano=%6.0fms[%s] jank=%s%n"
              (:name r) (:expected r)
              (:bb-ms r) (if (:bb-ok r) "✓" "✗")
              (:clj-ms r) (if (:clj-ok r) "✓" "✗")
              (:nano-ms r) (if (:nano-ok r) "✓" "✗")
              (cond
                (= :NOT_INSTALLED (:jank r)) "—"
                :else (format "%6.0fms[%s]" (:jank-ms r) (if (:jank-ok r) "✓" "✗")))))
    (println "\n=== ratios (bb=1.00 baseline) ===")
    (doseq [r rows]
      (printf "%-22s bb=1.00 clj=%5.2fx nano=%5.2fx jank=%s%n"
              (:name r)
              (/ (:clj-ms r) (:bb-ms r))
              (/ (:nano-ms r) (:bb-ms r))
              (if (= :NOT_INSTALLED (:jank r))
                "N/A"
                (format "%.2fx" (/ (:jank-ms r) (:bb-ms r))))))
    ;; Snapshot for the §6.1 Skill triad to consume.
    (spit "/Users/bob/i/nanoclj-zig/.topos/bench/parallel-snapshot.edn"
          (pr-str {:rows rows :timestamp-ms (System/currentTimeMillis)
                   :runtimes {:bb true :clojure true :nanoclj-zig true
                              :jank (boolean JANK)}}))
    (println "\nsnapshot →" "/Users/bob/i/nanoclj-zig/.topos/bench/parallel-snapshot.edn")))

(when (= *file* (first *command-line-args*))
  (apply -main *command-line-args*))
;; Direct invocation via shebang: bb runs the file; -main hooks via top-level call:
(-main)
