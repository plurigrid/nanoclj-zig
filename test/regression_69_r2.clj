;; regression_69_r2.clj — round 2: 69 MAXIMALLY DIFFERENT tests
;; Every test here probes a different dimension than round 1.
;; Run: (load-file "examples/regression_69_r2.clj")

(do

;; 1-7: kernel boundaries (where Clojure meets trit meets witness)
(println (integer? (at 0 0)))
(println (integer? (trit-at 0 0)))
(println (integer? (find-balancer 0 0)))
(println (float? (fv-dot (fv 1) (fv 1))))
(println (= "dense-f64" (type (fv 1))))
(println (map? (semi-decide "(+ 1 1)" 2)))
(println (string? (type (list))))

;; 8-14: empty/nil edge cases
(println (nil? (first (list))))
(println (nil? (next (list 1))))
(println (nil? (seq (list))))
(println (= 0 (count (list))))
(println (= 0 (count [])))
(println (= 0 (count {})))
(println (nil? (get {} :x)))

;; 15-21: type coercion boundaries
(println (= 3 (int 3.7)))
(println (= 3.0 (double 3)))
(println (= 42 (parse-long "42")))
(println (nil? (parse-long "abc")))
(println (= true (parse-boolean "true")))
(println (= false (parse-boolean "false")))
(println (nil? (parse-boolean "maybe")))

;; 22-28: higher-order function composition
(println (= 10 (reduce + 0 (list 1 2 3 4))))
(println (= (list) (filter even? (list 1 3 5))))
(println (= 3 (count (map inc (list 1 2 3)))))
(println (= 2 (count (take 2 (list 1 2 3 4 5)))))
(println (= 3 (count (drop 2 (list 1 2 3 4 5)))))
(println (= 6 ((comp (partial * 2) (partial + 1)) 2)))
(println (true? ((complement nil?) 42)))

;; 29-35: nested data structures
(println (= 1 (get (get {:a {:b 1}} :a) :b)))
(println (= 1 (get-in {:a {:b 1}} (list :a :b))))
(println (= {:a {:b 2}} (assoc-in {:a {:b 1}} (list :a :b) 2)))
(println (= 3 (get-in {:a [1 2 3]} (list :a 2))))
(println (= 2 (count (keys {:a 1 :b 2}))))
(println (= 2 (count (vals {:a 1 :b 2}))))
(println (= {:a 2} (update {:a 1} :a inc)))

;; 36-42: string operations
(println (= 5 (count "hello")))
(println (= "ell" (subs "hello" 1 4)))
(println (= "HELLO" (str "HELLO")))
(println (= "a" (name :a)))
(println (= "a" (name 'a)))
(println (nil? (namespace :a)))
(println (= "ns" (namespace :ns/a)))

;; 43-49: bitwise operations (integer-only, no floats)
(println (= -1 (bit-not 0)))
(println (= true (bit-test 5 0)))
(println (= false (bit-test 5 1)))
(println (= 7 (bit-set 5 1)))
(println (= 4 (bit-clear 5 0)))
(println (= 6 (bit-flip 5 0)))
(println (= 4 (bit-and-not 5 1)))

;; 50-56: GF(3) conservation at different scales
(println (= 0 (trit-sum 0 3)))
(println (= 0 (trit-sum 999 9)))
(println (= 0 (trit-sum 42 27)))
(println (= 0 (trit-sum 1069 333)))
(println (= 0 (+ 1 -1 (find-balancer 1 -1))))
(println (= 0 (mod (+ -1 -1 (find-balancer -1 -1)) 3)))
(println (= 0 (+ 0 0 (find-balancer 0 0))))

;; 57-63: Jepsen adversarial
(println (do (jepsen/reset!) true))
(println (= true (get (jepsen/check) :valid?)))
(println (integer? (jepsen/record! 0 0 0 0 0 1)))
(println (integer? (jepsen/record! 0 0 0 0 0 2)))
(println (= true (get (jepsen/check-unique-ids) :valid?)))
(println (= true (get (jepsen/check-counter) :valid?)))
(println (vector? (jepsen/gen 5 42)))

;; 64-69: pattern engine agreement + divergence
(println (get (re-match :thompson "hello" "hello") :matched?))
(println (get (peg-match :vm "hello" "hello") :matched?))
(println (get (re-match :backtrack "a" "a") :matched?))
(println (not (get (re-match :thompson "x" "y") :matched?)))
(println (= 6 (count (match-all "ab" "ab"))))
(println (= -1 (get (re-match :thompson "x" "y") :trit)))

(println "--- 69 round 2 tests complete ---")

)
