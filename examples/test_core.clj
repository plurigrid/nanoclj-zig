;; nanoclj-zig core test suite
;; Run with: (load-file "examples/test_core.clj")

(deftest test-arithmetic
  (testing "basic ops"
    (is (= 4 (+ 2 2)))
    (is (= 0 (- 5 5)))
    (is (= 6 (* 2 3)))
    (is= 42 (* 6 7)))
  (testing "comparison"
    (is (< 1 2))
    (is (> 3 2))
    (is (<= 2 2))
    (is (>= 5 3))))

(deftest test-collections
  (testing "list ops"
    (is= 3 (count (list 1 2 3)))
    (is= 1 (first (list 1 2 3)))
    (is= 3 (last (list 1 2 3)))
    (is= 2 (second (list 1 2 3))))
  (testing "vector ops"
    (is= 3 (count [1 2 3]))
    (is= 2 (nth [10 20 30] 1)))
  (testing "map ops"
    (is= 2 (get {:a 1 :b 2} :b))
    (is= {:a 1} (dissoc {:a 1 :b 2} :b))
    (is (contains? {:a 1} :a))
    (is (not (contains? {:a 1} :b)))))

(deftest test-strings
  (is= 5 (string-length "hello"))
  (is= "HELLO" (upper-case "hello"))
  (is= "hello" (lower-case "HELLO"))
  (is (starts-with? "hello" "hel"))
  (is (ends-with? "hello" "llo"))
  (is= 2 (index-of "hello" "l")))

(deftest test-predicates
  (is (integer? 42))
  (is (not (integer? 3.14)))
  (is (pos? 1))
  (is (neg? -1))
  (is (zero? 0))
  (is (even? 4))
  (is (odd? 3))
  (is (nil? nil))
  (is (not (nil? 0))))

(deftest test-hof
  (testing "partial"
    (is= 5 ((partial + 2) 3)))
  (testing "complement"
    (is ((complement zero?) 1))
    (is (not ((complement zero?) 0)))))

(deftest test-atom
  (let* [a (atom 0)]
    (is= 0 (deref a))
    (reset! a 42)
    (is= 42 (deref a))
    (swap! a inc)
    (is= 43 (deref a))))

(deftest test-destructuring
  (let* [[a b c] [1 2 3]]
    (is= 1 a)
    (is= 2 b)
    (is= 3 c))
  (let* [[x & rest] [10 20 30]]
    (is= 10 x)
    (is= 2 (count rest))))

(run-tests)
