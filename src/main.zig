const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
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
fn rep(input: []const u8, env: *Env, gc: *GC) ![]const u8 {
    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch |err| {
        return switch (err) {
            error.UnexpectedEOF => "Error: unexpected EOF",
            error.UnmatchedParen => "Error: unmatched )",
            error.UnmatchedBracket => "Error: unmatched ]",
            error.UnmatchedBrace => "Error: unmatched }",
            error.InvalidNumber => "Error: invalid number",
            error.UnexpectedChar => "Error: unexpected character",
            else => "Error: read failed",
        };
    };

    // Fuel-bounded eval: guaranteed termination
    var res = semantics.Resources.initDefault();
    const domain = semantics.evalBounded(form, env, gc, &res);

    return switch (domain) {
        .value => |v| printer.prStr(v, gc, true) catch "Error: print failed",
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
}

/// Bytecode REP: parse -> compile -> VM execute (uses persistent VM for globals)
fn bcRep(input: []const u8, gc: *GC, allocator: std.mem.Allocator, vm: *bc.VM, env: *Env) []const u8 {
    var reader = Reader.init(input, gc);
    const form = reader.readForm() catch return "Error: read failed";

    var comp = Compiler.init(allocator, gc, null, &vm.globals, env);
    defer comp.deinit();

    const dest = comp.allocReg() catch return "Error: too many registers";
    comp.compile(form, dest) catch return "Error: compilation failed";
    comp.emit(bc.encode_d(.ret, dest)) catch return "Error: emit failed";

    const func_def = comp.finalize() catch return "Error: finalize failed";

    const closure_obj = gc.allocObj(.bc_closure) catch return "Error: alloc failed";
    closure_obj.data.bc_closure = .{
        .def = func_def,
        .upvalues = &.{},
    };

    // Reset VM state for new execution but keep globals
    vm.frame_count = 0;
    vm.fuel = 100_000_000;
    @memset(&vm.stack, Value.makeNil());

    const result = vm.execute(&closure_obj.data.bc_closure) catch |err| return switch (err) {
        error.FuelExhausted => "Error: fuel exhausted",
        error.StackOverflow => "Error: stack overflow",
        error.TypeError => "Error: type error",
        error.ArityError => "Error: arity error",
        error.UndefinedGlobal => "Error: undefined global",
    };

    return printer.prStr(result, gc, true) catch "Error: print failed";
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
        tw_str, tw_ns / 1_000_000, bc_str, bc_ns / 1_000_000,
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
        _ = bcRep(src, gc, allocator, vm, env);
    }
}

/// Load standard Clojure macros into the tree-walk environment.
fn loadMacroPrelude(env: *Env, gc: *GC) void {
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

    for (macros) |src| {
        var reader = Reader.init(src, gc);
        const form = reader.readForm() catch continue;
        _ = eval_mod.eval(form, env, gc) catch {};
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
    const inet_builtins = @import("inet_builtins.zig");
    defer inet_builtins.deinitNets();

    // First Futamura projection: PE constant bindings through inet
    const peval = @import("peval.zig");
    const pe_count = peval.pevalEnv(&env, &gc);
    _ = pe_count;

    const stdout = compat.stdoutFile();
    const stdin_file = compat.stdinFile();

    // ── Demo: color strip banner ──────────────────────────────────
    // Detect terminal width (fallback 80)
    const width: u32 = 80;

    compat.fileWriteAll(stdout, "\x1b[1mnanoclj-zig v0.1.0\x1b[0m\n");
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

                const sresult = rep(sline, &sector_env, &gc) catch "Error: internal error";
                if (!std.mem.eql(u8, sresult, "nil") or !isCommentOnly(sline)) {
                    compat.fileWriteAll(stdout, sresult);
                    compat.fileWriteAll(stdout, "\n");
                }
            }
            compat.fileWriteAll(stdout, "Returned to full nanoclj-zig\n");
            continue;
        }

        // Bytecode eval: (bc <expr>)
        if (std.mem.startsWith(u8, line, "(bc ") and line[line.len - 1] == ')') {
            const inner = line[4 .. line.len - 1];
            const bc_result = bcRep(inner, &gc, allocator, &vm, &env);
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

        const result = rep(line, &env, &gc) catch "Error: internal error";
        // Suppress nil output from comment-only lines
        if (!std.mem.eql(u8, result, "nil") or !isCommentOnly(line)) {
            compat.fileWriteAll(stdout, result);
            compat.fileWriteAll(stdout, "\n");
        }
        if (result.len > 0 and result[0] != 'E') {
            allocator.free(result);
        }
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
    _ = @import("simd_str.zig");
    _ = @import("namespace.zig");
    _ = @import("colorspace.zig");
    _ = @import("persistent_vector.zig");
    _ = @import("persistent_map.zig");
    _ = @import("ies.zig");
    _ = @import("pattern.zig");
    _ = @import("sector.zig");
    // sector_boot.zig: x86 real-mode only, skip on ARM/macOS
    _ = @import("regex.zig");
    _ = @import("pluralism.zig");
    _ = @import("holy.zig");
    _ = @import("congrunet.zig");
    _ = @import("decomp.zig");
}
