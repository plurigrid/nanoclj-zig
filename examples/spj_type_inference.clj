;; SPJ Resurrected: Hindley-Milner type inference as miniKanren
;;
;; The key insight (SPJ 1987, "The Implementation of Functional Programming Languages"):
;; Type inference IS unification search. A type variable is a logic variable.
;; Algorithm W is just run* with constraints.
;;
;; Fogus (Joy of Clojure ch. 16): "Logic programming turns functions inside out.
;; Instead of computing a result from inputs, you state relationships and let
;; the system find satisfying assignments."
;;
;; Hickey (core.logic): Made this practical in Clojure. We make it practical in Zig.

;; === Type language ===
;; Types: :Int, :Bool, :String, [:-> input output], [:List elem]

;; === Rule 1: Literals have known types ===
(defn typeof-literal [expr]
  (run* [t]
    (conde
      [(== expr 42)      (== t :Int)]
      [(== expr true)    (== t :Bool)]
      [(== expr false)   (== t :Bool)]
      [(== expr "hello") (== t :String)])))

(def r1 (typeof-literal 42))
(def r2 (typeof-literal true))
(def r3 (typeof-literal "hello"))

;; === Rule 2: If-then-else constrains types ===
;; (if test then else) requires:
;;   typeof(test) = Bool
;;   typeof(then) = typeof(else) = result type
(defn typeof-if [test-type then-type else-type]
  (run* [result]
    (== test-type :Bool)
    (== then-type else-type)
    (== result then-type)))

(def r4 (typeof-if :Bool :Int :Int))      ; valid: Int
(def r5 (typeof-if :Bool :Int :String))    ; empty: type mismatch

;; === Rule 3: Function application (the SPJ core) ===
;; (f x) where typeof(f) = [a :-> b] and typeof(x) = a  =>  result type = b
(defn typeof-app [fn-type arg-type]
  (run* [result]
    (fresh [a b]
      (== fn-type [a :-> b])
      (== arg-type a)
      (== result b))))

(def r6 (typeof-app [:Int :-> :Bool] :Int))   ; Bool
(def r7 (typeof-app [:Int :-> :Bool] :String)) ; empty: arg mismatch

;; === Rule 4: Lambda abstraction ===
;; (fn [x] body) where x:a and body:b  =>  [a :-> b]
(defn typeof-lambda [param-type body-type]
  (run* [result]
    (== result [param-type :-> body-type])))

(def r8 (typeof-lambda :Int :Bool))  ; [:Int :-> :Bool]

;; === Rule 5: Composition (the street fighting move) ===
;; (comp f g) where f:[b -> c] and g:[a -> b]  =>  [a -> c]
;; SPJ: "This is where unification earns its keep — b must agree."
(defn typeof-comp [f-type g-type]
  (run* [result]
    (fresh [a b1 b2 c]
      (== f-type [b1 :-> c])
      (== g-type [a :-> b2])
      (== b1 b2)              ; the unification constraint!
      (== result [a :-> c]))))

(def r9 (typeof-comp [:Bool :-> :String] [:Int :-> :Bool]))
;; => ([:Int :-> :String])  — Int->Bool->String collapses to Int->String

;; === The Mahajan dimensional analysis parallel ===
;; Types ARE dimensions. A type error is a dimensional analysis failure.
;; [Int -> Bool] composed with [Bool -> String] works because the "units cancel."
;; [Int -> Bool] composed with [String -> Bool] fails — units don't match.
(def r10 (typeof-comp [:Int :-> :Bool] [:String :-> :Bool]))
;; => () — empty! String ≠ Int, just like meters ≠ seconds.

;; === Print results ===
(println "=== SPJ Type Inference via miniKanren ===")
(println "literal 42:     " r1)
(println "literal true:   " r2)
(println "literal hello:  " r3)
(println "if Bool Int Int: " r4)
(println "if Bool Int Str: " r5 "(type error)")
(println "app Int->Bool Int:" r6)
(println "app Int->Bool Str:" r7 "(type error)")
(println "lambda Int Bool: " r8)
(println "comp B->S . I->B:" r9)
(println "comp I->B . S->B:" r10 "(type error)")
