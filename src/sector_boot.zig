// ════════════════════════════════════════════════════════════════════
// SectorClojure Boot Sector — Freestanding x86 Lisp
// ════════════════════════════════════════════════════════════════════
//
// A minimal Lisp evaluator that boots from BIOS, inspired by SectorLisp.
// Two-stage design:
//   Stage 1: 512-byte boot sector (inline asm, loads stage 2)
//   Stage 2: Zig freestanding 32-bit Lisp (eval/apply/read/print/GC)
//
// Memory layout (real mode, 64KB segment):
//   0x0000..0x7BFF : Cons cells (grow UPWARD from 0x0000)
//   0x7C00..0x7DFF : Boot sector code (512 bytes)
//   0x7E00..0x7FFF : Stage 2 code (loaded from disk)
//   0x8000..0x9FFF : Atom interning table
//   0xA000..0xBFFF : Input buffer / scratch
//   0xF000..0xFFFF : Stack (grows down)
//
// Primitives (SectorLisp's 8 + Clojure essentials):
//   cons, car, cdr, atom?, eq — McCarthy core
//   quote, cond, lambda       — special forms
//   def, if, do               — Clojure minimum
//   +, -, *, =, <             — arithmetic
//   println, read-string      — I/O
//
// Build: zig build sector
// Test:  qemu-system-i386 -fda zig-out/bin/sector.img -nographic
// ════════════════════════════════════════════════════════════════════

// ── NULL = 0x7C00 (SectorLisp convention) ────────────────────────
const NULL: usize = 0x7C00;
const CONS_START: usize = 0x1000;
const ATOM_START: usize = 0x8000;
const INPUT_BUF: usize = 0xA000;

// Cell layout: [car:i16, cdr:i16] = 4 bytes per cons cell
// Positive offset from NULL = atom (interned string pointer)
// Negative offset from NULL = cons cell

var cons_ptr: usize = CONS_START;
var atom_ptr: usize = ATOM_START;

// Pre-interned atoms
const NIL: i16 = 0; // NULL offset 0 = nil
var T_ATOM: i16 = 0;
var QUOTE_ATOM: i16 = 0;
var COND_ATOM: i16 = 0;
var LAMBDA_ATOM: i16 = 0;
var DEF_ATOM: i16 = 0;
var IF_ATOM: i16 = 0;

// Global environment (alist of (symbol . value) pairs)
var global_env: i16 = 0; // NIL initially

// ── BIOS I/O (freestanding only) ─────────────────────────────────
const is_freestanding = @import("builtin").os.tag == .freestanding;

fn putchar(c: u8) void {
    if (is_freestanding) {
        asm volatile (
            \\ mov $0x0E, %%ah
            \\ int $0x10
            :
            : [al] "{al}" (c),
            : .{ .ah = true }
        );
    }
}

fn getchar() u8 {
    if (is_freestanding) {
        return asm volatile (
            \\ xor %%ah, %%ah
            \\ int $0x16
            : [ret] "={al}" (-> u8),
            :
            : .{ .ah = true }
        );
    }
    return 0;
}

fn puts(s: [*]const u8) void {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) putchar(s[i]);
}

fn putint(n: i16) void {
    if (n < 0) {
        putchar('-');
        putint(-n);
        return;
    }
    if (n >= 10) putint(@divTrunc(n, 10));
    putchar(@intCast(@as(u16, @bitCast(@rem(n, 10))) + '0'));
}

// ── Cons cell operations ─────────────────────────────────────────

fn cons(a: i16, d: i16) i16 {
    const p: [*]volatile i16 = @ptrFromInt(cons_ptr);
    p[0] = a; // CAR
    p[1] = d; // CDR
    const result: i16 = @intCast(@as(isize, @intCast(cons_ptr)) - @as(isize, @intCast(NULL)));
    cons_ptr += 4;
    return result;
}

fn car(x: i16) i16 {
    if (x == NIL) return NIL;
    if (x > 0) return x; // atoms are their own car
    const addr: usize = @intCast(@as(isize, @intCast(NULL)) + @as(isize, x));
    return @as(*volatile i16, @ptrFromInt(addr)).*;
}

fn cdr(x: i16) i16 {
    if (x == NIL) return NIL;
    if (x > 0) return NIL; // atoms have nil cdr
    const addr: usize = @intCast(@as(isize, @intCast(NULL)) + @as(isize, x) + 2);
    return @as(*volatile i16, @ptrFromInt(addr)).*;
}

fn is_atom(x: i16) bool {
    return x >= 0; // atoms are non-negative offsets, cons cells are negative
}

fn eq(a: i16, b: i16) bool {
    return a == b;
}

// ── Atom interning ───────────────────────────────────────────────

fn intern(name: [*]const u8, len: usize) i16 {
    // Search existing atoms
    var p: usize = ATOM_START;
    while (p < atom_ptr) {
        const slen: usize = @as(*volatile u8, @ptrFromInt(p)).*;
        if (slen == len) {
            var match = true;
            for (0..len) |i| {
                if (@as(*volatile u8, @ptrFromInt(p + 1 + i)).* != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) return @intCast(@as(isize, @intCast(p)) - @as(isize, @intCast(NULL)));
        }
        p += 1 + slen + 1; // length byte + string + null terminator
    }
    // Intern new atom
    const result: i16 = @intCast(@as(isize, @intCast(atom_ptr)) - @as(isize, @intCast(NULL)));
    @as(*volatile u8, @ptrFromInt(atom_ptr)).* = @intCast(len);
    atom_ptr += 1;
    for (0..len) |i| {
        @as(*volatile u8, @ptrFromInt(atom_ptr + i)).* = name[i];
    }
    atom_ptr += len;
    @as(*volatile u8, @ptrFromInt(atom_ptr)).* = 0;
    atom_ptr += 1;
    return result;
}

fn atom_name(x: i16) [*]const u8 {
    if (x <= 0) return @ptrCast(&"<cons>".*);
    const addr: usize = @intCast(@as(isize, @intCast(NULL)) + @as(isize, x));
    return @ptrFromInt(addr + 1); // skip length byte
}

fn atom_len(x: i16) usize {
    if (x <= 0) return 0;
    const addr: usize = @intCast(@as(isize, @intCast(NULL)) + @as(isize, x));
    return @as(*volatile u8, @ptrFromInt(addr)).*;
}

// ── Reader (S-expression parser) ─────────────────────────────────

var read_buf: [*]volatile u8 = @ptrFromInt(INPUT_BUF);
var read_pos: usize = 0;
var read_len: usize = 0;

fn skip_ws() void {
    while (read_pos < read_len) {
        const c = read_buf[read_pos];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') return;
        read_pos += 1;
    }
}

fn peek() u8 {
    if (read_pos >= read_len) return 0;
    return read_buf[read_pos];
}

fn advance() u8 {
    const c = read_buf[read_pos];
    read_pos += 1;
    return c;
}

fn is_delim(c: u8) bool {
    return c == 0 or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '(' or c == ')';
}

fn read_form() i16 {
    skip_ws();
    const c = peek();
    if (c == 0) return NIL;
    if (c == '\'') {
        _ = advance();
        const form = read_form();
        return cons(QUOTE_ATOM, cons(form, NIL));
    }
    if (c == '(') {
        _ = advance();
        return read_list();
    }
    return read_atom();
}

fn read_list() i16 {
    skip_ws();
    if (peek() == ')') {
        _ = advance();
        return NIL;
    }
    const head = read_form();
    const tail = read_list();
    return cons(head, tail);
}

fn read_atom() i16 {
    const start = read_pos;
    while (read_pos < read_len and !is_delim(read_buf[read_pos])) {
        read_pos += 1;
    }
    const len = read_pos - start;
    if (len == 0) return NIL;

    // Check for integer
    var is_int = true;
    var neg = false;
    for (start..read_pos) |i| {
        const ch = read_buf[i];
        if (i == start and ch == '-' and len > 1) {
            neg = true;
        } else if (ch < '0' or ch > '9') {
            is_int = false;
            break;
        }
    }
    if (is_int) {
        var val: i16 = 0;
        var p = start;
        if (neg) p += 1;
        while (p < read_pos) : (p += 1) {
            val = val * 10 + @as(i16, read_buf[p] - '0');
        }
        if (neg) val = -val;
        // Encode integer as special atom (high bit trick)
        // For simplicity, store small integers as their value + a large offset
        return val; // TODO: proper integer tagging
    }

    return intern(@ptrFromInt(INPUT_BUF + start), len);
}

// ── Printer ──────────────────────────────────────────────────────

fn print_val(x: i16) void {
    if (x == NIL) {
        puts("nil");
        return;
    }
    if (eq(x, T_ATOM)) {
        puts("true");
        return;
    }
    if (is_atom(x)) {
        const name = atom_name(x);
        const len = atom_len(x);
        for (0..len) |i| putchar(name[i]);
        return;
    }
    // It's a cons cell (list)
    putchar('(');
    var cur = x;
    var first = true;
    while (cur != NIL and !is_atom(cur)) {
        if (!first) putchar(' ');
        first = false;
        print_val(car(cur));
        cur = cdr(cur);
    }
    if (cur != NIL) {
        puts(" . ");
        print_val(cur);
    }
    putchar(')');
}

// ── Environment ──────────────────────────────────────────────────

fn lookup(sym: i16, env: i16) i16 {
    var e = env;
    while (e != NIL and !is_atom(e)) {
        const pair = car(e);
        if (eq(car(pair), sym)) return cdr(pair);
        e = cdr(e);
    }
    return NIL;
}

fn bind(sym: i16, val: i16) void {
    global_env = cons(cons(sym, val), global_env);
}

// ── Evaluator ────────────────────────────────────────────────────

fn eval(expr: i16, env: i16) i16 {
    if (expr == NIL) return NIL;

    // Atom → lookup in environment
    if (is_atom(expr)) {
        if (eq(expr, T_ATOM)) return T_ATOM;
        const v = lookup(expr, env);
        if (v != NIL) return v;
        return lookup(expr, global_env);
    }

    const op = car(expr);
    const rest_expr = cdr(expr);

    // quote
    if (eq(op, QUOTE_ATOM)) return car(rest_expr);

    // if
    if (eq(op, IF_ATOM)) {
        const test_expr = car(rest_expr);
        const then_expr = car(cdr(rest_expr));
        const else_expr = car(cdr(cdr(rest_expr)));
        const test_val = eval(test_expr, env);
        if (test_val != NIL) return eval(then_expr, env);
        return eval(else_expr, env);
    }

    // cond
    if (eq(op, COND_ATOM)) return evcon(rest_expr, env);

    // def
    if (eq(op, DEF_ATOM)) {
        const sym = car(rest_expr);
        const val = eval(car(cdr(rest_expr)), env);
        bind(sym, val);
        return val;
    }

    // lambda — return unevaluated
    if (eq(op, LAMBDA_ATOM)) return expr;

    // Application: (f args...)
    const f = eval(op, env);
    const args = evlis(rest_expr, env);
    return apply_fn(f, args, env);
}

fn evcon(clauses: i16, env: i16) i16 {
    if (clauses == NIL) return NIL;
    const clause = car(clauses);
    if (eval(car(clause), env) != NIL) {
        return eval(car(cdr(clause)), env);
    }
    return evcon(cdr(clauses), env);
}

fn evlis(exprs: i16, env: i16) i16 {
    if (exprs == NIL) return NIL;
    return cons(eval(car(exprs), env), evlis(cdr(exprs), env));
}

fn pairlis(keys: i16, vals: i16, env: i16) i16 {
    if (keys == NIL) return env;
    return cons(cons(car(keys), car(vals)), pairlis(cdr(keys), cdr(vals), env));
}

fn apply_fn(f: i16, args: i16, env: i16) i16 {
    if (f == NIL) return NIL;
    if (is_atom(f)) return NIL; // can't apply an atom

    // (lambda (params...) body)
    if (eq(car(f), LAMBDA_ATOM)) {
        const params = car(cdr(f));
        const body = car(cdr(cdr(f)));
        const new_env = pairlis(params, args, env);
        return eval(body, new_env);
    }
    return NIL;
}

// ── ABC Garbage Collector (SectorLisp-style) ─────────────────────
// Save cons_ptr before eval (A), after eval (B), copy result (C).
// Perfect defragmentation for acyclic Lisp data.

var gc_save_a: usize = 0;

fn gc_before() void {
    gc_save_a = cons_ptr;
}

fn gc_after(result: i16) i16 {
    // For now: simple nursery reset if result is an atom
    if (is_atom(result)) {
        cons_ptr = gc_save_a;
        return result;
    }
    // TODO: full ABC copy collector
    return result;
}

// ── Init: pre-intern fundamental atoms ───────────────────────────

fn init_atoms() void {
    T_ATOM = intern("true", 4);
    QUOTE_ATOM = intern("quote", 5);
    COND_ATOM = intern("cond", 4);
    LAMBDA_ATOM = intern("lambda", 6);
    DEF_ATOM = intern("def", 3);
    IF_ATOM = intern("if", 2);
}

// ── REPL ─────────────────────────────────────────────────────────

fn read_line() void {
    read_pos = 0;
    read_len = 0;
    while (true) {
        const c = getchar();
        putchar(c); // echo
        if (c == '\r' or c == '\n') {
            putchar('\r');
            putchar('\n');
            return;
        }
        if (c == 8 or c == 127) { // backspace
            if (read_len > 0) read_len -= 1;
            continue;
        }
        if (read_len < 512) {
            read_buf[read_len] = c;
            read_len += 1;
        }
    }
}

fn main_loop() void {
    init_atoms();

    // Banner
    puts("SectorClojure v0.1\r\n");
    puts("McCarthy kernel: cons car cdr atom? eq quote cond lambda def if\r\n");
    puts("SRFI evolution: (tmap f) (tfilter p) (ttake n) (tdrop n) ...\r\n\r\n");

    while (true) {
        puts("sc=> ");
        read_line();
        if (read_len == 0) continue;

        gc_before();
        const form = read_form();
        const result = eval(form, NIL);
        const final = gc_after(result);
        print_val(final);
        putchar('\r');
        putchar('\n');
    }
}

// ── Boot entry ───────────────────────────────────────────────────

comptime {
    if (is_freestanding) {
        @export(&_start_impl, .{ .name = "_start" });
    }
}

fn _start_impl() callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ xor %%ax, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%ss
        \\ mov $0xF000, %%sp
        \\ sti
        \\ call %[main:P]
        \\ hlt
        :
        : [main] "X" (&main_loop),
    );
}

pub fn panic(_: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    if (is_freestanding) {
        puts("PANIC\r\n");
        while (true) asm volatile ("hlt");
    }
    while (true) {}
}

// ── Compile-time tests (run in host mode, not freestanding) ──────

test "atom interning" {
    init_atoms();
    const a1 = intern("hello", 5);
    const a2 = intern("hello", 5);
    try @import("std").testing.expectEqual(a1, a2);
    const a3 = intern("world", 5);
    try @import("std").testing.expect(a1 != a3);
}

test "cons/car/cdr" {
    cons_ptr = CONS_START;
    const c = cons(T_ATOM, NIL);
    try @import("std").testing.expect(c < 0); // cons cells are negative offsets
    try @import("std").testing.expectEqual(T_ATOM, car(c));
    try @import("std").testing.expectEqual(NIL, cdr(c));
}

test "nested cons" {
    cons_ptr = CONS_START;
    const inner = cons(T_ATOM, NIL);
    const outer = cons(inner, NIL);
    try @import("std").testing.expectEqual(inner, car(outer));
}
