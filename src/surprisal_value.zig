//! Clojure values for contextual surprisal. Records are portable descriptions,
//! not sealed proofs or capabilities. Revalidate every boundary; there is no
//! global handle table. Context (including revision) AND exact weights identify
//! a model. Native construction snapshots all vectors used in returned records.
const std = @import("std");
const kernel = @import("surprisal.zig");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

const Model = struct { context: Value, distribution: kernel.Distribution };
const Event = struct { model: Model, mask: u128 };
const Path = struct { model: Model, refinement: kernel.Refinement };
const Op = enum { model, event, whole, probability, bits, score, union_of, intersection, subset, refine, refinement_bits, compose };
const Builtin = struct { name: []const u8, function: *const fn ([]Value, *GC, *Env, *Resources) anyerror!Value };

pub const builtins = [_]Builtin{
    .{ .name = "surprisal/model", .function = Handler(.model).call },
    .{ .name = "surprisal/event", .function = Handler(.event).call },
    .{ .name = "surprisal/whole", .function = Handler(.whole).call },
    .{ .name = "surprisal/probability", .function = Handler(.probability).call },
    .{ .name = "surprisal/bits", .function = Handler(.bits).call },
    .{ .name = "surprisal/score", .function = Handler(.score).call },
    .{ .name = "surprisal/union", .function = Handler(.union_of).call },
    .{ .name = "surprisal/intersection", .function = Handler(.intersection).call },
    .{ .name = "surprisal/subset?", .function = Handler(.subset).call },
    .{ .name = "surprisal/refine", .function = Handler(.refine).call },
    .{ .name = "surprisal/refinement-bits", .function = Handler(.refinement_bits).call },
    .{ .name = "surprisal/compose", .function = Handler(.compose).call },
};

/// Used by the full core and by hosts that expose only this pure namespace.
pub fn register(env: *Env, gc: *GC) !void {
    for (builtins) |b| try @import("core.zig").registerBuiltin(b.name, b.function, env, gc);
}

fn Handler(comptime op: Op) type {
    return struct {
        fn call(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
            return dispatch(op, args, gc) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // The existing evaluators erase arbitrary builtin error names.
                // Return domain failures as explicit data so scripts can inspect
                // them, and never confuse invalid input with zero probability.
                else => {
                    const obj = try gc.allocObj(.map);
                    try put(obj, gc, "surprisal/error", try keyword(gc, @errorName(err)));
                    return Value.makeObj(obj);
                },
            };
        }
    };
}

fn keyword(gc: *GC, name: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(name));
}

fn put(obj: *Obj, gc: *GC, name: []const u8, v: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try keyword(gc, name));
    try obj.data.map.vals.append(gc.allocator, v);
}

fn field(v: Value, gc: *GC, name: []const u8) !Value {
    if (!v.isObj() or v.asObj().kind != .map) return error.InvalidRecord;
    const m = v.asObj().data.map;
    if (m.keys.items.len != m.vals.items.len or m.keys.items.len > 4) return error.InvalidRecord;
    var result: ?Value = null;
    for (m.keys.items, m.vals.items) |k, item| {
        if (k.isKeyword() and std.mem.eql(u8, gc.getString(k.asKeywordId()), name)) {
            if (result != null) return error.InvalidRecord;
            result = item;
        }
    }
    return result orelse error.InvalidRecord;
}

fn checkRecord(v: Value, gc: *GC, tag: []const u8) !void {
    const t = try field(v, gc, "surprisal/type");
    if (!t.isKeyword() or !std.mem.eql(u8, gc.getString(t.asKeywordId()), tag)) return error.InvalidRecord;
    if (v.asObj().data.map.keys.items.len != 3) return error.InvalidRecord;
}

fn vector(v: Value) ![]const Value {
    if (!v.isObj() or v.asObj().kind != .vector) return error.ExpectedVector;
    const items = v.asObj().data.vector.items.items;
    if (items.len > kernel.max_atoms) return error.TooManyAtoms;
    return items;
}

fn makeModel(context: Value, weights: Value) !Model {
    if (!context.isKeyword() and !context.isString()) return error.InvalidContext;
    const items = try vector(weights);
    var counts: [kernel.max_atoms]u64 = undefined;
    for (items, 0..) |w, i| {
        if (!w.isInt()) return error.ExpectedIntegerWeight;
        if (w.asInt() < 0) return error.NegativeWeight;
        counts[i] = @intCast(w.asInt());
    }
    return .{ .context = context, .distribution = try kernel.Distribution.init(counts[0..items.len]) };
}

fn readModel(v: Value, gc: *GC) !Model {
    try checkRecord(v, gc, "model");
    return makeModel(try field(v, gc, "context"), try field(v, gc, "weights"));
}

fn sameModel(a: *const Model, b: *const Model) !void {
    if (!Value.eql(a.context, b.context) or a.distribution.len != b.distribution.len or
        !std.mem.eql(u64, a.distribution.weights[0..a.distribution.len], b.distribution.weights[0..b.distribution.len]))
        return error.ModelMismatch;
}

fn readAtoms(model: *const Model, v: Value) !u128 {
    const items = try vector(v);
    var indices: [kernel.max_atoms]usize = undefined;
    for (items, 0..) |item, i| {
        if (!item.isInt()) return error.ExpectedIntegerIndex;
        if (item.asInt() < 0 or item.asInt() >= model.distribution.len) return error.AtomOutOfRange;
        indices[i] = @intCast(item.asInt());
    }
    return model.distribution.event(indices[0..items.len]);
}

fn readEvent(v: Value, gc: *GC) !Event {
    try checkRecord(v, gc, "event");
    const m = try readModel(try field(v, gc, "model"), gc);
    return .{ .model = m, .mask = try readAtoms(&m, try field(v, gc, "atoms")) };
}

fn readPath(v: Value, gc: *GC) !Path {
    try checkRecord(v, gc, "refinement");
    const coarse = try readEvent(try field(v, gc, "coarse"), gc);
    const fine = try readEvent(try field(v, gc, "fine"), gc);
    try sameModel(&coarse.model, &fine.model);
    return .{ .model = coarse.model, .refinement = try coarse.model.distribution.refine(coarse.mask, fine.mask) };
}

fn newRecord(gc: *GC, tag: []const u8) !*Obj {
    const obj = try gc.allocObj(.map);
    try put(obj, gc, "surprisal/type", try keyword(gc, tag));
    return obj;
}

fn writeModel(m: *const Model, gc: *GC) !Value {
    const obj = try newRecord(gc, "model");
    const weights = try gc.allocObj(.vector);
    for (m.distribution.weights[0..m.distribution.len]) |w|
        try weights.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(w)));
    try put(obj, gc, "context", m.context);
    try put(obj, gc, "weights", Value.makeObj(weights));
    return Value.makeObj(obj);
}

fn writeEvent(e: *const Event, gc: *GC) !Value {
    const obj = try newRecord(gc, "event");
    const atoms = try gc.allocObj(.vector);
    for (0..e.model.distribution.len) |i| {
        if (e.mask & (@as(u128, 1) << @as(u7, @intCast(i))) != 0)
            try atoms.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(i)));
    }
    try put(obj, gc, "model", try writeModel(&e.model, gc));
    try put(obj, gc, "atoms", Value.makeObj(atoms));
    return Value.makeObj(obj);
}

fn writePath(p: *const Path, gc: *GC) !Value {
    const obj = try newRecord(gc, "refinement");
    try put(obj, gc, "coarse", try writeEvent(&.{ .model = p.model, .mask = p.refinement.coarse }, gc));
    try put(obj, gc, "fine", try writeEvent(&.{ .model = p.model, .mask = p.refinement.fine }, gc));
    return Value.makeObj(obj);
}

fn dispatch(op: Op, args: []const Value, gc: *GC) !Value {
    const arity: usize = switch (op) {
        .whole, .probability, .bits, .score, .refinement_bits => 1,
        else => 2,
    };
    if (args.len != arity) return error.ArityError;
    switch (op) {
        .model => return writeModel(&try makeModel(args[0], args[1]), gc),
        .event, .whole => {
            const m = try readModel(args[0], gc);
            const mask = if (op == .whole) try m.distribution.whole() else try readAtoms(&m, args[1]);
            return writeEvent(&.{ .model = m, .mask = mask }, gc);
        },
        .bits, .probability, .score => {
            const e = try readEvent(args[0], gc);
            if (op == .bits) return Value.makeFloat(try e.model.distribution.bits(e.mask));
            if (op == .probability) return Value.makeFloat(try e.model.distribution.probability(e.mask));
            const obj = try newRecord(gc, "score");
            try put(obj, gc, "event", try writeEvent(&e, gc));
            try put(obj, gc, "probability", Value.makeFloat(try e.model.distribution.probability(e.mask)));
            try put(obj, gc, "bits", Value.makeFloat(try e.model.distribution.bits(e.mask)));
            return Value.makeObj(obj);
        },
        .union_of, .intersection, .subset, .refine => {
            const a = try readEvent(args[0], gc);
            const b = try readEvent(args[1], gc);
            try sameModel(&a.model, &b.model);
            if (op == .subset) return Value.makeBool(a.mask & ~b.mask == 0);
            if (op == .refine) return writePath(&.{ .model = a.model, .refinement = try a.model.distribution.refine(a.mask, b.mask) }, gc);
            const mask = if (op == .union_of) a.mask | b.mask else a.mask & b.mask;
            return writeEvent(&.{ .model = a.model, .mask = mask }, gc);
        },
        .refinement_bits => {
            const p = try readPath(args[0], gc);
            return Value.makeFloat(try p.model.distribution.refinementBits(p.refinement));
        },
        .compose => {
            const a = try readPath(args[0], gc);
            const b = try readPath(args[1], gc);
            try sameModel(&a.model, &b.model);
            return writePath(&.{ .model = a.model, .refinement = try a.model.distribution.compose(a.refinement, b.refinement) }, gc);
        },
    }
}
