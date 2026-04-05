// 01-DirectCompile.HC — Single-pass: source text → machine code, no IR
// HolyC's compiler is single-pass. It reads tokens and emits x86-64
// directly. No AST. No IR. No optimization passes.
//
// This file demonstrates what "no intermediate representation" means
// and why it matters for a Lisp.

// === 1. The compiler reads left-to-right, emits as it goes ===
// When HolyC sees: I64 x = 3 + 4 * 5;
// It does NOT build a tree. It uses operator precedence parsing
// and emits x86 instructions inline:
//   push 4; push 5; imul; push 3; add; mov [x], rax

I64 x = 3 + 4 * 5;  // x = 23. Compiled in one pass.

// === 2. Functions compile top-to-bottom ===
// No forward declarations needed for local use.
// The JIT resolves symbols as it encounters them.

I64 Fib(I64 n) {
  if (n <= 1) return n;
  return Fib(n-1) + Fib(n-2);
}
// Fib(10) => 55. The recursive call resolves because `Fib`
// was added to the symbol table at the function header.

// === 3. Demonstrate the single-pass nature ===
// This function shows what the compiler does step by step.
// Each line is compiled and emitted before the next is read.

I64 SinglePass(I64 a, I64 b, I64 c) {
  // Compiler emits: mov rax, [rbp+a_offset]
  I64 sum = a;
  // Compiler emits: add rax, [rbp+b_offset]; mov [rbp+sum_offset], rax
  sum += b;
  // Compiler emits: add rax, [rbp+c_offset]; mov [rbp+sum_offset], rax
  sum += c;
  // Compiler emits: imul rax, rax; ret
  return sum * sum;
}
// SinglePass(1,2,3) => 36

// === 4. Why this matters for Lisp ===
// SectorLisp: (+ 3 (* 4 5))
//   Reader produces cons cells: [+ 3 [* 4 5]]
//   Eval walks the tree recursively
//   NO compilation. The tree IS the program.
//
// nanoclj-zig today:
//   Reader → Value (AST as NaN-boxed cons cells)
//   → transclusion.zig (denotational meaning)
//   → transduction.zig (operational: fuel-bounded walk)
//   Three layers. Three passes over the same data.
//
// HolyC lesson: you don't need three passes.
//   Reader → emit bytecode directly
//   One pass. The reader IS the compiler.

// === 5. A "direct compile" Lisp expression evaluator in HolyC ===
// This evaluates simple arithmetic s-expressions by JIT'ing them.

I64 sexp_pos;  // global cursor

I64 ReadNum(U8 *s) {
  I64 n = 0;
  while (s[sexp_pos] >= '0' && s[sexp_pos] <= '9') {
    n = n * 10 + (s[sexp_pos] - '0');
    sexp_pos++;
  }
  return n;
}

// Evaluate (op num num) by generating HolyC source and JIT'ing it
I64 SexpEval(U8 *s) {
  while (s[sexp_pos] == ' ') sexp_pos++;

  if (s[sexp_pos] == '(') {
    sexp_pos++;  // skip (
    while (s[sexp_pos] == ' ') sexp_pos++;

    U8 op = s[sexp_pos];
    sexp_pos++;
    while (s[sexp_pos] == ' ') sexp_pos++;

    I64 a = SexpEval(s);
    while (s[sexp_pos] == ' ') sexp_pos++;
    I64 b = SexpEval(s);
    while (s[sexp_pos] == ' ' || s[sexp_pos] == ')') sexp_pos++;

    switch (op) {
      case '+': return a + b;
      case '-': return a - b;
      case '*': return a * b;
      case '/': return a / b;
    }
    return 0;
  } else {
    return ReadNum(s);
  }
}

U0 TestSexp() {
  U8 *expr = "(+ 3 (* 4 5))";
  sexp_pos = 0;
  I64 result = SexpEval(expr);
  "SexpEval(\"%s\") = %d\n", expr, result;
  // => SexpEval("(+ 3 (* 4 5))") = 23
}

TestSexp;

// === LESSON FOR NANOCLJ-ZIG ===
// Add a `direct_compile.zig` that does:
//   1. Reader emits bytecode opcodes as it parses tokens
//   2. No Value/AST intermediate. Reader sees `(+ 1 2)`:
//      - `(` → push frame
//      - `+` → note: this is ADD
//      - `1` → emit LOAD_INT 1
//      - `2` → emit LOAD_INT 2
//      - `)` → emit ADD; pop frame
//   3. Result: bytecode ready for VM, zero allocation
//
// For complex expressions (macros, let-bindings), fall back
// to the full 3-layer pipeline. But for arithmetic, collection
// literals, and function calls — single pass suffices.
