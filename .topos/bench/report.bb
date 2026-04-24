#!/usr/bin/env bb
;; report.bb — run the full faithful bench suite and emit a digest.
;;
;; Usage:  bb .topos/bench/report.bb
;; Output: one-line-per-bench table to stdout + JSON digest to
;;         .topos/bench/.last-digest.json (for CI ingestion).
;;
;; Streams `zig build bench` → splits BMF-JSON → flattens → prints table.

(require '[babashka.fs :as fs]
         '[babashka.process :refer [shell]]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def root (-> *file* fs/parent fs/parent fs/parent str))
(def zig  (str root "/.zig-toolchains/zig-aarch64-macos-0.16.0-dev.3070+b22eb176b/zig"))

(defn human-ns [v]
  (cond
    (nil? v)       "—"
    (< v 1e3)      (format "%.1f ns" (double v))
    (< v 1e6)      (format "%.2f µs" (/ v 1e3))
    (< v 1e9)      (format "%.2f ms" (/ v 1e6))
    :else          (format "%.2f s"  (/ v 1e9))))

(defn human-bytes [v]
  (cond
    (or (nil? v) (zero? v)) "—"
    (< v 1024)              (format "%d B"   v)
    (< v (* 1024 1024))     (format "%.1f KiB" (/ v 1024.0))
    (< v (* 1024 1024 1024)) (format "%.2f MiB" (/ v 1024.0 1024.0))
    :else                   (format "%.2f GiB" (/ v 1024.0 1024.0 1024.0))))

(defn parse-bmf-line [line]
  (try
    (let [m (json/parse-string line true)
          [name body] (first m)]
      (when body
        {:name    (clojure.core/name name)
         :median  (get-in body [:latency :value])
         :lower   (get-in body [:latency :lower_value])
         :upper   (get-in body [:latency :upper_value])
         :cv      (get-in body [:cv_pct :value])
         :batch   (get-in body [:batch :value])
         :alloc   (get-in body [:allocated :value])
         ;; reader_1mb shape
         :forms   (get-in body [:forms :value])
         :ratio   (get-in body [:peak_ratio :value])}))
    (catch Exception _ nil)))

(println "# running `zig build bench` (ReleaseFast, c_allocator)…")
(let [t0    (System/nanoTime)
      res   (shell {:dir root :out :string :err :string :continue true}
                   zig "build" "bench")
      wall  (long (/ (- (System/nanoTime) t0) 1000000))
      lines (->> (:out res)
                 (str/split-lines)
                 (remove str/blank?))
      rows  (keep parse-bmf-line lines)]
  (println (format "# wall: %d ms, exit: %d, parsed %d/%d BMF rows"
                   wall (:exit res) (count rows) (count lines)))
  (println)
  (printf "%-26s %12s %12s %6s %9s %10s%n"
          "name" "median" "min" "cv%" "batch" "alloc")
  (println (apply str (repeat 80 "-")))
  (doseq [r (sort-by :name rows)]
    (printf "%-26s %12s %12s %6s %9s %10s%n"
            (:name r)
            (human-ns (:median r))
            (human-ns (:lower r))
            (if (:cv r) (format "%.1f" (double (:cv r))) "—")
            (or (:batch r) "—")
            (human-bytes (:alloc r))))
  (println)
  (let [digest-path (str root "/.topos/bench/.last-digest.json")]
    (spit digest-path (json/generate-string
                        {:wall_ms wall
                         :exit    (:exit res)
                         :rows    rows
                         :raw     (vec lines)}
                        {:pretty true}))
    (println "# digest →" digest-path))
  (System/exit (:exit res)))
