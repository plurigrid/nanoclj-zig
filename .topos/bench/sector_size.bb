#!/usr/bin/env bb
;; sector_size.bb — constitutive check: sector.bin ≤ 512 bytes.
;; Run after `zig build sector`.
(require '[babashka.fs :as fs]
         '[cheshire.core :as json])

(let [root (-> *file* fs/parent fs/parent fs/parent str)
      bin  (str root "/zig-out/bin/sector.bin")]
  (cond
    (not (fs/exists? bin))
    (do (println (json/generate-string
                   {:bench "sector_size" :status "missing" :path bin}))
        (System/exit 1))

    :else
    (let [size (fs/size bin)]
      (if (> size 512)
        (do (println (json/generate-string
                       {:bench "sector_size" :status "fail"
                        :bytes size :limit 512}))
            (System/exit 2))
        (println (json/generate-string
                   {:bench "sector_size" :status "ok"
                    :bytes size :limit 512}))))))
