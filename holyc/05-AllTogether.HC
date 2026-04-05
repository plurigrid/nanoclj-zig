// 05-AllTogether.HC — A tiny Lisp combining all five lessons
// JIT eval + single-pass + symbol table + ABC GC + rich output
// This is the HolyC proof-of-concept for what nanoclj-zig should become.

// === Value representation ===
// Tagged 64-bit: high 4 bits = type tag, low 60 bits = payload
// (HolyC has no NaN-boxing since it's not a float language)

#define TAG_NIL  0x0000000000000000
#define TAG_INT  0x1000000000000000
#define TAG_SYM  0x2000000000000000
#define TAG_CONS 0x3000000000000000
#define TAG_FN   0x4000000000000000
#define TAG_MASK 0xF000000000000000
#define VAL_MASK 0x0FFFFFFFFFFFFFFF

#define NIL5 TAG_NIL
#define MKINT(n)  (TAG_INT  | ((n) & VAL_MASK))
#define MKSYM(n)  (TAG_SYM  | ((n) & VAL_MASK))
#define MKCONS(n) (TAG_CONS | ((n) & VAL_MASK))
#define MKFN(n)   (TAG_FN   | ((n) & VAL_MASK))

#define TAGOF(v) ((v) & TAG_MASK)
#define VALOF(v) ((v) & VAL_MASK)
#define IS_NIL(v) ((v) == NIL5)
#define IS_INT(v) (TAGOF(v) == TAG_INT)
#define IS_SYM(v) (TAGOF(v) == TAG_SYM)
#define IS_CONS(v) (TAGOF(v) == TAG_CONS)

// === Heap (for cons cells) ===
#define HEAP5_SIZE 8192
I64 heap5[HEAP5_SIZE];
I64 hp5;

U0 Heap5Init() { hp5 = 0; }

I64 Cons5(I64 car, I64 cdr) {
  I64 addr = hp5;
  heap5[hp5++] = car;
  heap5[hp5++] = cdr;
  return MKCONS(addr);
}

I64 Car5(I64 v) { return heap5[VALOF(v)]; }
I64 Cdr5(I64 v) { return heap5[VALOF(v) + 1]; }

// === Symbol table (lesson 3) ===
#define MAX_SYMS 256
U8 sym_names[MAX_SYMS][32];
I64 sym_vals[MAX_SYMS];
I64 sym_count;

U0 SymInit() { sym_count = 0; }

I64 SymIntern(U8 *name) {
  I64 i;
  for (i = 0; i < sym_count; i++)
    if (!StrCmp(sym_names[i], name)) return MKSYM(i);
  StrCpy(sym_names[sym_count], name);
  sym_vals[sym_count] = NIL5;
  return MKSYM(sym_count++);
}

U0 SymSet(I64 sym, I64 val) { sym_vals[VALOF(sym)] = val; }
I64 SymGet(I64 sym) { return sym_vals[VALOF(sym)]; }

U8 *SymName(I64 sym) { return sym_names[VALOF(sym)]; }

// Expose env as iterable (lesson 3)
U0 PrintEnv() {
  "$CYAN$env:$FG$ {";
  I64 i;
  for (i = 0; i < sym_count; i++) {
    if (i > 0) ", ";
    "$YELLOW$%s$FG$: ", sym_names[i];
    I64 v = sym_vals[i];
    if (IS_INT(v)) "$LTBLUE$%d$FG$", VALOF(v);
    else if (IS_NIL(v)) "$DKGRAY$nil$FG$";
    else if (IS_CONS(v)) "$GREEN$(...list...)$FG$";
    else if (IS_SYM(v)) "$YELLOW$%s$FG$", SymName(v);
    else "?";
  }
  "}\n";
}

// === Rich printer (lesson 5 — DolDoc style) ===
U0 PrintVal(I64 v) {
  if (IS_NIL(v)) {
    "$DKGRAY$nil$FG$";
  } else if (IS_INT(v)) {
    "$LTBLUE$%d$FG$", VALOF(v);
  } else if (IS_SYM(v)) {
    "$YELLOW$%s$FG$", SymName(v);
  } else if (IS_CONS(v)) {
    "$GREEN$($FG$";
    PrintVal(Car5(v));
    I64 rest = Cdr5(v);
    while (IS_CONS(rest)) {
      " ";
      PrintVal(Car5(rest));
      rest = Cdr5(rest);
    }
    if (!IS_NIL(rest)) {
      " . ";
      PrintVal(rest);
    }
    "$GREEN$)$FG$";
  } else {
    "$RED$??$FG$";
  }
}

// === Single-pass eval (lessons 1+2) ===
// Reader + eval in one pass. No AST. No IR.

I64 eval_pos;
U8 *eval_src;

U0 SkipWs() { while (eval_src[eval_pos] == ' ') eval_pos++; }

I64 ReadAtom() {
  // Number?
  if (eval_src[eval_pos] >= '0' && eval_src[eval_pos] <= '9') {
    I64 n = 0;
    while (eval_src[eval_pos] >= '0' && eval_src[eval_pos] <= '9')
      n = n * 10 + (eval_src[eval_pos++] - '0');
    return MKINT(n);
  }
  // Symbol
  U8 buf[32];
  I64 len = 0;
  while (eval_src[eval_pos] && eval_src[eval_pos] != ' '
         && eval_src[eval_pos] != ')' && eval_src[eval_pos] != '(')
    buf[len++] = eval_src[eval_pos++];
  buf[len] = 0;
  return SymIntern(buf);
}

// Forward declaration
I64 Eval5();

I64 Eval5() {
  SkipWs;

  if (eval_src[eval_pos] == '(') {
    eval_pos++;  // skip (
    SkipWs;

    // ABC GC: save heap before eval (lesson 4)
    I64 gc_a = hp5;

    // Read operator
    U8 op_buf[32];
    I64 op_len = 0;
    while (eval_src[eval_pos] != ' ' && eval_src[eval_pos] != ')')
      op_buf[op_len++] = eval_src[eval_pos++];
    op_buf[op_len] = 0;
    SkipWs;

    // Special forms (single-pass: handle as we read)
    if (!StrCmp(op_buf, "def")) {
      // (def name value) — read name, eval value, bind
      I64 sym = ReadAtom;
      SkipWs;
      I64 val = Eval5;
      SkipWs;
      if (eval_src[eval_pos] == ')') eval_pos++;
      SymSet(sym, val);
      return val;
    }

    if (!StrCmp(op_buf, "env")) {
      // (env) — print and return the symbol table
      if (eval_src[eval_pos] == ')') eval_pos++;
      PrintEnv;
      return NIL5;
    }

    if (!StrCmp(op_buf, "list")) {
      // (list a b c ...) — build a list
      I64 head = NIL5;
      I64 tail = NIL5;
      while (eval_src[eval_pos] && eval_src[eval_pos] != ')') {
        I64 elem = Eval5;
        I64 cell = Cons5(elem, NIL5);
        if (IS_NIL(head)) { head = cell; tail = cell; }
        else { heap5[VALOF(tail) + 1] = cell; tail = cell; }
        SkipWs;
      }
      if (eval_src[eval_pos] == ')') eval_pos++;
      return head;
    }

    if (!StrCmp(op_buf, "first")) {
      I64 lst = Eval5;
      SkipWs;
      if (eval_src[eval_pos] == ')') eval_pos++;
      return IS_CONS(lst) ? Car5(lst) : NIL5;
    }

    if (!StrCmp(op_buf, "rest")) {
      I64 lst = Eval5;
      SkipWs;
      if (eval_src[eval_pos] == ')') eval_pos++;
      return IS_CONS(lst) ? Cdr5(lst) : NIL5;
    }

    // Arithmetic: +, -, *, /
    I64 a = Eval5; SkipWs;
    I64 b = Eval5; SkipWs;
    if (eval_src[eval_pos] == ')') eval_pos++;

    if (!StrCmp(op_buf, "+")) return MKINT(VALOF(a) + VALOF(b));
    if (!StrCmp(op_buf, "-")) return MKINT(VALOF(a) - VALOF(b));
    if (!StrCmp(op_buf, "*")) return MKINT(VALOF(a) * VALOF(b));
    if (!StrCmp(op_buf, "/")) return MKINT(VALOF(a) / VALOF(b));

    // Unknown form
    "$RED$Unknown: %s$FG$\n", op_buf;
    return NIL5;

  } else if (eval_src[eval_pos] == 0 || eval_src[eval_pos] == ')') {
    return NIL5;
  } else {
    // Atom: number or symbol lookup
    I64 atom = ReadAtom;
    if (IS_INT(atom)) return atom;
    // Symbol: look up in env
    I64 val = SymGet(atom);
    return IS_NIL(val) ? atom : val;
  }
}

// === The REPL (all five lessons combined) ===
U0 LispEval(U8 *src) {
  eval_src = src;
  eval_pos = 0;

  // ABC GC checkpoint
  I64 gc_a = hp5;

  I64 result = Eval5;

  // Rich output (lesson 5)
  "$CYAN$=> $FG$";
  PrintVal(result);
  "\n";

  // ABC GC: in a real implementation, we'd compact here
  // For demo, just report allocation
  I64 allocated = hp5 - gc_a;
  if (allocated > 0)
    "$DKGRAY$  [%d words allocated]$FG$\n", allocated;
}

// === Demo ===
U0 Demo() {
  Heap5Init;
  SymInit;

  "\n$WHITE$$IV$ HOLYC LISP: All Five Lessons $IV$$FG$\n\n";

  "Lesson 1 — JIT eval (every expression compiled):\n";
  LispEval("(+ 3 (* 4 5))");

  "\nLesson 2 — Single pass (no AST):\n";
  LispEval("(* (+ 1 2) (+ 3 4))");

  "\nLesson 3 — Symbol table as value:\n";
  LispEval("(def answer 42)");
  LispEval("(def pi 314)");
  LispEval("(env)");
  LispEval("(+ answer pi)");

  "\nLesson 4 — ABC GC (allocation tracking):\n";
  LispEval("(list 1 2 3)");
  LispEval("(first (list 10 20 30))");
  LispEval("(rest (list 10 20 30))");

  "\nLesson 5 — Rich output (color-coded types):\n";
  LispEval("42");
  LispEval("answer");
  LispEval("(list 1 2 3)");

  "\n$GREEN$All five lessons demonstrated.$FG$\n";
  "Heap used: %d / %d words\n", hp5, HEAP5_SIZE;
  "Symbols: %d\n", sym_count;
}

Demo;

// === MAPPING TO NANOCLJ-ZIG ===
//
// HolyC file           → nanoclj-zig file      → What changes
// ──────────────────────────────────────────────────────────────
// 00-Eval.HC           → main.zig              → Default to bytecode VM
// 01-DirectCompile.HC  → direct_compile.zig    → Reader emits bytecodes
// 02-SymbolTable.HC    → core.zig              → (env), (env-keys), (env-get)
// 03-AbcGc.HC          → gc.zig                → abcCollect() for REPL
// 04-DolDoc.HC         → repl.zig              → ANSI color + OSC links
// 05-AllTogether.HC    → (integration test)    → Verify all 5 compose
