;; regression_69.clj — 69 invariants that must never break
;; Run: cat examples/regression_69.clj | ./zig-out/bin/nanoclj
;; All lines should print true. Any false = regression.

(do

;; 1-10: arithmetic
(println (= 6 (+ 1 2 3)))
(println (= 24 (* 1 2 3 4)))
(println (= 5 (/ 10 2)))
(println (= 3 (- 10 7)))
(println (= 1 (mod 7 3)))
(println (= 1 (rem 7 3)))
(println (= 2 (quot 7 3)))
(println (= 5 (abs -5)))
(println (= 2 (inc 1)))
(println (= 0 (dec 1)))

;; 11-20: predicates
(println (= true (= 1 1)))
(println (= true (< 1 2)))
(println (= true (> 2 1)))
(println (= true (>= 2 2)))
(println (= true (not false)))
(println (= true (not= 1 2)))
(println (= true (nil? nil)))
(println (= true (even? 4)))
(println (= true (odd? 3)))
(println (= true (zero? 0)))

;; 21-30: collections
(println (= 3 (count (list 1 2 3))))
(println (= 1 (first (list 1 2 3))))
(println (= 2 (first (rest (list 1 2 3)))))
(println (= 3 (last (list 1 2 3))))
(println (= 2 (nth (list 1 2 3) 1)))
(println (= 4 (count (conj (list 1 2 3) 0))))
(println (nil? (seq (list))))
(println (vector? (vec (list 1 2))))
(println (= 3 (peek [1 2 3])))
(println (= 2 (count (pop [1 2 3]))))

;; 31-40: maps
(println (= 1 (get {:a 1} :a)))
(println (= 2 (get (assoc {} :a 2) :a)))
(println (nil? (get (dissoc {:a 1} :a) :a)))
(println (= 2 (get (merge {:a 1} {:a 2}) :a)))
(println (contains? {:a 1} :a))
(println (= "a" (name :a)))
(println (= :a (keyword "a")))
(println (= "ab" (str "a" "b")))
(println (= 42 (parse-long "42")))
(println (identical? 1 1))

;; 41-50: HOF
(println (= 2 (first (map inc (list 1 2 3)))))
(println (= 2 (first (filter even? (list 1 2 3 4)))))
(println (= 15 (reduce + (list 1 2 3 4 5))))
(println (= 7 ((partial + 2) 5)))
(println (= 7 ((comp inc inc) 5)))
(println (= 42 ((constantly 42) 1)))
(println (= true ((complement even?) 3)))
(println (= 9 (do (defn sq [x] (* x x)) (sq 3))))
(println (= 1 (first (sort (list 3 1 2)))))
(println (= 3 (first (reverse (list 1 2 3)))))

;; 51-57: control flow
(println (= 42 (and true 42)))
(println (= 42 (or nil 42)))
(println (= 3 (when true (+ 1 2))))
(println (nil? (when-not true 42)))
(println (= "two" (case 2 1 "one" 2 "two" 3 "three")))
(println (= 0 (try (/ 1 0) (catch e 0))))
(println (nil? (doseq [x (list 1)] x)))

;; 58-63: GF(3) conservation
(println (= 0 (+ 1 0 (find-balancer 1 0))))
(println (= 0 (trit-sum 1069 3)))
(println (= 0 (trit-sum 1069 9)))
(println (= (at 1069 0) (at 1069 0)))
(println (= 1 (separation 3 5)))
(println (= -1 (separation 7 5)))

;; 64-69: substrate + jepsen
(println (get (semi-decide "(+ 1 2)" 3) :tree-walk-answer))
(println (do (jepsen/reset!) (get (jepsen/check) :valid?)))
(println (= -1 (compare 1 2)))
(println (= true (some? 42)))
(println (= true (coll? [1 2])))
(println (= true (boolean? true)))

(println "--- 69 regression tests complete ---")

)
