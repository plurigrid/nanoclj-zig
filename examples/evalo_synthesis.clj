;; evalo — the relational interpreter (Byrd's crown jewel)
;;
;; (evalo expr val env) means: expr evaluates to val under env.
;; Run forward = eval. Run backward = program synthesis.
;;
;; Expression language:
;;   42, :foo           → self-evaluating
;;   [:quote x]         → x
;;   [:var :name]       → environment lookup
;;   [:lambda :x body]  → closure
;;   [:app f arg]       → function application
;;   [:if test then else] → conditional
;;
;; Environment = list of (name val) pairs: '((:x 1) (:y 2))

;; === Forward: evaluate known expressions ===

(println "=== Forward evaluation ===")

;; Self-evaluating integer
(def r1 (run* [q] (evalo 42 q '())))
(println "42 =>" r1)

;; Self-evaluating keyword
(def r2 (run* [q] (evalo :hello q '())))
(println ":hello =>" r2)

;; Quote
(def r3 (run* [q] (evalo [:quote [1 2 3]] q '())))
(println "[:quote [1 2 3]] =>" r3)

;; Variable lookup
(def r4 (run* [q] (evalo [:var :x] q '((:x 42)))))
(println "[:var :x] with x=42 =>" r4)

;; Lambda creates closure
(def r5 (run* [q] (evalo [:lambda :x [:var :x]] q '())))
(println "[:lambda :x [:var :x]] =>" r5)

;; Application: identity function
(def r6 (run* [q] (evalo [:app [:lambda :x [:var :x]] [:quote 42]] q '())))
(println "(identity 42) =>" r6)

;; Application: constant function
(def r7 (run* [q] (evalo [:app [:lambda :x [:quote 99]] [:quote 42]] q '())))
(println "(const 99) applied to 42 =>" r7)

;; If-then-else: true branch
(def r8 (run* [q] (evalo [:if [:quote true] [:quote :yes] [:quote :no]] q '())))
(println "(if true :yes :no) =>" r8)

;; If-then-else: false branch
(def r9 (run* [q] (evalo [:if [:quote false] [:quote :yes] [:quote :no]] q '())))
(println "(if false :yes :no) =>" r9)

;; === Backward: program synthesis ===

(println "\n=== Backward synthesis ===")

;; What expressions evaluate to 42 in empty env?
(def r10 (run 5 [q] (evalo q 42 '())))
(println "Programs producing 42:" r10)

;; What expressions evaluate to :hello?
(def r11 (run 3 [q] (evalo q :hello '())))
(println "Programs producing :hello:" r11)

;; === The Byrd insight ===
;; evalo is a RELATION, not a function.
;; Forward: (evalo known-expr ?val env) = evaluation
;; Backward: (evalo ?expr known-val env) = synthesis
;; Sideways: (evalo ?expr ?val known-env) = enumerate all (expr, val) pairs
;; This is why Pitts' adjoint characterization matters:
;; evalo is the right adjoint to "forgetting the evaluation derivation"

(println "\n=== Summary ===")
(println "Forward eval: expression → value (the easy direction)")
(println "Backward synthesis: value → expression (the hard direction)")
(println "evalo makes both the SAME computation — just run the relation differently")
