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
const semantics = @import("semantics.zig");
const substrate = @import("substrate.zig");
const gay_skills = @import("gay_skills.zig");
const tree_vfs = @import("tree_vfs.zig");
const inet_builtins = @import("inet_builtins.zig");
const inet_compile = @import("inet_compile.zig");
const http_fetch = @import("http_fetch.zig");
const peval_mod = @import("peval.zig");
const ibc_denom = @import("ibc_denom.zig");
const church_turing = @import("church_turing.zig");
const gorj_bridge = @import("gorj_bridge.zig");
const computable_sets = @import("computable_sets.zig");
const avalon_api_example = @import("avalon_api_example.zig");

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
        .{ "pr-str", &prStrFn }, .{ "read-string", &readStringFn }, .{ "load-file", &loadFileFn },
        .{ "str", &strFn },    .{ "subs", &subsFn },
        .{ "not", &notFn },    .{ "mod", &modFn },
        .{ "inc", &incFn },    .{ "dec", &decFn },
        .{ "zero?", &isZeroP },
        .{ "apply", &applyFn },
        .{ "take", &takeFn },
        .{ "drop", &dropFn },
        .{ "reduce", &reduceFn },
        .{ "range", &rangeFn },
        .{ "map", &mapFn },
        .{ "filter", &filterFn },
        .{ "concat", &concatFn },
        .{ "reverse", &reverseFn },
        .{ "empty?", &isEmptyP },
        .{ "into", &intoFn },
        .{ "set?", &isSetP },
        .{ "seq?", &isSeqP },
        .{ "sequential?", &isSequentialP },
        // Trit-tick time quantum builtins
        .{ "trit-phase", &tritPhaseFn },
        .{ "frames->trit-ticks", &framesToTritTicksFn },
        .{ "samples->trit-ticks", &samplesToTritTicksFn },
        .{ "trit-ticks-per-sec", &tritTicksPerSecFn },
        .{ "flicks-per-sec", &flicksPerSecFn },
        .{ "glimpses-per-tick", &glimpsesPerTickFn },
        .{ "cognitive-jerk", &cognitiveJerkFn },
        .{ "p-adic", &padicFn },
        .{ "p-adic-depth", &padicDepthFn },
        // Information spacetime builtins
        .{ "separation", &separationFn },
        .{ "cone-volume", &coneVolumeFn },
        .{ "info-density", &infoDensityFn },
        .{ "causal-depth", &causalDepthFn },
        .{ "padic-cones", &padicConesFn },
        // Jepsen builtins
        .{ "jepsen/nemesis!", &jepsenNemesisFn },
        .{ "jepsen/gen", &jepsenGenFn },
        .{ "jepsen/record!", &jepsenRecordFn },
        .{ "jepsen/check", &jepsenCheckFn },
        .{ "jepsen/reset!", &jepsenResetFn },
        .{ "jepsen/history", &jepsenHistoryFn },
        .{ "jepsen/check-unique-ids", &jepsenCheckUniqueIdsFn },
        .{ "jepsen/check-counter", &jepsenCheckCounterFn },
        .{ "jepsen/check-cas-register", &jepsenCheckCasRegisterFn },
        // Gay Color builtins
        .{ "color-at", &substrate.colorAtFn },
        .{ "color-seed", &substrate.colorSeedFn },
        .{ "colors", &substrate.colorsFn },
        .{ "hue-to-trit", &substrate.hueToTritFn },
        .{ "mix64", &substrate.mix64Fn },
        .{ "xor-fingerprint", &substrate.xorFingerprintFn },
        // Splittable RNG builtins
        .{ "split-rng", &splitRngFn },
        .{ "rng-next", &rngNextFn },
        .{ "rng-split", &rngSplitFn },
        .{ "rng-trit", &rngTritFn },
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
        // IBC denom (bmorphism/shitcoin geodesic)
        .{ "ibc-denom", &ibc_denom.ibcDenomFn },
        .{ "ibc-trit", &ibc_denom.ibcTritFn },
        .{ "noble-usdc-on", &ibc_denom.nobleUsdcOnFn },
        .{ "noble-precompute", &ibc_denom.noblePrecomputeFn },
        .{ "noble-channels", &ibc_denom.nobleChannelsFn },
        // Church-Turing ill-posedness witness
        .{ "ill-posed", &church_turing.illPosedFn },
        // Decidability hierarchy
        .{ "decidable?", &church_turing.decidableFn },
        .{ "semi-decide", &church_turing.semiDecideFn },
        .{ "halting-witness", &church_turing.haltingWitnessFn },
        .{ "primitive-recursive", &church_turing.primitiveRecursiveFn },
        // gorj bridge — collapsed loops (no hex roundtrip, fused eval pipeline)
        .{ "gorj-pipe", &gorj_bridge.gorjPipeFn },
        .{ "gorj-eval", &gorj_bridge.gorjEvalFn },
        .{ "gorj-encode", &gorj_bridge.gorjEncodeFn },
        .{ "gorj-decode", &gorj_bridge.gorjDecodeFn },
        .{ "gorj-version", &gorj_bridge.gorjVersionFn },
        .{ "gorj-tools", &gorj_bridge.gorjToolsFn },
        // Computable sets, reductions, Weihrauch degrees, guideline auditor
        .{ "computable-set", &computable_sets.computableSetFn },
        .{ "set-density", &computable_sets.setDensityFn },
        .{ "reduce-verify", &computable_sets.reduceVerifyFn },
        .{ "weihrauch-degree", &computable_sets.weihrauchDegreeFn },
        .{ "audit-guideline", &computable_sets.auditGuidelineFn },
        .{ "audit-all-guidelines", &computable_sets.auditAllGuidelinesFn },
        // Arithmetical hierarchy
        .{ "classify-problem", &computable_sets.classifyProblemFn },
        .{ "detect-morphism", &computable_sets.detectMorphismFn },
        .{ "list-problems", &computable_sets.listProblemsFn },
        // Möbius inversion & realizability
        .{ "mobius", &computable_sets.mobiusBuiltinFn },
        .{ "mertens", &computable_sets.mertensBuiltinFn },
        .{ "moebius-boundary", &computable_sets.moebiusBoundaryFn },
        .{ "flip-primes", &computable_sets.flipPrimesFn },
        .{ "morphism-graph", &computable_sets.morphismGraphFn },
        // Gorard ordinal tower
        .{ "gorard-tower", &computable_sets.gorardTowerFn },
        .{ "gorard-trit-sum", &computable_sets.gorardTritSumFn },
        // stopthrowingrocks blog concepts
        .{ "simulation-fuel", &computable_sets.simulationFuelFn },
        .{ "simulation-escape?", &computable_sets.simulationEscapeFn },
        .{ "matrix-derivation", &computable_sets.matrixDerivationFn },
        .{ "matrix-derivation-trace", &computable_sets.matrixDerivationTraceFn },
        .{ "gromov-matrix", &computable_sets.gromovMatrixFn },
        .{ "color-sort-trit-sum", &computable_sets.colorSortTritSumFn },
        .{ "turn-state", &computable_sets.turnStateFn },
        .{ "consensus-classify", &computable_sets.consensusClassifyFn },
        // Stacks Project
        .{ "stacks-tags", &computable_sets.stacksTagsFn },
        .{ "stacks-trit-sum", &computable_sets.stacksTritSumFn },
        .{ "stacks-lookup", &computable_sets.stacksLookupFn },
        // Matter lamp (IKEA VARMBLIXT + BILRESA)
        .{ "matter-lamp", &computable_sets.matterLampFn },
        .{ "bilresa-commands", &computable_sets.bilresaCommandsFn },
        .{ "bilresa-trit-sum", &computable_sets.bilresaTritSumFn },
        .{ "matter-scene", &computable_sets.matterSceneFn },
        // Diophantine equations
        .{ "pythagorean-triples", &computable_sets.pythagoreanTriplesFn },
        .{ "pell-solve", &computable_sets.pellSolveFn },
        .{ "markov-triples", &computable_sets.markovTriplesFn },
        .{ "rh-check", &computable_sets.rhCheckFn },
        // Avalon integration API sample spec
        .{ "avalon-api-spec", &avalon_api_example.avalonApiSpecFn },
        .{ "avalon-api-example", &avalon_api_example.avalonApiExampleFn },
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
    // Integer division when both args are ints and evenly divisible
    if (args[0].isInt() and args[1].isInt()) {
        const b = args[1].asInt();
        if (b == 0) return error.DivisionByZero;
        const a = args[0].asInt();
        if (@rem(a, b) == 0) return Value.makeInt(@divTrunc(a, b));
    }
    const a_f: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    const b_f: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else args[1].asFloat();
    return Value.makeFloat(a_f / b_f);
}

fn modFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0].isInt() and args[1].isInt()) {
        return Value.makeInt(@rem(args[0].asInt(), args[1].asInt()));
    }
    // Support float mod
    const a_f: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else if (args[0].isFloat()) args[0].asFloat() else return error.TypeError;
    const b_f: f64 = if (args[1].isInt()) @floatFromInt(args[1].asInt()) else if (args[1].isFloat()) args[1].asFloat() else return error.TypeError;
    return Value.makeFloat(@rem(a_f, b_f));
}

// Comparison
fn eql(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
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
    const raw = args[1].asInt();
    if (raw < 0) return error.InvalidArgs;
    const idx: usize = std.math.cast(usize, raw) orelse return error.InvalidArgs;
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

/// (load-file path) → result of last form
fn loadFileFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const path = gc.getString(args[0].asStringId());

    // Read file contents via C stdio (compat with 0.16)
    // Need null-terminated path for fopen
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return Value.makeNil();
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path: [*c]const u8 = @ptrCast(&path_buf);
    const file = std.c.fopen(c_path, "r") orelse return Value.makeNil();
    defer _ = std.c.fclose(file);

    var contents = compat.emptyList(u8);
    defer contents.deinit(gc.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        try contents.appendSlice(gc.allocator, buf[0..n]);
    }

    // Read and eval each form sequentially
    var r = reader_mod.Reader.init(contents.items, gc);
    var last_result = Value.makeNil();
    while (true) {
        const form = r.readForm() catch break;
        if (form.isNil()) {
            // Skip nil from comments, try next form
            if (r.pos >= r.src.len) break;
            continue;
        }
        var res = semantics.Resources.initDefault();
        const domain = semantics.evalBounded(form, env, gc, &res);
        last_result = switch (domain) {
            .value => |v| v,
            else => Value.makeNil(),
        };
    }
    return last_result;
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
    const raw_start = args[1].asInt();
    if (raw_start < 0) return error.InvalidArgs;
    const start: usize = std.math.cast(usize, raw_start) orelse return error.InvalidArgs;
    const end: usize = if (args.len == 3 and args[2].isInt()) blk: {
        const raw_end = args[2].asInt();
        if (raw_end < 0) return error.InvalidArgs;
        break :blk std.math.cast(usize, raw_end) orelse return error.InvalidArgs;
    } else s.len;
    if (start > s.len or end > s.len or start > end) return error.InvalidArgs;
    const id = try gc.internString(s[start..end]);
    return Value.makeString(id);
}

fn notFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(!args[0].isTruthy());
}

// ── Splittable RNG (SplitMix64) ──

fn splitMix64(seed: u64) u64 {
    var z = seed +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn splitRngFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const left = splitMix64(seed);
    const right = splitMix64(left);
    const obj = try gc.allocObj(.vector);
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@bitCast(@as(i48, @truncate(@as(i64, @bitCast(left)))))));
    try obj.data.vector.items.append(gc.allocator, Value.makeInt(@bitCast(@as(i48, @truncate(@as(i64, @bitCast(right)))))));
    return Value.makeObj(obj);
}

fn rngNextFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const next = splitMix64(seed);
    return Value.makeInt(@bitCast(@as(i48, @truncate(@as(i64, @bitCast(next))))));
}

fn rngSplitFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    return splitRngFn(args, gc, undefined);
}

fn rngTritFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const h = splitMix64(seed);
    const trit: i48 = @as(i48, @intCast(h % 3)) - 1; // -1, 0, or 1
    return Value.makeInt(trit);
}

fn incFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() +% 1);
}

fn decFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    return Value.makeInt(args[0].asInt() -% 1);
}

fn isZeroP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return Value.makeBool(false);
    return Value.makeBool(args[0].asInt() == 0);
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

fn takeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: usize = @intCast(@max(@as(i48, 0), args[0].asInt()));
    if (args[1].isNil()) return Value.makeObj(try gc.allocObj(.list));
    if (!args[1].isObj()) return error.TypeError;
    const obj = args[1].asObj();
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    const new = try gc.allocObj(.list);
    const limit = @min(n, items.len);
    for (items[0..limit]) |item| try new.data.list.items.append(gc.allocator, item);
    return Value.makeObj(new);
}

fn dropFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: usize = @intCast(@max(@as(i48, 0), args[0].asInt()));
    if (args[1].isNil()) return Value.makeObj(try gc.allocObj(.list));
    if (!args[1].isObj()) return error.TypeError;
    const obj = args[1].asObj();
    const items = switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        else => return error.TypeError,
    };
    const new = try gc.allocObj(.list);
    const start = @min(n, items.len);
    for (items[start..]) |item| try new.data.list.items.append(gc.allocator, item);
    return Value.makeObj(new);
}

fn reduceFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    // (reduce f init coll) or (reduce f coll)
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const func = args[0];
    var acc: Value = undefined;
    var items: []Value = undefined;

    if (args.len == 3) {
        acc = args[1];
        if (args[2].isNil()) return acc;
        if (!args[2].isObj()) return error.TypeError;
        const obj = args[2].asObj();
        items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
    } else {
        if (args[1].isNil()) {
            // (reduce f '()) — call f with no args
            if (isBuiltinSentinel(func, gc)) |name| {
                if (lookupBuiltin(name)) |builtin| {
                    const empty: []Value = &.{};
                    return builtin(empty, gc, env);
                }
            }
            return eval_mod.apply(func, &.{}, env, gc);
        }
        if (!args[1].isObj()) return error.TypeError;
        const obj = args[1].asObj();
        items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return error.TypeError,
        };
        if (items.len == 0) {
            if (isBuiltinSentinel(func, gc)) |name| {
                if (lookupBuiltin(name)) |builtin| {
                    const empty: []Value = &.{};
                    return builtin(empty, gc, env);
                }
            }
            return eval_mod.apply(func, &.{}, env, gc);
        }
        acc = items[0];
        items = items[1..];
    }

    for (items) |item| {
        var pair = [2]Value{ acc, item };
        if (isBuiltinSentinel(func, gc)) |name| {
            if (lookupBuiltin(name)) |builtin| {
                acc = try builtin(&pair, gc, env);
                continue;
            }
        }
        acc = try eval_mod.apply(func, &pair, env, gc);
    }
    return acc;
}

fn rangeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    // (range end), (range start end), (range start end step)
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

fn getItems(val: Value) ?[]Value {
    if (val.isNil()) return &.{};
    if (!val.isObj()) return null;
    const obj = val.asObj();
    return switch (obj.kind) {
        .list => obj.data.list.items.items,
        .vector => obj.data.vector.items.items,
        .set => obj.data.set.items.items,
        else => null,
    };
}

fn mapFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const func = args[0];
    const items = getItems(args[1]) orelse return error.TypeError;
    const new = try gc.allocObj(.list);
    const core = @import("core.zig");
    for (items) |item| {
        var a = [1]Value{item};
        const v = if (core.isBuiltinSentinel(func, gc)) |name|
            (if (core.lookupBuiltin(name)) |builtin| try builtin(&a, gc, env) else try eval_mod.apply(func, &a, env, gc))
        else
            try eval_mod.apply(func, &a, env, gc);
        try new.data.list.items.append(gc.allocator, v);
    }
    return Value.makeObj(new);
}

fn filterFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const func = args[0];
    const items = getItems(args[1]) orelse return error.TypeError;
    const new = try gc.allocObj(.list);
    const core = @import("core.zig");
    for (items) |item| {
        var a = [1]Value{item};
        const v = if (core.isBuiltinSentinel(func, gc)) |name|
            (if (core.lookupBuiltin(name)) |builtin| try builtin(&a, gc, env) else try eval_mod.apply(func, &a, env, gc))
        else
            try eval_mod.apply(func, &a, env, gc);
        if (v.isTruthy()) {
            try new.data.list.items.append(gc.allocator, item);
        }
    }
    return Value.makeObj(new);
}

fn concatFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    const new = try gc.allocObj(.list);
    for (args) |arg| {
        const items = getItems(arg) orelse continue;
        for (items) |item| try new.data.list.items.append(gc.allocator, item);
    }
    return Value.makeObj(new);
}

fn reverseFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    const new = try gc.allocObj(.list);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        try new.data.list.items.append(gc.allocator, items[i]);
    }
    return Value.makeObj(new);
}

fn isEmptyP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0].isNil()) return Value.makeBool(true);
    const items = getItems(args[0]) orelse return error.TypeError;
    return Value.makeBool(items.len == 0);
}

fn intoFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj()) return error.TypeError;
    const target = args[0].asObj();
    const src_items = getItems(args[1]) orelse return error.TypeError;
    switch (target.kind) {
        .vector => {
            const new = try gc.allocObj(.vector);
            for (target.data.vector.items.items) |item| try new.data.vector.items.append(gc.allocator, item);
            for (src_items) |item| try new.data.vector.items.append(gc.allocator, item);
            return Value.makeObj(new);
        },
        .list => {
            const new = try gc.allocObj(.list);
            for (target.data.list.items.items) |item| try new.data.list.items.append(gc.allocator, item);
            for (src_items) |item| try new.data.list.items.append(gc.allocator, item);
            return Value.makeObj(new);
        },
        .set => {
            const new = try gc.allocObj(.set);
            for (target.data.set.items.items) |item| try new.data.set.items.append(gc.allocator, item);
            for (src_items) |item| {
                var found = false;
                for (new.data.set.items.items) |existing| {
                    if (existing.eql(item)) { found = true; break; }
                }
                if (!found) try new.data.set.items.append(gc.allocator, item);
            }
            return Value.makeObj(new);
        },
        else => return error.TypeError,
    }
}

fn isSetP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .set);
}

fn isSeqP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value.makeBool(args[0].isObj() and args[0].asObj().kind == .list);
}

fn isSequentialP(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isObj()) return Value.makeBool(false);
    const k = args[0].asObj().kind;
    return Value.makeBool(k == .list or k == .vector);
}

// ── Trit-tick time quantum builtins ──────────────────────────────

const transitivity = @import("transitivity.zig");
const jepsen = @import("jepsen.zig");

/// (trit-phase n) → -1, 0, or 1 — GF(3) phase of tick count n
fn tritPhaseFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    return Value.makeInt(@as(i48, transitivity.tritPhase(n)));
}

/// (frames->trit-ticks frames fps) → integer trit-ticks
fn framesToTritTicksFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const frames: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const fps: u32 = @intCast(@max(@as(i48, 1), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.framesToTritTicks(frames, fps)));
}

/// (samples->trit-ticks samples rate) → integer trit-ticks
fn samplesToTritTicksFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const samples: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const rate: u32 = @intCast(@max(@as(i48, 1), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.samplesToTritTicks(samples, rate)));
}

/// (trit-ticks-per-sec) → 2116800000
fn tritTicksPerSecFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(transitivity.TRIT_TICKS_PER_SEC));
}

/// (flicks-per-sec) → 705600000
fn flicksPerSecFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(@intCast(transitivity.FLICK));
}

/// (glimpses-per-tick) → 1069
fn glimpsesPerTickFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeInt(1069);
}

/// (cognitive-jerk tick-count glimpse-count) → -1, 0, or 1
/// Measures phase alignment between objective time (ticks) and
/// subjective microstructure (glimpses).
/// 0 = flow (aligned), 1 = anticipation (leading), -1 = drag (lagging)
fn cognitiveJerkFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const ticks: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const glimpses: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    var tt = transitivity.TritTime{ .ticks = ticks, .glimpses = glimpses };
    _ = &tt;
    return Value.makeInt(@as(i48, tt.jerk()));
}

/// (p-adic p n) → v_p(n), the p-adic valuation (highest power of p dividing n)
fn padicFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const p: u64 = @intCast(@max(@as(i48, 2), args[0].asInt()));
    const n: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.padicVal(p, n)));
}

/// (p-adic-depth n) → (v2 v3 v5 v7 v1069) — multi-prime ultrametric fingerprint
fn padicDepthFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const n: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const d = transitivity.PadicDepth.of(n);
    const new = try gc.allocObj(.list);
    for (d.v) |vi| {
        try new.data.list.items.append(gc.allocator, Value.makeInt(@intCast(vi)));
    }
    return Value.makeObj(new);
}

// ============================================================================
// INFORMATION SPACETIME BUILTINS
// ============================================================================

/// (separation distance budget) → -1 (spacelike), 0 (lightlike), 1 (timelike)
fn separationFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const dist: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const budget: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@as(i48, transitivity.classify(dist, budget).trit()));
}

/// (cone-volume branching depth) → number of nodes reachable
fn coneVolumeFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const b: u64 = @intCast(@max(@as(i48, 1), args[0].asInt()));
    const d: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    const vol = transitivity.coneVolume(b, d);
    return Value.makeInt(@intCast(@min(vol, @as(u64, @intCast(std.math.maxInt(i48))))));
}

/// (info-density nodes volume) → density × 1000 (fixed-point)
fn infoDensityFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const nodes: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const volume: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.infoDensity(nodes, volume)));
}

/// (causal-depth branching target-volume) → ticks needed
fn causalDepthFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const b: u64 = @intCast(@max(@as(i48, 1), args[0].asInt()));
    const v: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    return Value.makeInt(@intCast(transitivity.causalDepth(b, v)));
}

/// (padic-cones depth) → [vol₂ vol₃ vol₅ vol₇ vol₁₀₆₉]
fn padicConesFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isInt()) return error.TypeError;
    const d: u64 = @intCast(@max(@as(i48, 0), args[0].asInt()));
    const cones = transitivity.padicCones(d);
    const obj = try gc.allocObj(.vector);
    for (cones) |vol| {
        const clamped = @min(vol, @as(u64, @intCast(std.math.maxInt(i48))));
        try obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(clamped)));
    }
    return Value.makeObj(obj);
}

// ============================================================================
// JEPSEN BUILTINS: embedded linearizability testing
// ============================================================================

/// (jepsen/nemesis! kind) → previous-kind
/// Kinds: :none :trit-corrupt :trit-duplicate :version-rewind :eval-drop :causal-invert
fn jepsenNemesisFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const kind: jepsen.NemesisKind = if (args[0].isKeyword()) blk: {
        const name = gc.getString(args[0].asKeywordId());
        if (std.mem.eql(u8, name, "none")) break :blk .none
        else if (std.mem.eql(u8, name, "trit-corrupt")) break :blk .trit_corrupt
        else if (std.mem.eql(u8, name, "trit-duplicate")) break :blk .trit_duplicate
        else if (std.mem.eql(u8, name, "version-rewind")) break :blk .version_rewind
        else if (std.mem.eql(u8, name, "eval-drop")) break :blk .eval_drop
        else if (std.mem.eql(u8, name, "causal-invert")) break :blk .causal_invert
        else break :blk .none;
    } else if (args[0].isInt()) blk: {
        const v = args[0].asInt();
        break :blk if (v >= 0 and v <= 5) @enumFromInt(@as(u8, @intCast(v))) else .none;
    } else return error.TypeError;

    const prev = jepsen.activateNemesis(kind);
    return Value.makeInt(@as(i48, @intFromEnum(prev)));
}

/// (jepsen/gen n seed) → vector of [op-kind detail] pairs
fn jepsenGenFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const n: usize = @intCast(@max(@as(i48, 1), args[0].asInt()));
    const seed: u64 = @intCast(@max(@as(i48, 0), args[1].asInt()));
    const clamped_n = @min(n, 1000); // safety cap

    var buf: [1000]jepsen.HistoryEntry = undefined;
    const gen_count = jepsen.generatePlan(seed, clamped_n, &buf);

    const obj = try gc.allocObj(.vector);
    for (0..gen_count) |i| {
        const entry_obj = try gc.allocObj(.vector);
        const op_name: []const u8 = switch (buf[i].op) {
            .eval => "eval",
            .nemesis => "nemesis",
            .recover => "recover",
            .check => "check",
        };
        try entry_obj.data.vector.items.append(gc.allocator, Value.makeKeyword(try gc.internString(op_name)));
        try entry_obj.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(buf[i].detail)));
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry_obj));
    }
    return Value.makeObj(obj);
}

/// (jepsen/record! op-kind result trit-before trit-after version-id) → causal-ts
fn jepsenRecordFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = gc;
    if (args.len < 4) return error.ArityError;
    const op: jepsen.OpKind = if (args[0].isInt())
        @enumFromInt(@as(u8, @intCast(@max(@as(i48, 0), args[0].asInt()))))
    else
        .eval;
    const result_kind: jepsen.OpResult = if (args[1].isInt())
        @enumFromInt(@as(u8, @intCast(@max(@as(i48, 0), args[1].asInt()))))
    else
        .ok;
    const trit_before: i8 = if (args[2].isInt()) @intCast(@max(@as(i48, -1), @min(args[2].asInt(), 1))) else 0;
    const trit_after: i8 = if (args[3].isInt()) @intCast(@max(@as(i48, -1), @min(args[3].asInt(), 1))) else 0;
    const version_id: u64 = if (args.len > 4 and args[4].isInt()) @intCast(@max(@as(i48, 0), args[4].asInt())) else 0;
    const detail: u32 = if (args.len > 5 and args[5].isInt()) @intCast(@max(@as(i48, 0), args[5].asInt())) else 0;

    jepsen.record(op, result_kind, trit_before, trit_after, version_id, detail);
    return Value.makeInt(@intCast(jepsen.causal_clock));
}

/// (jepsen/check) → {:valid? bool :violations N :ops-checked N :nemesis-events N :max-trit-drift N}
fn jepsenCheckFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const result = jepsen.check();

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(result.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("violations")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(result.violation_count)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("ops-checked")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(result.ops_checked)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("nemesis-events")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(result.nemesis_events)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("max-trit-drift")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@as(i48, result.max_trit_drift)));
    return Value.makeObj(obj);
}

/// (jepsen/reset!) → nil
fn jepsenResetFn(args: []Value, _: *GC, _: *Env) anyerror!Value {
    _ = args;
    jepsen.resetHistory();
    return Value.makeNil();
}

/// (jepsen/history) → vector of maps (recent history entries)
fn jepsenHistoryFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const hist = jepsen.getHistory();
    const obj = try gc.allocObj(.vector);
    const limit = @min(hist.len, 100); // cap at 100 entries for display
    for (0..limit) |i| {
        const entry = hist[i];
        const entry_obj = try gc.allocObj(.map);
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("op")));
        const op_name: []const u8 = switch (entry.op) {
            .eval => "eval",
            .nemesis => "nemesis",
            .recover => "recover",
            .check => "check",
        };
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeKeyword(try gc.internString(op_name)));
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("result")));
        const res_name: []const u8 = switch (entry.result) {
            .ok => "ok",
            .fail => "fail",
            .info => "info",
        };
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeKeyword(try gc.internString(res_name)));
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("ts")));
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(entry.causal_ts)));
        try entry_obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("trit")));
        try entry_obj.data.map.vals.append(gc.allocator, Value.makeInt(@as(i48, entry.trit_after)));
        try obj.data.vector.items.append(gc.allocator, Value.makeObj(entry_obj));
    }
    return Value.makeObj(obj);
}

/// (jepsen/check-unique-ids) → {:valid? bool :attempted N :duplicated N :min-id N :max-id N}
fn jepsenCheckUniqueIdsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const r = jepsen.checkUniqueIds();
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(r.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("attempted")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.attempted)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("duplicated")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.duplicated)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("min-id")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.min_id)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("max-id")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.max_id)));
    return Value.makeObj(obj);
}

/// (jepsen/check-counter) → {:valid? bool :reads N :errors N :lower N :upper N}
fn jepsenCheckCounterFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const r = jepsen.checkCounter();
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(r.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("reads")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.reads)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("errors")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.errors)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("lower")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(r.lower_bound, @as(u64, @intCast(std.math.maxInt(i48)))))));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("upper")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@min(r.upper_bound, @as(u64, @intCast(std.math.maxInt(i48)))))));
    return Value.makeObj(obj);
}

/// (jepsen/check-cas-register) → {:valid? bool :reads N :writes N :cas-ops N :stale-reads N :lost-writes N :value N}
fn jepsenCheckCasRegisterFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const r = jepsen.checkCasRegister();
    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("valid?")));
    try obj.data.map.vals.append(gc.allocator, Value.makeBool(r.valid));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("reads")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.reads)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("writes")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.writes)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("cas-ops")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.cas_ops)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("stale-reads")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.stale_reads)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("lost-writes")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.lost_writes)));
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("value")));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(r.register_value)));
    return Value.makeObj(obj);
}
