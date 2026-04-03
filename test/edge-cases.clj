;; nanoclj-zig edge case torture tests
;; Run each form and compare expected output

;; === 1. CLOSURE CAPTURE & MUTATION SEMANTICS ===

;; closure captures environment at definition time
(def make-adder (fn* [x] (fn* [y] (+ x y))))
(def add5 (make-adder 5))
(add5 3)  ;; => 8

;; closure over loop variable (classic JS footgun)
(def fns (let* [v []]
  (let* [f0 (fn* [] 0)
         f1 (fn* [] 1)
         f2 (fn* [] 2)]
    [f0 f1 f2])))
((nth fns 0))  ;; => 0
((nth fns 2))  ;; => 2

;; deeply nested closures (3 levels)
(def outer (fn* [a]
  (fn* [b]
    (fn* [c]
      (+ a (+ b c))))))
(((outer 1) 2) 3)  ;; => 6

;; === 2. VARIADIC ARGS EDGE CASES ===

;; zero rest args
(def f (fn* [& xs] (count xs)))
(f)  ;; => 0

;; rest with fixed prefix
(def g (fn* [a b & more] (+ a (+ b (count more)))))
(g 10 20)      ;; => 30  (more is empty)
(g 10 20 1 2 3)  ;; => 33

;; === 3. NUMERIC EDGE CASES (i48 boundary + float) ===

;; i48 max/min (2^47 - 1 = 140737488355327)
(+ 140737488355326 1)  ;; => 140737488355327 (i48 max)
(- 0 140737488355328)  ;; => -140737488355328 (i48 min)

;; integer overflow → what happens?
(+ 140737488355327 1)  ;; => ??? (overflow or promotion?)

;; float precision
(/ 1 3)        ;; => 0.3333...
(= 0.1 0.1)   ;; => true
(+ 0.1 0.2)   ;; => 0.30000000000000004 (IEEE 754)
(= (+ 0.1 0.2) 0.3)  ;; => false (classic)

;; mixed int/float
(+ 1 0.5)     ;; => 1.5
(* 2 3.14)    ;; => 6.28

;; negative zero
(/ -1.0 (/ 1.0 0.0))  ;; => -0.0 or error?

;; === 4. EMPTY COLLECTION EDGE CASES ===

(first [])    ;; => nil
(rest [])     ;; => ()
(first ())    ;; => nil
(rest ())     ;; => ()
(count [])    ;; => 0
(count {})    ;; => 0
(count ())    ;; => 0
(first {})    ;; => nil? or error?

;; conj to empty
(conj [] 1)   ;; => [1]
(conj () 1)   ;; => (1)
(conj nil 1)  ;; => ??? (Clojure returns (1))

;; nested empty
[[[] []] []]  ;; => [[[] []] []]

;; === 5. MAP EDGE CASES ===

;; keyword keys
(get {:a 1 :b 2} :a)  ;; => 1
(get {:a 1} :missing)  ;; => nil
(get {:a 1} :missing :default)  ;; => :default (3-arity get)

;; assoc chain
(assoc (assoc {} :a 1) :b 2)  ;; => {:a 1 :b 2}

;; overwrite key
(assoc {:a 1} :a 99)  ;; => {:a 99}

;; numeric keys
(get {0 "zero" 1 "one"} 0)  ;; => "zero"

;; nil as value
(get {:a nil} :a)  ;; => nil (but is key present?)

;; === 6. RECURSION DEPTH ===

;; factorial (tests deep recursion without TCO)
(def fact (fn* [n]
  (if (<= n 1)
    1
    (* n (fact (- n 1))))))
(fact 10)    ;; => 3628800
(fact 20)    ;; => 2432902008176640000 (if i48 enough: 2.4e18 < 1.4e14... OVERFLOW)

;; mutual recursion
(def is-even? (fn* [n]
  (if (= n 0) true (is-odd? (- n 1)))))
(def is-odd? (fn* [n]
  (if (= n 0) false (is-even? (- n 1)))))
(is-even? 10)  ;; => true
(is-odd? 11)   ;; => true

;; deep recursion (stack overflow test)
(def countdown (fn* [n]
  (if (= n 0) 0 (countdown (- n 1)))))
(countdown 1000)    ;; => 0
(countdown 10000)   ;; => 0 or stack overflow?

;; === 7. HIGHER-ORDER FUNCTIONS ===

;; function as argument
(def twice (fn* [f x] (f (f x))))
(twice (fn* [x] (+ x 1)) 0)  ;; => 2

;; function returning function that returns function
(def compose (fn* [f g] (fn* [x] (f (g x)))))
(def inc (fn* [x] (+ x 1)))
(def dbl (fn* [x] (* x 2)))
((compose inc dbl) 3)  ;; => 7  (inc(dbl(3)) = inc(6) = 7)
((compose dbl inc) 3)  ;; => 8  (dbl(inc(3)) = dbl(4) = 8)

;; apply edge cases
(apply + [])        ;; => 0 (identity for +)
(apply + [1])       ;; => 1
(apply + [1 2 3])   ;; => 6

;; === 8. LET* SCOPING ===

;; shadow in same let
(let* [x 1 x (+ x 1)] x)  ;; => 2

;; let doesn't leak
(let* [secret 42] secret)  ;; => 42
;; secret  ;; => error: SymbolNotFound

;; nested let
(let* [x 1]
  (let* [y 2]
    (let* [z 3]
      (+ x (+ y z)))))  ;; => 6

;; === 9. TRUTHINESS ===

(if true 1 2)   ;; => 1
(if false 1 2)  ;; => 2
(if nil 1 2)    ;; => 2
(if 0 1 2)      ;; => 1 (0 is truthy in Clojure!)
(if "" 1 2)     ;; => 1 ("" is truthy in Clojure!)
(if [] 1 2)     ;; => 1 ([] is truthy in Clojure!)
(if () 1 2)     ;; => 1 (() is truthy in Clojure!)

;; not
(not true)   ;; => false
(not false)  ;; => true
(not nil)    ;; => true
(not 0)      ;; => false (0 is truthy!)
(not "")     ;; => false

;; === 10. STRING EDGE CASES ===

(str)              ;; => ""
(str nil)          ;; => "" (Clojure prints "")
(str 1 " " 2)     ;; => "1 2"
(str true)         ;; => "true"
(str :kw)          ;; => ":kw"
(count "")         ;; => 0
(count "hello")    ;; => 5
(subs "hello" 0 0) ;; => ""
(subs "hello" 5)   ;; => "" (past end)
(subs "hello" 2 4) ;; => "ll"

;; === 11. QUOTE BEHAVIOR ===

(quote (1 2 3))         ;; => (1 2 3)
(quote hello)           ;; => hello
'(+ 1 2)               ;; => (+ 1 2) (not 3)
(first '(+ 1 2))       ;; => + (the symbol)
(= (first '(+ 1 2)) '+)  ;; => true? (symbol comparison)

;; === 12. DEF RETURNS VALUE ===

(def x 42)   ;; => what? Clojure returns #'user/x, nanoclj likely returns 42 or nil
x            ;; => 42

;; redefine
(def x 99)
x            ;; => 99

;; def with expression
(def y (+ 1 2))
y  ;; => 3

;; === 13. EQUALITY EDGE CASES ===

(= nil nil)        ;; => true
(= true true)      ;; => true
(= false false)    ;; => true
(= nil false)      ;; => false (nil != false)
(= 1 1)            ;; => true
(= 1 1.0)          ;; => ??? (Clojure: false, many impls: true)
(= [] ())          ;; => ??? (Clojure: true if same elements)
(= [1 2] [1 2])    ;; => true? (structural equality)
(= {:a 1} {:a 1})  ;; => true? (structural equality)
(= :a :a)          ;; => true (interned)
(= 'x 'x)         ;; => true (interned)

;; === 14. GF(3) SUBSTRATE ===

(gf3-add 1 1)      ;; => -1 (1+1 = 2 ≡ -1 mod 3)
(gf3-add 1 -1)     ;; => 0
(gf3-mul 1 -1)     ;; => -1
(gf3-mul -1 -1)    ;; => 1
(gf3-conserved? [1 -1 0])  ;; => true (sum = 0)
(gf3-conserved? [1 1 1])   ;; => true (sum = 3 ≡ 0)
(gf3-conserved? [1 1 0])   ;; => false (sum = 2)

;; === 15. SELF-REFERENTIAL / WEIRD ===

;; function that returns itself
(def self (fn* [] self))
(fn? (self))  ;; => true

;; Y-combinator (if eval is correct)
(def Y (fn* [f]
  ((fn* [x] (f (fn* [& args] (apply (x x) args))))
   (fn* [x] (f (fn* [& args] (apply (x x) args)))))))

(def factorial
  (Y (fn* [f]
    (fn* [n]
      (if (<= n 1) 1 (* n (f (- n 1))))))))
(factorial 5)  ;; => 120

;; === 16. ERROR CASES (should error gracefully) ===

;; (1 2 3)           ;; error: 1 is not a function
;; (+ "a" 1)         ;; error: type mismatch
;; (nth [1 2] 5)     ;; error: index out of bounds
;; (def)              ;; error: arity
;; (let* [x] x)      ;; error: odd number of let bindings
;; (fn* 1 2)          ;; error: params must be vector
;; undefined-symbol   ;; error: SymbolNotFound
