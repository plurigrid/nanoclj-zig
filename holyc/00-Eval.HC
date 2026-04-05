// 00-Eval.HC — JIT as eval: the shell IS the compiler
// In HolyC, every line typed at the terminal goes through the JIT.
// There is no "interpreter mode." This file demonstrates.
//
// Run: #include "00-Eval.HC"
// Or just paste lines at the TempleOS shell prompt.

// === 1. Top-level expression: compiled and executed immediately ===
// In HolyC, this line IS the program. No main(). No build step.
"Hello from the JIT\n";

// === 2. Define a function: JIT'd into the global symbol table ===
I64 Square(I64 x) { return x * x; }

// The function is now callable from the shell prompt:
//   Square(7);   // => 49

// === 3. The shell is the compiler is the eval ===
// ExePrint compiles a string and executes it. This is HolyC's `eval`.
U0 Eval(U8 *src) {
  ExePrint("%s;", src);
}

// Usage:
//   Eval("Square(9)");   // => 81
//   Eval("1+2+3");       // => 6

// === 4. Runtime code generation ===
// Build a function as a string, compile it, call it.
U0 MakeAdder(I64 n) {
  U8 buf[256];
  StrPrint(buf, "I64 Add%d(I64 x) { return x + %d; }", n, n);
  ExePrint(buf);
  // Add5, Add10, etc. now exist in the global symbol table
}

MakeAdder(5);
MakeAdder(42);
// Now callable: Add5(10) => 15, Add42(100) => 142

// === 5. No distinction between "compile time" and "run time" ===
// This loop generates 10 functions at the top level:
I64 i;
for (i = 0; i < 10; i++) {
  U8 buf[256];
  StrPrint(buf, "I64 Mul%d(I64 x) { return x * %d; }", i, i);
  ExePrint(buf);
}
// Mul0(7) => 0, Mul3(7) => 21, Mul9(7) => 63

// === LESSON FOR NANOCLJ-ZIG ===
// In HolyC, `Eval("expr")` is just `ExePrint`.
// In nanoclj-zig, `(eval expr)` goes through tree-walk by default.
// The fix: make bytecode compilation the default path.
// Tree-walk becomes the debugger, not the evaluator.
//
// HolyC equivalent of nanoclj-zig's `(bc expr)`:
//   There is no equivalent. ALL code is compiled. Always.
//   The "interpreter" does not exist. This is the lesson.
