const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const color_strip = @import("color_strip.zig");
const substrate = @import("substrate.zig");
const holy = @import("holy.zig");
const bc = @import("bytecode.zig");
const Compiler = @import("compiler.zig").Compiler;
const disasm = @import("disasm.zig");
const profile = @import("profile.zig");
const incr = @import("incr.zig");

fn nanoNow() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}
pub const llm = @import("llm.zig");

/// Check if input is only whitespace and/or comments
fn isCommentOnly(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',') {
            i += 1;
            continue;
        }
        if (c == ';') {
            while (i < input.len and input[i] != '\n') i += 1;
            continue;
        }
        return false;
    }
    return true;
}

/// Bounded REP: uses fuel-bounded eval from semantics.zig.
/// Defends against: infinite loops (fuel), deep recursion (depth),
/// while maintaining denotational/operational agreement.
/// Always returns heap-owned memory (gc.allocator); caller frees.
fn rep(input: []const u8, env: *Env, gc: *GC) ![]u8 {
    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch |err| {
        const msg: []const u8 = switch (err) {
            error.UnexpectedEOF => "Error: unexpected EOF",
            error.UnmatchedParen => "Error: unmatched )",
            error.UnmatchedBracket => "Error: unmatched ]",
            error.UnmatchedBrace => "Error: unmatched }",
            error.InvalidNumber => "Error: invalid number",
            error.UnexpectedChar => "Error: unexpected character",
            else => "Error: read failed",
        };
        return gc.allocator.dupe(u8, msg);
    };

    // Fuel-bounded eval: guaranteed termination
    var res = semantics.Resources.initDefault();
    const domain = semantics.evalBounded(form, env, gc, &res);

    const msg: []const u8 = switch (domain) {
        .value => |v| return @constCast(printer.prStr(v, gc, true) catch
            return gc.allocator.dupe(u8, "Error: print failed")),
        .bottom => |reason| switch (reason) {
            .fuel_exhausted => "Error: computation exceeded fuel limit (possible infinite loop)",
            .depth_exceeded => "Error: recursion depth exceeded (possible stack bomb)",
            .read_depth_exceeded => "Error: nesting too deep",
            .divergent => "Error: divergent computation",
        },
        .err => |e| switch (e.kind) {
            .unbound_symbol => "Error: symbol not found",
            .not_a_function => "Error: not a function",
            .arity_error => "Error: wrong number of arguments",
            .type_error => "Error: type error",
            .overflow => "Error: integer overflow",
            .division_by_zero => "Error: division by zero",
            .index_out_of_bounds => "Error: index out of bounds",
            .malformed_input => "Error: malformed input",
            .collection_too_large => "Error: collection too large",
            .string_too_long => "Error: string too long",
            .invalid_syntax => "Error: invalid syntax",
        },
    };
    return gc.allocator.dupe(u8, msg);
}

/// Bytecode REP: parse -> compile -> VM execute (uses persistent VM for globals).
/// Always returns owned heap memory — caller must `gc.allocator.free(...)` the result.
fn bcRep(input: []const u8, gc: *GC, allocator: std.mem.Allocator, vm: *bc.VM, env: *Env) []u8 {
    const errStr = struct {
        fn dup(g: *GC, msg: []const u8) []u8 {
            // OOM here means the host is already wedged; fall back to an empty
            // owned slice so the caller's free() remains valid.
            return g.allocator.dupe(u8, msg) catch g.allocator.alloc(u8, 0) catch &.{};
        }
    }.dup;

    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch return errStr(gc, "Error: read failed");

    var comp = Compiler.init(allocator, gc, null, &vm.globals, env);
    defer comp.deinit();

    const dest = comp.allocReg() catch return errStr(gc, "Error: too many registers");
    comp.compile(form, dest) catch return errStr(gc, "Error: compilation failed");
    comp.emit(bc.encode_d(.ret, dest)) catch return errStr(gc, "Error: emit failed");

    const func_def = comp.finalize() catch return errStr(gc, "Error: finalize failed");

    const closure_obj = gc.allocObj(.bc_closure) catch return errStr(gc, "Error: alloc failed");
    closure_obj.data.bc_closure = .{
        .def = func_def,
        .upvalues = &.{},
    };

    // Reset VM state for new execution but keep globals
    vm.frame_count = 0;
    vm.fuel = 100_000_000;
    @memset(&vm.stack, Value.makeNil());

    const result = vm.execute(&closure_obj.data.bc_closure) catch |err| return errStr(gc, switch (err) {
        error.FuelExhausted => "Error: fuel exhausted",
        error.StackOverflow => "Error: stack overflow",
        error.TypeError => "Error: type error",
        error.ArityError => "Error: arity error",
        error.UndefinedGlobal => "Error: undefined global",
    });

    const owned = printer.prStr(result, gc, true) catch return errStr(gc, "Error: print failed");
    return @constCast(owned);
}

/// Time bytecode execution only (uses persistent VM with globals)
fn timeBcRep(input: []const u8, gc: *GC, allocator: std.mem.Allocator, vm: *bc.VM, env: *Env) []const u8 {
    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch return "Error: read failed";

    var comp = Compiler.init(allocator, gc, null, &vm.globals, env);
    defer comp.deinit();
    const dest = comp.allocReg() catch return "Error: compile failed";
    comp.compile(form, dest) catch return "Error: compile failed";
    comp.emit(bc.encode_d(.ret, dest)) catch return "Error: emit failed";
    const func_def = comp.finalize() catch return "Error: finalize failed";

    const closure_obj = gc.allocObj(.bc_closure) catch return "Error: alloc failed";
    closure_obj.data.bc_closure = .{ .def = func_def, .upvalues = &.{} };

    vm.frame_count = 0;
    vm.fuel = 10_000_000_000;
    @memset(&vm.stack, Value.makeNil());

    const start = nanoNow();
    const result = vm.execute(&closure_obj.data.bc_closure) catch {
        return "Error: VM execution failed";
    };
    const end = nanoNow();
    const ns: u64 = @intCast(end - start);

    const val_str = printer.prStr(result, gc, true) catch "?";

    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "bytecode: {s} in {d}ms ({d}us)", .{
        val_str, ns / 1_000_000, ns / 1_000,
    }) catch return "Error: format failed";

    return allocator.dupe(u8, out) catch "Error: alloc failed";
}

/// Benchmark: tree-walk vs bytecode side by side (uses persistent VM)
fn benchRep(input: []const u8, env: *Env, gc: *GC, allocator: std.mem.Allocator, vm: *bc.VM) []const u8 {
    // Tree-walk timing
    var reader1 = Reader.init(input, gc);
    const form1 = reader1.readForm() catch return "Error: read failed";
    const tw_start = nanoNow();
    var res = semantics.Resources.initDefault();
    const tw_result = semantics.evalBounded(form1, env, gc, &res);
    const tw_end = nanoNow();
    const tw_ns: u64 = @intCast(tw_end - tw_start);

    const tw_str = switch (tw_result) {
        .value => |v| printer.prStr(v, gc, true) catch "?",
        else => "bottom/err",
    };

    // Bytecode timing
    var reader2 = Reader.init(input, gc);
    const form2 = reader2.readForm() catch return "Error: read failed";

    var comp = Compiler.init(allocator, gc, null, &vm.globals, env);
    defer comp.deinit();
    const dest_reg = comp.allocReg() catch return "Error: compile failed";
    comp.compile(form2, dest_reg) catch return "Error: compile failed";
    comp.emit(bc.encode_d(.ret, dest_reg)) catch return "Error: emit failed";
    const func_def = comp.finalize() catch return "Error: finalize failed";

    const closure_obj = gc.allocObj(.bc_closure) catch return "Error: alloc failed";
    closure_obj.data.bc_closure = .{ .def = func_def, .upvalues = &.{} };

    vm.frame_count = 0;
    vm.fuel = 10_000_000_000;
    @memset(&vm.stack, Value.makeNil());

    const bc_start = nanoNow();
    const bc_result = vm.execute(&closure_obj.data.bc_closure) catch {
        return "Error: VM execution failed";
    };
    const bc_end = nanoNow();
    const bc_ns: u64 = @intCast(bc_end - bc_start);

    const bc_str = printer.prStr(bc_result, gc, true) catch "?";

    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "tree-walk: {s} in {d}ms | bytecode: {s} in {d}ms | speedup: {d:.1}x", .{
        tw_str,                                                                   tw_ns / 1_000_000, bc_str, bc_ns / 1_000_000,
        @as(f64, @floatFromInt(tw_ns)) / @as(f64, @floatFromInt(@max(bc_ns, 1))),
    }) catch return "Error: format failed";

    return allocator.dupe(u8, out) catch "Error: alloc failed";
}

/// Load bytecode prelude: defines core HOFs (map, filter, reduce, reverse, range)
/// as bytecode globals so they're available to all (bc ...) calls.
fn loadBcPrelude(gc: *GC, allocator: std.mem.Allocator, vm: *bc.VM, env: *Env) void {
    const forms = [_][]const u8{
        // reverse: accumulator-based O(n)
        \\(def reverse (fn* [xs]
        \\  (loop [acc (list) rem xs]
        \\    (if (zero? (count rem))
        \\      acc
        \\      (recur (cons (first rem) acc) (rest rem))))))
        ,
        // map: apply f to each element
        \\(def map (fn* [f xs]
        \\  (loop [acc (list) rem xs]
        \\    (if (zero? (count rem))
        \\      (reverse acc)
        \\      (recur (cons (f (first rem)) acc) (rest rem))))))
        ,
        // filter: keep elements where (f x) is truthy
        \\(def filter (fn* [f xs]
        \\  (loop [acc (list) rem xs]
        \\    (if (zero? (count rem))
        \\      (reverse acc)
        \\      (if (f (first rem))
        \\        (recur (cons (first rem) acc) (rest rem))
        \\        (recur acc (rest rem)))))))
        ,
        // reduce: fold left with initial value
        \\(def reduce (fn* [f init xs]
        \\  (loop [acc init rem xs]
        \\    (if (zero? (count rem))
        \\      acc
        \\      (recur (f acc (first rem)) (rest rem))))))
        ,
        // range: generate list of integers [0, n)
        \\(def range (fn* [n]
        \\  (loop [acc (list) i (dec n)]
        \\    (if (neg? i)
        \\      acc
        \\      (recur (cons i acc) (dec i))))))
        ,
        // take: first n elements
        \\(def take (fn* [n xs]
        \\  (loop [acc (list) rem xs i n]
        \\    (if (zero? i)
        \\      (reverse acc)
        \\      (if (zero? (count rem))
        \\        (reverse acc)
        \\        (recur (cons (first rem) acc) (rest rem) (dec i)))))))
        ,
        // drop: skip first n elements
        \\(def drop (fn* [n xs]
        \\  (loop [rem xs i n]
        \\    (if (zero? i)
        \\      rem
        \\      (if (zero? (count rem))
        \\        (list)
        \\        (recur (rest rem) (dec i)))))))
        ,
        // concat: append two lists
        \\(def concat (fn* [a b]
        \\  (loop [acc b rem (reverse a)]
        \\    (if (zero? (count rem))
        \\      acc
        \\      (recur (cons (first rem) acc) (rest rem))))))
        ,
        // apply: apply function to arg list (limited to arity ≤ 8)
        \\(def apply (fn* [f args]
        \\  (let* [n (count args)]
        \\    (if (= n 0) (f)
        \\    (if (= n 1) (f (nth args 0))
        \\    (if (= n 2) (f (nth args 0) (nth args 1))
        \\    (if (= n 3) (f (nth args 0) (nth args 1) (nth args 2))
        \\    (f (nth args 0) (nth args 1) (nth args 2) (nth args 3)))))))))
        ,
    };

    for (forms) |src| {
        const r = bcRep(src, gc, allocator, vm, env);
        gc.allocator.free(r);
    }
}

/// Load standard Clojure macros into the tree-walk environment.
pub fn loadMacroPrelude(env: *Env, gc: *GC) void {
    const eval_mod = @import("eval.zig");
    const macros = [_][]const u8{
        // when: (when test body...)
        \\(defmacro when [test & body]
        \\  (list 'if test (cons 'do body)))
        ,
        // when-not: (when-not test body...)
        \\(defmacro when-not [test & body]
        \\  (list 'if test nil (cons 'do body)))
        ,
        // cond: (cond test1 expr1 test2 expr2 ...)
        \\(defmacro cond [& clauses]
        \\  (when (> (count clauses) 0)
        \\    (list 'if (first clauses)
        \\      (first (rest clauses))
        \\      (cons 'cond (rest (rest clauses))))))
        ,
        // ->: thread-first
        \\(defmacro -> [x & forms]
        \\  (reduce (fn* [acc form]
        \\    (if (list? form)
        \\      (cons (first form) (cons acc (rest form)))
        \\      (list form acc)))
        \\    x forms))
        ,
        // ->>: thread-last (append acc to end of form)
        \\(defmacro ->> [x & forms]
        \\  (reduce (fn* [acc form]
        \\    (if (list? form)
        \\      (concat form (list acc))
        \\      (list form acc)))
        \\    x forms))
        ,
        // and: short-circuit and
        \\(defmacro and [& xs]
        \\  (if (zero? (count xs)) true
        \\    (if (= 1 (count xs)) (first xs)
        \\      (list 'if (first xs) (cons 'and (rest xs)) false))))
        ,
        // or: short-circuit or
        \\(defmacro or [& xs]
        \\  (if (zero? (count xs)) nil
        \\    (if (= 1 (count xs)) (first xs)
        \\      (list 'let* ['__or__ (first xs)]
        \\        (list 'if '__or__ '__or__ (cons 'or (rest xs)))))))
        ,
        // doto: (doto x (f args...) (g args...))
        \\(defmacro doto [x & forms]
        \\  (let* [gx '__doto__]
        \\    (cons 'let* (cons [gx x]
        \\      (concat (map (fn* [f] (cons (first f) (cons gx (rest f)))) forms) (list gx))))))
        ,
        // if-let: (if-let [x expr] then else)
        \\(defmacro if-let [bindings then & else-forms]
        \\  (list 'let* bindings
        \\    (list 'if (first bindings)
        \\      then
        \\      (if (> (count else-forms) 0) (first else-forms) nil))))
        ,
        // when-let: (when-let [x expr] body...)
        \\(defmacro when-let [bindings & body]
        \\  (list 'let* bindings
        \\    (cons 'when (cons (first bindings) body))))
        ,
        // amap: (amap arr idx ret expr)
        //   ret ← fresh dense_f64 copy of arr; for each idx in 0..n-1, ret[idx] ← expr.
        //   Returns (vec ret) so the result compares equal to a plain vector.
        \\(defmacro amap [arr idx ret expr]
        \\  (list 'let* (vector '__amap_arr__ arr
        \\                      ret (list 'make-array (list 'count '__amap_arr__)))
        \\    (list 'dotimes (vector idx (list 'count '__amap_arr__))
        \\      (list 'aset ret idx (list 'nth '__amap_arr__ idx)))
        \\    (list 'dotimes (vector idx (list 'count '__amap_arr__))
        \\      (list 'aset ret idx expr))
        \\    (list 'vec ret)))
        ,
        // areduce: (areduce arr elt acc init expr)
        //   Fold over arr's elements, binding `elt` to each element and `acc`
        //   to the running accumulator (starting at init). Atom-backed.
        \\(defmacro areduce [arr elt acc init expr]
        \\  (list 'let* (vector '__areduce_arr__ arr
        \\                      '__areduce_acc__ (list 'atom init))
        \\    (list 'dotimes (vector '__areduce_i__ (list 'count '__areduce_arr__))
        \\      (list 'let* (vector elt (list 'nth '__areduce_arr__ '__areduce_i__)
        \\                          acc (list 'deref '__areduce_acc__))
        \\        (list 'reset! '__areduce_acc__ expr)))
        \\    (list 'deref '__areduce_acc__)))
        ,
    };

    for (macros) |src| {
        var reader = Reader.init(src, gc);
        const form = reader.readForm() catch continue;
        _ = eval_mod.eval(form, env, gc) catch {};
    }

    // kanren macros — only when kanren is enabled
    if (profile.enable_kanren) {
        const kanren_macros = [_][]const u8{
            // run*: (run* [q] goal...) → run-goal with fresh q
            \\(defmacro run* [vars & goals]
            \\  (let* [q (first vars)]
            \\    (list 'let* [q '(lvar)]
            \\      (list 'run-goal 0 q (cons 'conj-goal goals)))))
            ,
            // run: (run n [q] goal...) → limited results
            \\(defmacro run [n vars & goals]
            \\  (let* [q (first vars)]
            \\    (list 'let* [q '(lvar)]
            \\      (list 'run-goal n q (cons 'conj-goal goals)))))
            ,
            // fresh: (fresh [a b] goal...) → introduce fresh lvars and conjoin goals
            \\(defmacro fresh [vars & goals]
            \\  (if (zero? (count vars))
            \\    (cons 'conj-goal goals)
            \\    (list 'let* [(first vars) '(lvar)]
            \\      (cons 'fresh (cons (vec (rest vars)) goals)))))
            ,
        };
        for (kanren_macros) |src| {
            var reader = Reader.init(src, gc);
            const form = reader.readForm() catch continue;
            _ = eval_mod.eval(form, env, gc) catch {};
        }
    }
}

pub fn main() !void {
    const compat = @import("compat.zig");
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gc = GC.init(allocator);
    defer gc.deinit();

    var env = Env.init(allocator, null);
    env.is_root = true;
    defer env.deinit();

    try core.initCore(&env, &gc);
    defer core.deinitCore();
    const tree_vfs = @import("tree_vfs.zig");
    defer tree_vfs.deinitForest();
    defer if (profile.enable_inet) @import("inet_builtins.zig").deinitNets();

    // First Futamura projection: PE constant bindings through inet
    if (profile.enable_peval) {
        const peval_mod = @import("peval.zig");
        const pe_count = peval_mod.pevalEnv(&env, &gc);
        _ = pe_count;
    }

    const stdout = compat.stdoutFile();
    const stdin_file = compat.stdinFile();

    // ── Demo: color strip banner ──────────────────────────────────
    // Detect terminal width (fallback 80)
    const width: u32 = 80;

    compat.fileWriteAll(stdout, "\x1b[1mnanoclj-zig v0.1.0\x1b[0m");
    if (std.mem.eql(u8, profile.profileName(), "full")) {
        compat.fileWriteAll(stdout, "\n");
    } else {
        var pbuf: [64]u8 = undefined;
        const pmsg = std.fmt.bufPrint(&pbuf, " [profile: {s}]\n", .{profile.profileName()}) catch " [profile: ?]\n";
        compat.fileWriteAll(stdout, pmsg);
    }
    color_strip.renderTritWheel(stdout, width) catch {};
    compat.fileWriteAll(stdout, "\n");

    // Seed from hostname or "world"
    const world_name: []const u8 = if (std.c.getenv("USER")) |c| std.mem.span(c) else "world";

    color_strip.renderNamedStrip(stdout, world_name, width, 2) catch {};
    compat.fileWriteAll(stdout, "\n");

    // Bind world identity into env
    const world_sym = gc.internString("*world*") catch 0;
    const world_str = gc.internString(world_name) catch 0;
    env.set(gc.getString(world_sym), Value.makeString(world_str)) catch {};

    // Compute and bind seed
    var world_seed: u64 = 0;
    for (world_name) |c| {
        world_seed = world_seed *% substrate.GOLDEN +% @as(u64, c);
    }
    world_seed = substrate.mix64(world_seed);
    const seed_sym = gc.internString("*seed*") catch 0;
    env.set(gc.getString(seed_sym), Value.makeInt(@bitCast(@as(u48, @truncate(world_seed))))) catch {};

    // ── Initialize gorj session with world seed (SPI: index-addressed) ──
    const gorj_bridge = @import("gorj_bridge.zig");
    gorj_bridge.initSession(world_seed);

    // ── Bytecode VM (persistent across REPL) ──────────────────────
    var vm = bc.VM.init(&gc, 100_000_000);
    defer vm.deinit();

    // ── Incremental compilation registry (green tier) ────────────
    var incr_registry = incr.IncrRegistry.init(allocator);
    defer incr_registry.deinit();

    // ── Tier policy: hysteresis-based dynamic tier selection ─────
    const tier_policy_mod = @import("tier_policy.zig");
    var tier_policy = tier_policy_mod.TierPolicy.init(allocator);
    defer tier_policy.deinit();

    // ── Bytecode prelude: core higher-order functions ────────────
    // ── Macro prelude: standard Clojure macros ────────────────────
    loadMacroPrelude(&env, &gc);

    loadBcPrelude(&gc, allocator, &vm, &env);

    // ── REPL: world=> ─────────────────────────────────────────────
    while (true) {
        // Prompt with world name
        var prompt_buf: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "\x1b[36m{s}\x1b[0m=> ", .{world_name}) catch "world=> ";
        compat.fileWriteAll(stdout, prompt);

        var line_buf = @import("compat.zig").emptyList(u8);
        defer line_buf.deinit(allocator);
        while (true) {
            var byte: [1]u8 = undefined;
            const n = compat.fileRead(stdin_file, &byte);
            if (n == 0) {
                if (line_buf.items.len == 0) {
                    compat.fileWriteAll(stdout, "\n");
                    return;
                }
                break;
            }
            if (byte[0] == '\n') {
                // Multi-line: if parens are unbalanced, keep reading
                var depth: i32 = 0;
                var in_string = false;
                for (line_buf.items) |c| {
                    if (c == '"') in_string = !in_string;
                    if (!in_string) {
                        if (c == '(') depth += 1;
                        if (c == ')') depth -= 1;
                    }
                }
                if (depth > 0) {
                    line_buf.append(allocator, ' ') catch break;
                    compat.fileWriteAll(stdout, "  ");
                    continue;
                }
                break;
            }
            line_buf.append(allocator, byte[0]) catch break;
        }

        const line = line_buf.items;
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "(quit)") or std.mem.eql(u8, line, "(exit)")) break;

        // Special REPL commands
        if (std.mem.eql(u8, line, "(colors)")) {
            color_strip.renderNamedStrip(stdout, world_name, width, 4) catch {};
            continue;
        }
        if (std.mem.startsWith(u8, line, "(colors ")) {
            // (colors "name") — show color strip for any name
            const name_start = std.mem.indexOf(u8, line, "\"") orelse continue;
            const name_end = std.mem.lastIndexOf(u8, line, "\"") orelse continue;
            if (name_end > name_start + 1) {
                color_strip.renderNamedStrip(stdout, line[name_start + 1 .. name_end], width, 4) catch {};
            }
            continue;
        }
        if (std.mem.eql(u8, line, "(gap)")) {
            color_strip.renderGapStrip(stdout, world_seed, substrate.CANONICAL_SEED, width) catch {};
            continue;
        }
        if (std.mem.eql(u8, line, "(wheel)")) {
            color_strip.renderTritWheel(stdout, width) catch {};
            continue;
        }

        // SectorClojure tier introspection: (sector-tier), (sector-tier N), (sector-builtins)
        if (std.mem.eql(u8, line, "(sector-builtins)")) {
            const sector = @import("sector.zig");
            var tier_idx: u4 = 0;
            while (tier_idx <= @intFromEnum(sector.Tier.full)) : (tier_idx += 1) {
                const tier: sector.Tier = @enumFromInt(tier_idx);
                const spec = sector.TIER_SPECS[tier_idx];
                var buf2: [256]u8 = undefined;
                const hdr = std.fmt.bufPrint(&buf2, "Tier {d} ({s}): {d} builtins — {s}\n", .{
                    tier_idx, spec.name, sector.countBuiltinsAtTier(tier), spec.description,
                }) catch continue;
                compat.fileWriteAll(stdout, hdr);
            }
            continue;
        }
        if (std.mem.eql(u8, line, "(sector-tier)")) {
            compat.fileWriteAll(stdout, "8 (full nanoclj-zig)\n");
            continue;
        }
        if (std.mem.startsWith(u8, line, "(sector-tier ") and line[line.len - 1] == ')') {
            const sector = @import("sector.zig");
            const inner = line[13 .. line.len - 1];
            const tier_num = std.fmt.parseInt(u4, std.mem.trim(u8, inner, " "), 10) catch {
                compat.fileWriteAll(stdout, "Error: tier must be 0-8\n");
                continue;
            };
            if (tier_num > @intFromEnum(sector.Tier.full)) {
                compat.fileWriteAll(stdout, "Error: tier must be 0-8\n");
                continue;
            }
            const tier: sector.Tier = @enumFromInt(tier_num);
            const spec = sector.TIER_SPECS[tier_num];

            // Create a fresh restricted environment
            var sector_env = Env.init(allocator, null);
            sector_env.is_root = true;
            defer sector_env.deinit();

            const n = sector.initTier(&sector_env, &gc, tier) catch {
                compat.fileWriteAll(stdout, "Error: failed to init sector tier\n");
                continue;
            };
            sector.loadTierMacros(tier, &sector_env, &gc);

            var buf2: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf2, "SectorClojure Tier {d} ({s}): {d} builtins loaded\n{s}\n", .{
                tier_num, spec.name, n, spec.description,
            }) catch "ok\n";
            compat.fileWriteAll(stdout, msg);

            // Enter sector sub-REPL
            compat.fileWriteAll(stdout, "Entering sector REPL (type (exit) to return)\n");
            while (true) {
                var pbuf: [128]u8 = undefined;
                const sprompt = std.fmt.bufPrint(&pbuf, "\x1b[33msc/{s}\x1b[0m=> ", .{spec.name}) catch "sc=> ";
                compat.fileWriteAll(stdout, sprompt);

                var sbuf = @import("compat.zig").emptyList(u8);
                defer sbuf.deinit(allocator);
                while (true) {
                    var byte2: [1]u8 = undefined;
                    const n2 = compat.fileRead(stdin_file, &byte2);
                    if (n2 == 0) break;
                    if (byte2[0] == '\n') {
                        var depth2: i32 = 0;
                        var in_str = false;
                        for (sbuf.items) |ch| {
                            if (ch == '"') in_str = !in_str;
                            if (!in_str) {
                                if (ch == '(') depth2 += 1;
                                if (ch == ')') depth2 -= 1;
                            }
                        }
                        if (depth2 > 0) {
                            sbuf.append(allocator, ' ') catch break;
                            compat.fileWriteAll(stdout, "  ");
                            continue;
                        }
                        break;
                    }
                    sbuf.append(allocator, byte2[0]) catch break;
                }
                const sline = sbuf.items;
                if (sline.len == 0) continue;
                if (std.mem.eql(u8, sline, "(exit)") or std.mem.eql(u8, sline, "(quit)")) break;

                const sresult = rep(sline, &sector_env, &gc) catch
                    @constCast(gc.allocator.dupe(u8, "Error: internal error") catch "");
                defer if (sresult.len > 0) gc.allocator.free(sresult);
                if (!std.mem.eql(u8, sresult, "nil") or !isCommentOnly(sline)) {
                    compat.fileWriteAll(stdout, sresult);
                    compat.fileWriteAll(stdout, "\n");
                }
            }
            compat.fileWriteAll(stdout, "Returned to full nanoclj-zig\n");
            continue;
        }

        // Tier policy introspection
        if (std.mem.eql(u8, line, "(tier-policy)")) {
            var tbuf: [256]u8 = undefined;
            const count = tier_policy.profiles.count();
            const msg = std.fmt.bufPrint(&tbuf, "tier-policy: {d} profiled expressions, thresholds: blue→red@{d} red→green@{d} demote@{d}", .{
                count, tier_policy.promote_to_red, tier_policy.promote_to_green, tier_policy.demote_after_failures,
            }) catch "tier-policy: ?";
            compat.fileWriteAll(stdout, msg);
            compat.fileWriteAll(stdout, "\n");
            continue;
        }
        if (std.mem.eql(u8, line, "(tier-reset)")) {
            tier_policy.reset();
            compat.fileWriteAll(stdout, "tier-policy: reset\n");
            continue;
        }

        // Incremental compilation: (incr ...) and (incr-list)
        if (std.mem.startsWith(u8, line, "(incr")) {
            const result = incr.handleIncrCommand(line, &gc, &incr_registry);
            compat.fileWriteAll(stdout, result);
            compat.fileWriteAll(stdout, "\n");
            continue;
        }

        // Bytecode eval: (bc <expr>)
        if (std.mem.startsWith(u8, line, "(bc ") and line[line.len - 1] == ')') {
            const inner = line[4 .. line.len - 1];
            const bc_result = bcRep(inner, &gc, allocator, &vm, &env);
            defer gc.allocator.free(bc_result);
            compat.fileWriteAll(stdout, bc_result);
            compat.fileWriteAll(stdout, "\n");
            continue;
        }
        // Benchmark: (bench <expr>) — tree-walk vs bytecode
        if (std.mem.startsWith(u8, line, "(bench ") and line[line.len - 1] == ')') {
            const inner = line[7 .. line.len - 1];
            const bench_result = benchRep(inner, &env, &gc, allocator, &vm);
            compat.fileWriteAll(stdout, bench_result);
            compat.fileWriteAll(stdout, "\n");
            continue;
        }
        // Time bytecode only: (time-bc <expr>)
        if (std.mem.startsWith(u8, line, "(time-bc ") and line[line.len - 1] == ')') {
            const inner = line[9 .. line.len - 1];
            const time_result = timeBcRep(inner, &gc, allocator, &vm, &env);
            compat.fileWriteAll(stdout, time_result);
            compat.fileWriteAll(stdout, "\n");
            continue;
        }
        // Disassemble: (disasm <expr>)
        if (std.mem.startsWith(u8, line, "(disasm ") and line[line.len - 1] == ')') {
            const inner = line[8 .. line.len - 1];
            var reader = Reader.init(inner, &gc);
            const form = reader.readForm() catch {
                compat.fileWriteAll(stdout, "Error: read failed\n");
                continue;
            };
            var comp = Compiler.init(allocator, &gc, null, &vm.globals, &env);
            defer comp.deinit();
            const dest = comp.allocReg() catch {
                compat.fileWriteAll(stdout, "Error: compile failed\n");
                continue;
            };
            comp.compile(form, dest) catch {
                compat.fileWriteAll(stdout, "Error: compile failed\n");
                continue;
            };
            comp.emit(bc.encode_d(.ret, dest)) catch {
                compat.fileWriteAll(stdout, "Error: emit failed\n");
                continue;
            };
            const func_def = comp.finalize() catch {
                compat.fileWriteAll(stdout, "Error: finalize failed\n");
                continue;
            };
            const listing = disasm.disassemble(func_def, &gc, allocator) catch {
                compat.fileWriteAll(stdout, "Error: disassemble failed\n");
                continue;
            };
            defer allocator.free(listing);
            compat.fileWriteAll(stdout, listing);
            continue;
        }

        // ── Tier-aware dispatch with hysteresis ─────────────────
        const recommended = tier_policy.recommend(line, &gc, &env) catch tier_policy_mod.Tier.blue;
        var actual_tier = recommended;
        var result: []const u8 = "";
        var tier_success = false;

        // Try recommended tier, fall back on failure
        if (actual_tier == .green) {
            const green_result = incr.handleIncrCommand(line, &gc, &incr_registry);
            if (!std.mem.startsWith(u8, green_result, "Error")) {
                result = green_result;
                tier_success = true;
            } else {
                actual_tier = .red; // fall through to red
            }
        }
        // bcRep always returns owned heap memory; track for free below.
        var bc_owned: ?[]u8 = null;
        if (actual_tier == .red and !tier_success) {
            const bc_result = bcRep(line, &gc, allocator, &vm, &env);
            bc_owned = bc_result;
            if (!std.mem.startsWith(u8, bc_result, "Error")) {
                result = bc_result;
                tier_success = true;
            } else {
                actual_tier = .blue; // fall through to blue
            }
        }
        // When we fall through to the blue (interpreter) tier, rep() returns
        // owned heap memory; hold the pointer so we can free it below.
        var rep_owned: ?[]u8 = null;
        if (!tier_success) {
            actual_tier = .blue;
            if (rep(line, &env, &gc)) |r| {
                rep_owned = r;
                result = r;
                tier_success = !std.mem.startsWith(u8, r, "Error");
            } else |_| {
                result = "Error: internal error";
                tier_success = false;
            }
        }

        // Record outcome for hysteresis learning
        tier_policy.recordResult(line, actual_tier, tier_success, 0);

        // Show tier badge when promoted above blue
        if (actual_tier != .blue) {
            var tier_buf: [32]u8 = undefined;
            compat.fileWriteAll(stdout, tier_policy_mod.TierPolicy.formatStatus(actual_tier, &tier_buf));
        }

        // Suppress nil output from comment-only lines
        if (!std.mem.eql(u8, result, "nil") or !isCommentOnly(line)) {
            compat.fileWriteAll(stdout, result);
            compat.fileWriteAll(stdout, "\n");
        }

        if (rep_owned) |r| gc.allocator.free(r);
        if (bc_owned) |r| gc.allocator.free(r);
    }
}

test {
    _ = @import("value.zig");
    _ = @import("reader.zig");
    _ = @import("gc.zig");
    _ = @import("semantics.zig");
    _ = @import("tree_vfs.zig");
    _ = @import("inet.zig");
    _ = @import("inet_builtins.zig");
    _ = @import("inet_compile.zig");
    _ = @import("thread_peval.zig");
    _ = @import("peval.zig");
    _ = @import("bytecode.zig");
    _ = @import("compiler.zig");
    _ = @import("ibc_denom.zig");
    _ = @import("http_fetch.zig");
    _ = @import("church_turing.zig");
    _ = @import("syrup_bridge.zig");
    _ = @import("gorj_bridge.zig");
    _ = @import("avalon_api_example.zig");
    _ = @import("gorj_mcp.zig");
    _ = @import("disasm.zig");
    _ = @import("incr.zig");
    _ = @import("simd_str.zig");
    _ = @import("namespace.zig");
    _ = @import("colorspace.zig");
    _ = @import("persistent_vector.zig");
    _ = @import("persistent_map.zig");
    _ = @import("ies.zig");
    _ = @import("pattern.zig");
    _ = @import("datalog.zig");
    _ = @import("spi.zig");
    _ = @import("sector.zig");
    _ = @import("flow.zig");
    _ = @import("flow_value.zig");
    // sector_boot.zig: x86 real-mode only, skip on ARM/macOS
    _ = @import("regex.zig");
    _ = @import("pluralism.zig");
    _ = @import("holy.zig");
    _ = @import("congrunet.zig");
    _ = @import("decomp.zig");
    _ = @import("tier_policy.zig");
    _ = @import("refs_agents.zig");
    _ = @import("eval.zig");
}

// ============================================================================
// CLOJURE ARRAY API TESTS (amap / areduce / aset-char / aset-long)
// ============================================================================

fn evalSource(src: []const u8, env: *Env, gc: *GC) !Value {
    const eval_mod = @import("eval.zig");
    var reader = Reader.init(src, gc);
    var last = Value.makeNil();
    while (reader.pos < reader.src.len) {
        const form = reader.readForm() catch break;
        last = try eval_mod.eval(form, env, gc);
    }
    return last;
}

fn arrayApiTestEnv(env: *Env, gc: *GC) !void {
    core.deinitCore();
    try core.initCore(env, gc);
    loadMacroPrelude(env, gc);
}

test "array api: make-array + aset-long + vec" {
    const compat = @import("compat.zig");
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var gc = GC.init(allocator);
    defer gc.deinit();
    var env = Env.init(allocator, null);
    env.is_root = true;
    defer env.deinit();
    try arrayApiTestEnv(&env, &gc);
    defer core.deinitCore();

    const result = try evalSource(
        \\(let* [a (make-array 3)]
        \\  (dotimes [i 3] (aset-long a i (* i 2)))
        \\  (vec a))
    , &env, &gc);
    try std.testing.expect(result.isObj());
    try std.testing.expect(result.asObj().kind == .vector);
    const items = result.asObj().data.vector.items.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i48, 0), items[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), items[1].asInt());
    try std.testing.expectEqual(@as(i48, 4), items[2].asInt());
}

test "array api: aset-char coerces code points" {
    const compat = @import("compat.zig");
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var gc = GC.init(allocator);
    defer gc.deinit();
    var env = Env.init(allocator, null);
    env.is_root = true;
    defer env.deinit();
    try arrayApiTestEnv(&env, &gc);
    defer core.deinitCore();

    const result = try evalSource(
        \\(let* [a (make-array 2)]
        \\  (aset-char a 0 65)
        \\  (aset-char a 1 90)
        \\  (+ (aget a 0) (aget a 1)))
    , &env, &gc);
    try std.testing.expectEqual(@as(i48, 155), result.asInt());
}

test "array api: areduce folds elements" {
    const compat = @import("compat.zig");
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var gc = GC.init(allocator);
    defer gc.deinit();
    var env = Env.init(allocator, null);
    env.is_root = true;
    defer env.deinit();
    try arrayApiTestEnv(&env, &gc);
    defer core.deinitCore();

    const result = try evalSource(
        \\(areduce [1 2 3] i acc 0 (+ acc i))
    , &env, &gc);
    try std.testing.expectEqual(@as(i48, 6), result.asInt());
}

test "array api: amap doubles each element via aget" {
    const compat = @import("compat.zig");
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var gc = GC.init(allocator);
    defer gc.deinit();
    var env = Env.init(allocator, null);
    env.is_root = true;
    defer env.deinit();
    try arrayApiTestEnv(&env, &gc);
    defer core.deinitCore();

    const result = try evalSource(
        \\(amap [1 2 3] i ret (* 2 (aget ret i)))
    , &env, &gc);
    try std.testing.expect(result.isObj());
    try std.testing.expect(result.asObj().kind == .vector);
    const items = result.asObj().data.vector.items.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i48, 2), items[0].asInt());
    try std.testing.expectEqual(@as(i48, 4), items[1].asInt());
    try std.testing.expectEqual(@as(i48, 6), items[2].asInt());
}
