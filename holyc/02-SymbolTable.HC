// 02-SymbolTable.HC — Global symbol table as first-class runtime value
// In HolyC, every function/variable defined at the top level enters
// the global symbol table. You can query it, iterate it, and use it
// to resolve names at runtime. This IS the environment.

// === 1. Define some values ===
I64 answer = 42;
F64 pi = 3.14159265;
I64 Square2(I64 x) { return x * x; }

// === 2. Look up a symbol by name at runtime ===
// HashFind searches the global symbol table.
U0 Lookup(U8 *name) {
  CHashExport *entry = HashFind(name, Fs->hash_table, HTT_EXPORT_SYS_SYM);
  if (entry)
    "Found '%s' at address 0x%X\n", name, entry->val;
  else
    "'%s' not found\n", name;
}

Lookup("answer");    // Found 'answer' at address 0x...
Lookup("Square2");   // Found 'Square2' at address 0x...
Lookup("bogus");     // 'bogus' not found

// === 3. List all symbols in a hash table ===
// This is HolyC's equivalent of `(env)` returning a map.
U0 ListSymbols(I64 max_count) {
  I64 count = 0;
  CHashTable *ht = Fs->hash_table;
  I64 i;
  for (i = 0; i < ht->mask + 1 && count < max_count; i++) {
    CHash *h = ht->body[i];
    while (h && count < max_count) {
      if (h->type == HTT_EXPORT_SYS_SYM || h->type == HTT_FUN) {
        "  %s\n", h->str;
        count++;
      }
      h = h->next;
    }
  }
  "... (%d symbols shown)\n", count;
}

"First 20 symbols in global table:\n";
ListSymbols(20);

// === 4. Define a new symbol dynamically ===
U0 DefineVar(U8 *name, I64 val) {
  // In HolyC, you can't easily add arbitrary typed globals at runtime.
  // But you CAN compile them into existence:
  U8 buf[256];
  StrPrint(buf, "I64 %s = %d;", name, val);
  ExePrint(buf);
  "Defined %s = %d\n", name, val;
}

DefineVar("magic", 1337);
// Now: magic; => 1337

// === 5. The symbol table IS the environment ===
// In HolyC, there is no separate "environment" data structure.
// The hash table that the compiler uses to resolve names IS
// the same table that runtime uses to call functions.
//
// When you type `Square2(7);` at the shell:
//   1. JIT compiler looks up "Square2" in hash table
//   2. Finds the function pointer
//   3. Emits a CALL instruction to that address
//   4. Executes immediately
//
// There is no "binding" step. No "closure capture." No "env chain."
// The global table is flat, mutable, and always available.

// === 6. The environment as a value (what nanoclj-zig should do) ===
// Conceptually, HolyC's hash table is:
//   {"answer": 42, "pi": 3.14, "Square2": <fn@0x...>, "magic": 1337}
//
// In Clojure terms, this is just a map. nanoclj-zig should expose:
//   (env)         => {:answer 42, :pi 3.14, :Square2 #fn, :magic 1337}
//   (env "answer") => 42
//   (env-set! "x" 99)  => defines x = 99 in global scope
//
// The key insight: the environment is not a hidden implementation detail.
// It is a first-class data structure. HolyC proves this by making
// the symbol table the ONLY way to reference anything.

// === LESSON FOR NANOCLJ-ZIG ===
// In core.zig, add three builtins:
//   (env)       — returns global Env as a nanoclj map value
//   (env-keys)  — returns all bound names as a vector of symbols
//   (env-get k) — looks up a name in the current scope chain
//
// This mirrors HolyC's HashFind/HashTable iteration.
// The environment becomes inspectable, serializable, diffable.
// You can snapshot it: (def checkpoint (env))
// You can restore it: (env-load! checkpoint)
// You can diff two sessions: (env-diff checkpoint (env))
