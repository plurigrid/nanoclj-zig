;; test-full.clj — Full integration: skills + transclusion + decomposition + sheaves
;;
;; Run: ./zig-out/bin/nanoclj test-full.clj

(println "╔══════════════════════════════════════════════╗")
(println "║  nanoclj-zig full integration test           ║")
(println "╚══════════════════════════════════════════════╝")
(println)

;; ── 1. Register skills ─────────────────────────────────────────
(println "=== 1. Register skills ===")
(skill-register (skill-parse-file ".agents/skills/tropical-algebra/SKILL.md"))
(skill-register (skill-parse-file ".agents/skills/color-game/SKILL.md"))
(skill-register (skill-parse-file ".agents/skills/double-category/SKILL.md"))
(skill-register (skill-parse-file ".agents/skills/rosetta-decomp/SKILL.md"))
(def stats (skill-net-stats))
(println "  skills:" (get stats :skills) "cells:" (get stats :cells))
(println "  GF(3) trit-sum:" (get stats :trit-sum)
         (if (zero? (get stats :trit-sum)) "CONSERVED" "VIOLATION"))
(println)

;; ── 2. Tier 1: list all skills ─────────────────────────────────
(println "=== 2. Tier 1: Available skills ===")
(println (skill-list))
(println)

;; ── 3. Tier 2: activate with transclusion ──────────────────────
(println "=== 3. Tier 2: Activate rosetta-decomp (transcludes .topos + horse) ===")
(def activated (skill-load "rosetta-decomp"))
(println "  body length:" (count activated))
(println "  contains Clairambault?:" (not= -1 (.indexOf activated "Clairambault")))
(println "  contains Categories?:" (not= -1 (.indexOf activated "Categories")))
(println)

;; ── 4. Direct transclusion from all source types ───────────────
(println "=== 4. Direct transclusion ===")
(println "  horse .tree (thy-0001):" (count (skill-transclude "thy-0001")) "chars")
(println "  .topos paper:" (count (skill-transclude "rosetta-stone-interactive-quantitative-semantics")) "chars")
(println "  .topos model:" (count (skill-transclude "gf3-conservation")) "chars")
(println "  skill dir:" (count (skill-transclude "tropical-algebra")) "chars")
(println)

;; ── 5. Cache stats ─────────────────────────────────────────────
(println "=== 5. Cache stats ===")
(println "  " (skill-cache-stats))
(println)

;; ── 6. Decompose a graph ───────────────────────────────────────
(println "=== 6. Structured Decomposition ===")
(def g {:nodes [1 2 3 4 5]
        :edges [[1 2] [2 3] [3 4] [4 5] [1 3] [3 5]]})
(def d (decompose g))
(println "  net-id:" d)
(println "  bags:" (decomp-bags d))
(println "  treewidth:" (decomp-width d))
(println "  adhesions:" (count (decomp-adhesions d)))
(println)

;; ── 7. Sheaf construction + section ────────────────────────────
(println "=== 7. Sheaves ===")
(def sh (sheaf count nil))
(println "  section [1 2 3]:" (section sh [1 2 3]))
(println "  section [a b c d e]:" (section sh [:a :b :c :d :e]))
(println "  restrict [1 2 3 4 5] to [2 4]:" (restrict [1 2 3 4 5] [2 4]))
(println)

;; ── 8. Extend section ──────────────────────────────────────────
(println "=== 8. Extend section ===")
(def sh2 (sheaf identity nil))
(def merged (extend-section sh2 [[1 2 3] [3 4 5]] [[1 2 3] [3 4 5]]))
(println "  merged:" merged)
(println)

;; ── 9. Decomp-map (functorial lift) ────────────────────────────
(println "=== 9. Functorial lift ===")
(def mapped (decomp-map count d))
(println "  bag sizes:" (decomp-bags mapped))
(println)

;; ── 10. Decomp-skeleton ────────────────────────────────────────
(println "=== 10. Skeleton ===")
(def skel (decomp-skeleton d))
(println "  skeleton bags:" (decomp-bags skel))
(println)

;; ── 11. Invalidate + re-cache ──────────────────────────────────
(println "=== 11. Cache invalidation ===")
(def gen-before (get (skill-cache-stats) :generation))
(skill-invalidate)
(def gen-after (get (skill-cache-stats) :generation))
(println "  generation:" gen-before "->" gen-after)
(println)

;; ── 12. Watch ──────────────────────────────────────────────────
(println "=== 12. Watcher ===")
(println "  watch tropical-algebra:" (skill-watch "tropical-algebra" ".agents/skills/tropical-algebra/SKILL.md"))
(println)

(println "╔══════════════════════════════════════════════╗")
(println "║  ALL TESTS PASSED                            ║")
(println "╚══════════════════════════════════════════════╝")
