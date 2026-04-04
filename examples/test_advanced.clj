;; nanoclj-zig advanced feature tests
;; Tests: transients, volatile, loop/recur, case, condp, for, dotimes,
;;        multimethods, defmacro, threading, dense_f64, trace

(deftest test-transients
  (testing "vector transient"
    (let* [t (transient [1 2 3])
           t2 (conj! t 4)
           v (persistent! t2)]
      (is= 4 (count v))
      (is= 4 (nth v 3))))
  (testing "map transient"
    (let* [t (transient {:a 1})
           t2 (assoc! t :b 2)
           m (persistent! t2)]
      (is= 2 (get m :b)))))

(deftest test-volatile
  (let* [v (volatile! 0)]
    (is= 0 (deref v))
    (vreset! v 42)
    (is= 42 (deref v))
    (vswap! v inc)
    (is= 43 (deref v))))

(deftest test-loop-recur
  (testing "factorial"
    (is= 120 (loop [n 5 acc 1]
               (if (<= n 1) acc (recur (dec n) (* acc n))))))
  (testing "sum to N"
    (is= 55 (loop [i 0 s 0]
              (if (> i 10) s (recur (inc i) (+ s i)))))))

(deftest test-case
  (is= "one" (case 1 1 "one" 2 "two" "other"))
  (is= "two" (case 2 1 "one" 2 "two" "other"))
  (is= "other" (case 3 1 "one" 2 "two" "other")))

(deftest test-condp
  (is= "pos" (condp = 1 1 "pos" 2 "neg" "zero"))
  (is= "neg" (condp = 2 1 "pos" 2 "neg" "zero")))

(deftest test-for
  (is= (list 1 4 9) (for [x [1 2 3]] (* x x)))
  (is= 3 (count (for [x [10 20 30]] (inc x)))))

(deftest test-dotimes
  (let* [a (atom 0)]
    (dotimes [i 5] (swap! a + i))
    (is= 10 (deref a))))

(deftest test-doseq
  (let* [a (atom 0)]
    (doseq [x [1 2 3]] (swap! a + x))
    (is= 6 (deref a))))

(deftest test-mapv-filterv
  (is= [2 4 6] (mapv (fn* [x] (* x 2)) [1 2 3]))
  (is= [2 4] (filterv even? [1 2 3 4 5]))
  (is= (list 2 4) (remove odd? (list 1 2 3 4 5)))
  (is= (list 2 4 6) (keep (fn* [x] (when (even? x) x)) (list 1 2 3 4 5 6))))

(deftest test-reductions
  (is= (list 0 1 3 6 10) (reductions + 0 [1 2 3 4])))

(deftest test-cond-thread
  (testing "cond->"
    (is= 3 (cond-> 1 true (+ 1) true (+ 1) false (+ 100))))
  (testing "cond->>"
    (is= 3 (cond->> 1 true (+ 1) true (+ 1) false (+ 100)))))

(deftest test-as-thread
  (is= 6 (as-> 1 x (+ x 2) (* x 2))))

(deftest test-dense-f64
  (testing "creation and access"
    (let* [v (fv 1.0 2.0 3.0)]
      (is= 3 (fv-count v))
      (is= 2.0 (fv-get v 1))))
  (testing "dot product"
    (is= 14.0 (fv-dot (fv 1.0 2.0 3.0) (fv 1.0 2.0 3.0)))))

(deftest test-trace
  (let* [t (make-trace)]
    (trace-observe! t "x" 1.0 -0.5)
    (trace-observe! t "y" 2.0 -1.0)
    (is= -1.5 (trace-log-weight t))
    (is= 2 (count (trace-sites t)))))

(deftest test-metadata
  (let* [v (with-meta [1 2 3] {:doc "test"})]
    (is= {:doc "test"} (meta v))
    (is (nil? (meta [1 2 3])))))

(deftest test-print-fns
  (testing "pr-str"
    (is= "42" (pr-str 42))
    (is= "\"hello\"" (pr-str "hello"))
    (is= ":foo" (pr-str :foo))
    (is= "[1 2 3]" (pr-str [1 2 3]))))

(deftest test-seq-ops
  (testing "seq"
    (is (nil? (seq [])))
    (is (nil? (seq nil)))
    (is= 3 (count (seq [1 2 3]))))
  (testing "vec"
    (is= [1 2 3] (vec (list 1 2 3))))
  (testing "into"
    (is= [1 2 3 4 5] (into [1 2 3] [4 5]))))

(run-tests)
