const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const Limits = @import("transitivity.zig").Limits;
const transduction = @import("transduction.zig");
const transclusion = @import("transclusion.zig");
const Domain = transclusion.Domain;
const transitivity_mod = @import("transitivity.zig");
const pluralism = @import("pluralism.zig");

pub const BehaviorLevel = enum(i8) {
    absent = 0,
    surface = 1,
    partial = 2,
    equivalent = 3,
    dominant = 4,

    pub fn label(self: BehaviorLevel) []const u8 {
        return switch (self) {
            .absent => "absent",
            .surface => "surface",
            .partial => "partial",
            .equivalent => "equivalent",
            .dominant => "dominant",
        };
    }
};

pub const Feature = enum {
    clone,
    close,
    completions,
    describe,
    eval,
    interrupt,
    load_file,
    lookup,
    ls_sessions,
    stdin,
    streaming_output,
    bounded_eval,
    interrupt_semantics,
    middleware_discovery,

    pub fn label(self: Feature) []const u8 {
        return switch (self) {
            .clone => "clone",
            .close => "close",
            .completions => "completions",
            .describe => "describe",
            .eval => "eval",
            .interrupt => "interrupt",
            .load_file => "load-file",
            .lookup => "lookup",
            .ls_sessions => "ls-sessions",
            .stdin => "stdin",
            .streaming_output => "streaming-output",
            .bounded_eval => "bounded-eval",
            .interrupt_semantics => "interrupt-semantics",
            .middleware_discovery => "middleware-discovery",
        };
    }
};

pub const all_features = [_]Feature{
    .clone, .close, .completions, .describe, .eval, .interrupt, .load_file,
    .lookup, .ls_sessions, .stdin, .streaming_output, .bounded_eval,
    .interrupt_semantics, .middleware_discovery,
};

pub const RuntimeKind = enum {
    jvm,
    juvix,
    nanoclj_zig_current,
    nanoclj_zig_target,

    pub fn label(self: RuntimeKind) []const u8 {
        return switch (self) {
            .jvm => "jvm",
            .juvix => "juvix",
            .nanoclj_zig_current => "nanoclj-zig-current",
            .nanoclj_zig_target => "nanoclj-zig-target",
        };
    }
};

pub fn parseRuntime(name: []const u8) ?RuntimeKind {
    if (std.mem.eql(u8, name, "jvm") or std.mem.eql(u8, name, "jvm-nrepl")) return .jvm;
    if (std.mem.eql(u8, name, "juvix")) return .juvix;
    if (std.mem.eql(u8, name, "nanoclj-zig") or std.mem.eql(u8, name, "nanoclj-zig-current")) return .nanoclj_zig_current;
    if (std.mem.eql(u8, name, "nanoclj-zig-target") or std.mem.eql(u8, name, "plurigrid-target")) return .nanoclj_zig_target;
    return null;
}

pub fn level(runtime: RuntimeKind, feature: Feature) BehaviorLevel {
    return switch (runtime) {
        .jvm => switch (feature) {
            .bounded_eval => .absent,
            else => .equivalent,
        },
        .juvix => switch (feature) {
            .describe, .lookup, .load_file => .surface,
            .eval, .completions => .partial,
            .clone, .close, .interrupt, .ls_sessions, .stdin, .streaming_output, .interrupt_semantics, .middleware_discovery => .absent,
            .bounded_eval => .surface,
        },
        .nanoclj_zig_current => switch (feature) {
            .clone, .close, .completions, .describe, .load_file, .lookup => .partial,
            .eval, .ls_sessions => .equivalent,
            .interrupt, .stdin, .interrupt_semantics => .surface,
            .streaming_output, .middleware_discovery => .absent,
            .bounded_eval => .dominant,
        },
        .nanoclj_zig_target => switch (feature) {
            .eval, .bounded_eval => .dominant,
            else => .equivalent,
        },
    };
}

pub const MorphismKind = enum {
    equivalence,
    dominance,
    reverse_dominance,
    incomparable,

    pub fn label(self: MorphismKind) []const u8 {
        return switch (self) {
            .equivalence => "equivalence",
            .dominance => "dominance",
            .reverse_dominance => "reverse-dominance",
            .incomparable => "incomparable",
        };
    }
};

pub const Morphism = struct {
    kind: MorphismKind,
    dominated: usize,
    equivalent: usize,
    incomparable: usize,
    total: usize,
};

pub fn morphism(left: RuntimeKind, right: RuntimeKind) Morphism {
    var left_ge_right = true;
    var right_ge_left = true;
    var dominated: usize = 0;
    var equivalent_count: usize = 0;
    var incomparable_count: usize = 0;
    for (all_features) |feature| {
        const l = @intFromEnum(level(left, feature));
        const r = @intFromEnum(level(right, feature));
        if (l > r) dominated += 1;
        if (l == r) equivalent_count += 1 else incomparable_count += 1;
        if (l < r) left_ge_right = false;
        if (r < l) right_ge_left = false;
    }
    const kind: MorphismKind = if (left_ge_right and right_ge_left)
        .equivalence
    else if (left_ge_right)
        .dominance
    else if (right_ge_left)
        .reverse_dominance
    else
        .incomparable;
    return .{ .kind = kind, .dominated = dominated, .equivalent = equivalent_count, .incomparable = incomparable_count, .total = all_features.len };
}

pub const EvaluatorProfile = struct {
    name: []const u8,
    limits: Limits,

    pub const nrepl = EvaluatorProfile{
        .name = "nrepl",
        .limits = .{ .max_depth = 256, .max_fuel = 1_000_000, .max_collection_size = 10_000, .max_string_len = 256 * 1024 },
    };
    pub const local = EvaluatorProfile{ .name = "local", .limits = .{} };
    pub const embed_min = EvaluatorProfile{
        .name = "embed-min",
        .limits = .{ .max_depth = 64, .max_fuel = 100_000, .max_collection_size = 1_000, .max_string_len = 64 * 1024 },
    };
};

pub const RuntimeOrdering = enum(i8) {
    a_dominates = -1,
    equivalent = 0,
    b_dominates = 1,
    incomparable = 2,

    pub fn toTrit(self: RuntimeOrdering) i8 {
        return switch (self) {
            .a_dominates => -1,
            .equivalent => 0,
            .b_dominates => 1,
            .incomparable => 0,
        };
    }
};

pub const ProfileComparison = struct {
    ordering: RuntimeOrdering,
    a_domain: Domain,
    b_domain: Domain,
    a_fuel_used: u64,
    b_fuel_used: u64,
};

pub fn compareProfilesOnExpr(
    form: Value,
    env_a: *Env,
    gc_a: *GC,
    profile_a: EvaluatorProfile,
    env_b: *Env,
    gc_b: *GC,
    profile_b: EvaluatorProfile,
) ProfileComparison {
    var res_a = Resources.init(profile_a.limits);
    var res_b = Resources.init(profile_b.limits);
    const da = transduction.evalBounded(form, env_a, gc_a, &res_a);
    const db = transduction.evalBounded(form, env_b, gc_b, &res_b);
    const fuel_a = profile_a.limits.max_fuel - res_a.fuel;
    const fuel_b = profile_b.limits.max_fuel - res_b.fuel;

    const ordering: RuntimeOrdering = switch (da) {
        .value => |va| switch (db) {
            .value => |vb| if (transitivity_mod.structuralEq(va, vb, gc_a)) .equivalent else .incomparable,
            .bottom, .err => .a_dominates,
        },
        .bottom, .err => switch (db) {
            .value => .b_dominates,
            .bottom, .err => .equivalent,
        },
    };

    return .{
        .ordering = ordering,
        .a_domain = da,
        .b_domain = db,
        .a_fuel_used = fuel_a,
        .b_fuel_used = fuel_b,
    };
}

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn featureMap(runtime: RuntimeKind, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    for (all_features) |feature| {
        const feature_kw = try gc.internString(feature.label());
        const level_id = try gc.internString(level(runtime, feature).label());
        try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(feature_kw));
        try obj.data.map.vals.append(gc.allocator, Value.makeString(level_id));
    }
    return Value.makeObj(obj);
}

fn runtimeMap(runtime: RuntimeKind, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "runtime", Value.makeString(try gc.internString(runtime.label())));
    try addKV(obj, gc, "features", try featureMap(runtime, gc));
    return Value.makeObj(obj);
}

fn morphismMap(left: RuntimeKind, right: RuntimeKind, gc: *GC) !Value {
    const m = morphism(left, right);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "left", Value.makeString(try gc.internString(left.label())));
    try addKV(obj, gc, "right", Value.makeString(try gc.internString(right.label())));
    try addKV(obj, gc, "kind", Value.makeString(try gc.internString(m.kind.label())));
    try addKV(obj, gc, "dominated", Value.makeInt(@intCast(m.dominated)));
    try addKV(obj, gc, "equivalent", Value.makeInt(@intCast(m.equivalent)));
    try addKV(obj, gc, "incomparable", Value.makeInt(@intCast(m.incomparable)));
    try addKV(obj, gc, "total", Value.makeInt(@intCast(m.total)));
    return Value.makeObj(obj);
}

pub fn behaviorLatticeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    const runtime = parseRuntime(gc.getString(args[0].asStringId())) orelse return error.TypeError;
    return runtimeMap(runtime, gc);
}

pub fn behavioralEquivalenceFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isString() or !args[1].isString()) return error.ArityError;
    const left = parseRuntime(gc.getString(args[0].asStringId())) orelse return error.TypeError;
    const right = parseRuntime(gc.getString(args[1].asStringId())) orelse return error.TypeError;
    return Value.makeBool(morphism(left, right).kind == .equivalence);
}

pub fn behavioralDominanceFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2 or !args[0].isString() or !args[1].isString()) return error.ArityError;
    const left = parseRuntime(gc.getString(args[0].asStringId())) orelse return error.TypeError;
    const right = parseRuntime(gc.getString(args[1].asStringId())) orelse return error.TypeError;
    return morphismMap(left, right, gc);
}

pub fn behaviorCompareFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.InvalidArgs;
    const form = args[0];
    var env_b = env.*;
    const r = compareProfilesOnExpr(form, env, gc, EvaluatorProfile.nrepl, &env_b, gc, EvaluatorProfile.local);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "ordering", Value.makeString(try gc.internString(@tagName(r.ordering))));
    try addKV(obj, gc, "a-fuel", Value.makeInt(@intCast(r.a_fuel_used)));
    try addKV(obj, gc, "b-fuel", Value.makeInt(@intCast(r.b_fuel_used)));
    try addKV(obj, gc, "trit", Value.makeInt(@intCast(r.ordering.toTrit())));
    return Value.makeObj(obj);
}

pub fn behaviorProfileFn(_: []Value, gc: *GC, _: *Env, res: *Resources) anyerror!Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "fuel-remaining", Value.makeInt(@intCast(res.fuel)));
    try addKV(obj, gc, "max-depth-seen", Value.makeInt(@intCast(res.max_depth_seen)));
    try addKV(obj, gc, "steps-taken", Value.makeInt(@intCast(res.steps_taken)));
    const pos: []const u8 = if (res.limits.max_fuel <= 100_000)
        "embed-min"
    else if (res.limits.max_fuel <= 1_000_000)
        "nrepl"
    else
        "local";
    try addKV(obj, gc, "lattice-position", Value.makeString(try gc.internString(pos)));
    return Value.makeObj(obj);
}

pub const World = pluralism.World;
pub const EqualityMode = pluralism.EqualityMode;
pub const HashMode = pluralism.HashMode;
pub const TruthMode = pluralism.TruthMode;
pub const Trit = pluralism.Trit;
pub const OrderMode = pluralism.OrderMode;
pub const Comparison = pluralism.Comparison;
pub const CollectionMode = pluralism.CollectionMode;
pub const EvalStrategy = pluralism.EvalStrategy;
pub const NumberMode = pluralism.NumberMode;
pub const LogicMode = pluralism.LogicMode;
pub const ErrorMode = pluralism.ErrorMode;
pub const IdentityMode = pluralism.IdentityMode;
pub const getWorld = pluralism.getWorld;
pub const setWorld = pluralism.setWorld;
pub const setWorldFn = pluralism.setWorldFn;
pub const currentWorldFn = pluralism.currentWorldFn;
pub const pluralEqual = pluralism.pluralEqual;
pub const pluralEqualFn = pluralism.pluralEqualFn;
pub const pluralCompare = pluralism.pluralCompare;
pub const pluralCompareFn = pluralism.pluralCompareFn;
pub const pluralTruth = pluralism.pluralTruth;
pub const tritFn = pluralism.tritFn;
pub const pluralHash = pluralism.pluralHash;
pub const pluralHashFn = pluralism.pluralHashFn;

fn truthModeFromKeyword(name: []const u8) ?TruthMode {
    if (std.mem.eql(u8, name, "classical")) return .classical;
    if (std.mem.eql(u8, name, "intuitionistic")) return .intuitionistic;
    if (std.mem.eql(u8, name, "paraconsistent")) return .paraconsistent;
    return null;
}

fn truthModeLabel(mode: TruthMode) []const u8 {
    return @tagName(mode);
}

fn worldForTruthMode(mode: TruthMode) World {
    return switch (mode) {
        .classical => World.standard,
        .intuitionistic => World.constructivist,
        .paraconsistent => World.anarchist,
    };
}

fn worldLabel(w: World) []const u8 {
    if (std.meta.eql(w, World.standard)) return "standard";
    if (std.meta.eql(w, World.constructivist)) return "constructivist";
    if (std.meta.eql(w, World.anarchist)) return "anarchist";
    if (std.meta.eql(w, World.speculative)) return "speculative";
    return "custom";
}

fn worldMap(gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    const w = getWorld().*;
    try addKV(obj, gc, "world", Value.makeKeyword(try gc.internString(worldLabel(w))));
    try addKV(obj, gc, "equality", Value.makeKeyword(try gc.internString(@tagName(w.equality))));
    try addKV(obj, gc, "hash", Value.makeKeyword(try gc.internString(@tagName(w.hash))));
    try addKV(obj, gc, "truth", Value.makeKeyword(try gc.internString(@tagName(w.truth))));
    try addKV(obj, gc, "order", Value.makeKeyword(try gc.internString(@tagName(w.order))));
    try addKV(obj, gc, "collection", Value.makeKeyword(try gc.internString(@tagName(w.collection))));
    try addKV(obj, gc, "eval-strategy", Value.makeKeyword(try gc.internString(@tagName(w.eval_strategy))));
    try addKV(obj, gc, "numbers", Value.makeKeyword(try gc.internString(@tagName(w.numbers))));
    try addKV(obj, gc, "logic", Value.makeKeyword(try gc.internString(@tagName(w.logic))));
    try addKV(obj, gc, "errors", Value.makeKeyword(try gc.internString(@tagName(w.errors))));
    try addKV(obj, gc, "identity", Value.makeKeyword(try gc.internString(@tagName(w.identity))));
    return Value.makeObj(obj);
}

pub fn pluralProfileFn(_: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "behavior", try behaviorProfileFn(&.{}, gc, env, res));
    try addKV(obj, gc, "worlding", try worldMap(gc));
    return Value.makeObj(obj);
}

pub fn logicWorldFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeKeyword(try gc.internString(truthModeLabel(getWorld().truth)));
}

pub fn setLogicFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isKeyword()) return error.ArityError;
    const name = gc.getString(args[0].asKeywordId());
    const mode = truthModeFromKeyword(name) orelse return error.TypeError;
    setWorld(worldForTruthMode(mode));
    return Value.makeKeyword(try gc.internString(truthModeLabel(mode)));
}

fn probeMap(gc: *GC, mode: TruthMode, observed: Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "logic", Value.makeKeyword(try gc.internString(truthModeLabel(mode))));
    try addKV(obj, gc, "truth-trit", Value.makeInt(@intFromEnum(pluralTruth(observed, mode))));
    try addKV(obj, gc, "world", Value.makeKeyword(try gc.internString(worldLabel(worldForTruthMode(mode)))));
    try addKV(obj, gc, "observed", observed);
    return Value.makeObj(obj);
}

pub fn crossLogicEvalFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const observed_domain = transduction.evalBounded(args[0], env, gc, res);
    const observed = switch (observed_domain) {
        .value => |v| v,
        .bottom => Value.makeKeyword(try gc.internString("bottom")),
        .err => Value.makeKeyword(try gc.internString("error")),
    };

    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.append(gc.allocator, try probeMap(gc, .classical, observed));
    try vec.data.vector.items.append(gc.allocator, try probeMap(gc, .intuitionistic, observed));
    try vec.data.vector.items.append(gc.allocator, try probeMap(gc, .paraconsistent, observed));
    return Value.makeObj(vec);
}

pub fn logicDominanceFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 3 or !args[1].isKeyword() or !args[2].isKeyword()) return error.ArityError;
    const left_mode = truthModeFromKeyword(gc.getString(args[1].asKeywordId())) orelse return error.TypeError;
    const right_mode = truthModeFromKeyword(gc.getString(args[2].asKeywordId())) orelse return error.TypeError;
    const observed_domain = transduction.evalBounded(args[0], env, gc, res);
    const observed = switch (observed_domain) {
        .value => |v| v,
        .bottom => Value.makeKeyword(try gc.internString("bottom")),
        .err => Value.makeKeyword(try gc.internString("error")),
    };
    const lt: i8 = @intFromEnum(pluralTruth(observed, left_mode));
    const rt: i8 = @intFromEnum(pluralTruth(observed, right_mode));
    const kind: []const u8 = if (lt == rt)
        "equivalent"
    else if (lt > rt)
        "left-dominates"
    else
        "right-dominates";
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "left", Value.makeKeyword(try gc.internString(truthModeLabel(left_mode))));
    try addKV(obj, gc, "right", Value.makeKeyword(try gc.internString(truthModeLabel(right_mode))));
    try addKV(obj, gc, "left-trit", Value.makeInt(lt));
    try addKV(obj, gc, "right-trit", Value.makeInt(rt));
    try addKV(obj, gc, "kind", Value.makeKeyword(try gc.internString(kind)));
    return Value.makeObj(obj);
}

pub fn pluralProofFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const obj = try gc.allocObj(.map);
    const classical_kw = Value.makeKeyword(try gc.internString("classical"));
    const intuitionistic_kw = Value.makeKeyword(try gc.internString("intuitionistic"));
    const paraconsistent_kw = Value.makeKeyword(try gc.internString("paraconsistent"));
    var classical_vs_intuitionistic = [_]Value{ args[0], classical_kw, intuitionistic_kw };
    var classical_vs_paraconsistent = [_]Value{ args[0], classical_kw, paraconsistent_kw };
    var intuitionistic_vs_paraconsistent = [_]Value{ args[0], intuitionistic_kw, paraconsistent_kw };
    try addKV(obj, gc, "expr-probe", try crossLogicEvalFn(args, gc, env, res));
    try addKV(obj, gc, "classical-vs-intuitionistic", try logicDominanceFn(classical_vs_intuitionistic[0..], gc, env, res));
    try addKV(obj, gc, "classical-vs-paraconsistent", try logicDominanceFn(classical_vs_paraconsistent[0..], gc, env, res));
    try addKV(obj, gc, "intuitionistic-vs-paraconsistent", try logicDominanceFn(intuitionistic_vs_paraconsistent[0..], gc, env, res));
    return Value.makeObj(obj);
}
