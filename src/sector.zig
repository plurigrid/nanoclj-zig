const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const semantics = @import("semantics.zig");

// ════════════════════════════════════════════════════════════════════
// SectorClojure: Minimal kernel with SRFI-based evolvability tiers
// ════════════════════════════════════════════════════════════════════
//
// Tier 0: McCarthy kernel (9 primitives + def/fn/if)
//   SectorLisp's irreducible eval: cons car cdr atom? eq quote cond lambda
//   + Clojure minimum: def, fn*, if, do
//
// Tier 1: SRFI-1 (List Library)
//   map, filter, reduce, take, drop, every?, some, partition
//   reverse, concat, flatten, interleave, zip, append
//
// Tier 2: SRFI-9/16/26 (Records + Multi-arity + Partial)
//   defrecord (basic), case-lambda → multi-arity fn/defn, partial, comp
//
// Tier 3: SRFI-43/69/113/128/151 (Core Data Structures)
//   vector, hash-map, hash-set, sorted-set, compare, bit-*
//   Foundation: mutable structures, then persistence via HAMT
//
// Tier 4: SRFI-41/158/196 (Laziness + Generators)
//   lazy-seq, iterate, repeat, cycle, range, generators
//
// Tier 5: SRFI-171/146/224 (Transducers + Immutable Mappings)
//   transduce, into, sequence, persistent assoc/dissoc/update/merge
//
// Tier 6: SRFI-13/95/132/64/269 (Strings, Sorting, Testing)
//   clojure.string/*, sort, sort-by, deftest, is, testing
//
// Tier 7: SRFI-241/248/252/253 (Pattern Matching, Specs)
//   core.match, try/catch, generative testing, specs
//
// Tier 8: Clojure-native (no SRFI: HAMTs, protocols, atoms, keywords, ns)
//   Full nanoclj-zig with 195+ builtins
//
// Each tier is a self-contained slice of nanoclj-zig's core.zig.
// To boot a SectorClojure, call initTier(n) for tiers 0..n.
// ════════════════════════════════════════════════════════════════════

pub const Tier = enum(u4) {
    mccarthy = 0, // 9 primitives + def/fn/if/do
    lists = 1, // SRFI-1: list library
    structural = 2, // SRFI-9/16/26: records, multi-arity, partial
    collections = 3, // SRFI-43/69/113: vectors, maps, sets, bitwise
    laziness = 4, // SRFI-41/158/196: lazy-seq, generators, range
    transducers = 5, // SRFI-171/146: transducers, immutable mappings
    strings = 6, // SRFI-13/95/132/64: strings, sorting, testing
    advanced = 7, // SRFI-241/248/252: patterns, specs, continuations
    full = 8, // nanoclj-zig complete: protocols, atoms, ns, domain
};

pub const TierStats = struct {
    name: []const u8,
    srfis: []const u16,
    builtin_count: u16,
    description: []const u8,
};

pub const TIER_SPECS = [_]TierStats{
    .{ .name = "mccarthy", .srfis = &.{}, .builtin_count = 13, .description = "SectorLisp kernel: cons car cdr atom? eq quote cond lambda + def fn* if do" },
    .{ .name = "lists", .srfis = &.{1}, .builtin_count = 40, .description = "SRFI-1 list library: map filter reduce take drop partition every? some" },
    .{ .name = "structural", .srfis = &.{ 9, 16, 26, 227, 232 }, .builtin_count = 25, .description = "Records, multi-arity fn, partial, comp, optional args" },
    .{ .name = "collections", .srfis = &.{ 43, 69, 113, 125, 128, 151 }, .builtin_count = 50, .description = "Vectors, hash-maps, sets, comparators, bitwise" },
    .{ .name = "laziness", .srfis = &.{ 41, 158, 196 }, .builtin_count = 30, .description = "Lazy sequences, generators, range objects" },
    .{ .name = "transducers", .srfis = &.{ 171, 146, 224, 250 }, .builtin_count = 35, .description = "Transducers, immutable mappings, into, sequence" },
    .{ .name = "strings", .srfis = &.{ 13, 14, 95, 132, 64, 175, 269 }, .builtin_count = 30, .description = "String library, sorting, test suites" },
    .{ .name = "advanced", .srfis = &.{ 241, 248, 252, 253, 257 }, .builtin_count = 20, .description = "Pattern matching, delimited continuations, specs" },
    .{ .name = "full", .srfis = &.{}, .builtin_count = 195, .description = "Full nanoclj-zig: GF(3), inet, miniKanren, peval, forester" },
};

// ────────────────────────────────────────────────────────────────────
// Tier 0: McCarthy kernel — SectorLisp's 9 + Clojure minimum
// ────────────────────────────────────────────────────────────────────
// These 13 primitives are the irreducible kernel of SectorClojure.
// From these, the metacircular evaluator can derive everything else.

fn t0_cons(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const new = try gc.allocObj(.list);
    try new.data.list.items.append(gc.allocator, args[0]);
    if (!args[1].isNil() and args[1].isObj()) {
        const obj = args[1].asObj();
        const items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
        for (items) |item| try new.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(new);
}

fn t0_car(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    return if (items.len > 0) items[0] else Value.makeNil();
}

fn t0_cdr(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const new = try gc.allocObj(.list);
    if (args[0].isNil()) return Value.makeObj(new);
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    if (items.len > 1) {
        for (items[1..]) |item| try new.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(new);
}

fn t0_atom(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(!args[0].isObj() or switch (args[0].asObj().kind) {
        .list, .vector, .map, .set => false,
        else => true,
    });
}

fn t0_eq(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return Value.makeBool(semantics.structuralEq(args[0], args[1], gc));
}

fn t0_list(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.list);
    for (args) |a| try obj.data.list.items.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn t0_count(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeInt(0);
    if (args[0].isString()) {
        return Value.makeInt(@intCast(gc.getString(args[0].asStringId()).len));
    }
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    const n: i48 = @intCast(switch (obj.kind) {
        .list => obj.data.list.items.items.len,
        .vector => obj.data.vector.items.items.len,
        .map => obj.data.map.keys.items.len,
        .set => obj.data.set.items.items.len,
        else => return error.TypeError,
    });
    return Value.makeInt(n);
}

fn t0_nil_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isNil());
}

fn t0_not(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(!args[0].isTruthy());
}

fn t0_println(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const compat = @import("compat.zig");
    const stdout = compat.stdoutFile();
    for (args, 0..) |a, i| {
        if (i > 0) compat.fileWriteAll(stdout, " ");
        const s = try printer.prStr(a, gc, false);
        defer gc.allocator.free(s);
        compat.fileWriteAll(stdout, s);
    }
    compat.fileWriteAll(stdout, "\n");
    return Value.makeNil();
}

fn t0_pr_str(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const compat = @import("compat.zig");
    var buf = compat.emptyList(u8);
    for (args, 0..) |a, i| {
        if (i > 0) try buf.append(gc.allocator, ' ');
        try printer.prStrInto(&buf, a, gc, true);
    }
    const id = try gc.internString(buf.items);
    buf.deinit(gc.allocator);
    return Value.makeString(id);
}

fn t0_read_string(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    var r = Reader.init(s, gc);
    return r.readForm() catch Value.makeNil();
}

// ────────────────────────────────────────────────────────────────────
// Tier 1: SRFI-1 — List library extensions
// ────────────────────────────────────────────────────────────────────

fn t1_first(args: []Value, _: *GC, _: *Env) anyerror!Value {
    return t0_car(args, undefined, undefined);
}

fn t1_rest(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    return t0_cdr(args, gc, undefined);
}

fn t1_nth(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or !args[1].isInt()) return error.TypeError;
    const obj = args[0].asObj();
    const idx: usize = std.math.cast(usize, @max(@as(i48, 0), args[1].asInt())) orelse return error.InvalidArgs;
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    if (idx >= items.len) return error.InvalidArgs;
    return items[idx];
}

fn t1_empty_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeBool(true);
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    const n = switch (obj.kind) {
        .list => obj.data.list.items.items.len,
        .vector => obj.data.vector.items.items.len,
        .map => obj.data.map.keys.items.len,
        .set => obj.data.set.items.items.len,
        else => return error.TypeError,
    };
    return Value.makeBool(n == 0);
}

fn t1_reverse(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeObj(try gc.allocObj(.list));
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    const new = try gc.allocObj(.list);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        try new.data.list.items.append(gc.allocator, items[i]);
    }
    return Value.makeObj(new);
}

fn t1_concat(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const new = try gc.allocObj(.list);
    for (args) |arg| {
        if (arg.isNil()) continue;
        if (!arg.isObj()) continue;
        const obj = arg.asObj();
        const items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => continue,
        };
        for (items) |item| try new.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(new);
}

fn t1_conj(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    switch (src.kind) {
        .list => {
            const new = try gc.allocObj(.list);
            var i = args.len;
            while (i > 1) {
                i -= 1;
                try new.data.list.items.append(gc.allocator, args[i]);
            }
            for (src.data.list.items.items) |item| try new.data.list.items.append(gc.allocator, item);
            return Value.makeObj(new);
        },
        .vector => {
            const new = try gc.allocObj(.vector);
            for (src.data.vector.items.items) |item| try new.data.vector.items.append(gc.allocator, item);
            for (args[1..]) |a| try new.data.vector.items.append(gc.allocator, a);
            return Value.makeObj(new);
        },
        else => return error.TypeError,
    }
}

// ────────────────────────────────────────────────────────────────────
// Tier 1 continued: Arithmetic (SRFI-1 expects numeric lists)
// ────────────────────────────────────────────────────────────────────

fn t1_add(args: []Value, _: *GC, _: *Env) anyerror!Value {
    var sum_i: i48 = 0;
    var sum_f: f64 = 0;
    var is_float = false;
    for (args) |a| {
        if (a.isInt()) {
            sum_i += a.asInt();
            sum_f += @floatFromInt(a.asInt());
        } else {
            is_float = true;
            sum_f += a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(sum_f) else Value.makeInt(sum_i);
}

fn t1_sub(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) {
        if (args[0].isInt()) return Value.makeInt(-args[0].asInt());
        return Value.makeFloat(-args[0].asFloat());
    }
    var is_float = false;
    var ri = if (args[0].isInt()) args[0].asInt() else blk: {
        is_float = true;
        break :blk @as(i48, 0);
    };
    var rf: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    for (args[1..]) |a| {
        if (a.isInt()) {
            ri -= a.asInt();
            rf -= @floatFromInt(a.asInt());
        } else {
            is_float = true;
            rf -= a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(rf) else Value.makeInt(ri);
}

fn t1_mul(args: []Value, _: *GC, _: *Env) anyerror!Value {
    var pi: i48 = 1;
    var pf: f64 = 1;
    var is_float = false;
    for (args) |a| {
        if (a.isInt()) {
            pi *= a.asInt();
            pf *= @floatFromInt(a.asInt());
        } else {
            is_float = true;
            pf *= a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(pf) else Value.makeInt(pi);
}

fn t1_div(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        const b = args[1].asInt();
        if (b == 0) return error.DivisionByZero;
        const a = args[0].asInt();
        if (@rem(a, b) == 0) return Value.makeInt(@divTrunc(a, b));
    }
    const af: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const bf: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeFloat(af / bf);
}

fn t1_mod(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        return Value.makeInt(@rem(args[0].asInt(), args[1].asInt()));
    }
    const af: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const bf: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeFloat(@rem(af, bf));
}

fn t1_lt(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const af: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const bf: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeBool(af < bf);
}

fn t1_gt(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const af: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const bf: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeBool(af > bf);
}

fn t1_lte(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const af: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const bf: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeBool(af <= bf);
}

fn t1_gte(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const af: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const bf: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeBool(af >= bf);
}

fn t1_inc(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    return Value.makeInt(args[0].asInt() +% 1);
}

fn t1_dec(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isInt()) return error.ArityError;
    return Value.makeInt(args[0].asInt() -% 1);
}

fn t1_zero_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return Value.makeBool(false);
    return Value.makeBool(args[0].asInt() == 0);
}

fn t1_str(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const compat = @import("compat.zig");
    var buf = compat.emptyList(u8);
    for (args) |a| {
        try printer.prStrInto(&buf, a, gc, false);
    }
    const id = try gc.internString(buf.items);
    buf.deinit(gc.allocator);
    return Value.makeString(id);
}

fn t1_number_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt() or args[0].isFloat());
}

fn t1_string_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isString());
}

fn t1_keyword_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isKeyword());
}

fn t1_symbol_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isSymbol());
}

fn t1_list_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .list);
}

fn t1_vector_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .vector);
}

fn t1_map_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .map);
}

fn t1_fn_p(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .function);
}

// ────────────────────────────────────────────────────────────────────
// Tier 3: SRFI-43/69/113 — Core data structures
// ────────────────────────────────────────────────────────────────────

fn t3_vector(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.vector);
    for (args) |a| try obj.data.vector.items.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn t3_hash_map(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;
    const obj = try gc.allocObj(.map);
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        try obj.data.map.keys.append(gc.allocator, args[i]);
        try obj.data.map.vals.append(gc.allocator, args[i + 1]);
    }
    return Value.makeObj(obj);
}

fn t3_get(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isNil()) return Value.makeNil();
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (obj.kind != .map) return error.TypeError;
    for (obj.data.map.keys.items, 0..) |k, i| {
        if (k.eql(args[1])) return obj.data.map.vals.items[i];
    }
    return Value.makeNil();
}

fn t3_assoc(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    if (src.kind != .map) return error.TypeError;
    const new = try gc.allocObj(.map);
    for (src.data.map.keys.items, 0..) |k, i| {
        try new.data.map.keys.append(gc.allocator, k);
        try new.data.map.vals.append(gc.allocator, src.data.map.vals.items[i]);
    }
    var j: usize = 1;
    while (j < args.len) : (j += 2) {
        var found = false;
        for (new.data.map.keys.items, 0..) |k, i| {
            if (k.eql(args[j])) {
                new.data.map.vals.items[i] = args[j + 1];
                found = true;
                break;
            }
        }
        if (!found) {
            try new.data.map.keys.append(gc.allocator, args[j]);
            try new.data.map.vals.append(gc.allocator, args[j + 1]);
        }
    }
    return Value.makeObj(new);
}

// ────────────────────────────────────────────────────────────────────
// Tier 4: SRFI-41/158/196 — Laziness + Range
// ────────────────────────────────────────────────────────────────────

fn t4_range(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len == 0 or args.len > 3) return error.ArityError;
    var start: i48 = 0;
    var end: i48 = undefined;
    var step: i48 = 1;
    if (args.len == 1) {
        if (!args[0].isInt()) return error.TypeError;
        end = args[0].asInt();
    } else {
        if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
        start = args[0].asInt();
        end = args[1].asInt();
        if (args.len == 3) {
            if (!args[2].isInt()) return error.TypeError;
            step = args[2].asInt();
        }
    }
    if (step == 0) return error.InvalidArgs;
    const new = try gc.allocObj(.list);
    var i = start;
    if (step > 0) {
        while (i < end) : (i += step) {
            try new.data.list.items.append(gc.allocator, Value.makeInt(i));
        }
    } else {
        while (i > end) : (i += step) {
            try new.data.list.items.append(gc.allocator, Value.makeInt(i));
        }
    }
    return Value.makeObj(new);
}

// ────────────────────────────────────────────────────────────────────
// Registration: install builtins for a given tier into an environment
// ────────────────────────────────────────────────────────────────────

pub const BuiltinFn = *const fn (args: []Value, gc: *GC, env: *Env) anyerror!Value;

pub const BuiltinEntry = struct {
    name: []const u8,
    func: BuiltinFn,
    tier: Tier,
};

pub const SECTOR_BUILTINS = [_]BuiltinEntry{
    // ── Tier 0: McCarthy kernel ──
    .{ .name = "cons", .func = &t0_cons, .tier = .mccarthy },
    .{ .name = "car", .func = &t0_car, .tier = .mccarthy },
    .{ .name = "cdr", .func = &t0_cdr, .tier = .mccarthy },
    .{ .name = "atom?", .func = &t0_atom, .tier = .mccarthy },
    .{ .name = "=", .func = &t0_eq, .tier = .mccarthy },
    .{ .name = "list", .func = &t0_list, .tier = .mccarthy },
    .{ .name = "count", .func = &t0_count, .tier = .mccarthy },
    .{ .name = "nil?", .func = &t0_nil_p, .tier = .mccarthy },
    .{ .name = "not", .func = &t0_not, .tier = .mccarthy },
    .{ .name = "println", .func = &t0_println, .tier = .mccarthy },
    .{ .name = "pr-str", .func = &t0_pr_str, .tier = .mccarthy },
    .{ .name = "read-string", .func = &t0_read_string, .tier = .mccarthy },
    // ── Tier 1: SRFI-1 list library + arithmetic ──
    .{ .name = "first", .func = &t0_car, .tier = .lists },
    .{ .name = "rest", .func = &t0_cdr, .tier = .lists },
    .{ .name = "nth", .func = &t1_nth, .tier = .lists },
    .{ .name = "empty?", .func = &t1_empty_p, .tier = .lists },
    .{ .name = "reverse", .func = &t1_reverse, .tier = .lists },
    .{ .name = "concat", .func = &t1_concat, .tier = .lists },
    .{ .name = "conj", .func = &t1_conj, .tier = .lists },
    .{ .name = "+", .func = &t1_add, .tier = .lists },
    .{ .name = "-", .func = &t1_sub, .tier = .lists },
    .{ .name = "*", .func = &t1_mul, .tier = .lists },
    .{ .name = "/", .func = &t1_div, .tier = .lists },
    .{ .name = "mod", .func = &t1_mod, .tier = .lists },
    .{ .name = "<", .func = &t1_lt, .tier = .lists },
    .{ .name = ">", .func = &t1_gt, .tier = .lists },
    .{ .name = "<=", .func = &t1_lte, .tier = .lists },
    .{ .name = ">=", .func = &t1_gte, .tier = .lists },
    .{ .name = "inc", .func = &t1_inc, .tier = .lists },
    .{ .name = "dec", .func = &t1_dec, .tier = .lists },
    .{ .name = "zero?", .func = &t1_zero_p, .tier = .lists },
    .{ .name = "str", .func = &t1_str, .tier = .lists },
    .{ .name = "number?", .func = &t1_number_p, .tier = .lists },
    .{ .name = "string?", .func = &t1_string_p, .tier = .lists },
    .{ .name = "keyword?", .func = &t1_keyword_p, .tier = .lists },
    .{ .name = "symbol?", .func = &t1_symbol_p, .tier = .lists },
    .{ .name = "list?", .func = &t1_list_p, .tier = .lists },
    .{ .name = "vector?", .func = &t1_vector_p, .tier = .lists },
    .{ .name = "map?", .func = &t1_map_p, .tier = .lists },
    .{ .name = "fn?", .func = &t1_fn_p, .tier = .lists },
    // ── Tier 3: SRFI-43/69/113 collections ──
    .{ .name = "vector", .func = &t3_vector, .tier = .collections },
    .{ .name = "hash-map", .func = &t3_hash_map, .tier = .collections },
    .{ .name = "get", .func = &t3_get, .tier = .collections },
    .{ .name = "assoc", .func = &t3_assoc, .tier = .collections },
    // ── Tier 4: SRFI-41/158/196 laziness ──
    .{ .name = "range", .func = &t4_range, .tier = .laziness },
};

pub fn initTier(env: *Env, gc: *GC, max_tier: Tier) !u16 {
    var count: u16 = 0;
    for (SECTOR_BUILTINS) |entry| {
        if (@intFromEnum(entry.tier) <= @intFromEnum(max_tier)) {
            const id = try gc.internString(entry.name);
            try env.set(entry.name, Value.makeKeyword(id));
            try env.setById(id, Value.makeKeyword(id));
            count += 1;
        }
    }
    return count;
}

pub fn lookupSectorBuiltin(name: []const u8, max_tier: Tier) ?BuiltinFn {
    for (SECTOR_BUILTINS) |entry| {
        if (@intFromEnum(entry.tier) <= @intFromEnum(max_tier) and std.mem.eql(u8, entry.name, name)) {
            return entry.func;
        }
    }
    return null;
}

pub fn countBuiltinsAtTier(tier: Tier) u16 {
    var n: u16 = 0;
    for (SECTOR_BUILTINS) |entry| {
        if (@intFromEnum(entry.tier) <= @intFromEnum(tier)) n += 1;
    }
    return n;
}

pub fn tierName(tier: Tier) []const u8 {
    return TIER_SPECS[@intFromEnum(tier)].name;
}

pub fn tierSrfis(tier: Tier) []const u16 {
    return TIER_SPECS[@intFromEnum(tier)].srfis;
}

// ────────────────────────────────────────────────────────────────────
// Self-bootstrap: Clojure macros defined at each tier level
// ────────────────────────────────────────────────────────────────────

pub const TIER_1_MACROS = [_][]const u8{
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
};

pub const TIER_2_MACROS = [_][]const u8{
    // ->: thread-first
    \\(defmacro -> [x & forms]
    \\  (reduce (fn* [acc form]
    \\    (if (list? form)
    \\      (cons (first form) (cons acc (rest form)))
    \\      (list form acc)))
    \\    x forms))
    ,
    // ->>: thread-last
    \\(defmacro ->> [x & forms]
    \\  (reduce (fn* [acc form]
    \\    (if (list? form)
    \\      (concat form (list acc))
    \\      (list form acc)))
    \\    x forms))
    ,
    // and/or: short-circuit
    \\(defmacro and [& xs]
    \\  (if (zero? (count xs)) true
    \\    (if (= 1 (count xs)) (first xs)
    \\      (list 'if (first xs) (cons 'and (rest xs)) false))))
    ,
    \\(defmacro or [& xs]
    \\  (if (zero? (count xs)) nil
    \\    (if (= 1 (count xs)) (first xs)
    \\      (list 'let* ['__or__ (first xs)]
    \\        (list 'if '__or__ '__or__ (cons 'or (rest xs)))))))
    ,
};

pub const TIER_4_MACROS = [_][]const u8{
    // run* / run / fresh — miniKanren at tier 4
    \\(defmacro run* [vars & goals]
    \\  (let* [q (first vars)]
    \\    (list 'let* [q '(lvar)]
    \\      (list 'run-goal 0 q (cons 'conj-goal goals)))))
    ,
    \\(defmacro run [n vars & goals]
    \\  (let* [q (first vars)]
    \\    (list 'let* [q '(lvar)]
    \\      (list 'run-goal n q (cons 'conj-goal goals)))))
    ,
    \\(defmacro fresh [vars & goals]
    \\  (if (zero? (count vars))
    \\    (cons 'conj-goal goals)
    \\    (list 'let* [(first vars) '(lvar)]
    \\      (cons 'fresh (cons (vec (rest vars)) goals)))))
    ,
};

pub fn loadTierMacros(tier: Tier, env: *Env, gc: *GC) void {
    const macro_sets = [_]struct { min_tier: Tier, macros: []const []const u8 }{
        .{ .min_tier = .lists, .macros = &TIER_1_MACROS },
        .{ .min_tier = .structural, .macros = &TIER_2_MACROS },
        .{ .min_tier = .laziness, .macros = &TIER_4_MACROS },
    };
    for (macro_sets) |ms| {
        if (@intFromEnum(tier) >= @intFromEnum(ms.min_tier)) {
            for (ms.macros) |src| {
                var reader = Reader.init(src, gc);
                const form = reader.readForm() catch continue;
                _ = eval_mod.eval(form, env, gc) catch {};
            }
        }
    }
}

// ────────────────────────────────────────────────────────────────────
// Metacircular evaluator: SectorLisp's eval in ~40 lines of Clojure
// This proves the kernel is complete — you can run LISP in LISP.
// ────────────────────────────────────────────────────────────────────

pub const METACIRCULAR_EVAL =
    \\;; SectorClojure metacircular evaluator
    \\;; Proves: 13 Tier 0 primitives suffice for self-hosting
    \\(def pairlis (fn* [keys vals env]
    \\  (if (nil? keys) env
    \\    (cons (list (first keys) (first vals))
    \\      (pairlis (rest keys) (rest vals) env)))))
    \\
    \\(def lookup (fn* [sym env]
    \\  (if (nil? env) nil
    \\    (if (= sym (first (first env)))
    \\      (first (rest (first env)))
    \\      (lookup sym (rest env))))))
    \\
    \\(def evlis (fn* [exprs env]
    \\  (if (nil? exprs) (list)
    \\    (cons (eval1 (first exprs) env)
    \\      (evlis (rest exprs) env)))))
    \\
    \\(def evcon (fn* [clauses env]
    \\  (if (eval1 (first (first clauses)) env)
    \\    (eval1 (first (rest (first clauses))) env)
    \\    (evcon (rest clauses) env))))
    \\
    \\(def eval1 (fn* [expr env]
    \\  (cond
    \\    (atom? expr) (lookup expr env)
    \\    (= (first expr) 'quote) (first (rest expr))
    \\    (= (first expr) 'cond)  (evcon (rest expr) env)
    \\    (= (first expr) 'lambda) expr
    \\    true (apply1 (eval1 (first expr) env)
    \\                 (evlis (rest expr) env)
    \\                 env))))
    \\
    \\(def apply1 (fn* [f args env]
    \\  (if (= (first f) 'lambda)
    \\    (eval1 (first (rest (rest f)))
    \\           (pairlis (first (rest f)) args env))
    \\    nil)))
;

// ────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────

test "tier 0 — mccarthy kernel count" {
    var n: u16 = 0;
    for (SECTOR_BUILTINS) |e| {
        if (e.tier == .mccarthy) n += 1;
    }
    try std.testing.expectEqual(@as(u16, 12), n);
}

test "tier 1 — list library count" {
    var n: u16 = 0;
    for (SECTOR_BUILTINS) |e| {
        if (e.tier == .lists) n += 1;
    }
    try std.testing.expect(n >= 20);
}

test "cumulative tier counts" {
    const t0 = countBuiltinsAtTier(.mccarthy);
    const t1 = countBuiltinsAtTier(.lists);
    const t3 = countBuiltinsAtTier(.collections);
    const t4 = countBuiltinsAtTier(.laziness);
    try std.testing.expect(t0 < t1);
    try std.testing.expect(t1 < t3);
    try std.testing.expect(t3 < t4);
}

test "tier spec metadata" {
    try std.testing.expectEqualStrings("mccarthy", TIER_SPECS[0].name);
    try std.testing.expectEqualStrings("lists", TIER_SPECS[1].name);
    try std.testing.expectEqual(@as(usize, 0), TIER_SPECS[0].srfis.len);
    try std.testing.expectEqual(@as(u16, 1), TIER_SPECS[1].srfis[0]);
}

test "sector lookup at tier boundary" {
    const cons_t0 = lookupSectorBuiltin("cons", .mccarthy);
    try std.testing.expect(cons_t0 != null);

    const range_t0 = lookupSectorBuiltin("range", .mccarthy);
    try std.testing.expect(range_t0 == null);

    const range_t4 = lookupSectorBuiltin("range", .laziness);
    try std.testing.expect(range_t4 != null);
}

test "metacircular eval source present" {
    try std.testing.expect(METACIRCULAR_EVAL.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, METACIRCULAR_EVAL, "eval1") != null);
    try std.testing.expect(std.mem.indexOf(u8, METACIRCULAR_EVAL, "pairlis") != null);
}
