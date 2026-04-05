;; test-skills.clj — Exercise skill_inet.zig progressive disclosure
;;
;; Run: ./zig-out/bin/nanoclj test-skills.clj

;; ── Phase 0: Parse a SKILL.md from disk ──────────────────────────
(println "=== Phase 0: Parse SKILL.md ===")
(def tropical (skill-parse-file ".agents/skills/tropical-algebra/SKILL.md"))
(println "Parsed:" tropical)
(println "  name:" (get tropical :name))
(println "  trit:" (get tropical :trit))
(println)

;; ── Phase 1: Register skills into the interaction net ────────────
(println "=== Phase 1: Register into inet ===")
(skill-register tropical)
(skill-register (skill-parse-file ".agents/skills/color-game/SKILL.md"))
(println "Net stats:" (skill-net-stats))
(println)

;; ── Tier 1: List all skills (metadata only, ~100 tokens/skill) ──
(println "=== Tier 1: Available Skills XML ===")
(println (skill-list))
(println)

;; ── Tier 2: Activate a specific skill (full body) ────��──────────
(println "=== Tier 2: Activate tropical-algebra ===")
(println (skill-load "tropical-algebra"))
(println)

;; ── Tier 2: Activate another ────────────────────────────────────
(println "=== Tier 2: Activate color-game ===")
(def cg (skill-activate "color-game"))
(println "  name:" (get cg :name))
(println "  description:" (get cg :description))
(println "  trit:" (get cg :trit))
(println "  body length:" (count (get cg :body)))
(println)

;; ── Phase 3: Transclusion ───────────────────────────────────────
(println "=== Phase 3: Tree Transclusion ===")
(skill-register (skill-parse-file ".agents/skills/double-category/SKILL.md"))
(println "=== Tier 2 with transclusion (double-category): ===")
(println (skill-load "double-category"))
(println)

;; Direct transclusion
(println "=== Direct transclude bci-0003: ===")
(println (skill-transclude "bci-0003"))
(println)

;; ── GF(3) conservation check ────────────────────────────────────
(println "=== GF(3) Conservation ===")
(def stats (skill-net-stats))
(println "  trit-sum mod 3:" (get stats :trit-sum))
(println "  cells:" (get stats :cells))
(println "  live:" (get stats :live))
(println "  skills:" (get stats :skills))
(println (if (zero? (get stats :trit-sum)) "  CONSERVED" "  VIOLATION"))
