#!/bin/bash
set -e

ZIG_BIN="$1"
LABEL="${2:-unknown}"
NANOCLJ="./zig-out/bin/nanoclj"

if [ -z "$ZIG_BIN" ]; then
  echo "Usage: $0 <zig-binary> [label]"
  exit 1
fi

echo "=== Benchmark: $LABEL ($($ZIG_BIN version)) ==="
cd "$(dirname "$0")"

eval_expr() {
  local result
  result=$(echo "$1" | "$NANOCLJ" 2>/dev/null | sed -n '2s/^user=> //p')
  echo "$result"
}

# Debug build
echo "--- Debug build ---"
$ZIG_BIN build 2>&1
echo ""

echo "--- Correctness ---"
PASS=0; FAIL=0; TOTAL=0
check() {
  local expr="$1" expected="$2"
  TOTAL=$((TOTAL+1))
  local got
  got=$(eval_expr "$expr")
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS+1))
    printf "  OK  %-60s => %s\n" "$expr" "$got"
  else
    FAIL=$((FAIL+1))
    printf "  FAIL %-60s => '%s' (expected '%s')\n" "$expr" "$got" "$expected"
  fi
}

check "(+ 1 2)" "3"
check "(* 6 7)" "42"
check "(- 100 58)" "42"
check "(if true 42 0)" "42"
check "(if false 1 2)" "2"
check "(do (def! x 10) (+ x x))" "20"
check "(do (def! fib (fn* (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 10))" "55"
check "(do (def! fib (fn* (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 15))" "610"
check "(do (def! fib (fn* (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 20))" "6765"
check "(do (def! fact (fn* (n) (if (<= n 1) 1 (* n (fact (- n 1)))))) (fact 10))" "3628800"
check "(do (def! sum (fn* (n) (if (<= n 0) 0 (+ n (sum (- n 1)))))) (sum 100))" "5050"
check "(do (def! sum (fn* (n) (if (<= n 0) 0 (+ n (sum (- n 1)))))) (sum 1000))" "500500"
check "(list 1 2 3 4 5)" "(1 2 3 4 5)"
check "(count (list 1 2 3 4 5))" "5"
check "(first (list 10 20 30))" "10"

echo ""
echo "  Score: $PASS/$TOTAL"

# ReleaseFast
echo ""
echo "--- ReleaseFast build ---"
time $ZIG_BIN build -Doptimize=ReleaseFast 2>&1
echo ""

echo "--- Performance (ReleaseFast) ---"
for expr in \
  "(do (def! fib (fn* (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 20))" \
  "(do (def! fib (fn* (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 25))" \
  "(do (def! sum (fn* (n) (if (<= n 0) 0 (+ n (sum (- n 1)))))) (sum 10000))"
do
  printf "  %-70s " "$expr"
  result=$( { time eval_expr "$expr" ; } 2>&1 )
  val=$(echo "$result" | head -1)
  real=$(echo "$result" | grep real | awk '{print $2}')
  printf "=> %-12s %s\n" "$val" "$real"
done

echo ""
echo "--- Binary size: $(ls -lh $NANOCLJ | awk '{print $5}') ---"
echo "=== Done: $LABEL ==="
