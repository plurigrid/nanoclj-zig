;; test-decomp.clj — Exercise StructuredDecompositions + Sheaves
;;
;; Run: ./zig-out/bin/nanoclj test-decomp.clj

;; ── Triangle graph: K3 ──────────────────────────────────────────
(println "=== Decompose K3 (triangle) ===")
(def g {:nodes [1 2 3]
        :edges [[1 2] [2 3] [1 3]]})
(def d (decompose g))
(println "  net-id:" d)

(println "  bags:" (decomp-bags d))
(println "  treewidth:" (decomp-width d))
(println "  adhesions:" (decomp-adhesions d))
(println)

;; ── Path graph: P4 ──────────────────────────────────────────────
(println "=== Decompose P4 (path) ===")
(def p {:nodes [:a :b :c :d]
        :edges [[:a :b] [:b :c] [:c :d]]})
(def dp (decompose p))
(println "  net-id:" dp)
(println "  bags:" (decomp-bags dp))
(println "  treewidth:" (decomp-width dp))
(println "  adhesions:" (decomp-adhesions dp))
(println)

;; ── Sheaf construction ──────────────────────────────────────────
(println "=== Sheaf ===")
(def sh (sheaf count nil))
(println "  sheaf:" sh)
(println "  section over [1 2 3]:" (section sh [1 2 3]))
(println)

;; ── Restrict ────────────────────────────────────────────────────
(println "=== Restrict ===")
(println "  [1 2 3 4 5] ∩ [2 4 6]:" (restrict [1 2 3 4 5] [2 4 6]))
(println "  [a b c] ∩ [b c d]:" (restrict [:a :b :c] [:b :c :d]))
(println)

;; ── Extend section (no glue) ────────────────────────────────────
(println "=== Extend section (no glue) ===")
(def sh2 (sheaf identity nil))
(def merged (extend-section sh2 [[1 2] [3 4]] [[1 2] [3 4]]))
(println "  merged:" merged)
(println)

;; ── Decomp-map (functorial lift) ────────────────────────────────
(println "=== Decomp-map ===")
(def mapped (decomp-map count dp))
(println "  mapped net-id:" mapped)
(println "  mapped bags:" (decomp-bags mapped))
(println)

;; ── Decomp-skeleton ─────────────────────────────────────────────
(println "=== Decomp-skeleton ===")
(def skel (decomp-skeleton dp))
(println "  skeleton net-id:" skel)
(println "  skeleton bags:" (decomp-bags skel))
(println)

;; ── Decomp-glue (inet reduction) ────────────────────────────────
(println "=== Decomp-glue ===")
(println "  glued:" (decomp-glue dp))
(println)

(println "=== All decomp tests passed ===")
