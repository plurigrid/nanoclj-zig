//! Monoidal diagram kernel for nanoclj-zig.
//!
//! This is a common substrate for graphical monoidal languages:
//! string diagrams, signal flow graphs, tensor networks, open games,
//! and ZX-style spider calculi. The first slice keeps the runtime
//! representation simple: Clojure maps and vectors in, Zig validation
//! and normalization out.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const semantics = @import("semantics.zig");

pub const DiagramError = error{
    ArityError,
    TypeError,
    InvalidDiagram,
    DomainMismatch,
};

const DiagramKind = enum {
    id,
    box,
    spider,
    swap,
    seq,
    tensor,
};

const Analysis = struct {
    kind: DiagramKind,
    normalized: Value,
    dom: std.ArrayListUnmanaged(Value) = .{},
    cod: std.ArrayListUnmanaged(Value) = .{},
    nodes: usize = 0,
    depth: usize = 0,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        self.dom.deinit(allocator);
        self.cod.deinit(allocator);
    }
};

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
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

fn valueName(val: Value, gc: *GC) ?[]const u8 {
    if (val.isKeyword()) return gc.getString(val.asKeywordId());
    if (val.isString()) return gc.getString(val.asStringId());
    if (val.isSymbol()) return gc.getString(val.asSymbolId());
    return null;
}

fn parseKind(tag_val: Value, gc: *GC) ?DiagramKind {
    const name = valueName(tag_val, gc) orelse return null;
    if (std.mem.eql(u8, name, "id")) return .id;
    if (std.mem.eql(u8, name, "box")) return .box;
    if (std.mem.eql(u8, name, "generator")) return .box;
    if (std.mem.eql(u8, name, "spider")) return .spider;
    if (std.mem.eql(u8, name, "swap")) return .swap;
    if (std.mem.eql(u8, name, "seq")) return .seq;
    if (std.mem.eql(u8, name, "tensor")) return .tensor;
    return null;
}

fn kindName(kind: DiagramKind) []const u8 {
    return switch (kind) {
        .id => "id",
        .box => "box",
        .spider => "spider",
        .swap => "swap",
        .seq => "seq",
        .tensor => "tensor",
    };
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

fn copySeq(dest: *std.ArrayListUnmanaged(Value), allocator: std.mem.Allocator, vals: []const Value) !void {
    try dest.appendSlice(allocator, vals);
}

fn sameInterface(a: []const Value, b: []const Value, gc: *GC) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!semantics.structuralEq(av, bv, gc)) return false;
    }
    return true;
}

fn vectorValue(gc: *GC, vals: []const Value) !Value {
    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.appendSlice(gc.allocator, vals);
    return Value.makeObj(vec);
}

fn maybeAttachAttrs(obj: *Obj, gc: *GC, attrs: ?Value) !void {
    if (attrs) |v| try addKV(obj, gc, "attrs", v);
}

fn makeIdDiagram(gc: *GC, wires: []const Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "id"));
    try addKV(obj, gc, "wires", try vectorValue(gc, wires));
    return Value.makeObj(obj);
}

fn makeBoxDiagram(gc: *GC, name: Value, dom: []const Value, cod: []const Value, attrs: ?Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "box"));
    try addKV(obj, gc, "name", name);
    try addKV(obj, gc, "dom", try vectorValue(gc, dom));
    try addKV(obj, gc, "cod", try vectorValue(gc, cod));
    try maybeAttachAttrs(obj, gc, attrs);
    return Value.makeObj(obj);
}

fn makeSpiderDiagram(gc: *GC, wire: Value, ins: i48, outs: i48, attrs: ?Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "spider"));
    try addKV(obj, gc, "wire", wire);
    try addKV(obj, gc, "ins", Value.makeInt(ins));
    try addKV(obj, gc, "outs", Value.makeInt(outs));
    try maybeAttachAttrs(obj, gc, attrs);
    return Value.makeObj(obj);
}

fn makeSwapDiagram(gc: *GC, left: []const Value, right: []const Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "swap"));
    try addKV(obj, gc, "left", try vectorValue(gc, left));
    try addKV(obj, gc, "right", try vectorValue(gc, right));
    return Value.makeObj(obj);
}

fn makeCompositeDiagram(gc: *GC, kind: DiagramKind, parts: []const Value, collapse_singleton: bool) !Value {
    if (collapse_singleton and parts.len == 1) return parts[0];
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, kindName(kind)));
    try addKV(obj, gc, "parts", try vectorValue(gc, parts));
    return Value.makeObj(obj);
}

fn appendFlattenedPart(dest: *std.ArrayListUnmanaged(Value), gc: *GC, expected: DiagramKind, analysis: Analysis) !void {
    if (analysis.kind != expected or !analysis.normalized.isObj()) {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    }
    const obj = analysis.normalized.asObj();
    if (obj.kind != .map) {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    }
    const parts_val = mapGetByKeyword(obj, gc, "parts") orelse {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    };
    const parts = seqItems(parts_val) orelse {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    };
    try dest.appendSlice(gc.allocator, parts);
}

fn analyzeComposite(kind: DiagramKind, parts_val: Value, gc: *GC) anyerror!Analysis {
    const parts = seqItems(parts_val) orelse return error.TypeError;
    if (parts.len == 0) return error.InvalidDiagram;

    var flat_parts: std.ArrayListUnmanaged(Value) = .{};
    defer flat_parts.deinit(gc.allocator);

    var dom: std.ArrayListUnmanaged(Value) = .{};
    errdefer dom.deinit(gc.allocator);
    var cod: std.ArrayListUnmanaged(Value) = .{};
    errdefer cod.deinit(gc.allocator);

    var total_nodes: usize = 0;
    var max_depth: usize = 0;
    var first = true;
    var only_kind: DiagramKind = kind;

    for (parts) |part| {
        var child = try analyzeDiagram(part, gc);
        defer child.deinit(gc.allocator);

        try appendFlattenedPart(&flat_parts, gc, kind, child);
        total_nodes += child.nodes;
        if (child.depth > max_depth) max_depth = child.depth;

        if (first) {
            only_kind = child.kind;
            try copySeq(&dom, gc.allocator, child.dom.items);
            try copySeq(&cod, gc.allocator, child.cod.items);
            first = false;
            continue;
        }

        switch (kind) {
            .seq => {
                if (!sameInterface(cod.items, child.dom.items, gc)) {
                    return error.DomainMismatch;
                }
                cod.clearRetainingCapacity();
                try copySeq(&cod, gc.allocator, child.cod.items);
            },
            .tensor => {
                try copySeq(&dom, gc.allocator, child.dom.items);
                try copySeq(&cod, gc.allocator, child.cod.items);
            },
            else => return error.InvalidDiagram,
        }
    }

    const collapse = flat_parts.items.len == 1;
    const normalized = try makeCompositeDiagram(gc, kind, flat_parts.items, true);
    return .{
        .kind = if (collapse) only_kind else kind,
        .normalized = normalized,
        .dom = dom,
        .cod = cod,
        .nodes = total_nodes,
        .depth = if (collapse) max_depth else max_depth + 1,
    };
}

fn analyzeDiagram(diag: Value, gc: *GC) anyerror!Analysis {
    if (!diag.isObj()) return error.TypeError;
    const obj = diag.asObj();
    if (obj.kind != .map) return error.TypeError;

    const tag_val = mapGetByKeyword(obj, gc, "tag") orelse return error.InvalidDiagram;
    const kind = parseKind(tag_val, gc) orelse return error.InvalidDiagram;

    switch (kind) {
        .id => {
            const wires_val = mapGetByKeyword(obj, gc, "wires") orelse return error.InvalidDiagram;
            const wires = seqItems(wires_val) orelse return error.TypeError;
            var dom: std.ArrayListUnmanaged(Value) = .{};
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .{};
            errdefer cod.deinit(gc.allocator);
            try copySeq(&dom, gc.allocator, wires);
            try copySeq(&cod, gc.allocator, wires);
            return .{
                .kind = .id,
                .normalized = try makeIdDiagram(gc, wires),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .box => {
            const name = mapGetByKeyword(obj, gc, "name") orelse return error.InvalidDiagram;
            const dom_val = mapGetByKeyword(obj, gc, "dom") orelse return error.InvalidDiagram;
            const cod_val = mapGetByKeyword(obj, gc, "cod") orelse return error.InvalidDiagram;
            const dom_items = seqItems(dom_val) orelse return error.TypeError;
            const cod_items = seqItems(cod_val) orelse return error.TypeError;
            var dom: std.ArrayListUnmanaged(Value) = .{};
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .{};
            errdefer cod.deinit(gc.allocator);
            try copySeq(&dom, gc.allocator, dom_items);
            try copySeq(&cod, gc.allocator, cod_items);
            return .{
                .kind = .box,
                .normalized = try makeBoxDiagram(gc, name, dom_items, cod_items, mapGetByKeyword(obj, gc, "attrs")),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .spider => {
            const wire = mapGetByKeyword(obj, gc, "wire") orelse return error.InvalidDiagram;
            const ins_val = mapGetByKeyword(obj, gc, "ins") orelse return error.InvalidDiagram;
            const outs_val = mapGetByKeyword(obj, gc, "outs") orelse return error.InvalidDiagram;
            if (!ins_val.isInt() or !outs_val.isInt()) return error.TypeError;
            const ins = ins_val.asInt();
            const outs = outs_val.asInt();
            if (ins < 0 or outs < 0) return error.InvalidDiagram;

            var dom: std.ArrayListUnmanaged(Value) = .{};
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .{};
            errdefer cod.deinit(gc.allocator);

            var i: i48 = 0;
            while (i < ins) : (i += 1) try dom.append(gc.allocator, wire);
            i = 0;
            while (i < outs) : (i += 1) try cod.append(gc.allocator, wire);

            return .{
                .kind = .spider,
                .normalized = try makeSpiderDiagram(gc, wire, ins, outs, mapGetByKeyword(obj, gc, "attrs")),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .swap => {
            const left_val = mapGetByKeyword(obj, gc, "left") orelse return error.InvalidDiagram;
            const right_val = mapGetByKeyword(obj, gc, "right") orelse return error.InvalidDiagram;
            const left = seqItems(left_val) orelse return error.TypeError;
            const right = seqItems(right_val) orelse return error.TypeError;

            var dom: std.ArrayListUnmanaged(Value) = .{};
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .{};
            errdefer cod.deinit(gc.allocator);
            try copySeq(&dom, gc.allocator, left);
            try copySeq(&dom, gc.allocator, right);
            try copySeq(&cod, gc.allocator, right);
            try copySeq(&cod, gc.allocator, left);

            return .{
                .kind = .swap,
                .normalized = try makeSwapDiagram(gc, left, right),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .seq => {
            const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return error.InvalidDiagram;
            return analyzeComposite(.seq, parts_val, gc);
        },
        .tensor => {
            const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return error.InvalidDiagram;
            return analyzeComposite(.tensor, parts_val, gc);
        },
    }
}

fn errorLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.ArityError => "arity-error",
        error.TypeError => "type-error",
        error.InvalidDiagram => "invalid-diagram",
        error.DomainMismatch => "domain-mismatch",
        else => "diagram-error",
    };
}

fn summaryFromAnalysis(analysis: Analysis, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "ok", Value.makeBool(true));
    try addKV(obj, gc, "kind", try kw(gc, kindName(analysis.kind)));
    try addKV(obj, gc, "dom", try vectorValue(gc, analysis.dom.items));
    try addKV(obj, gc, "cod", try vectorValue(gc, analysis.cod.items));
    try addKV(obj, gc, "nodes", Value.makeInt(@intCast(analysis.nodes)));
    try addKV(obj, gc, "depth", Value.makeInt(@intCast(analysis.depth)));
    try addKV(obj, gc, "normalized", analysis.normalized);
    return Value.makeObj(obj);
}

fn errorSummary(gc: *GC, err: anyerror) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "ok", Value.makeBool(false));
    try addKV(obj, gc, "error", Value.makeString(try gc.internString(errorLabel(err))));
    return Value.makeObj(obj);
}

pub fn diagramIdFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const wires = seqItems(args[0]) orelse return error.TypeError;
    return makeIdDiagram(gc, wires);
}

pub fn diagramBoxFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    const dom = seqItems(args[1]) orelse return error.TypeError;
    const cod = seqItems(args[2]) orelse return error.TypeError;
    const attrs: ?Value = if (args.len == 4) args[3] else null;
    return makeBoxDiagram(gc, args[0], dom, cod, attrs);
}

pub fn diagramSpiderFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    if (!args[1].isInt() or !args[2].isInt()) return error.TypeError;
    const attrs: ?Value = if (args.len == 4) args[3] else null;
    return makeSpiderDiagram(gc, args[0], args[1].asInt(), args[2].asInt(), attrs);
}

pub fn diagramSwapFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const left = seqItems(args[0]) orelse return error.TypeError;
    const right = seqItems(args[1]) orelse return error.TypeError;
    return makeSwapDiagram(gc, left, right);
}

pub fn diagramSeqFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    return makeCompositeDiagram(gc, .seq, args, false);
}

pub fn diagramTensorFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    return makeCompositeDiagram(gc, .tensor, args, false);
}

pub fn diagramNormalizeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    var analysis = try analyzeDiagram(args[0], gc);
    defer analysis.deinit(gc.allocator);
    return analysis.normalized;
}

pub fn diagramWellTypedFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    var analysis = analyzeDiagram(args[0], gc) catch return Value.makeBool(false);
    defer analysis.deinit(gc.allocator);
    return Value.makeBool(true);
}

pub fn diagramSummaryFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    var analysis = analyzeDiagram(args[0], gc) catch |err| return errorSummary(gc, err);
    defer analysis.deinit(gc.allocator);
    return summaryFromAnalysis(analysis, gc);
}

test "monoidal diagram: sequential composition normalizes and preserves interfaces" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const g = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("g")), &.{B}, &.{C}, null);
    var seq_args = [_]Value{ f, g };
    const seq = try diagramSeqFn(seq_args[0..], &gc, &env, &resources);

    var analysis = try analyzeDiagram(seq, &gc);
    defer analysis.deinit(gc.allocator);

    try std.testing.expectEqual(DiagramKind.seq, analysis.kind);
    try std.testing.expectEqual(@as(usize, 1), analysis.dom.items.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.cod.items.len);
    try std.testing.expect(semantics.structuralEq(A, analysis.dom.items[0], &gc));
    try std.testing.expect(semantics.structuralEq(C, analysis.cod.items[0], &gc));
}

test "monoidal diagram: tensor concatenates boundaries" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const D = try kw(&gc, "D");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const g = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("g")), &.{C}, &.{D}, null);
    var tensor_args = [_]Value{ f, g };
    const tensor = try diagramTensorFn(tensor_args[0..], &gc, &env, &resources);

    var analysis = try analyzeDiagram(tensor, &gc);
    defer analysis.deinit(gc.allocator);

    try std.testing.expectEqual(DiagramKind.tensor, analysis.kind);
    try std.testing.expectEqual(@as(usize, 2), analysis.dom.items.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.cod.items.len);
    try std.testing.expect(semantics.structuralEq(A, analysis.dom.items[0], &gc));
    try std.testing.expect(semantics.structuralEq(C, analysis.dom.items[1], &gc));
    try std.testing.expect(semantics.structuralEq(B, analysis.cod.items[0], &gc));
    try std.testing.expect(semantics.structuralEq(D, analysis.cod.items[1], &gc));
}

test "monoidal diagram: invalid sequential composition is rejected" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const D = try kw(&gc, "D");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const g = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("g")), &.{C}, &.{D}, null);
    var seq_args = [_]Value{ f, g };
    const seq = try diagramSeqFn(seq_args[0..], &gc, &env, &resources);

    try std.testing.expectError(error.DomainMismatch, analyzeDiagram(seq, &gc));
}
