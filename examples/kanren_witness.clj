;; Kanren Witness: relational search over the epochal time model
;;
;; Instead of CHECKING if an epoch is ill-posed, we ASK:
;; "Under what conditions is an epoch well-posed?"
;; miniKanren finds all satisfying assignments — or proves none exist.

;; === The witness relation ===
;; An epoch is well-posed iff:
;;   substrate_agrees? = true  AND  classifier_agrees? = true
;; An epoch is ill-posed with count N iff N of those are false.

(defn witness-relation [epoch-idx]
  "Given epoch index, search for all possible ill-posedness states"
  (run* [q]
    (fresh [sub-ok cls-ok diagnosis count]
      (conde
        ;; well-posed: both agree
        [(== sub-ok true) (== cls-ok true)
         (== diagnosis :well-posed) (== count 0)]
        ;; single: substrate diverges
        [(== sub-ok false) (== cls-ok true)
         (== diagnosis :church-turing) (== count 1)]
        ;; single: classifier diverges
        [(== sub-ok true) (== cls-ok false)
         (== diagnosis :classifier-divergence) (== count 1)]
        ;; double: both diverge
        [(== sub-ok false) (== cls-ok false)
         (== diagnosis :double-ill-posed) (== count 2)])
      (== q {:epoch epoch-idx
             :substrate sub-ok
             :classifier cls-ok
             :diagnosis diagnosis
             :ill-count count}))))

;; All 4 possible states for any epoch
(println "=== Possible states for epoch 15 ===")
(def states (witness-relation 15))
(println "Found" (count states) "possible states:")
(map println states)

;; === Constrained search: what epochs CAN be well-posed? ===
;; Given our Cyton data: inet always diverges from tree-walk (Church-Turing)
;; AND Ch2 classifier always diverges (range vs stddev boundary)
;; So substrate=false AND classifier=false for ALL epochs.

(defn cyton-constrained [epoch-idx]
  "Search under Cyton constraints: inet diverges, Ch2 diverges"
  (run* [q]
    (fresh [sub-ok cls-ok diagnosis count]
      ;; Cyton constraint: inet always diverges
      (== sub-ok false)
      ;; Cyton constraint: Ch2 range/stddev always disagree
      (== cls-ok false)
      (conde
        [(== sub-ok true) (== cls-ok true)
         (== diagnosis :well-posed) (== count 0)]
        [(== sub-ok false) (== cls-ok true)
         (== diagnosis :church-turing) (== count 1)]
        [(== sub-ok true) (== cls-ok false)
         (== diagnosis :classifier-divergence) (== count 1)]
        [(== sub-ok false) (== cls-ok false)
         (== diagnosis :double-ill-posed) (== count 2)])
      (== q {:epoch epoch-idx :diagnosis diagnosis :ill-count count}))))

(println "\n=== Cyton-constrained search for epoch 15 ===")
(def constrained (cyton-constrained 15))
(println "Found" (count constrained) "satisfying state(s):")
(map println constrained)

;; === The street fighting insight ===
;; Without constraints: 4 possible states (well-posed + 3 ill-posed)
;; With Cyton constraints: exactly 1 state (double ill-posed)
;; The constraints ELIMINATE 3 of 4 possibilities.
;; This is dimensional analysis: the "units" (substrate=false, classifier=false)
;; constrain the search space to a single point.

;; === Inverse problem: what constraints would make epoch well-posed? ===
(defn what-would-fix [epoch-idx]
  "Search for conditions that would make this epoch well-posed"
  (run* [q]
    (fresh [sub-ok cls-ok]
      (== sub-ok true)   ; need substrate agreement
      (== cls-ok true)   ; need classifier agreement
      (== q {:epoch epoch-idx
             :needs-substrate-fix true
             :needs-classifier-fix true
             :fix "resolve inet divergence AND calibrate Ch2 threshold"}))))

(println "\n=== What would fix epoch 15? ===")
(map println (what-would-fix 15))

;; === Type-level parallel ===
;; The witness relation is a TYPE for epochs:
;;   Epoch : (Bool × Bool) → Diagnosis × Nat
;; The Cyton constraints are a TYPE REFINEMENT:
;;   CytonEpoch : {e : Epoch | e.substrate = false ∧ e.classifier = false}
;; The refinement type has exactly one inhabitant: double-ill-posed.
;; SPJ would recognize this as a singleton type — the type IS the value.

(println "\n=== Summary ===")
(println "Unconstrained: 4 states (well-posed + 3 ill-posed)")
(println "Cyton-constrained: 1 state (double ill-posed)")
(println "This IS type refinement: the constraint narrows to a singleton type")
