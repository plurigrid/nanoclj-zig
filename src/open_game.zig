//! Open-game runtime and constructors on top of the monoidal diagram kernel.
//!
//! This module keeps the substrate plain:
//!   - diagrams stay as maps/vectors
//!   - open-game constructors lower to ordinary diagram boxes
//!   - `play` normalizes and records seeded execution context
//!   - `evaluate` performs best-response diagnostics when explicit payoff
//!     tables are present, and falls back to structural closure checks

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const monoidal_diagram = @import("monoidal_diagram.zig");
const semantics = @import("semantics.zig");

const default_seed: i64 = 42;
const default_primary = "inet-batch";
const companion_names = [_][]const u8{
    "thread-peval",
    "kanren-search",
    "propagator-fixpoint",
};

const AttrPair = struct {
    key: []const u8,
    value: Value,
};

const Scan = struct {
    boxes: usize = 0,
    world_boxes: usize = 0,
    coworld_boxes: usize = 0,
    open_game_boxes: usize = 0,
    closure_boxes: usize = 0,
    contextad_layers: usize = 0,
    readonly_effects: usize = 0,
    local_effects: usize = 0,
    contended_effects: usize = 0,
    agreement_required: bool = false,
    decision_boxes: usize = 0,
    dependent_decision_boxes: usize = 0,
    nature_boxes: usize = 0,
    stochastic_boxes: usize = 0,
    forward_function_boxes: usize = 0,
    backward_function_boxes: usize = 0,
    lens_boxes: usize = 0,
    discount_boxes: usize = 0,
    payoff_boxes: usize = 0,

    fn semanticallyClosed(self: *const Scan) bool {
        return self.world_boxes > 0 and
            self.coworld_boxes > 0 and
            self.closure_boxes > 0 and
            self.contextad_layers > 0 and
            self.agreement_required;
    }

    fn strategicBoxes(self: *const Scan) usize {
        return self.decision_boxes +
            self.nature_boxes +
            self.stochastic_boxes +
            self.forward_function_boxes +
            self.backward_function_boxes +
            self.lens_boxes +
            self.discount_boxes +
            self.payoff_boxes;
    }

    fn hasStrategicSurface(self: *const Scan) bool {
        return self.strategicBoxes() > 0;
    }
};

const EngineSelection = struct {
    seed: i64,
    companion: []const u8,
    source: []const u8,
};

const DecisionSpec = struct {
    atomic: []const u8,
    name: Value,
    player: Value,
    action_space: Value,
    payoff_table: Value,
    observation_space: Value,
    default_action: Value,
    observation_hint: Value,
    state_hint: Value,
    epsilon: f64,
};

const PayoffAdjustment = struct {
    player: Value,
    amount: f64,
    is_global: bool,
};

const StrategicInfo = struct {
    decisions: std.ArrayListUnmanaged(DecisionSpec) = .empty,
    adjustments: std.ArrayListUnmanaged(PayoffAdjustment) = .empty,
    discount_factor: f64 = 1.0,
    missing_payoff_tables: usize = 0,

    fn deinit(self: *StrategicInfo, allocator: std.mem.Allocator) void {
        self.decisions.deinit(allocator);
        self.adjustments.deinit(allocator);
    }
};

const DecisionDiagnostic = struct {
    value: Value,
    equilibrium: bool,
    profitable: bool,
    missing_payoff: bool,
};

const DiagnosticsSummary = struct {
    diagnostics: Value,
    profitable: Value,
    equilibrium: bool,
    count: usize,
    profitable_count: usize,
    missing_payoff_count: usize,
};

fn nowSeed() i64 {
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) {
        return 42;
    } else {
        // FWD 2026-04-18: std.time.nanoTimestamp removed in 0.16-dev;
        //                  use clock_gettime(MONOTONIC) as in core.zig nowSeed().
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) *% 1_000_000_000 +% @as(i64, ts.nsec);
    }
}

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn strv(gc: *GC, s: []const u8) !Value {
    return Value.makeString(try gc.internString(s));
}

fn addKV(obj: *Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn addRawKV(obj: *Obj, gc: *GC, key: Value, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, key);
    try obj.data.map.vals.append(gc.allocator, val);
}

fn seqItems(val: Value) ?[]const Value {
    if (val.isNil()) return &[_]Value{};
    if (!val.isObj()) return null;
    const obj = val.asObj();
    return switch (obj.kind) {
        .vector => obj.data.vector.items.items,
        .list => obj.data.list.items.items,
        else => null,
    };
}

fn vectorValue(gc: *GC, vals: []const Value) !Value {
    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.appendSlice(gc.allocator, vals);
    return Value.makeObj(vec);
}

fn emptyVectorValue(gc: *GC) !Value {
    return vectorValue(gc, &.{});
}

fn keywordVector(gc: *GC, labels: []const []const u8) !Value {
    const vec = try gc.allocObj(.vector);
    for (labels) |label| {
        try vec.data.vector.items.append(gc.allocator, try kw(gc, label));
    }
    return Value.makeObj(vec);
}

fn mapGetByKeyword(map_obj: *Obj, gc: *GC, key: []const u8) ?Value {
    if (map_obj.kind != .map) return null;
    for (map_obj.data.map.keys.items, 0..) |k, i| {
        if (k.isKeyword() and std.mem.eql(u8, gc.getString(k.asKeywordId()), key)) {
            return map_obj.data.map.vals.items[i];
        }
    }
    return null;
}

fn mapGetByValue(map_obj: *Obj, gc: *GC, key: Value) ?Value {
    if (map_obj.kind != .map) return null;
    for (map_obj.data.map.keys.items, 0..) |k, i| {
        if (semantics.structuralEq(k, key, gc)) return map_obj.data.map.vals.items[i];
    }
    return null;
}

fn valueName(val: Value, gc: *GC) ?[]const u8 {
    if (val.isKeyword()) return gc.getString(val.asKeywordId());
    if (val.isString()) return gc.getString(val.asStringId());
    if (val.isSymbol()) return gc.getString(val.asSymbolId());
    return null;
}

fn mapGetByName(map_obj: *Obj, gc: *GC, key: []const u8) ?Value {
    if (map_obj.kind != .map) return null;
    for (map_obj.data.map.keys.items, 0..) |k, i| {
        const name = valueName(k, gc) orelse continue;
        if (std.mem.eql(u8, name, key)) return map_obj.data.map.vals.items[i];
    }
    return null;
}

fn mapGetByNames(map_obj: *Obj, gc: *GC, keys: []const []const u8) ?Value {
    for (keys) |key| {
        if (mapGetByKeyword(map_obj, gc, key)) |v| return v;
        if (mapGetByName(map_obj, gc, key)) |v| return v;
    }
    return null;
}

fn boolValue(val: Value) ?bool {
    if (!val.isBool()) return null;
    return val.asBool();
}

fn lookupOpt(opts: ?Value, gc: *GC, key: []const u8) ?Value {
    const v = opts orelse return null;
    if (!v.isObj()) return null;
    const obj = v.asObj();
    return mapGetByKeyword(obj, gc, key) orelse mapGetByName(obj, gc, key);
}

fn sameName(val: Value, gc: *GC, expected: []const u8) bool {
    const name = valueName(val, gc) orelse return false;
    return std.mem.eql(u8, name, expected);
}

fn chooseCompanion(seed: i64) []const u8 {
    const len: i64 = @intCast(companion_names.len);
    const idx: usize = @intCast(@mod(seed, len));
    return companion_names[idx];
}

fn seedAsI48(seed: i64) i48 {
    const max: i64 = std.math.maxInt(i48);
    return @intCast(@mod(seed, max + 1));
}

fn selectEngine(opts: ?Value, gc: *GC) EngineSelection {
    var seed = default_seed;
    var source: []const u8 = "profile";

    if (lookupOpt(opts, gc, "randomize")) |v| {
        if (boolValue(v) == true) {
            seed = nowSeed();
            source = "random";
        }
    }
    if (lookupOpt(opts, gc, "seed")) |v| {
        if (v.isInt()) {
            seed = v.asInt();
            source = "explicit-seed";
        }
    }

    var companion = chooseCompanion(seed);
    if (lookupOpt(opts, gc, "companion")) |v| {
        const requested = valueName(v, gc) orelse "";
        for (companion_names) |candidate| {
            if (std.mem.eql(u8, requested, candidate)) {
                companion = candidate;
                source = "explicit-companion";
                break;
            }
        }
    }

    return .{ .seed = seed, .companion = companion, .source = source };
}

fn worldSettingsValue(gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "role", try kw(gc, "forward-play"));
    try addKV(obj, gc, "equality", try kw(gc, "homotopy"));
    try addKV(obj, gc, "hash", try kw(gc, "zobrist"));
    try addKV(obj, gc, "truth", try kw(gc, "intuitionistic"));
    try addKV(obj, gc, "order", try kw(gc, "preorder"));
    try addKV(obj, gc, "collection", try kw(gc, "persistent"));
    try addKV(obj, gc, "eval-strategy", try kw(gc, "speculative"));
    try addKV(obj, gc, "numbers", try kw(gc, "rational"));
    try addKV(obj, gc, "logic", try kw(gc, "linear"));
    try addKV(obj, gc, "errors", try kw(gc, "result"));
    try addKV(obj, gc, "identity", try kw(gc, "narrative"));
    return Value.makeObj(obj);
}

fn coworldSettingsValue(gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "role", try kw(gc, "backward-coplay"));
    try addKV(obj, gc, "equality", try kw(gc, "functional"));
    try addKV(obj, gc, "hash", try kw(gc, "fnv1a"));
    try addKV(obj, gc, "truth", try kw(gc, "paraconsistent"));
    try addKV(obj, gc, "order", try kw(gc, "preorder"));
    try addKV(obj, gc, "collection", try kw(gc, "confluent"));
    try addKV(obj, gc, "eval-strategy", try kw(gc, "lazy"));
    try addKV(obj, gc, "numbers", try kw(gc, "rational"));
    try addKV(obj, gc, "logic", try kw(gc, "relevant"));
    try addKV(obj, gc, "errors", try kw(gc, "recovery"));
    try addKV(obj, gc, "identity", try kw(gc, "functional"));
    return Value.makeObj(obj);
}

fn benchmarksValue(gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "normalize-1k-nodes-ms", Value.makeInt(10));
    try addKV(obj, gc, "normalize-10k-nodes-ms", Value.makeInt(100));
    try addKV(obj, gc, "active-pair-rewrites-per-sec-per-core", Value.makeInt(5_000_000));
    try addKV(obj, gc, "monte-carlo-10k-paths-365-ticks-ms", Value.makeInt(2_000));
    try addKV(obj, gc, "best-response-10k-agents-ms", Value.makeInt(1_000));
    try addKV(obj, gc, "nouns-fork-detection-ms", Value.makeInt(50));
    return Value.makeObj(obj);
}

fn profileIdForSeed(seed: i64) []const u8 {
    return if (seed == default_seed) "world-coworld-open-game-seed42" else "world-coworld-open-game-runtime";
}

fn profileValue(seed: i64, gc: *GC) !Value {
    const engine = try gc.allocObj(.map);
    try addKV(engine, gc, "primary-semantics", try kw(gc, default_primary));
    try addKV(engine, gc, "companion-semantics", try keywordVector(gc, &companion_names));
    try addKV(engine, gc, "seed", Value.makeInt(seedAsI48(seed)));
    try addKV(engine, gc, "seeded-companion", try kw(gc, chooseCompanion(seed)));
    try addKV(engine, gc, "agreement-required", Value.makeBool(true));

    const contextad = try gc.allocObj(.map);
    try addKV(contextad, gc, "ctx-shape", try keywordVector(gc, &.{ "market", "chain", "governance", "agent", "disclosure" }));
    try addKV(contextad, gc, "effect-classes", try keywordVector(gc, &.{ "readonly", "local", "contended" }));

    const artifacts = try gc.allocObj(.map);
    try addKV(artifacts, gc, "analysis", try strv(gc, ".topos/analyses/world-coworld-contextad-open-games.md"));
    try addKV(artifacts, gc, "model", try strv(gc, ".topos/models/world-coworld-open-game-seed42.json"));
    try addKV(artifacts, gc, "diagram", try strv(gc, ".topos/diagrams/world-coworld-open-game-seed42.clj"));

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "id", try strv(gc, profileIdForSeed(seed)));
    try addKV(obj, gc, "seed", Value.makeInt(seedAsI48(seed)));
    try addKV(obj, gc, "primary-semantics", try kw(gc, default_primary));
    try addKV(obj, gc, "companion-semantics", try keywordVector(gc, &companion_names));
    try addKV(obj, gc, "seeded-companion", try kw(gc, chooseCompanion(seed)));
    try addKV(obj, gc, "engine", Value.makeObj(engine));
    try addKV(obj, gc, "contextad", Value.makeObj(contextad));
    try addKV(obj, gc, "world", try worldSettingsValue(gc));
    try addKV(obj, gc, "coworld", try coworldSettingsValue(gc));
    try addKV(obj, gc, "benchmarks", try benchmarksValue(gc));
    try addKV(obj, gc, "artifacts", Value.makeObj(artifacts));
    return Value.makeObj(obj);
}

fn openGameParityValue(gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "upstream", try kw(gc, "open-game-hs"));
    try addKV(obj, gc, "engine", try kw(gc, "open-game-engine"));
    try addKV(obj, gc, "available", try keywordVector(gc, &.{
        "decision",
        "decision-no-obs",
        "dependent-decision",
        "forward-function",
        "backward-function",
        "from-functions",
        "nature",
        "lift-stochastic",
        "discount",
        "add-payoffs",
        "sequential-composition",
        "simultaneous-composition",
        "profile",
        "play",
        "diagnostics",
        "equilibrium-check",
    }));
    try addKV(obj, gc, "partial", try keywordVector(gc, &.{
        "bayesian-context",
        "stochastic-evaluation",
        "lens-semantics",
        "stateful-optics",
    }));
    try addKV(obj, gc, "missing", try keywordVector(gc, &.{
        "parser-preprocessor",
        "quasiquoter",
        "graphics",
        "io-games",
        "act-bridge",
        "evm-bridge",
    }));
    return Value.makeObj(obj);
}

fn scanDiagram(diag: Value, gc: *GC, scan: *Scan) !void {
    if (!diag.isObj()) return;
    const obj = diag.asObj();
    if (obj.kind != .map) return;
    const tag_val = mapGetByKeyword(obj, gc, "tag") orelse return;
    const tag_name = valueName(tag_val, gc) orelse return;

    if (std.mem.eql(u8, tag_name, "box") or std.mem.eql(u8, tag_name, "generator")) {
        scan.boxes += 1;
        const attrs_val = mapGetByKeyword(obj, gc, "attrs") orelse return;
        if (!attrs_val.isObj()) return;
        const attrs = attrs_val.asObj();
        if (attrs.kind != .map) return;

        if (mapGetByKeyword(attrs, gc, "role")) |v| {
            if (sameName(v, gc, "world")) scan.world_boxes += 1;
            if (sameName(v, gc, "coworld")) scan.coworld_boxes += 1;
        }
        if (mapGetByKeyword(attrs, gc, "semantics")) |v| {
            if (sameName(v, gc, "open-game")) scan.open_game_boxes += 1;
            if (sameName(v, gc, "closure")) scan.closure_boxes += 1;
        }
        if (mapGetByKeyword(attrs, gc, "layer")) |v| {
            if (sameName(v, gc, "contextad")) scan.contextad_layers += 1;
        }
        if (mapGetByKeyword(attrs, gc, "effect-class")) |v| {
            if (sameName(v, gc, "readonly")) scan.readonly_effects += 1;
            if (sameName(v, gc, "local")) scan.local_effects += 1;
            if (sameName(v, gc, "contended")) scan.contended_effects += 1;
        }
        if (mapGetByKeyword(attrs, gc, "agreement-required")) |v| {
            if (boolValue(v) == true) scan.agreement_required = true;
        }
        if (mapGetByKeyword(attrs, gc, "payoff-table") != null) scan.payoff_boxes += 1;

        if (mapGetByKeyword(attrs, gc, "atomic")) |v| {
            if (sameName(v, gc, "decision") or sameName(v, gc, "decision-no-obs")) {
                scan.decision_boxes += 1;
            } else if (sameName(v, gc, "dependent-decision")) {
                scan.decision_boxes += 1;
                scan.dependent_decision_boxes += 1;
            } else if (sameName(v, gc, "nature")) {
                scan.nature_boxes += 1;
            } else if (sameName(v, gc, "lift-stochastic")) {
                scan.stochastic_boxes += 1;
            } else if (sameName(v, gc, "forward-function")) {
                scan.forward_function_boxes += 1;
            } else if (sameName(v, gc, "backward-function")) {
                scan.backward_function_boxes += 1;
            } else if (sameName(v, gc, "from-functions")) {
                scan.lens_boxes += 1;
            } else if (sameName(v, gc, "discount")) {
                scan.discount_boxes += 1;
            } else if (sameName(v, gc, "add-payoffs")) {
                scan.payoff_boxes += 1;
            }
        }
        return;
    }

    if (std.mem.eql(u8, tag_name, "seq") or std.mem.eql(u8, tag_name, "tensor")) {
        const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return;
        const parts = seqItems(parts_val) orelse return;
        for (parts) |part| try scanDiagram(part, gc, scan);
    }
}

fn roleCountsValue(scan: Scan, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "boxes", Value.makeInt(@intCast(scan.boxes)));
    try addKV(obj, gc, "world", Value.makeInt(@intCast(scan.world_boxes)));
    try addKV(obj, gc, "coworld", Value.makeInt(@intCast(scan.coworld_boxes)));
    try addKV(obj, gc, "open-game", Value.makeInt(@intCast(scan.open_game_boxes)));
    try addKV(obj, gc, "closure", Value.makeInt(@intCast(scan.closure_boxes)));
    try addKV(obj, gc, "contextad", Value.makeInt(@intCast(scan.contextad_layers)));
    try addKV(obj, gc, "decision", Value.makeInt(@intCast(scan.decision_boxes)));
    try addKV(obj, gc, "dependent-decision", Value.makeInt(@intCast(scan.dependent_decision_boxes)));
    try addKV(obj, gc, "nature", Value.makeInt(@intCast(scan.nature_boxes)));
    try addKV(obj, gc, "lift-stochastic", Value.makeInt(@intCast(scan.stochastic_boxes)));
    try addKV(obj, gc, "forward-function", Value.makeInt(@intCast(scan.forward_function_boxes)));
    try addKV(obj, gc, "backward-function", Value.makeInt(@intCast(scan.backward_function_boxes)));
    try addKV(obj, gc, "from-functions", Value.makeInt(@intCast(scan.lens_boxes)));
    try addKV(obj, gc, "discount", Value.makeInt(@intCast(scan.discount_boxes)));
    try addKV(obj, gc, "payoff-box", Value.makeInt(@intCast(scan.payoff_boxes)));
    return Value.makeObj(obj);
}

fn effectCountsValue(scan: Scan, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "readonly", Value.makeInt(@intCast(scan.readonly_effects)));
    try addKV(obj, gc, "local", Value.makeInt(@intCast(scan.local_effects)));
    try addKV(obj, gc, "contended", Value.makeInt(@intCast(scan.contended_effects)));
    return Value.makeObj(obj);
}

fn closureWitnessesValue(scan: Scan, gc: *GC) !Value {
    var labels = std.ArrayListUnmanaged(Value).empty;
    defer labels.deinit(gc.allocator);

    if (scan.world_boxes > 0) try labels.append(gc.allocator, try kw(gc, "world-present"));
    if (scan.coworld_boxes > 0) try labels.append(gc.allocator, try kw(gc, "coworld-present"));
    if (scan.contextad_layers > 0) try labels.append(gc.allocator, try kw(gc, "context-carried"));
    if (scan.closure_boxes > 0) try labels.append(gc.allocator, try kw(gc, "closure-box-present"));
    if (scan.agreement_required) try labels.append(gc.allocator, try kw(gc, "agreement-required"));
    if (scan.decision_boxes > 0) try labels.append(gc.allocator, try kw(gc, "decision-surface"));
    if (scan.payoff_boxes > 0) try labels.append(gc.allocator, try kw(gc, "explicit-payoffs"));

    return vectorValue(gc, labels.items);
}

fn risksValue(scan: Scan, diagnostics: DiagnosticsSummary, info: *const StrategicInfo, gc: *GC) !Value {
    var labels = std.ArrayListUnmanaged(Value).empty;
    defer labels.deinit(gc.allocator);

    if (!scan.hasStrategicSurface()) {
        if (scan.world_boxes == 0) try labels.append(gc.allocator, try kw(gc, "missing-world"));
        if (scan.coworld_boxes == 0) try labels.append(gc.allocator, try kw(gc, "missing-coworld"));
        if (scan.contextad_layers == 0) try labels.append(gc.allocator, try kw(gc, "missing-contextad"));
        if (scan.closure_boxes == 0) try labels.append(gc.allocator, try kw(gc, "missing-closure"));
        if (!scan.agreement_required) try labels.append(gc.allocator, try kw(gc, "missing-agreement-gate"));
        if (scan.world_boxes != scan.coworld_boxes) try labels.append(gc.allocator, try kw(gc, "role-imbalance"));
    } else {
        if (info.missing_payoff_tables > 0 or diagnostics.missing_payoff_count > 0) {
            try labels.append(gc.allocator, try kw(gc, "missing-payoff-table"));
        }
        if (diagnostics.profitable_count > 0) {
            try labels.append(gc.allocator, try kw(gc, "profitable-deviation"));
        }
    }

    if (scan.contended_effects > 0) try labels.append(gc.allocator, try kw(gc, "contended-state"));
    return vectorValue(gc, labels.items);
}

fn equilibriaValue(scan: Scan, diagnostics: DiagnosticsSummary, closed: bool, gc: *GC) !Value {
    var labels = std.ArrayListUnmanaged(Value).empty;
    defer labels.deinit(gc.allocator);

    if (closed) try labels.append(gc.allocator, try kw(gc, "world-coworld-closure"));
    if (scan.agreement_required) try labels.append(gc.allocator, try kw(gc, "portfolio-agreement-gated"));
    if (scan.contended_effects == 0) try labels.append(gc.allocator, try kw(gc, "effect-separation"));
    if (diagnostics.count > 0) {
        try labels.append(gc.allocator, try kw(gc, "best-response-analysis"));
        if (diagnostics.equilibrium) {
            try labels.append(gc.allocator, try kw(gc, "best-response-stable"));
        } else {
            try labels.append(gc.allocator, try kw(gc, "best-response-broken"));
        }
    }
    if (scan.nature_boxes > 0 or scan.stochastic_boxes > 0) {
        try labels.append(gc.allocator, try kw(gc, "stochastic-context"));
    }

    return vectorValue(gc, labels.items);
}

fn structuralPayoffsValue(scan: Scan, closed: bool, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "world-count", Value.makeInt(@intCast(scan.world_boxes)));
    try addKV(obj, gc, "coworld-count", Value.makeInt(@intCast(scan.coworld_boxes)));
    try addKV(obj, gc, "decision-count", Value.makeInt(@intCast(scan.decision_boxes)));
    try addKV(obj, gc, "agreement-score", Value.makeInt(if (scan.agreement_required) 1 else 0));
    try addKV(obj, gc, "closure-score", Value.makeInt(if (closed) 1 else 0));
    return Value.makeObj(obj);
}

fn closureValue(scan: Scan, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "semantically-closed?", Value.makeBool(scan.semanticallyClosed()));
    try addKV(obj, gc, "witnesses", try closureWitnessesValue(scan, gc));
    return Value.makeObj(obj);
}

fn phaseValue(gc: *GC, phase: []const u8, payload_key: []const u8, payload: Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "phase", try kw(gc, phase));
    try addKV(obj, gc, payload_key, payload);
    return Value.makeObj(obj);
}

fn buildTraceValue(
    game: Value,
    summary: Value,
    input: Value,
    context: Value,
    selection: EngineSelection,
    scan: Scan,
    gc: *GC,
) !Value {
    var phases = std.ArrayListUnmanaged(Value).empty;
    defer phases.deinit(gc.allocator);

    try phases.append(gc.allocator, try phaseValue(gc, "normalize", "summary", summary));
    try phases.append(gc.allocator, try phaseValue(gc, "scan", "roles", try roleCountsValue(scan, gc)));
    try phases.append(gc.allocator, try phaseValue(gc, "portfolio", "secondary", try kw(gc, selection.companion)));
    try phases.append(gc.allocator, try phaseValue(gc, "closure", "result", try closureValue(scan, gc)));

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "ok", Value.makeBool(true));
    try addKV(obj, gc, "profile-id", try strv(gc, profileIdForSeed(selection.seed)));
    try addKV(obj, gc, "analysis-id", try strv(gc, "world-coworld-contextad-open-games"));
    try addKV(obj, gc, "seed", Value.makeInt(seedAsI48(selection.seed)));
    try addKV(obj, gc, "primary-semantics", try kw(gc, default_primary));
    try addKV(obj, gc, "companion-semantics", try kw(gc, selection.companion));
    try addKV(obj, gc, "companion-source", try kw(gc, selection.source));
    try addKV(obj, gc, "agreement-basis", try kw(gc, "normalized-diagram"));
    try addKV(obj, gc, "agreement", Value.makeBool(true));
    try addKV(obj, gc, "input", input);
    try addKV(obj, gc, "context", context);
    try addKV(obj, gc, "game", game);
    try addKV(obj, gc, "summary", summary);
    try addKV(obj, gc, "profile", try profileValue(selection.seed, gc));
    try addKV(obj, gc, "role-counts", try roleCountsValue(scan, gc));
    try addKV(obj, gc, "effect-counts", try effectCountsValue(scan, gc));
    try addKV(obj, gc, "closure", try closureValue(scan, gc));
    try addKV(obj, gc, "trace", try vectorValue(gc, phases.items));
    return Value.makeObj(obj);
}

fn summarizeGame(game: Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    var args = [_]Value{game};
    return monoidal_diagram.diagramSummaryFn(args[0..], gc, env, res);
}

fn isTraceMap(v: Value, gc: *GC) bool {
    if (!v.isObj()) return false;
    const obj = v.asObj();
    if (obj.kind != .map) return false;
    return mapGetByKeyword(obj, gc, "summary") != null and mapGetByKeyword(obj, gc, "primary-semantics") != null;
}

fn playValueFor(game: Value, input: Value, context: Value, opts: ?Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    const summary = try summarizeGame(game, gc, env, res);
    if (!summary.isObj()) return error.TypeError;
    const summary_obj = summary.asObj();
    if (summary_obj.kind != .map) return error.TypeError;
    const normalized = mapGetByKeyword(summary_obj, gc, "normalized") orelse return error.TypeError;

    const selection = selectEngine(opts, gc);
    var scan = Scan{};
    try scanDiagram(normalized, gc, &scan);
    return buildTraceValue(game, summary, input, context, selection, scan, gc);
}

fn skipOptionKey(key: Value, gc: *GC) bool {
    const name = valueName(key, gc) orelse return false;
    return std.mem.eql(u8, name, "dom") or
        std.mem.eql(u8, name, "cod") or
        std.mem.eql(u8, name, "semantics") or
        std.mem.eql(u8, name, "atomic") or
        std.mem.eql(u8, name, "upstream");
}

fn copyOptionAttrs(dst: *Obj, opts: ?Value, gc: *GC) anyerror!void {
    const val = opts orelse return;
    if (!val.isObj()) return error.TypeError;
    const obj = val.asObj();
    if (obj.kind != .map) return error.TypeError;
    for (obj.data.map.keys.items, obj.data.map.vals.items) |key, entry| {
        if (skipOptionKey(key, gc)) continue;
        try addRawKV(dst, gc, key, entry);
    }
}

fn boundaryValueFromOpts(opts: ?Value, gc: *GC, key: []const u8) anyerror!Value {
    if (lookupOpt(opts, gc, key)) |v| {
        const items = seqItems(v) orelse return error.TypeError;
        return vectorValue(gc, items);
    }
    return emptyVectorValue(gc);
}

fn seqToVectorValue(v: Value, gc: *GC) anyerror!Value {
    const items = seqItems(v) orelse return error.TypeError;
    return vectorValue(gc, items);
}

fn firstSeqItem(v: Value) ?Value {
    const items = seqItems(v) orelse return null;
    if (items.len == 0) return null;
    return items[0];
}

fn buildOpenGameBox(
    name: Value,
    atomic: []const u8,
    dom: Value,
    cod: Value,
    opts: ?Value,
    extra_attrs: []const AttrPair,
    gc: *GC,
    env: *Env,
    res: *Resources,
) anyerror!Value {
    const attrs = try gc.allocObj(.map);
    try addKV(attrs, gc, "semantics", try kw(gc, "open-game"));
    try addKV(attrs, gc, "atomic", try kw(gc, atomic));
    try addKV(attrs, gc, "upstream", try kw(gc, "open-game-hs"));
    for (extra_attrs) |entry| try addKV(attrs, gc, entry.key, entry.value);
    try copyOptionAttrs(attrs, opts, gc);

    var args = [_]Value{ name, dom, cod, Value.makeObj(attrs) };
    return monoidal_diagram.diagramBoxFn(args[0..], gc, env, res);
}

fn appendDistinct(values: *std.ArrayListUnmanaged(Value), candidate: Value, gc: *GC) !void {
    for (values.items) |existing| {
        if (semantics.structuralEq(existing, candidate, gc)) return;
    }
    try values.append(gc.allocator, candidate);
}

fn collectPayoffAdjustments(attrs: *Obj, info: *StrategicInfo, gc: *GC) !void {
    if (mapGetByNames(attrs, gc, &.{ "payoffs" })) |payoffs| {
        if (payoffs.asNumber()) |amount| {
            try info.adjustments.append(gc.allocator, .{
                .player = Value.makeNil(),
                .amount = amount,
                .is_global = true,
            });
            return;
        }
        if (!payoffs.isObj()) return;
        const obj = payoffs.asObj();
        switch (obj.kind) {
            .map => {
                for (obj.data.map.keys.items, obj.data.map.vals.items) |player, raw| {
                    const amount = raw.asNumber() orelse continue;
                    try info.adjustments.append(gc.allocator, .{
                        .player = player,
                        .amount = amount,
                        .is_global = false,
                    });
                }
            },
            .vector, .list => {
                const rows = seqItems(payoffs) orelse return;
                for (rows) |row| {
                    if (!row.isObj()) continue;
                    const row_obj = row.asObj();
                    if (row_obj.kind != .map) continue;
                    const player = mapGetByNames(row_obj, gc, &.{ "player" }) orelse Value.makeNil();
                    const amount_val = mapGetByNames(row_obj, gc, &.{ "payoff", "amount" }) orelse continue;
                    const amount = amount_val.asNumber() orelse continue;
                    try info.adjustments.append(gc.allocator, .{
                        .player = player,
                        .amount = amount,
                        .is_global = player.isNil(),
                    });
                }
            },
            else => {},
        }
        return;
    }

    if (mapGetByNames(attrs, gc, &.{ "payoff", "amount" })) |raw| {
        const amount = raw.asNumber() orelse return;
        const player = mapGetByNames(attrs, gc, &.{ "player" }) orelse Value.makeNil();
        try info.adjustments.append(gc.allocator, .{
            .player = player,
            .amount = amount,
            .is_global = player.isNil(),
        });
    }
}

fn collectStrategicInfo(diag: Value, gc: *GC, info: *StrategicInfo) !void {
    if (!diag.isObj()) return;
    const obj = diag.asObj();
    if (obj.kind != .map) return;
    const tag_val = mapGetByKeyword(obj, gc, "tag") orelse return;
    const tag_name = valueName(tag_val, gc) orelse return;

    if (std.mem.eql(u8, tag_name, "box") or std.mem.eql(u8, tag_name, "generator")) {
        const attrs_val = mapGetByKeyword(obj, gc, "attrs") orelse return;
        if (!attrs_val.isObj()) return;
        const attrs = attrs_val.asObj();
        if (attrs.kind != .map) return;
        const atomic_val = mapGetByKeyword(attrs, gc, "atomic") orelse return;
        const atomic = valueName(atomic_val, gc) orelse return;

        if (std.mem.eql(u8, atomic, "decision") or
            std.mem.eql(u8, atomic, "decision-no-obs") or
            std.mem.eql(u8, atomic, "dependent-decision"))
        {
            const name_val = mapGetByKeyword(obj, gc, "name") orelse Value.makeNil();
            const action_space = mapGetByNames(attrs, gc, &.{ "action-space", "actions" }) orelse Value.makeNil();
            const payoff_table = mapGetByNames(attrs, gc, &.{ "payoff-table" }) orelse Value.makeNil();
            const default_action = mapGetByNames(attrs, gc, &.{ "default-action" }) orelse firstSeqItem(action_space) orelse Value.makeNil();
            const epsilon = if (mapGetByNames(attrs, gc, &.{ "epsilon" })) |v| v.asNumber() orelse 0.0 else 0.0;
            if (payoff_table.isNil()) info.missing_payoff_tables += 1;
            try info.decisions.append(gc.allocator, .{
                .atomic = atomic,
                .name = name_val,
                .player = mapGetByNames(attrs, gc, &.{ "player" }) orelse Value.makeNil(),
                .action_space = action_space,
                .payoff_table = payoff_table,
                .observation_space = mapGetByNames(attrs, gc, &.{ "observation-space", "observations" }) orelse Value.makeNil(),
                .default_action = default_action,
                .observation_hint = mapGetByNames(attrs, gc, &.{ "observation", "context" }) orelse Value.makeNil(),
                .state_hint = mapGetByNames(attrs, gc, &.{ "state", "unobserved-state" }) orelse Value.makeNil(),
                .epsilon = epsilon,
            });
            return;
        }

        if (std.mem.eql(u8, atomic, "discount")) {
            if (mapGetByNames(attrs, gc, &.{ "discount-factor", "factor", "discount" })) |v| {
                if (v.asNumber()) |n| info.discount_factor *= n;
            }
            return;
        }

        if (std.mem.eql(u8, atomic, "add-payoffs")) {
            try collectPayoffAdjustments(attrs, info, gc);
            return;
        }

        return;
    }

    if (std.mem.eql(u8, tag_name, "seq") or std.mem.eql(u8, tag_name, "tensor")) {
        const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return;
        const parts = seqItems(parts_val) orelse return;
        for (parts) |part| try collectStrategicInfo(part, gc, info);
    }
}

fn lookupField(container: Value, gc: *GC, key: []const u8) ?Value {
    if (!container.isObj()) return null;
    const obj = container.asObj();
    if (obj.kind != .map) return null;
    return mapGetByKeyword(obj, gc, key) orelse mapGetByName(obj, gc, key);
}

fn lookupPlayerBinding(container: Value, player: Value, gc: *GC) ?Value {
    if (!container.isObj()) return null;
    const obj = container.asObj();
    if (obj.kind != .map) return null;
    if (mapGetByValue(obj, gc, player)) |v| return v;
    const name = valueName(player, gc) orelse return null;
    return mapGetByName(obj, gc, name);
}

fn numberOrNil(n: ?f64) Value {
    if (n) |value_num| return Value.makeFloat(value_num);
    return Value.makeNil();
}

fn candidateActions(spec: DecisionSpec, gc: *GC) !std.ArrayListUnmanaged(Value) {
    var items = std.ArrayListUnmanaged(Value).empty;
    if (seqItems(spec.action_space)) |actions| {
        for (actions) |action| try appendDistinct(&items, action, gc);
    }
    if (spec.payoff_table.isObj()) {
        if (seqItems(spec.payoff_table)) |rows| {
            for (rows) |row| {
                if (!row.isObj()) continue;
                const row_obj = row.asObj();
                if (row_obj.kind != .map) continue;
                const action = mapGetByNames(row_obj, gc, &.{ "action", "move", "strategy" }) orelse continue;
                try appendDistinct(&items, action, gc);
            }
        } else {
            const table = spec.payoff_table.asObj();
            if (table.kind == .map) {
                for (table.data.map.keys.items) |action| {
                    try appendDistinct(&items, action, gc);
                }
            }
        }
    }
    return items;
}

fn stateForDecision(state_source: Value, spec: DecisionSpec, gc: *GC) Value {
    if (!state_source.isNil()) {
        if (lookupPlayerBinding(state_source, spec.player, gc)) |bound| return bound;
        return state_source;
    }
    return spec.state_hint;
}

fn observationForDecision(observations: Value, spec: DecisionSpec, gc: *GC) Value {
    if (!observations.isNil()) {
        if (lookupPlayerBinding(observations, spec.player, gc)) |bound| return bound;
    }
    return spec.observation_hint;
}

fn rowMatches(row_obj: *Obj, action: Value, observation: Value, state: Value, gc: *GC) bool {
    const row_action = mapGetByNames(row_obj, gc, &.{ "action", "move", "strategy" }) orelse return false;
    if (!semantics.structuralEq(row_action, action, gc)) return false;

    if (mapGetByNames(row_obj, gc, &.{ "observation", "context" })) |row_observation| {
        if (observation.isNil()) return false;
        if (!semantics.structuralEq(row_observation, observation, gc)) return false;
    }

    if (mapGetByNames(row_obj, gc, &.{ "state", "unobserved-state" })) |row_state| {
        if (state.isNil()) return false;
        if (!semantics.structuralEq(row_state, state, gc)) return false;
    }

    return true;
}

fn payoffFromRow(row_obj: *Obj, player: Value, gc: *GC) ?f64 {
    if (mapGetByNames(row_obj, gc, &.{ "payoff", "utility" })) |v| {
        return v.asNumber();
    }
    if (mapGetByNames(row_obj, gc, &.{ "payoffs" })) |v| {
        if (v.asNumber()) |n| return n;
        if (!v.isObj()) return null;
        const obj = v.asObj();
        if (obj.kind != .map) return null;
        const player_val = mapGetByValue(obj, gc, player) orelse blk: {
            const player_name = valueName(player, gc) orelse break :blk Value.makeNil();
            break :blk mapGetByName(obj, gc, player_name) orelse Value.makeNil();
        };
        if (player_val.isNil()) return null;
        return player_val.asNumber();
    }
    return null;
}

fn payoffForAction(spec: DecisionSpec, action: Value, observation: Value, state: Value, gc: *GC) ?f64 {
    if (spec.payoff_table.isNil()) return null;
    if (!spec.payoff_table.isObj()) return null;

    if (seqItems(spec.payoff_table)) |rows| {
        for (rows) |row| {
            if (!row.isObj()) continue;
            const row_obj = row.asObj();
            if (row_obj.kind != .map) continue;
            if (!rowMatches(row_obj, action, observation, state, gc)) continue;
            if (payoffFromRow(row_obj, spec.player, gc)) |payoff| return payoff;
        }
        return null;
    }

    const table = spec.payoff_table.asObj();
    if (table.kind != .map) return null;
    const direct = mapGetByValue(table, gc, action) orelse return null;
    if (direct.asNumber()) |n| return n;
    if (!direct.isObj()) return null;
    const sub = direct.asObj();
    if (sub.kind != .map) return null;
    if (!observation.isNil()) {
        if (mapGetByValue(sub, gc, observation)) |v| return v.asNumber();
        const obs_name = valueName(observation, gc) orelse return null;
        if (mapGetByName(sub, gc, obs_name)) |v| return v.asNumber();
    }
    return null;
}

fn playerAdjustment(info: *const StrategicInfo, player: Value, gc: *GC) f64 {
    var total: f64 = 0.0;
    for (info.adjustments.items) |adj| {
        if (adj.is_global or semantics.structuralEq(adj.player, player, gc) or blk: {
            const adj_name = valueName(adj.player, gc) orelse break :blk false;
            const player_name = valueName(player, gc) orelse break :blk false;
            break :blk std.mem.eql(u8, adj_name, player_name);
        }) {
            total += adj.amount;
        }
    }
    return total;
}

fn transformedPayoff(raw: f64, info: *const StrategicInfo, player: Value, gc: *GC) f64 {
    return raw * info.discount_factor + playerAdjustment(info, player, gc);
}

fn decisionDiagnosticValue(
    spec: DecisionSpec,
    strategies: Value,
    observations: Value,
    state_source: Value,
    info: *const StrategicInfo,
    gc: *GC,
) !DecisionDiagnostic {
    var actions = try candidateActions(spec, gc);
    defer actions.deinit(gc.allocator);

    var current_action = lookupPlayerBinding(strategies, spec.player, gc) orelse spec.default_action;
    if (current_action.isNil() and actions.items.len > 0) current_action = actions.items[0];

    const observation = observationForDecision(observations, spec, gc);
    const state = stateForDecision(state_source, spec, gc);

    var current_payoff: ?f64 = null;
    if (!current_action.isNil()) {
        if (payoffForAction(spec, current_action, observation, state, gc)) |raw| {
            current_payoff = transformedPayoff(raw, info, spec.player, gc);
        }
    }

    var optimal_action = current_action;
    var optimal_payoff = current_payoff;
    for (actions.items) |candidate| {
        const raw = payoffForAction(spec, candidate, observation, state, gc) orelse continue;
        const transformed = transformedPayoff(raw, info, spec.player, gc);
        if (optimal_payoff == null or transformed > optimal_payoff.? + spec.epsilon) {
            optimal_payoff = transformed;
            optimal_action = candidate;
        }
    }

    var profitable = false;
    var equilibrium = false;
    var missing_payoff = false;
    var reason: []const u8 = "already-optimal";

    if (actions.items.len == 0) {
        reason = "missing-action-space";
        missing_payoff = true;
    } else if (optimal_payoff == null) {
        reason = "missing-payoff-table";
        missing_payoff = true;
    } else if (current_payoff == null) {
        reason = "missing-current-payoff";
        missing_payoff = true;
    } else if (optimal_payoff.? > current_payoff.? + spec.epsilon) {
        profitable = true;
        reason = "profitable-deviation";
    } else {
        equilibrium = true;
        reason = "already-optimal";
    }

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "equilibrium?", Value.makeBool(equilibrium));
    try addKV(obj, gc, "player", spec.player);
    try addKV(obj, gc, "decision", spec.name);
    try addKV(obj, gc, "atomic", try kw(gc, spec.atomic));
    try addKV(obj, gc, "strategy", current_action);
    try addKV(obj, gc, "current-action", current_action);
    try addKV(obj, gc, "optimal-move", optimal_action);
    try addKV(obj, gc, "optimal-action", optimal_action);
    try addKV(obj, gc, "payoff", numberOrNil(current_payoff));
    try addKV(obj, gc, "current-payoff", numberOrNil(current_payoff));
    try addKV(obj, gc, "optimal-payoff", numberOrNil(optimal_payoff));
    try addKV(obj, gc, "context", observation);
    try addKV(obj, gc, "state", state);
    try addKV(obj, gc, "unobserved-state", state);
    try addKV(obj, gc, "discount-factor", Value.makeFloat(info.discount_factor));
    try addKV(obj, gc, "payoff-adjustment", Value.makeFloat(playerAdjustment(info, spec.player, gc)));
    try addKV(obj, gc, "profitable-deviation?", Value.makeBool(profitable));
    try addKV(obj, gc, "payoff-known?", Value.makeBool(!missing_payoff));
    try addKV(obj, gc, "reason", try kw(gc, reason));

    return .{
        .value = Value.makeObj(obj),
        .equilibrium = equilibrium,
        .profitable = profitable,
        .missing_payoff = missing_payoff,
    };
}

fn diagnosticsValueFor(info: *const StrategicInfo, trace_obj: *Obj, gc: *GC) !DiagnosticsSummary {
    const input = mapGetByKeyword(trace_obj, gc, "input") orelse Value.makeNil();
    const context = mapGetByKeyword(trace_obj, gc, "context") orelse Value.makeNil();
    const strategies = lookupField(context, gc, "strategies") orelse lookupField(input, gc, "strategies") orelse Value.makeNil();
    const observations = lookupField(context, gc, "observations") orelse lookupField(input, gc, "observations") orelse Value.makeNil();
    const state = lookupField(context, gc, "state") orelse lookupField(input, gc, "state") orelse Value.makeNil();

    var diagnostics = std.ArrayListUnmanaged(Value).empty;
    defer diagnostics.deinit(gc.allocator);
    var profitable = std.ArrayListUnmanaged(Value).empty;
    defer profitable.deinit(gc.allocator);

    var equilibrium = true;
    var missing_payoff_count: usize = 0;

    for (info.decisions.items) |spec| {
        const diag = try decisionDiagnosticValue(spec, strategies, observations, state, info, gc);
        try diagnostics.append(gc.allocator, diag.value);
        if (diag.profitable) try profitable.append(gc.allocator, diag.value);
        if (!diag.equilibrium) equilibrium = false;
        if (diag.missing_payoff) missing_payoff_count += 1;
    }

    return .{
        .diagnostics = try vectorValue(gc, diagnostics.items),
        .profitable = try vectorValue(gc, profitable.items),
        .equilibrium = if (info.decisions.items.len == 0) true else equilibrium,
        .count = info.decisions.items.len,
        .profitable_count = profitable.items.len,
        .missing_payoff_count = missing_payoff_count,
    };
}

fn strategicSurfaceValue(scan: Scan, info: *const StrategicInfo, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "decisions", Value.makeInt(@intCast(scan.decision_boxes)));
    try addKV(obj, gc, "dependent-decisions", Value.makeInt(@intCast(scan.dependent_decision_boxes)));
    try addKV(obj, gc, "nature", Value.makeInt(@intCast(scan.nature_boxes)));
    try addKV(obj, gc, "lift-stochastic", Value.makeInt(@intCast(scan.stochastic_boxes)));
    try addKV(obj, gc, "forward-functions", Value.makeInt(@intCast(scan.forward_function_boxes)));
    try addKV(obj, gc, "backward-functions", Value.makeInt(@intCast(scan.backward_function_boxes)));
    try addKV(obj, gc, "from-functions", Value.makeInt(@intCast(scan.lens_boxes)));
    try addKV(obj, gc, "discounts", Value.makeInt(@intCast(scan.discount_boxes)));
    try addKV(obj, gc, "payoff-boxes", Value.makeInt(@intCast(scan.payoff_boxes)));
    try addKV(obj, gc, "discount-factor", Value.makeFloat(info.discount_factor));
    try addKV(obj, gc, "missing-payoff-tables", Value.makeInt(@intCast(info.missing_payoff_tables)));
    return Value.makeObj(obj);
}

pub fn openGameProfileFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len > 1) return error.ArityError;
    const seed = if (args.len == 1 and args[0].isInt()) args[0].asInt() else default_seed;
    return profileValue(seed, gc);
}

pub fn openGameParityFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return openGameParityValue(gc);
}

pub fn playFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len == 0 or args.len > 4) return error.ArityError;
    const game = args[0];
    const input = if (args.len >= 2) args[1] else Value.makeNil();
    const context = if (args.len >= 3) args[2] else Value.makeNil();
    const opts: ?Value = if (args.len == 4) args[3] else null;
    return playValueFor(game, input, context, opts, gc, env, res);
}

pub fn evaluateFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len == 0 or args.len > 2) return error.ArityError;

    const trace = if (isTraceMap(args[0], gc))
        args[0]
    else
        try playValueFor(args[0], Value.makeNil(), Value.makeNil(), if (args.len == 2) args[1] else null, gc, env, res);

    const trace_obj = trace.asObj();
    const summary = mapGetByKeyword(trace_obj, gc, "summary") orelse return error.TypeError;
    if (!summary.isObj()) return error.TypeError;
    const summary_obj = summary.asObj();
    if (summary_obj.kind != .map) return error.TypeError;
    const normalized = mapGetByKeyword(summary_obj, gc, "normalized") orelse return error.TypeError;

    var scan = Scan{};
    try scanDiagram(normalized, gc, &scan);
    const closed = scan.semanticallyClosed();

    var strategic = StrategicInfo{};
    defer strategic.deinit(gc.allocator);
    try collectStrategicInfo(normalized, gc, &strategic);
    const diagnostics = try diagnosticsValueFor(&strategic, trace_obj, gc);
    const equilibrium = if (diagnostics.count > 0) diagnostics.equilibrium else closed;

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "ok", Value.makeBool(true));
    try addKV(obj, gc, "profile-id", mapGetByKeyword(trace_obj, gc, "profile-id") orelse try strv(gc, profileIdForSeed(default_seed)));
    try addKV(obj, gc, "seed", mapGetByKeyword(trace_obj, gc, "seed") orelse Value.makeInt(default_seed));
    try addKV(obj, gc, "agreement", Value.makeBool(true));
    try addKV(obj, gc, "analysis-mode", try kw(gc, if (diagnostics.count > 0) "strategic" else "structural"));
    try addKV(obj, gc, "equilibrium?", Value.makeBool(equilibrium));
    try addKV(obj, gc, "equilibria", try equilibriaValue(scan, diagnostics, closed, gc));
    try addKV(obj, gc, "diagnostics", diagnostics.diagnostics);
    try addKV(obj, gc, "profitable-deviations", diagnostics.profitable);
    try addKV(obj, gc, "structural-payoffs", try structuralPayoffsValue(scan, closed, gc));
    try addKV(obj, gc, "risks", try risksValue(scan, diagnostics, &strategic, gc));
    try addKV(obj, gc, "snipes", try risksValue(scan, diagnostics, &strategic, gc));
    try addKV(obj, gc, "closure", try closureValue(scan, gc));
    try addKV(obj, gc, "role-counts", try roleCountsValue(scan, gc));
    try addKV(obj, gc, "effect-counts", try effectCountsValue(scan, gc));
    try addKV(obj, gc, "strategic-surface", try strategicSurfaceValue(scan, &strategic, gc));
    try addKV(obj, gc, "parity", try openGameParityValue(gc));
    try addKV(obj, gc, "benchmarks", try benchmarksValue(gc));
    try addKV(obj, gc, "trace", trace);
    return Value.makeObj(obj);
}

pub fn openGameDiagnosticsFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    const result = try evaluateFn(args, gc, env, res);
    const obj = result.asObj();
    return mapGetByKeyword(obj, gc, "diagnostics") orelse try emptyVectorValue(gc);
}

pub fn openGameIsEquilibriumFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    const result = try evaluateFn(args, gc, env, res);
    const obj = result.asObj();
    return mapGetByKeyword(obj, gc, "equilibrium?") orelse Value.makeBool(false);
}

pub fn openGameDecisionFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    const opts: ?Value = if (args.len == 4) args[3] else null;
    const dom = try boundaryValueFromOpts(opts, gc, "dom");
    const cod = try boundaryValueFromOpts(opts, gc, "cod");
    const actions = try seqToVectorValue(args[2], gc);
    const default_action = lookupOpt(opts, gc, "default-action") orelse firstSeqItem(actions) orelse Value.makeNil();
    const extra = [_]AttrPair{
        .{ .key = "player", .value = args[1] },
        .{ .key = "action-space", .value = actions },
        .{ .key = "default-action", .value = default_action },
    };
    return buildOpenGameBox(args[0], "decision", dom, cod, opts, &extra, gc, env, res);
}

pub fn openGameDecisionNoObsFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    const opts: ?Value = if (args.len == 4) args[3] else null;
    const dom = try boundaryValueFromOpts(opts, gc, "dom");
    const cod = try boundaryValueFromOpts(opts, gc, "cod");
    const actions = try seqToVectorValue(args[2], gc);
    const default_action = lookupOpt(opts, gc, "default-action") orelse firstSeqItem(actions) orelse Value.makeNil();
    const extra = [_]AttrPair{
        .{ .key = "player", .value = args[1] },
        .{ .key = "action-space", .value = actions },
        .{ .key = "default-action", .value = default_action },
    };
    return buildOpenGameBox(args[0], "decision-no-obs", dom, cod, opts, &extra, gc, env, res);
}

pub fn openGameDependentDecisionFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 4 and args.len != 5) return error.ArityError;
    const opts: ?Value = if (args.len == 5) args[4] else null;
    const dom = try boundaryValueFromOpts(opts, gc, "dom");
    const cod = try boundaryValueFromOpts(opts, gc, "cod");
    const observations = try seqToVectorValue(args[2], gc);
    const actions = try seqToVectorValue(args[3], gc);
    const default_action = lookupOpt(opts, gc, "default-action") orelse firstSeqItem(actions) orelse Value.makeNil();
    const extra = [_]AttrPair{
        .{ .key = "player", .value = args[1] },
        .{ .key = "observation-space", .value = observations },
        .{ .key = "action-space", .value = actions },
        .{ .key = "default-action", .value = default_action },
    };
    return buildOpenGameBox(args[0], "dependent-decision", dom, cod, opts, &extra, gc, env, res);
}

pub fn openGameForwardFunctionFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    const opts: ?Value = if (args.len == 4) args[3] else null;
    const dom = try seqToVectorValue(args[1], gc);
    const cod = try seqToVectorValue(args[2], gc);
    return buildOpenGameBox(args[0], "forward-function", dom, cod, opts, &.{}, gc, env, res);
}

pub fn openGameBackwardFunctionFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    const opts: ?Value = if (args.len == 4) args[3] else null;
    const dom = try seqToVectorValue(args[1], gc);
    const cod = try seqToVectorValue(args[2], gc);
    return buildOpenGameBox(args[0], "backward-function", dom, cod, opts, &.{}, gc, env, res);
}

pub fn openGameFromFunctionsFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    const opts: ?Value = if (args.len == 4) args[3] else null;
    const dom = try seqToVectorValue(args[1], gc);
    const cod = try seqToVectorValue(args[2], gc);
    return buildOpenGameBox(args[0], "from-functions", dom, cod, opts, &.{}, gc, env, res);
}

pub fn openGameNatureFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 2 and args.len != 3) return error.ArityError;
    const opts: ?Value = if (args.len == 3) args[2] else null;
    const dom = try boundaryValueFromOpts(opts, gc, "dom");
    const cod = try boundaryValueFromOpts(opts, gc, "cod");
    const extra = [_]AttrPair{
        .{ .key = "distribution", .value = args[1] },
    };
    return buildOpenGameBox(args[0], "nature", dom, cod, opts, &extra, gc, env, res);
}

pub fn openGameLiftStochasticFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 2 and args.len != 3) return error.ArityError;
    const opts: ?Value = if (args.len == 3) args[2] else null;
    const dom = try boundaryValueFromOpts(opts, gc, "dom");
    const cod = try boundaryValueFromOpts(opts, gc, "cod");
    const extra = [_]AttrPair{
        .{ .key = "distribution", .value = args[1] },
    };
    return buildOpenGameBox(args[0], "lift-stochastic", dom, cod, opts, &extra, gc, env, res);
}

pub fn openGameDiscountFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 2 and args.len != 3) return error.ArityError;
    const factor = args[1].asNumber() orelse return error.TypeError;
    const opts: ?Value = if (args.len == 3) args[2] else null;
    const dom = try boundaryValueFromOpts(opts, gc, "dom");
    const cod = try boundaryValueFromOpts(opts, gc, "cod");
    const extra = [_]AttrPair{
        .{ .key = "discount-factor", .value = Value.makeFloat(factor) },
    };
    return buildOpenGameBox(args[0], "discount", dom, cod, opts, &extra, gc, env, res);
}

pub fn openGameAddPayoffsFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    if (args.len != 2 and args.len != 3) return error.ArityError;
    const opts: ?Value = if (args.len == 3) args[2] else null;
    const dom = try boundaryValueFromOpts(opts, gc, "dom");
    const cod = try boundaryValueFromOpts(opts, gc, "cod");
    const extra = [_]AttrPair{
        .{ .key = "payoffs", .value = args[1] },
    };
    return buildOpenGameBox(args[0], "add-payoffs", dom, cod, opts, &extra, gc, env, res);
}

pub fn openGameSeqFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    return monoidal_diagram.diagramSeqFn(args, gc, env, res);
}

pub fn openGameTensorFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    return monoidal_diagram.diagramTensorFn(args, gc, env, res);
}

pub fn openGameSequentialFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    return monoidal_diagram.diagramSeqFn(args, gc, env, res);
}

pub fn openGameSimultaneousFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    return monoidal_diagram.diagramTensorFn(args, gc, env, res);
}

test "open game play returns seed42 world/coworld closure trace" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const context_attrs = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "layer", try kw(&gc, "contextad"));
        try addKV(obj, &gc, "effect-class", try kw(&gc, "readonly"));
        try addKV(obj, &gc, "seed", Value.makeInt(default_seed));
        break :blk Value.makeObj(obj);
    };
    const world_attrs = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "semantics", try kw(&gc, "open-game"));
        try addKV(obj, &gc, "role", try kw(&gc, "world"));
        break :blk Value.makeObj(obj);
    };
    const coworld_attrs = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "semantics", try kw(&gc, "open-game"));
        try addKV(obj, &gc, "role", try kw(&gc, "coworld"));
        break :blk Value.makeObj(obj);
    };
    const closure_attrs = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "semantics", try kw(&gc, "closure"));
        try addKV(obj, &gc, "agreement-required", Value.makeBool(true));
        break :blk Value.makeObj(obj);
    };

    var bootstrap_args = [_]Value{
        try strv(&gc, "bootstrap-context"),
        try vectorValue(&gc, &.{ try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "x") }) }),
        try vectorValue(&gc, &.{
            try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "world"), try kw(&gc, "x") }),
            try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "coworld"), try kw(&gc, "x") }),
        }),
        context_attrs,
    };
    const bootstrap = try monoidal_diagram.diagramBoxFn(bootstrap_args[0..], &gc, &env, &resources);

    var world_args = [_]Value{
        try strv(&gc, "world-play"),
        try vectorValue(&gc, &.{ try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "world"), try kw(&gc, "x") }) }),
        try vectorValue(&gc, &.{ try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "world"), try kw(&gc, "y") }) }),
        world_attrs,
    };
    const world_box = try monoidal_diagram.diagramBoxFn(world_args[0..], &gc, &env, &resources);

    var coworld_args = [_]Value{
        try strv(&gc, "coworld-coplay"),
        try vectorValue(&gc, &.{ try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "coworld"), try kw(&gc, "x") }) }),
        try vectorValue(&gc, &.{ try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "coworld"), try kw(&gc, "r") }) }),
        coworld_attrs,
    };
    const coworld_box = try monoidal_diagram.diagramBoxFn(coworld_args[0..], &gc, &env, &resources);

    var tensor_args = [_]Value{ world_box, coworld_box };
    const tensor = try monoidal_diagram.diagramTensorFn(tensor_args[0..], &gc, &env, &resources);

    var close_args = [_]Value{
        try strv(&gc, "close-world"),
        try vectorValue(&gc, &.{
            try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "world"), try kw(&gc, "y") }),
            try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "coworld"), try kw(&gc, "r") }),
        }),
        try vectorValue(&gc, &.{ try vectorValue(&gc, &.{ try kw(&gc, "ctx"), try kw(&gc, "closed"), try kw(&gc, "payoff-trace") }) }),
        closure_attrs,
    };
    const close = try monoidal_diagram.diagramBoxFn(close_args[0..], &gc, &env, &resources);

    var seq_args = [_]Value{ bootstrap, tensor, close };
    const game = try monoidal_diagram.diagramSeqFn(seq_args[0..], &gc, &env, &resources);
    var play_args = [_]Value{game};
    const trace = try playFn(play_args[0..], &gc, &env, &resources);

    try std.testing.expect(isTraceMap(trace, &gc));
    const trace_obj = trace.asObj();
    const seed_val = mapGetByKeyword(trace_obj, &gc, "seed") orelse return error.TestUnexpectedResult;
    try std.testing.expect(seed_val.isInt());
    try std.testing.expectEqual(default_seed, seed_val.asInt());

    const companion_val = mapGetByKeyword(trace_obj, &gc, "companion-semantics") orelse return error.TestUnexpectedResult;
    try std.testing.expect(sameName(companion_val, &gc, "thread-peval"));

    const closure_val = mapGetByKeyword(trace_obj, &gc, "closure") orelse return error.TestUnexpectedResult;
    const closure_obj = closure_val.asObj();
    const closed_val = mapGetByKeyword(closure_obj, &gc, "semantically-closed?") orelse return error.TestUnexpectedResult;
    try std.testing.expect(boolValue(closed_val) == true);
}

test "open game evaluate reports missing coworld as a risk" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const world_attrs = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "semantics", try kw(&gc, "open-game"));
        try addKV(obj, &gc, "role", try kw(&gc, "world"));
        break :blk Value.makeObj(obj);
    };

    var box_args = [_]Value{
        try strv(&gc, "world-only"),
        try vectorValue(&gc, &.{ try kw(&gc, "X") }),
        try vectorValue(&gc, &.{ try kw(&gc, "Y") }),
        world_attrs,
    };
    const game = try monoidal_diagram.diagramBoxFn(box_args[0..], &gc, &env, &resources);
    var eval_args = [_]Value{game};
    const result = try evaluateFn(eval_args[0..], &gc, &env, &resources);
    const obj = result.asObj();
    const risks_val = mapGetByKeyword(obj, &gc, "risks") orelse return error.TestUnexpectedResult;
    const risks = seqItems(risks_val) orelse return error.TestUnexpectedResult;

    var found = false;
    for (risks) |risk| {
        if (sameName(risk, &gc, "missing-coworld")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "open game decision diagnostics detect profitable deviation" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const cooperate = try kw(&gc, "cooperate");
    const defect = try kw(&gc, "defect");
    const alice = try kw(&gc, "alice");

    const row_a = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "action", cooperate);
        try addKV(obj, &gc, "payoff", Value.makeInt(1));
        break :blk Value.makeObj(obj);
    };
    const row_b = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "action", defect);
        try addKV(obj, &gc, "payoff", Value.makeInt(3));
        break :blk Value.makeObj(obj);
    };
    const payoff_table = try vectorValue(&gc, &.{ row_a, row_b });

    const opts = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "payoff-table", payoff_table);
        try addKV(obj, &gc, "default-action", cooperate);
        break :blk Value.makeObj(obj);
    };

    var decision_args = [_]Value{
        try strv(&gc, "prisoners-choice"),
        alice,
        try vectorValue(&gc, &.{ cooperate, defect }),
        opts,
    };
    const decision = try openGameDecisionFn(decision_args[0..], &gc, &env, &resources);

    const strategies = blk: {
        const obj = try gc.allocObj(.map);
        try addRawKV(obj, &gc, alice, cooperate);
        break :blk Value.makeObj(obj);
    };
    const input = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "strategies", strategies);
        break :blk Value.makeObj(obj);
    };

    var play_args = [_]Value{ decision, input };
    const trace = try playFn(play_args[0..], &gc, &env, &resources);
    var eval_args = [_]Value{trace};
    const report = try evaluateFn(eval_args[0..], &gc, &env, &resources);
    const report_obj = report.asObj();

    const equilibrium_val = mapGetByKeyword(report_obj, &gc, "equilibrium?") orelse return error.TestUnexpectedResult;
    try std.testing.expect(boolValue(equilibrium_val) == false);

    const diagnostics_val = mapGetByKeyword(report_obj, &gc, "diagnostics") orelse return error.TestUnexpectedResult;
    const diagnostics = seqItems(diagnostics_val) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);

    const diag_obj = diagnostics[0].asObj();
    const profitable_val = mapGetByKeyword(diag_obj, &gc, "profitable-deviation?") orelse return error.TestUnexpectedResult;
    try std.testing.expect(boolValue(profitable_val) == true);

    const optimal_val = mapGetByKeyword(diag_obj, &gc, "optimal-action") orelse return error.TestUnexpectedResult;
    try std.testing.expect(semantics.structuralEq(optimal_val, defect, &gc));
}

test "open game dependent decision respects observation-specific payoffs" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const alice = try kw(&gc, "alice");
    const rain = try kw(&gc, "rain");
    const umbrella = try kw(&gc, "umbrella");
    const no_umbrella = try kw(&gc, "no-umbrella");

    const rows = blk: {
        const a = try gc.allocObj(.map);
        try addKV(a, &gc, "observation", rain);
        try addKV(a, &gc, "action", umbrella);
        try addKV(a, &gc, "payoff", Value.makeInt(5));

        const b = try gc.allocObj(.map);
        try addKV(b, &gc, "observation", rain);
        try addKV(b, &gc, "action", no_umbrella);
        try addKV(b, &gc, "payoff", Value.makeInt(1));

        break :blk try vectorValue(&gc, &.{ Value.makeObj(a), Value.makeObj(b) });
    };

    const opts = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "payoff-table", rows);
        break :blk Value.makeObj(obj);
    };

    var decision_args = [_]Value{
        try strv(&gc, "weather-choice"),
        alice,
        try vectorValue(&gc, &.{ rain }),
        try vectorValue(&gc, &.{ umbrella, no_umbrella }),
        opts,
    };
    const decision = try openGameDependentDecisionFn(decision_args[0..], &gc, &env, &resources);

    const strategies = blk: {
        const obj = try gc.allocObj(.map);
        try addRawKV(obj, &gc, alice, no_umbrella);
        break :blk Value.makeObj(obj);
    };
    const observations = blk: {
        const obj = try gc.allocObj(.map);
        try addRawKV(obj, &gc, alice, rain);
        break :blk Value.makeObj(obj);
    };
    const input = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "strategies", strategies);
        try addKV(obj, &gc, "observations", observations);
        break :blk Value.makeObj(obj);
    };

    var play_args = [_]Value{ decision, input };
    const trace = try playFn(play_args[0..], &gc, &env, &resources);
    var eval_args = [_]Value{trace};
    const report = try evaluateFn(eval_args[0..], &gc, &env, &resources);
    const report_obj = report.asObj();
    const diagnostics_val = mapGetByKeyword(report_obj, &gc, "diagnostics") orelse return error.TestUnexpectedResult;
    const diagnostics = seqItems(diagnostics_val) orelse return error.TestUnexpectedResult;
    const diag_obj = diagnostics[0].asObj();

    const optimal_val = mapGetByKeyword(diag_obj, &gc, "optimal-action") orelse return error.TestUnexpectedResult;
    try std.testing.expect(semantics.structuralEq(optimal_val, umbrella, &gc));
}

test "open game discount and add-payoffs transform diagnostics" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const alice = try kw(&gc, "alice");
    const low = try kw(&gc, "low");
    const high = try kw(&gc, "high");

    const row_low = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "action", low);
        try addKV(obj, &gc, "payoff", Value.makeInt(1));
        break :blk Value.makeObj(obj);
    };
    const row_high = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "action", high);
        try addKV(obj, &gc, "payoff", Value.makeInt(3));
        break :blk Value.makeObj(obj);
    };
    const payoff_table = try vectorValue(&gc, &.{ row_low, row_high });

    const decision_opts = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "payoff-table", payoff_table);
        break :blk Value.makeObj(obj);
    };
    var decision_args = [_]Value{
        try strv(&gc, "pricing"),
        alice,
        try vectorValue(&gc, &.{ low, high }),
        decision_opts,
    };
    const decision = try openGameDecisionFn(decision_args[0..], &gc, &env, &resources);

    var discount_args = [_]Value{
        try strv(&gc, "discount"),
        Value.makeFloat(0.5),
    };
    const discount = try openGameDiscountFn(discount_args[0..], &gc, &env, &resources);

    const payoffs = blk: {
        const obj = try gc.allocObj(.map);
        try addRawKV(obj, &gc, alice, Value.makeInt(2));
        break :blk Value.makeObj(obj);
    };
    var add_payoffs_args = [_]Value{
        try strv(&gc, "bonus"),
        payoffs,
    };
    const add_payoffs = try openGameAddPayoffsFn(add_payoffs_args[0..], &gc, &env, &resources);

    var seq_args = [_]Value{ decision, discount, add_payoffs };
    const game = try openGameSeqFn(seq_args[0..], &gc, &env, &resources);

    const strategies = blk: {
        const obj = try gc.allocObj(.map);
        try addRawKV(obj, &gc, alice, low);
        break :blk Value.makeObj(obj);
    };
    const input = blk: {
        const obj = try gc.allocObj(.map);
        try addKV(obj, &gc, "strategies", strategies);
        break :blk Value.makeObj(obj);
    };

    var play_args = [_]Value{ game, input };
    const trace = try playFn(play_args[0..], &gc, &env, &resources);
    var eval_args = [_]Value{trace};
    const report = try evaluateFn(eval_args[0..], &gc, &env, &resources);
    const report_obj = report.asObj();
    const diagnostics_val = mapGetByKeyword(report_obj, &gc, "diagnostics") orelse return error.TestUnexpectedResult;
    const diagnostics = seqItems(diagnostics_val) orelse return error.TestUnexpectedResult;
    const diag_obj = diagnostics[0].asObj();

    const current_payoff = mapGetByKeyword(diag_obj, &gc, "current-payoff") orelse return error.TestUnexpectedResult;
    const optimal_payoff = mapGetByKeyword(diag_obj, &gc, "optimal-payoff") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.math.approxEqAbs(f64, current_payoff.asFloat(), 2.5, 1e-9));
    try std.testing.expect(std.math.approxEqAbs(f64, optimal_payoff.asFloat(), 3.5, 1e-9));
}
