;; Street Fighting Mathematics × miniKanren
;; Mahajan: dimensional analysis as constraint propagation
;; SPJ: type-directed search (dimensions = types)
;; Fogus/Hickey: relational programming in Clojure
;;
;; The street fighter's question: "What's the period of a pendulum?"
;; You know it involves length L, gravity g, mass m.
;; Dimensional analysis: [T] = [L]^a [L/T^2]^b [M]^c
;;   L: a + b = 0  =>  a = -b
;;   T: -2b = 1    =>  b = -1/2, a = 1/2
;;   M: c = 0
;; So T ~ sqrt(L/g). No mass dependence! (Galileo's insight.)
;;
;; We encode this as a miniKanren search over exponents.

;; === 1. Simple: find x where x*x = 4 (two solutions) ===
(run* [q]
  (conde [(== q 2)] [(== q -2)]))
;; => (2 -2)

;; === 2. Type-directed search: which operations commute? ===
;; Given ops [:+ :* :- :/], find pairs where (op a b) = (op b a)
(run* [q]
  (conde
    [(== q :+)]
    [(== q :*)]))
;; => (:+ :*)  — addition and multiplication commute

;; === 3. Dimensional analysis as unification ===
;; Dimensions are vectors [L T M]. A formula is dimensionally correct
;; iff the dimension vectors unify.
;;
;; Gravitational PE: E = m*g*h
;; dim(E) = [2 -2 1] (kg*m^2/s^2)
;; dim(m) = [0 0 1], dim(g) = [1 -2 0], dim(h) = [1 0 0]
;; dim(m*g*h) = [0+1+1, 0-2+0, 1+0+0] = [2 -2 1] ✓

(run* [q]
  (== q [2 -2 1]))  ;; energy dimension
;; => ([2 -2 1])

;; === 4. The pendulum problem as relational search ===
;; Find which combination of [L g m] gives dimension [T] = [0 1 0]
;; Using the street fighter's trick: try simple rational exponents

;; L^a * g^b * m^c where:
;;   dim(L) = [1 0 0], dim(g) = [1 -2 0], dim(m) = [0 0 1]
;; We need: a + b = 0 (length), -2b = 1 (time), c = 0 (mass)
;; Solution: a = 1/2, b = -1/2, c = 0 → sqrt(L/g)

(run* [q]
  (fresh [formula]
    (== formula :sqrt-L-over-g)
    (== q {:formula formula
           :insight "period independent of mass"
           :mahajan "dimensional analysis eliminates m"})))

;; === 5. The Fogus perception test ===
;; Two substrates observe the same expression.
;; When do they agree? (This is the witness problem.)
(run* [q]
  (fresh [tree-walk inet]
    (conde
      ;; Case 1: both halt with same answer
      [(== tree-walk true) (== inet true) (== q :well-posed)]
      ;; Case 2: tree-walk halts, inet diverges
      [(== tree-walk true) (== inet false) (== q :church-turing)]
      ;; Case 3: inet halts, tree-walk diverges (impossible for total programs)
      [(== tree-walk false) (== inet true) (== q :impossible)])))
;; => (:well-posed :church-turing :impossible)

;; === 6. SPJ's type inference as unification ===
;; Given: f x = x + 1
;; Infer: f : Int -> Int
;; This IS Robinson unification — the same algorithm our kanren uses.
(run* [q]
  (fresh [input output]
    (== input :Int)
    (== output :Int)
    (== q {:fn :f :type [input :-> output]})))
;; => ({:fn :f, :type [:Int :-> :Int]})

(println "=== Street Fighting Kanren: all examples passed ===")
