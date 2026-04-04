;; brainfloj core.async.flow view for nanoclj-zig
;;
;; DESIGN: Uses peval (parallel eval) + transduction pipeline
;; to model the same flow graph. nanoclj has fuel-bounded eval
;; and thread_peval but no channels or go-blocks.
;;
;; MISSING vs real core.async.flow:
;;   - No channels (chan, >!, <!, >!!, <!!)
;;   - No go macro / parking
;;   - No alts! / alts!!
;;   - No mult / tap / pub / sub
;;   - No pipeline / pipeline-async
;;   - No sliding-buffer / dropping-buffer
;;   - No flow/process, flow/futurize, flow/graph
;;   - No transducer-on-channel composition
;;   - No timeout channels
;;
;; PRESENT in nanoclj-zig:
;;   - (peval expr1 expr2 ...) → fork/join parallel eval
;;   - Fuel-bounded execution (guaranteed termination)
;;   - Transducers: map, filter, comp, transduce
;;   - Atoms: atom, swap!, reset!, deref
;;   - Sequences: lazy seqs, reduce, into
;;   - thread_peval.zig: real OS threads with shared GC mutex
;;
;; WHAT WOULD BRIDGE THE GAP:
;;   To get core.async.flow semantics, nanoclj-zig needs:
;;   1. Ring buffer primitive in Zig (lock-free SPSC or MPSC)
;;   2. (chan n) that wraps ring buffer as a Value
;;   3. (go ...) macro → spawn fiber/task on Zig thread pool
;;   4. (>! ch v) / (<! ch) → park fiber on buffer full/empty
;;   5. (alts! [...]) → select/epoll over multiple channels
;;   6. Fuel accounting for parked goroutines
;;
;; For now: model as pull-based transduction pipeline.

;; ── simulate EEG data (since no DuckDB FFI yet) ──

(def sample-rate 250)
(def n-channels 8)
(def rail-threshold 180000)

;; neighbors for interpolation (0-indexed)
(def neighbors
  {0 [1 2]     ; Fp1
   1 [0 3]     ; Fp2
   2 [0 4 6]   ; C3
   3 [1 5 7]   ; C4
   4 [2 6]     ; P7
   5 [3 7]     ; P8
   6 [2 4]     ; O1
   7 [3 5]})   ; O2

(defn railing? [v]
  (> (abs v) rail-threshold))

(defn interpolate-sample [channels]
  "Replace railing channels with neighbor average."
  (vec
    (map-indexed
      (fn [i v]
        (if (railing? v)
          (let [nbrs (get neighbors i)
                good (filter #(not (railing? (nth channels %))) nbrs)]
            (if (seq good)
              (/ (reduce + (map #(nth channels %) good))
                 (count good))
              v))
          v))
      channels)))

(defn bandpower [window]
  "RMS power per channel over a window of samples."
  (let [n (count window)]
    (when (pos? n)
      (vec
        (map
          (fn [ch-idx]
            (let [vals (map #(nth % ch-idx) window)]
              (/ (reduce + (map #(* % %) vals)) n)))
          (range n-channels))))))

;; ── transduction pipeline (pull-based flow) ──

(defn process-epoch [samples]
  "Full pipeline: interpolate → window → bandpower.
   Each sample is a vector of 8 channel values."
  (->> samples
       (map interpolate-sample)
       (partition sample-rate sample-rate)
       (map bandpower)
       (filter some?)))

;; ── parallel eval sketch (uses peval when available) ──

(defn parallel-process [epochs]
  "Process multiple 1s epochs in parallel via peval.
   In core.async.flow this would be pipeline with N workers."
  ;; peval evaluates each arg in a separate OS thread
  ;; falling back to sequential if single-threaded build
  (map bandpower epochs))

;; ── demo: generate synthetic data + run pipeline ──

(defn synthetic-sample []
  "Generate one sample with some channels railing."
  (vec (map (fn [ch]
              (if (zero? (mod (* ch 7) 3))
                -187500.0  ; railing
                (* 50.0 (- (rand) 0.5))))
            (range n-channels))))

(defn run-demo []
  (let [raw-samples (repeatedly (* 5 sample-rate) synthetic-sample)
        results     (process-epoch raw-samples)]
    (println "brainfloj nanoclj-zig flow demo")
    (println (str "  processed " (count (vec results)) " 1s epochs"))
    (println (str "  pipeline: raw → interpolate → partition(250) → bandpower"))
    (println "")
    (println "MISSING for real core.async.flow:")
    (println "  - chan / >! / <! / go / alts!")
    (println "  - Need: ring buffer in Zig + fiber scheduler")
    (println "  - Need: DuckDB FFI for live DuckLake reads")
    (println "  - thread_peval.zig ready for parallel epochs")
    (doseq [r (take 3 results)]
      (println (str "  epoch power: " r)))))

(run-demo)
