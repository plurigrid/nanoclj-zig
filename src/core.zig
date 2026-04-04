const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const reader_mod = @import("reader.zig");
const printer = @import("printer.zig");
const eval_mod = @import("eval.zig");
const substrate = @import("substrate.zig");
const gay_skills = @import("gay_skills.zig");
const tree_vfs = @import("tree_vfs.zig");
const inet_builtins = @import("inet_builtins.zig");
const inet_compile = @import("inet_compile.zig");
const http_fetch = @import("http_fetch.zig");
const peval_mod = @import("peval.zig");

pub const BuiltinFn = *const fn (args: []Value, gc: *GC, env: *Env) anyerror!Value;

// We store builtins as a separate lookup rather than in NaN-boxed values.
// The env holds a symbol that maps to a sentinel; we intercept in apply.

var builtin_table: std.StringHashMap(BuiltinFn) = undefined;
var initialized = false;

pub fn initCore(env: *Env, gc: *GC) !void {
    if (!initialized) {
        builtin_table = std.StringHashMap(BuiltinFn).init(gc.allocator);
        initialized = true;
    }

    const builtins = .{
        .{ "+", &add },         .{ "-", &sub },
        .{ "*", &mul },         .{ "/", &div_fn },
        .{ "=", &eql },        .{ "<", &lt },
        .{ ">", &gt },         .{ "<=", &lte },
        .{ ">=", &gte },       .{ "list", &listFn },
        .{ "vector", &vectorFn }, .{ "hash-map", &hashMapFn },
        .{ "first", &first },  .{ "rest", &rest },
        .{ "cons", &cons },    .{ "count", &count },
        .{ "nth", &nth },      .{ "get", &getFn },
        .{ "assoc", &assoc },  .{ "conj", &conj },
        .{ "nil?", &isNilP },  .{ "number?", &isNumberP },
        .{ "string?", &isStringP }, .{ "keyword?", &isKeywordP },
        .{ "symbol?", &isSymbolP }, .{ "list?", &isListP },
        .{ "vector?", &isVectorP }, .{ "map?", &isMapP },
        .{ "fn?", &isFnP },    .{ "println", &printlnFn },
        .{ "pr-str", &prStrFn }, .{ "read-string", &readStringFn },
        .{ "str", &strFn },    .{ "subs", &subsFn },
        .{ "not", &notFn },    .{ "mod", &modFn },
        .{ "apply", &applyFn },
        // Gay Color builtins
        .{ "color-at", &substrate.colorAtFn },
        .{ "color-seed", &substrate.colorSeedFn },
        .{ "colors", &substrate.colorsFn },
        .{ "hue-to-trit", &substrate.hueToTritFn },
        .{ "mix64", &substrate.mix64Fn },
        .{ "xor-fingerprint", &substrate.xorFingerprintFn },
        // GF(3) builtins
        .{ "gf3-add", &substrate.gf3AddFn },
        .{ "gf3-mul", &substrate.gf3MulFn },
        .{ "gf3-conserved?", &substrate.gf3ConservedFn },
        .{ "trit-balance", &substrate.tritBalanceFn },
        // BCI builtins
        .{ "bci-channels", &substrate.bciChannelsFn },
        .{ "bci-read", &substrate.bciReadFn },
        .{ "bci-trit", &substrate.bciTritFn },
        .{ "bci-entropy", &substrate.bciEntropyFn },
        // nREPL
        .{ "nrepl-start", &substrate.nreplStartFn },
        // Substrate traversal
        .{ "substrate", &substrate.substrateFn },
        .{ "traverse", &substrate.traverseFn },
        // Gay Skills 3,4,9-13,15-17 (1-2,5-8,14 already above)
        .{ "color-hex", &gay_skills.colorHexFn },
        .{ "color-trit", &gay_skills.colorTritFn },
        .{ "tropical-add", &gay_skills.tropicalAddFn },
        .{ "tropical-mul", &gay_skills.tropicalMulFn },
        .{ "world-create", &gay_skills.worldCreateFn },
        .{ "world-step", &gay_skills.worldStepFn },
        .{ "propagate", &gay_skills.propagateFn },
        .{ "entropy", &gay_skills.entropyFn },
        .{ "depth-color", &gay_skills.depthColorFn },
        .{ "bisim?", &gay_skills.bisimCheckFn },
        // Tree VFS builtins (horse/ Forester forest)
        .{ "tree-read", &tree_vfs.treeReadFn },
        .{ "tree-title", &tree_vfs.treeTitleFn },
        .{ "tree-transcluded", &tree_vfs.treeTranscludedFn },
        .{ "tree-transcluders", &tree_vfs.treeTranscludersFn },
        .{ "tree-ids", &tree_vfs.treeIdsFn },
        .{ "tree-isolated", &tree_vfs.treeIsolatedFn },
        .{ "tree-chain", &tree_vfs.treeChainFn },
        .{ "tree-taxon", &tree_vfs.treeTaxonFn },
        .{ "tree-author", &tree_vfs.treeAuthorFn },
        .{ "tree-meta", &tree_vfs.treeMetaFn },
        .{ "tree-imports", &tree_vfs.treeImportsFn },
        .{ "tree-by-taxon", &tree_vfs.treeByTaxonFn },
        // Interaction net builtins
        .{ "inet-new", &inet_builtins.inetNewFn },
        .{ "inet-cell", &inet_builtins.inetCellFn },
        .{ "inet-wire", &inet_builtins.inetWireFn },
        .{ "inet-reduce", &inet_builtins.inetReduceFn },
        .{ "inet-live", &inet_builtins.inetLiveFn },
        .{ "inet-pairs", &inet_builtins.inetPairsFn },
        .{ "inet-trit", &inet_builtins.inetTritFn },
        .{ "inet-from-forest", &inet_builtins.inetFromForestFn },
        .{ "inet-dot", &inet_builtins.inetDotFn },
        .{ "inet-compile", &inet_compile.inetCompileFn },
        .{ "inet-readback", &inet_compile.inetReadbackFn },
        .{ "inet-eval", &inet_compile.inetEvalFn },
        // Partial evaluation (first Futamura projection)
        .{ "peval", &peval_mod.pevalFn },
        // HTTP fetch
        .{ "http-fetch", &http_fetch.httpFetchFn },
    };

    inline for (builtins) |b| {
        try builtin_table.put(b[0], b[1]);
        // Put a keyword as sentinel value for the builtin name
        const id = try gc.internString(b[0]);
        try env.set(b[0], Value.makeKeyword(id));
        try env.setById(id, Value.makeKeyword(id));
    }
}

pub fn deinitCore() void {
    if (initialized) {
        builtin_table.deinit();
        initialized = false;
    }
}

pub fn lookupBuiltin(name: []const u8) ?BuiltinFn {
    if (!initialized) return null;
    return builtin_table.get(name);
}

pub fn isBuiltinSentinel(val: Value, gc: *GC) ?[]const u8 {
    if (!val.isKeyword()) return null;
    const name = gc.getString(val.asKeywordId());
    if (lookupBuiltin(name) != null) return name;
    return null;
}

// Arithmetic
fn add(args: []Value, _: *GC, _: *Env) anyerror!Value {
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

fn sub(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) {
        if (args[0].isInt()) return Value.makeInt(-args[0].asInt());
        return Value.makeFloat(-args[0].asFloat());
    }
    var is_float = false;
    var result_i = if (args[0].isInt()) args[0].asInt() else blk: {
        is_float = true;
        break :blk @as(i48, 0);
    };
    var result_f: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    for (args[1..]) |a| {
        if (a.isInt()) {
            result_i -= a.asInt();
            result_f -= @floatFromInt(a.asInt());
        } else {
            is_float = true;
            result_f -= a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(result_f) else Value.makeInt(result_i);
}

fn mul(args: []Value, _: *GC, _: *Env) anyerror!Value {
    var prod_i: i48 = 1;
    var prod_f: f64 = 1;
    var is_float = false;
    for (args) |a| {
        if (a.isInt()) {
            prod_i *= a.asInt();
            prod_f *= @floatFromInt(a.asInt());
        } else {
            is_float = true;
            prod_f *= a.asFloat();
        }
    }
    return if (is_float) Value.makeFloat(prod_f) else Value.makeInt(prod_i);
}

fn div_fn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a_f: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const b_f: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeFloat(a_f / b_f);
}

fn modFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        return Value.makeInt(@rem(args[0].asInt(), args[1].asInt()));
    }
    return error.TypeError;
}

// Comparison
fn eql(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const semantics = @import("semantics.zig");
    return Value.makeBool(semantics.structuralEq(args[0], args[1], gc));
}

fn lt(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .lt);
}
fn gt(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .gt);
}
fn lte(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .lte);
}
fn gte(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return numCmp(args[0], args[1], .gte);
}

const CmpOp = enum { lt, gt, lte, gte };
fn numCmp(a: Value, b: Value, op: CmpOp) anyerror!Value {
    const af: f64 = if (a.isInt()) @floatFromInt(a.asInt()) else a.asFloat();
    const bf: f64 = if (b.isInt()) @floatFromInt(b.asInt()) else b.asFloat();
    const result = switch (op) {
        .lt => af < bf,
        .gt => af > bf,
        .lte => af <= bf,
        .gte => af >= bf,
    };
    return Value.makeBool(result);
}

// Collections
fn listFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.list);
    for (args) |a| try obj.data.list.items.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn vectorFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const obj = try gc.allocObj(.vector);
    for (args) |a| try obj.data.vector.items.append(gc.allocator, a);
    return Value.makeObj(obj);
}

fn hashMapFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;
    const obj = try gc.allocObj(.map);
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        try obj.data.map.keys.append(gc.allocator, args[i]);
        try obj.data.map.vals.append(gc.allocator, args[i + 1]);
    }
    return Value.makeObj(obj);
}

fn first(args: []Value, _: *GC, _: *Env) anyerror!Value {
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

fn rest(args: []Value, gc: *GC, _: *Env) anyerror!Value {
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

fn cons(args: []Value, gc: *GC, _: *Env) anyerror!Value {
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

fn count(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeInt(0);
    // String count: return byte length
    if (args[0].isString()) {
        const s = gc.getString(args[0].asStringId());
        return Value.makeInt(@intCast(s.len));
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

fn nth(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or !args[1].isInt()) return error.TypeError;
    const obj = args[0].asObj();
    const idx: usize = @intCast(args[1].asInt());
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    if (idx >= items.len) return error.InvalidArgs;
    return items[idx];
}

fn getFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
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

fn assoc(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    if (src.kind != .map) return error.TypeError;
    const new = try gc.allocObj(.map);
    // copy existing
    for (src.data.map.keys.items, 0..) |k, i| {
        try new.data.map.keys.append(gc.allocator, k);
        try new.data.map.vals.append(gc.allocator, src.data.map.vals.items[i]);
    }
    var j: usize = 1;
    while (j < args.len) : (j += 2) {
        // replace or add
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

fn conj(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const src = args[0].asObj();
    switch (src.kind) {
        .list => {
            const new = try gc.allocObj(.list);
            // conj on list prepends
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

// Predicates
fn isNilP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isNil());
}
fn isNumberP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isInt() or (!args[0].isNil() and !args[0].isBool() and !args[0].isSymbol() and !args[0].isKeyword() and !args[0].isString() and !args[0].isObj()));
}
fn isStringP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isString());
}
fn isKeywordP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isKeyword());
}
fn isSymbolP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isSymbol());
}
fn isListP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .list);
}
fn isVectorP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .vector);
}
fn isMapP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .map);
}
fn isFnP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .function);
}

// IO
fn printlnFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    for (args, 0..) |a, i| {
        if (i > 0) stdout.writeAll(" ") catch {};
        const s = try printer.prStr(a, gc, false);
        defer gc.allocator.free(s);
        stdout.writeAll(s) catch {};
    }
    stdout.writeAll("\n") catch {};
    return Value.makeNil();
}

fn prStrFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    var buf = compat.emptyList(u8);
    for (args, 0..) |a, i| {
        if (i > 0) try buf.append(gc.allocator, ' ');
        try printer.prStrInto(&buf, a, gc, true);
    }
    const id = try gc.internString(buf.items);
    buf.deinit(gc.allocator);
    return Value.makeString(id);
}

fn readStringFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    var r = reader_mod.Reader.init(s, gc);
    return r.readForm() catch Value.makeNil();
}

fn strFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    var buf = compat.emptyList(u8);
    for (args) |a| {
        try printer.prStrInto(&buf, a, gc, false);
    }
    const id = try gc.internString(buf.items);
    buf.deinit(gc.allocator);
    return Value.makeString(id);
}

fn subsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isInt()) return error.TypeError;
    const s = gc.getString(args[0].asStringId());
    const start: usize = @intCast(args[1].asInt());
    const end: usize = if (args.len == 3 and args[2].isInt()) @intCast(args[2].asInt()) else s.len;
    if (start > s.len or end > s.len or start > end) return error.InvalidArgs;
    const id = try gc.internString(s[start..end]);
    return Value.makeString(id);
}

fn notFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(!args[0].isTruthy());
}

fn applyFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const func = args[0];
    const last = args[args.len - 1];
    var real_args = compat.emptyList(Value);
    defer real_args.deinit(gc.allocator);
    for (args[1 .. args.len - 1]) |a| try real_args.append(gc.allocator, a);
    if (last.isObj()) {
        const obj = last.asObj();
        const items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
        for (items) |item| try real_args.append(gc.allocator, item);
    }
    // Check if builtin
    if (isBuiltinSentinel(func, gc)) |name| {
        if (lookupBuiltin(name)) |builtin| {
            return builtin(real_args.items, gc, env);
        }
    }
    return eval_mod.apply(func, real_args.items, env, gc);
}
