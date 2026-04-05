// 03-AbcGc.HC — SectorLisp's ABC garbage collector in HolyC
// The ABC collector is 40 bytes of x86 assembly. This file implements
// the same algorithm in readable HolyC, then shows why it works for
// REPL one-shots in nanoclj-zig.
//
// The ABC algorithm (Tunney 2021):
//   A = heap pointer before eval
//   B = heap pointer after eval
//   C = copy destination (= A, overwriting garbage)
//   Copy only the cells reachable from the result.
//   Reset heap to C. Perfect compaction. Zero overhead.

// === 1. A minimal cons cell allocator ===

#define HEAP_SIZE 4096
I64 heap[HEAP_SIZE];  // flat array of 64-bit words
I64 hp;               // heap pointer (next free slot)

U0 HeapInit() { hp = 0; }

// Cons cell: [car, cdr] = two adjacent words
I64 Cons(I64 car, I64 cdr) {
  I64 addr = hp;
  heap[hp++] = car;
  heap[hp++] = cdr;
  return addr;  // "pointer" is just an index
}

I64 Car(I64 cell) { return heap[cell]; }
I64 Cdr(I64 cell) { return heap[cell + 1]; }

#define NIL -1
#define IS_ATOM(x) ((x) < 0 || (x) >= hp)

// === 2. The ABC Collector ===
// After evaluating an expression, we know:
//   - Everything allocated between A and B was working memory
//   - The result value is the only thing we need to keep
//   - We copy reachable cells from [A,B) down to A, compacting

I64 abc_dest;  // destination pointer during copy

I64 AbcCopy(I64 cell) {
  if (IS_ATOM(cell)) return cell;  // atoms don't move
  if (cell < 0) return cell;       // NIL

  // Copy this cell to the destination
  I64 new_addr = abc_dest;
  heap[abc_dest++] = heap[cell];      // car (will be patched)
  heap[abc_dest++] = heap[cell + 1];  // cdr (will be patched)

  // Recursively copy car and cdr, patch the new cell
  heap[new_addr] = AbcCopy(heap[cell]);
  heap[new_addr + 1] = AbcCopy(heap[cell + 1]);

  return new_addr;
}

// The full ABC cycle for one eval
I64 AbcEvalCycle(I64 expr) {
  // A: save heap pointer before eval
  I64 a = hp;

  // "Eval" — here we just build some garbage + a result
  // In real use, this would be: result = Eval(expr, env)
  I64 garbage1 = Cons(1, Cons(2, Cons(3, NIL)));  // intermediate list
  I64 garbage2 = Cons(10, Cons(20, NIL));          // more garbage
  I64 result = Cons(Car(garbage1), Cdr(garbage2)); // result uses parts

  // B: heap pointer after eval
  I64 b = hp;
  "Before GC: hp=%d (allocated %d words)\n", hp, b - a;

  // C: copy result down to A, compacting
  abc_dest = a;
  I64 new_result = AbcCopy(result);

  // Reset heap to end of copied data
  hp = abc_dest;
  "After GC:  hp=%d (kept %d words, freed %d)\n", hp, hp - a, b - hp;

  return new_result;
}

// === 3. Demonstrate ===
U0 TestAbcGc() {
  HeapInit;

  // Pre-existing data (before our eval)
  I64 existing = Cons(100, Cons(200, NIL));
  "Existing data at heap[0..%d)\n", hp;

  // Run an eval cycle with ABC collection
  I64 result = AbcEvalCycle(0);

  // Verify result is intact
  "Result: (%d . %d)\n", Car(result), Car(Cdr(result));
  // Should be: (1 . 20) — car from garbage1, cdr from garbage2

  // Existing data is untouched (it's before A)
  "Existing: (%d . (%d . NIL))\n", Car(existing), Car(Cdr(existing));

  // Run another cycle — garbage from first cycle is already gone
  I64 result2 = AbcEvalCycle(0);
  "Total heap used: %d words\n", hp;
}

TestAbcGc;

// === 4. Why this works for acyclic data ===
// Clojure persistent data structures are TREES (acyclic DAGs).
// The ABC collector handles trees perfectly:
//   - No cycle detection needed
//   - No mark phase (just copy reachable)
//   - No sweep phase (just reset pointer)
//   - Perfect compaction (no fragmentation ever)
//
// It FAILS for:
//   - Cycles (would infinite-loop during copy)
//   - Shared structure (would duplicate shared subtrees)
//   - Long-lived data across multiple evals (need mark-sweep)
//
// For REPL one-shots, none of these matter.

// === 5. The two-collector strategy for nanoclj-zig ===
//
// REPL mode (one-shot expressions):
//   1. Save hp (= A)
//   2. Eval expression (allocates freely)
//   3. hp after eval (= B)
//   4. ABC-copy result back to A
//   5. hp = end of copy (= C)
//   Result: zero fragmentation, zero mark phase, ~40 instructions
//
// Program mode (long-running, shared state):
//   Use existing mark-sweep GC (gc.zig)
//   Handles cycles, sharing, atoms, lazy seqs
//
// Switch between them:
//   (gc :abc)     — fast REPL mode (default at prompt)
//   (gc :sweep)   — safe program mode (default in (load "file.clj"))

// === LESSON FOR NANOCLJ-ZIG ===
// In gc.zig, add:
//   pub fn abcCollect(a: usize, result: Value) Value
// That copies only `result` and its transitive closure back to
// position `a` in the heap, then resets the allocation pointer.
// 40 bytes in x86. Maybe 60 lines in Zig.
// Use it for every REPL eval. Fall back to markSweep for (load ...).
