;; regression_69_r3.clj — round 3: LEFT BIRB vs RIGHT BIRB
;; Left birb: trusts nothing, tests failure modes, expects breakage
;; Right birb: trusts everything, tests success paths, expects harmony
;; The open identity equilibrium: where they agree is the fixed point.

(do

;; LEFT BIRB: adversarial (expects things to break)
;; 1-7: division by zero, overflow, underflow, empty access
(println (= 0 (try (/ 1 0) (catch e 0))))
(println (= 0 (try (nth (list) 99) (catch e 0))))
(println (nil? (get {} :nonexistent)))
(println (nil? (first (list))))
(println (nil? (next (list))))
(println (= 0 (count nil)))
(println (nil? (seq nil)))

;; 8-14: type confusion — wrong types should fail gracefully
(println (= 0 (try (+ "a" 1) (catch e 0))))
(println (= 0 (try (inc "a") (catch e 0))))
(println (= 0 (try (nth 42 0) (catch e 0))))
(println (= 0 (try (first 42) (catch e 0))))
(println (= 0 (try (count 42) (catch e 0))))
(println (= 0 (try (get 42 :a) (catch e 0))))
(println (= 0 (try (assoc 42 :a 1) (catch e 0))))

;; 15-21: nemesis — corrupt state and verify recovery
(println (do (jepsen/reset!) (jepsen/nemesis! :trit-corrupt) (jepsen/nemesis! :none) (get (jepsen/check) :valid?)))
(println (do (jepsen/reset!) (jepsen/record! 0 0 0 0 0 1) (jepsen/record! 0 0 0 0 0 2) (get (jepsen/check-unique-ids) :valid?)))
(println (do (jepsen/reset!) (jepsen/record! 0 0 0 1 0 1) (not (get (jepsen/check) :valid?))))
(println (integer? (at 0 0)))
(println (integer? (trit-at 0 0)))
(println (= 0 (trit-sum 0 0)))
(println (= 0 (trit-sum 999999 3)))

;; RIGHT BIRB: trusting (expects harmony)
;; 22-28: everything composes
(println (= 15 (reduce + (map inc (filter even? (list 0 1 2 3 4))))))
(println (= 3 (count (take 3 (drop 2 (list 1 2 3 4 5 6 7))))))
(println (= (list 6 4 2) (reverse (sort (filter even? (list 5 4 3 2 1 6))))))
(println (= 10 ((comp (partial * 2) (partial + 3)) 2)))
(println (= true (every? integer? (list 1 2 3))))
(println (= false (every? even? (list 1 2 3))))
(println (= true (not-any? nil? (list 1 2 3))))

;; 29-35: data flows through all layers
(println (= {:a 1 :b 2} (merge {:a 1} {:b 2})))
(println (= 2 (get-in {:a {:b 2}} (list :a :b))))
(println (= {:a {:b 3}} (assoc-in {} (list :a :b) 3)))
(println (= {:a 2} (update {:a 1} :a inc)))
(println (= (list :a :b) (sort (keys {:b 2 :a 1}))))
(println (= true (contains? #{1 2 3} 2)))
(println (= 3 (count (hash-set 1 2 3))))

;; EQUILIBRIUM: where left and right agree
;; 36-42: identity — same operation, opposite framing, same result
(println (= (+ 1 2) (- 6 3)))
(println (= (first (list 1)) (last (list 1))))
(println (= (count (list)) (count [])))
(println (= (find-balancer 1 -1) (find-balancer -1 1)))
(println (= (at 1069 0) (at 1069 0)))
(println (= (trit-sum 42 3) (trit-sum 42 3)))
(println (= (separation 5 5) 0))

;; 43-49: commutativity — order shouldn't matter for these
(println (= (+ 1 2) (+ 2 1)))
(println (= (* 3 4) (* 4 3)))
(println (= (merge {:a 1} {:b 2}) (merge {:b 2} {:a 1})))
(println (= (find-balancer 1 0) (find-balancer 0 1)))
(println (= (hash-set 1 2 3) (hash-set 3 2 1)))
(println (= (= 1 1) (= 2 2)))
(println (= (nil? nil) (nil? nil)))

;; 50-56: the witness sees what neither birb alone can
(println (not (get (semi-decide "(+ 1 2)" 3) :substrates-agree?)))
(println (get (semi-decide "(+ 1 2)" 3) :tree-walk-answer))
(println (get (semi-decide "(+ 1 2)" 3) :inet-trit-balanced?))
(println (not (get (semi-decide "(if true 1 0)" 1) :substrates-agree?)))
(println (get (semi-decide "(+ 0 0)" 0) :tree-walk-answer))
(println (integer? (get (semi-decide "(+ 1 2)" 3) :tree-walk-fuel-spent)))
(println (= false (get (semi-decide "(+ 1 2)" 4) :tree-walk-answer)))

;; 57-63: float boundary — left birb says floats are regression, right says they're necessary
(println (integer? (at 1069 0)))
(println (integer? (trit-at 1069 0)))
(println (integer? (find-balancer 1 0)))
(println (integer? (trit-sum 1069 333)))
(println (integer? (separation 3 5)))
(println (integer? (cone-volume 3 3)))
(println (integer? (causal-depth 3 10)))

;; 64-69: the birbs converge — these pass regardless of perspective
(println (= 0 (mod (+ 1 0 (find-balancer 1 0)) 3)))
(println (= 0 (mod (+ -1 1 (find-balancer -1 1)) 3)))
(println (= 0 (mod (+ 0 0 (find-balancer 0 0)) 3)))
(println (= true (and true true true)))
(println (= nil (or nil nil nil)))
(println (= 42 (or nil nil 42)))

(println "--- 69 round 3: LEFT+RIGHT BIRB equilibrium ---")

)
