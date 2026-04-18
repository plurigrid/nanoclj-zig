#!/usr/bin/env bb
;; arch_matrix.bb — cross-compile nanoclj for 6 targets, emit per-target JSON.
;; +1 incomparable: no JVM Clojure can do this.
(require '[babashka.fs :as fs]
         '[babashka.process :refer [shell]]
         '[cheshire.core :as json])

(def targets
  ["x86_64-linux"
   "aarch64-linux"
   "aarch64-macos"
   "arm-linux-gnueabihf"
   "riscv64-linux"
   "wasm32-freestanding"])

(let [root (-> *file* fs/parent fs/parent fs/parent str)
      zig  (str root "/.zig-toolchains/zig-aarch64-macos-0.16.0-dev.3070+b22eb176b/zig")]
  (doseq [t targets]
    (let [log  (str "/tmp/bench_arch_" t ".log")
          t0   (System/nanoTime)
          res  (shell {:dir root :out :string :err :string
                       :continue true}
                 zig "build" (str "-Dtarget=" t))
          ns   (- (System/nanoTime) t0)
          ok?  (zero? (:exit res))]
      (when-not ok?
        (spit log (str (:out res) (:err res))))
      (println (json/generate-string
                 (cond-> {:bench   "arch_matrix"
                          :target  t
                          :status  (if ok? "ok" "fail")
                          :wall_ms (long (/ ns 1000000))}
                   (not ok?) (assoc :log log)))))))
