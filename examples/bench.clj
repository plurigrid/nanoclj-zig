;; Benchmark suite: tree-walk vs bytecode
;; Run each with: (bench <expr>)

;; 1. Fibonacci (exponential recursion)
(bench (let* [fib (fn* [n] (if (<= n 1) n (+ (fib (- n 1)) (fib (- n 2)))))] (fib 25)))

;; 2. Fibonacci (linear via recur)
(bench (let* [fib (fn* [n a b] (if (<= n 0) a (recur (- n 1) b (+ a b))))] (fib 35 0 1)))

;; 3. Factorial (recur)
(bench (let* [fac (fn* [n acc] (if (<= n 1) acc (recur (- n 1) (* acc n))))] (fac 20 1)))

;; 4. Sum 1..N (recur)
(bench (let* [sum (fn* [n acc] (if (<= n 0) acc (recur (- n 1) (+ acc n))))] (sum 1000000 0)))

;; 5. Ackermann (3,6) — deeply recursive
(bench (let* [ack (fn* [m n] (cond (= m 0) (+ n 1) (= n 0) (ack (- m 1) 1) :else (ack (- m 1) (ack m (- n 1)))))] (ack 3 6)))

;; 6. Is-prime check (trial division)
(bench (let* [prime? (fn* [n] (let* [check (fn* [i] (cond (> (* i i) n) true (= 0 (rem n i)) false :else (recur (+ i 1))))] (and (> n 1) (check 2))))] (prime? 104729)))

;; 7. Collatz sequence length
(bench (let* [collatz (fn* [n steps] (if (= n 1) steps (recur (if (= 0 (rem n 2)) (quot n 2) (+ 1 (* 3 n))) (+ steps 1))))] (collatz 837799 0)))
