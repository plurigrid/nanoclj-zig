//! juvix_bridge: structural nanoclj-zig ↔ Juvix bridge.
//!
//! This bridge does not assume an in-process Juvix evaluator. Instead, it
//! provides a canonical tagged term encoding that can carry nanoclj values into
//! a Juvix-oriented ADT space and back on the data fragment.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const compat = @import("compat.zig");

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn str(gc: *GC, s: []const u8) !Value {
    return Value.makeString(try gc.internString(s));
}

fn addKV(obj: *Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn makeMap(gc: *GC) !*Obj {
    return try gc.allocObj(.map);
}

fn makeVector(gc: *GC) !*Obj {
    return try gc.allocObj(.vector);
}

fn getMapValueByKeyword(gc: *GC, map_val: Value, key: []const u8) ?Value {
    if (!map_val.isObj()) return null;
    const obj = map_val.asObj();
    if (obj.kind != .map) return null;
    for (obj.data.map.keys.items, obj.data.map.vals.items) |k, v| {
        if (k.isKeyword() and std.mem.eql(u8, gc.getString(k.asKeywordId()), key)) return v;
    }
    return null;
}

fn isEncodedTerm(gc: *GC, val: Value) bool {
    const tag_val = getMapValueByKeyword(gc, val, "juvix/tag") orelse return false;
    return tag_val.isKeyword();
}

fn makeOpaqueKind(gc: *GC, kind: []const u8) !Value {
    const obj = try makeMap(gc);
    try addKV(obj, gc, "juvix/tag", try kw(gc, "opaque"));
    try addKV(obj, gc, "kind", try str(gc, kind));
    return Value.makeObj(obj);
}

fn makeTaggedTerm(gc: *GC, tag: []const u8) !*Obj {
    const obj = try makeMap(gc);
    try addKV(obj, gc, "juvix/tag", try kw(gc, tag));
    return obj;
}

fn encodeValue(val: Value, gc: *GC) !Value {
    if (val.isNil()) {
        const obj = try makeMap(gc);
        try addKV(obj, gc, "juvix/tag", try kw(gc, "unit"));
        return Value.makeObj(obj);
    }
    if (val.isBool()) {
        const obj = try makeMap(gc);
        try addKV(obj, gc, "juvix/tag", try kw(gc, "bool"));
        try addKV(obj, gc, "value", Value.makeBool(val.asBool()));
        return Value.makeObj(obj);
    }
    if (val.isInt()) {
        const obj = try makeMap(gc);
        try addKV(obj, gc, "juvix/tag", try kw(gc, "int"));
        try addKV(obj, gc, "value", val);
        return Value.makeObj(obj);
    }
    if (val.isFloat()) {
        const obj = try makeMap(gc);
        try addKV(obj, gc, "juvix/tag", try kw(gc, "double"));
        try addKV(obj, gc, "value", val);
        return Value.makeObj(obj);
    }
    if (val.isString()) {
        const obj = try makeMap(gc);
        try addKV(obj, gc, "juvix/tag", try kw(gc, "string"));
        try addKV(obj, gc, "value", try str(gc, gc.getString(val.asStringId())));
        return Value.makeObj(obj);
    }
    if (val.isSymbol()) {
        const obj = try makeMap(gc);
        try addKV(obj, gc, "juvix/tag", try kw(gc, "symbol"));
        try addKV(obj, gc, "value", try str(gc, gc.getString(val.asSymbolId())));
        return Value.makeObj(obj);
    }
    if (val.isKeyword()) {
        const obj = try makeMap(gc);
        try addKV(obj, gc, "juvix/tag", try kw(gc, "keyword"));
        try addKV(obj, gc, "value", try str(gc, gc.getString(val.asKeywordId())));
        return Value.makeObj(obj);
    }
    if (!val.isObj()) return try makeOpaqueKind(gc, "unknown");

    const obj = val.asObj();
    switch (obj.kind) {
        .list => {
            const out = try makeMap(gc);
            const items = try makeVector(gc);
            for (obj.data.list.items.items) |item| {
                try items.data.vector.items.append(gc.allocator, try encodeValue(item, gc));
            }
            try addKV(out, gc, "juvix/tag", try kw(gc, "list"));
            try addKV(out, gc, "items", Value.makeObj(items));
            return Value.makeObj(out);
        },
        .vector => {
            const out = try makeMap(gc);
            const items = try makeVector(gc);
            for (obj.data.vector.items.items) |item| {
                try items.data.vector.items.append(gc.allocator, try encodeValue(item, gc));
            }
            try addKV(out, gc, "juvix/tag", try kw(gc, "vector"));
            try addKV(out, gc, "items", Value.makeObj(items));
            return Value.makeObj(out);
        },
        .map => {
            const out = try makeMap(gc);
            const entries = try makeVector(gc);
            for (obj.data.map.keys.items, obj.data.map.vals.items) |k, v| {
                const pair = try makeVector(gc);
                try pair.data.vector.items.append(gc.allocator, try encodeValue(k, gc));
                try pair.data.vector.items.append(gc.allocator, try encodeValue(v, gc));
                try entries.data.vector.items.append(gc.allocator, Value.makeObj(pair));
            }
            try addKV(out, gc, "juvix/tag", try kw(gc, "map"));
            try addKV(out, gc, "entries", Value.makeObj(entries));
            return Value.makeObj(out);
        },
        .set => {
            const out = try makeMap(gc);
            const items = try makeVector(gc);
            for (obj.data.set.items.items) |item| {
                try items.data.vector.items.append(gc.allocator, try encodeValue(item, gc));
            }
            try addKV(out, gc, "juvix/tag", try kw(gc, "set"));
            try addKV(out, gc, "items", Value.makeObj(items));
            return Value.makeObj(out);
        },
        .rational => {
            const out = try makeMap(gc);
            try addKV(out, gc, "juvix/tag", try kw(gc, "rational"));
            try addKV(out, gc, "numerator", Value.makeInt(@intCast(obj.data.rational.numerator)));
            try addKV(out, gc, "denominator", Value.makeInt(@intCast(obj.data.rational.denominator)));
            return Value.makeObj(out);
        },
        .color => {
            const c = obj.data.color;
            const out = try makeMap(gc);
            try addKV(out, gc, "juvix/tag", try kw(gc, "color"));
            try addKV(out, gc, "l", Value.makeFloat(c.L));
            try addKV(out, gc, "a", Value.makeFloat(c.a));
            try addKV(out, gc, "b", Value.makeFloat(c.b));
            try addKV(out, gc, "alpha", Value.makeFloat(c.alpha));
            return Value.makeObj(out);
        },
        .builtin_ref => {
            const out = try makeMap(gc);
            try addKV(out, gc, "juvix/tag", try kw(gc, "builtin"));
            try addKV(out, gc, "name", try str(gc, obj.data.builtin_ref.name));
            return Value.makeObj(out);
        },
        .function => return try makeOpaqueKind(gc, "function"),
        .macro_fn => return try makeOpaqueKind(gc, "macro"),
        .atom => return try makeOpaqueKind(gc, "atom"),
        .bc_closure => return try makeOpaqueKind(gc, "bytecode-closure"),
        .lazy_seq => return try makeOpaqueKind(gc, "lazy-seq"),
        .partial_fn => return try makeOpaqueKind(gc, "partial-fn"),
        .multimethod => return try makeOpaqueKind(gc, "multimethod"),
        .protocol => return try makeOpaqueKind(gc, "protocol"),
        .dense_f64 => return try makeOpaqueKind(gc, "dense-f64"),
        .trace => return try makeOpaqueKind(gc, "trace"),
        .channel => return try makeOpaqueKind(gc, "channel"),
        .agent => return try makeOpaqueKind(gc, "agent"),
        .file_handle => return try makeOpaqueKind(gc, "file"),
        .bytes => return try makeOpaqueKind(gc, "bytes"),
    }
}

fn decodeItemsTo(gc: *GC, src: Value, kind: value.ObjKind) anyerror!Value {
    if (!src.isObj() or src.asObj().kind != .vector) return error.TypeError;
    const out = try gc.allocObj(kind);
    for (src.asObj().data.vector.items.items) |item| {
        const decoded = try decodeValue(item, gc);
        switch (kind) {
            .list => try out.data.list.items.append(gc.allocator, decoded),
            .vector => try out.data.vector.items.append(gc.allocator, decoded),
            .set => try out.data.set.items.append(gc.allocator, decoded),
            else => unreachable,
        }
    }
    return Value.makeObj(out);
}

fn decodeMapEntries(gc: *GC, src: Value) anyerror!Value {
    if (!src.isObj() or src.asObj().kind != .vector) return error.TypeError;
    const out = try gc.allocObj(.map);
    for (src.asObj().data.vector.items.items) |entry| {
        if (!entry.isObj() or entry.asObj().kind != .vector) return error.TypeError;
        const pair = entry.asObj().data.vector.items.items;
        if (pair.len != 2) return error.TypeError;
        try out.data.map.keys.append(gc.allocator, try decodeValue(pair[0], gc));
        try out.data.map.vals.append(gc.allocator, try decodeValue(pair[1], gc));
    }
    return Value.makeObj(out);
}

fn decodeValue(val: Value, gc: *GC) anyerror!Value {
    const tag_val = getMapValueByKeyword(gc, val, "juvix/tag") orelse return val;
    if (!tag_val.isKeyword()) return error.TypeError;
    const tag = gc.getString(tag_val.asKeywordId());

    if (std.mem.eql(u8, tag, "unit")) return Value.makeNil();
    if (std.mem.eql(u8, tag, "bool")) return getMapValueByKeyword(gc, val, "value") orelse Value.makeBool(false);
    if (std.mem.eql(u8, tag, "int")) return getMapValueByKeyword(gc, val, "value") orelse Value.makeInt(0);
    if (std.mem.eql(u8, tag, "double")) return getMapValueByKeyword(gc, val, "value") orelse Value.makeFloat(0);
    if (std.mem.eql(u8, tag, "string")) {
        const payload = getMapValueByKeyword(gc, val, "value") orelse return error.TypeError;
        if (!payload.isString()) return error.TypeError;
        return str(gc, gc.getString(payload.asStringId()));
    }
    if (std.mem.eql(u8, tag, "symbol")) {
        const payload = getMapValueByKeyword(gc, val, "value") orelse return error.TypeError;
        if (!payload.isString()) return error.TypeError;
        return Value.makeSymbol(try gc.internString(gc.getString(payload.asStringId())));
    }
    if (std.mem.eql(u8, tag, "keyword")) {
        const payload = getMapValueByKeyword(gc, val, "value") orelse return error.TypeError;
        if (!payload.isString()) return error.TypeError;
        return Value.makeKeyword(try gc.internString(gc.getString(payload.asStringId())));
    }
    if (std.mem.eql(u8, tag, "list")) return decodeItemsTo(gc, getMapValueByKeyword(gc, val, "items") orelse return error.TypeError, .list);
    if (std.mem.eql(u8, tag, "vector")) return decodeItemsTo(gc, getMapValueByKeyword(gc, val, "items") orelse return error.TypeError, .vector);
    if (std.mem.eql(u8, tag, "set")) return decodeItemsTo(gc, getMapValueByKeyword(gc, val, "items") orelse return error.TypeError, .set);
    if (std.mem.eql(u8, tag, "map")) return decodeMapEntries(gc, getMapValueByKeyword(gc, val, "entries") orelse return error.TypeError);
    if (std.mem.eql(u8, tag, "rational")) {
        const num = getMapValueByKeyword(gc, val, "numerator") orelse return error.TypeError;
        const den = getMapValueByKeyword(gc, val, "denominator") orelse return error.TypeError;
        if (!num.isInt() or !den.isInt()) return error.TypeError;
        const out = try gc.allocObj(.rational);
        out.data.rational = value.Rational.init(num.asInt(), den.asInt());
        return Value.makeObj(out);
    }
    if (std.mem.eql(u8, tag, "color")) {
        const out = try gc.allocObj(.color);
        const l = getMapValueByKeyword(gc, val, "l") orelse return error.TypeError;
        const a = getMapValueByKeyword(gc, val, "a") orelse return error.TypeError;
        const b = getMapValueByKeyword(gc, val, "b") orelse return error.TypeError;
        const alpha = getMapValueByKeyword(gc, val, "alpha") orelse return error.TypeError;
        if (!l.isFloat() or !a.isFloat() or !b.isFloat() or !alpha.isFloat()) return error.TypeError;
        out.data.color = .{
            .L = @floatCast(l.asFloat()),
            .a = @floatCast(a.asFloat()),
            .b = @floatCast(b.asFloat()),
            .alpha = @floatCast(alpha.asFloat()),
        };
        return Value.makeObj(out);
    }

    // Opaque and builtin forms stay reflective maps on decode.
    return val;
}

pub fn juvixEncodeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return encodeValue(args[0], gc);
}

pub fn juvixDecodeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return decodeValue(args[0], gc);
}

pub fn juvixBridgeProfileFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const obj = try makeMap(gc);
    const exact = try makeVector(gc);
    const reflective = try makeVector(gc);
    const exact_names = [_][]const u8{
        "unit", "bool", "int", "double", "string", "symbol", "keyword",
        "list", "vector", "map", "set", "rational", "color",
    };
    const reflective_names = [_][]const u8{
        "builtin", "function", "macro", "atom", "bytecode-closure", "lazy-seq",
        "partial-fn", "multimethod", "protocol", "dense-f64", "trace", "channel",
        "lambda", "apply", "constructor", "let", "ann", "match", "pat-var", "pat-ctor", "pat-wildcard",
    };
    for (exact_names) |name| try exact.data.vector.items.append(gc.allocator, try str(gc, name));
    for (reflective_names) |name| try reflective.data.vector.items.append(gc.allocator, try str(gc, name));
    try addKV(obj, gc, "runtime", try str(gc, "juvix"));
    try addKV(obj, gc, "bridge-mode", try kw(gc, "structural-plus-source"));
    try addKV(obj, gc, "exact", Value.makeObj(exact));
    try addKV(obj, gc, "reflective", Value.makeObj(reflective));
    return Value.makeObj(obj);
}

fn requireEncodedItems(gc: *GC, encoded: Value, field: []const u8) anyerror![]Value {
    const items = getMapValueByKeyword(gc, encoded, field) orelse return error.TypeError;
    if (!items.isObj() or items.asObj().kind != .vector) return error.TypeError;
    return items.asObj().data.vector.items.items;
}

fn appendEncodedSource(buf: *std.ArrayListUnmanaged(u8), encoded: Value, gc: *GC) anyerror!void {
    const tag_val = getMapValueByKeyword(gc, encoded, "juvix/tag") orelse return error.TypeError;
    if (!tag_val.isKeyword()) return error.TypeError;
    const tag = gc.getString(tag_val.asKeywordId());

    if (std.mem.eql(u8, tag, "unit")) return buf.appendSlice(gc.allocator, "Unit");
    if (std.mem.eql(u8, tag, "bool")) {
        const payload = getMapValueByKeyword(gc, encoded, "value") orelse return error.TypeError;
        return buf.appendSlice(gc.allocator, if (payload.asBool()) "true" else "false");
    }
    if (std.mem.eql(u8, tag, "int") or std.mem.eql(u8, tag, "double")) {
        const payload = getMapValueByKeyword(gc, encoded, "value") orelse return error.TypeError;
        var tmp: [64]u8 = undefined;
        const s = if (payload.isInt())
            try std.fmt.bufPrint(&tmp, "{d}", .{payload.asInt()})
        else
            try std.fmt.bufPrint(&tmp, "{d}", .{payload.asFloat()});
        return buf.appendSlice(gc.allocator, s);
    }
    if (std.mem.eql(u8, tag, "string") or std.mem.eql(u8, tag, "symbol") or std.mem.eql(u8, tag, "keyword") or std.mem.eql(u8, tag, "builtin") or std.mem.eql(u8, tag, "opaque")) {
        const ctor = if (std.mem.eql(u8, tag, "string"))
            "String"
        else if (std.mem.eql(u8, tag, "symbol"))
            "Symbol"
        else if (std.mem.eql(u8, tag, "keyword"))
            "Keyword"
        else if (std.mem.eql(u8, tag, "builtin"))
            "Builtin"
        else
            "Opaque";
        const field_name = if (std.mem.eql(u8, tag, "opaque")) "kind" else if (std.mem.eql(u8, tag, "builtin")) "name" else "value";
        const payload = getMapValueByKeyword(gc, encoded, field_name) orelse return error.TypeError;
        if (!payload.isString()) return error.TypeError;
        try buf.appendSlice(gc.allocator, ctor);
        try buf.appendSlice(gc.allocator, "(\"");
        for (gc.getString(payload.asStringId())) |c| {
            switch (c) {
                '"' => try buf.appendSlice(gc.allocator, "\\\""),
                '\\' => try buf.appendSlice(gc.allocator, "\\\\"),
                '\n' => try buf.appendSlice(gc.allocator, "\\n"),
                '\t' => try buf.appendSlice(gc.allocator, "\\t"),
                else => try buf.append(gc.allocator, c),
            }
        }
        return buf.appendSlice(gc.allocator, "\")");
    }
    if (std.mem.eql(u8, tag, "rational")) {
        const num = getMapValueByKeyword(gc, encoded, "numerator") orelse return error.TypeError;
        const den = getMapValueByKeyword(gc, encoded, "denominator") orelse return error.TypeError;
        var tmp: [96]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "Rational({d}, {d})", .{ num.asInt(), den.asInt() });
        return buf.appendSlice(gc.allocator, s);
    }
    if (std.mem.eql(u8, tag, "color")) {
        const l = getMapValueByKeyword(gc, encoded, "l") orelse return error.TypeError;
        const a = getMapValueByKeyword(gc, encoded, "a") orelse return error.TypeError;
        const b = getMapValueByKeyword(gc, encoded, "b") orelse return error.TypeError;
        const alpha = getMapValueByKeyword(gc, encoded, "alpha") orelse return error.TypeError;
        var tmp: [160]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "Color({d}, {d}, {d}, {d})", .{ l.asFloat(), a.asFloat(), b.asFloat(), alpha.asFloat() });
        return buf.appendSlice(gc.allocator, s);
    }
    if (std.mem.eql(u8, tag, "lambda")) {
        const params = try requireEncodedItems(gc, encoded, "params");
        const body = getMapValueByKeyword(gc, encoded, "body") orelse return error.TypeError;
        try buf.appendSlice(gc.allocator, "Lambda([");
        for (params, 0..) |param, i| {
            if (i > 0) try buf.appendSlice(gc.allocator, ", ");
            try appendEncodedSource(buf, param, gc);
        }
        try buf.appendSlice(gc.allocator, "], ");
        try appendEncodedSource(buf, body, gc);
        try buf.append(gc.allocator, ')');
        return;
    }
    if (std.mem.eql(u8, tag, "apply")) {
        const fn_term = getMapValueByKeyword(gc, encoded, "fn") orelse return error.TypeError;
        const args = try requireEncodedItems(gc, encoded, "args");
        try buf.appendSlice(gc.allocator, "Apply(");
        try appendEncodedSource(buf, fn_term, gc);
        try buf.appendSlice(gc.allocator, ", [");
        for (args, 0..) |arg, i| {
            if (i > 0) try buf.appendSlice(gc.allocator, ", ");
            try appendEncodedSource(buf, arg, gc);
        }
        try buf.appendSlice(gc.allocator, "])");
        return;
    }
    if (std.mem.eql(u8, tag, "constructor")) {
        const name = getMapValueByKeyword(gc, encoded, "name") orelse return error.TypeError;
        if (!name.isString()) return error.TypeError;
        const args = try requireEncodedItems(gc, encoded, "args");
        try buf.appendSlice(gc.allocator, "Ctor(\"");
        try buf.appendSlice(gc.allocator, gc.getString(name.asStringId()));
        try buf.appendSlice(gc.allocator, "\", [");
        for (args, 0..) |arg, i| {
            if (i > 0) try buf.appendSlice(gc.allocator, ", ");
            try appendEncodedSource(buf, arg, gc);
        }
        try buf.appendSlice(gc.allocator, "])");
        return;
    }
    if (std.mem.eql(u8, tag, "let")) {
        const name = getMapValueByKeyword(gc, encoded, "name") orelse return error.TypeError;
        const value_term = getMapValueByKeyword(gc, encoded, "value") orelse return error.TypeError;
        const body = getMapValueByKeyword(gc, encoded, "body") orelse return error.TypeError;
        if (!name.isString()) return error.TypeError;
        try buf.appendSlice(gc.allocator, "Let(\"");
        try buf.appendSlice(gc.allocator, gc.getString(name.asStringId()));
        try buf.appendSlice(gc.allocator, "\", ");
        try appendEncodedSource(buf, value_term, gc);
        try buf.appendSlice(gc.allocator, ", ");
        try appendEncodedSource(buf, body, gc);
        try buf.append(gc.allocator, ')');
        return;
    }
    if (std.mem.eql(u8, tag, "ann")) {
        const term = getMapValueByKeyword(gc, encoded, "term") orelse return error.TypeError;
        const type_term = getMapValueByKeyword(gc, encoded, "type") orelse return error.TypeError;
        try buf.appendSlice(gc.allocator, "Ann(");
        try appendEncodedSource(buf, term, gc);
        try buf.appendSlice(gc.allocator, ", ");
        try appendEncodedSource(buf, type_term, gc);
        try buf.append(gc.allocator, ')');
        return;
    }
    if (std.mem.eql(u8, tag, "match")) {
        const scrutinee = getMapValueByKeyword(gc, encoded, "scrutinee") orelse return error.TypeError;
        const cases = try requireEncodedItems(gc, encoded, "cases");
        try buf.appendSlice(gc.allocator, "Match(");
        try appendEncodedSource(buf, scrutinee, gc);
        try buf.appendSlice(gc.allocator, ", [");
        for (cases, 0..) |case_term, i| {
            if (i > 0) try buf.appendSlice(gc.allocator, ", ");
            if (!case_term.isObj() or case_term.asObj().kind != .vector or case_term.asObj().data.vector.items.items.len != 2) return error.TypeError;
            try buf.append(gc.allocator, '(');
            try appendEncodedSource(buf, case_term.asObj().data.vector.items.items[0], gc);
            try buf.appendSlice(gc.allocator, ", ");
            try appendEncodedSource(buf, case_term.asObj().data.vector.items.items[1], gc);
            try buf.append(gc.allocator, ')');
        }
        try buf.appendSlice(gc.allocator, "])");
        return;
    }
    if (std.mem.eql(u8, tag, "pat-var")) {
        const name = getMapValueByKeyword(gc, encoded, "name") orelse return error.TypeError;
        if (!name.isString()) return error.TypeError;
        try buf.appendSlice(gc.allocator, "PatVar(\"");
        try buf.appendSlice(gc.allocator, gc.getString(name.asStringId()));
        try buf.appendSlice(gc.allocator, "\")");
        return;
    }
    if (std.mem.eql(u8, tag, "pat-wildcard")) {
        try buf.appendSlice(gc.allocator, "PatWildcard");
        return;
    }
    if (std.mem.eql(u8, tag, "pat-ctor")) {
        const name = getMapValueByKeyword(gc, encoded, "name") orelse return error.TypeError;
        if (!name.isString()) return error.TypeError;
        const args = try requireEncodedItems(gc, encoded, "args");
        try buf.appendSlice(gc.allocator, "PatCtor(\"");
        try buf.appendSlice(gc.allocator, gc.getString(name.asStringId()));
        try buf.appendSlice(gc.allocator, "\", [");
        for (args, 0..) |arg, i| {
            if (i > 0) try buf.appendSlice(gc.allocator, ", ");
            try appendEncodedSource(buf, arg, gc);
        }
        try buf.appendSlice(gc.allocator, "])");
        return;
    }

    const ctor = if (std.mem.eql(u8, tag, "list"))
        "List"
    else if (std.mem.eql(u8, tag, "vector"))
        "Vector"
    else if (std.mem.eql(u8, tag, "set"))
        "Set"
    else if (std.mem.eql(u8, tag, "map"))
        "Map"
    else
        return error.TypeError;

    try buf.appendSlice(gc.allocator, ctor);
    try buf.append(gc.allocator, '(');
    if (std.mem.eql(u8, tag, "map")) {
        const entries = getMapValueByKeyword(gc, encoded, "entries") orelse return error.TypeError;
        if (!entries.isObj() or entries.asObj().kind != .vector) return error.TypeError;
        try buf.append(gc.allocator, '[');
        for (entries.asObj().data.vector.items.items, 0..) |entry, i| {
            if (i > 0) try buf.appendSlice(gc.allocator, ", ");
            if (!entry.isObj() or entry.asObj().kind != .vector or entry.asObj().data.vector.items.items.len != 2) return error.TypeError;
            try buf.append(gc.allocator, '(');
            try appendEncodedSource(buf, entry.asObj().data.vector.items.items[0], gc);
            try buf.appendSlice(gc.allocator, ", ");
            try appendEncodedSource(buf, entry.asObj().data.vector.items.items[1], gc);
            try buf.append(gc.allocator, ')');
        }
        try buf.append(gc.allocator, ']');
    } else {
        const items = getMapValueByKeyword(gc, encoded, "items") orelse return error.TypeError;
        if (!items.isObj() or items.asObj().kind != .vector) return error.TypeError;
        try buf.append(gc.allocator, '[');
        for (items.asObj().data.vector.items.items, 0..) |item, i| {
            if (i > 0) try buf.appendSlice(gc.allocator, ", ");
            try appendEncodedSource(buf, item, gc);
        }
        try buf.append(gc.allocator, ']');
    }
    try buf.append(gc.allocator, ')');
}

fn printEncodedSource(encoded: Value, gc: *GC) anyerror![]const u8 {
    var buf = compat.emptyList(u8);
    try appendEncodedSource(&buf, encoded, gc);
    return buf.toOwnedSlice(gc.allocator);
}

const TermReader = struct {
    src: []const u8,
    pos: usize = 0,
    gc: *GC,

    fn skipWs(self: *TermReader) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) : (self.pos += 1) {}
    }

    fn eat(self: *TermReader, c: u8) bool {
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn expect(self: *TermReader, c: u8) !void {
        if (!self.eat(c)) return error.UnexpectedChar;
    }

    fn parseIdent(self: *TermReader) ![]const u8 {
        self.skipWs();
        const start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphabetic(self.src[self.pos]) or self.src[self.pos] == '-')) : (self.pos += 1) {}
        if (self.pos == start) return error.UnexpectedChar;
        return self.src[start..self.pos];
    }

    fn parseString(self: *TermReader) anyerror![]const u8 {
        self.skipWs();
        try self.expect('"');
        var buf = compat.emptyList(u8);
        errdefer buf.deinit(self.gc.allocator);
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                return buf.toOwnedSlice(self.gc.allocator);
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.UnexpectedEOF;
                const esc = self.src[self.pos];
                const resolved: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    '"', '\\' => esc,
                    else => return error.UnexpectedChar,
                };
                try buf.append(self.gc.allocator, resolved);
            } else {
                try buf.append(self.gc.allocator, c);
            }
        }
        return error.UnexpectedEOF;
    }

    fn parseNumberValue(self: *TermReader) !Value {
        self.skipWs();
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        var saw_dot = false;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '.') {
                if (saw_dot) break;
                saw_dot = true;
                continue;
            }
            if (!std.ascii.isDigit(c)) break;
        }
        const slice = self.src[start..self.pos];
        if (slice.len == 0 or std.mem.eql(u8, slice, "-")) return error.InvalidNumber;
        if (saw_dot) return Value.makeFloat(try std.fmt.parseFloat(f64, slice));
        return Value.makeInt(try std.fmt.parseInt(i48, slice, 10));
    }

    fn encodedWithStringField(self: *TermReader, tag: []const u8, field: []const u8) !Value {
        try self.expect('(');
        const payload = try self.parseString();
        defer self.gc.allocator.free(payload);
        try self.expect(')');
        const obj = try makeMap(self.gc);
        try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, tag));
        try addKV(obj, self.gc, field, try str(self.gc, payload));
        return Value.makeObj(obj);
    }

    fn parseVectorOfTerms(self: *TermReader) anyerror!Value {
        try self.expect('[');
        const vec = try makeVector(self.gc);
        self.skipWs();
        if (self.eat(']')) return Value.makeObj(vec);
        while (true) {
            try vec.data.vector.items.append(self.gc.allocator, try self.parseTerm());
            self.skipWs();
            if (self.eat(']')) break;
            try self.expect(',');
        }
        return Value.makeObj(vec);
    }

    fn parseMapEntries(self: *TermReader) anyerror!Value {
        try self.expect('[');
        const entries = try makeVector(self.gc);
        self.skipWs();
        if (self.eat(']')) return Value.makeObj(entries);
        while (true) {
            try self.expect('(');
            const pair = try makeVector(self.gc);
            try pair.data.vector.items.append(self.gc.allocator, try self.parseTerm());
            try self.expect(',');
            try pair.data.vector.items.append(self.gc.allocator, try self.parseTerm());
            try self.expect(')');
            try entries.data.vector.items.append(self.gc.allocator, Value.makeObj(pair));
            self.skipWs();
            if (self.eat(']')) break;
            try self.expect(',');
        }
        return Value.makeObj(entries);
    }

    fn parseCasePairs(self: *TermReader) anyerror!Value {
        try self.expect('[');
        const entries = try makeVector(self.gc);
        self.skipWs();
        if (self.eat(']')) return Value.makeObj(entries);
        while (true) {
            try self.expect('(');
            const pair = try makeVector(self.gc);
            try pair.data.vector.items.append(self.gc.allocator, try self.parseTerm());
            try self.expect(',');
            try pair.data.vector.items.append(self.gc.allocator, try self.parseTerm());
            try self.expect(')');
            try entries.data.vector.items.append(self.gc.allocator, Value.makeObj(pair));
            self.skipWs();
            if (self.eat(']')) break;
            try self.expect(',');
        }
        return Value.makeObj(entries);
    }

    fn parseCommaTerm(self: *TermReader) anyerror!Value {
        try self.expect(',');
        return self.parseTerm();
    }

    fn parseCtor(self: *TermReader, ident: []const u8) anyerror!Value {
        if (std.mem.eql(u8, ident, "Unit")) return Value.makeObj(try makeMap(self.gc));
        if (std.mem.eql(u8, ident, "String")) return self.encodedWithStringField("string", "value");
        if (std.mem.eql(u8, ident, "Symbol")) return self.encodedWithStringField("symbol", "value");
        if (std.mem.eql(u8, ident, "Keyword")) return self.encodedWithStringField("keyword", "value");
        if (std.mem.eql(u8, ident, "Builtin")) return self.encodedWithStringField("builtin", "name");
        if (std.mem.eql(u8, ident, "Opaque")) return self.encodedWithStringField("opaque", "kind");

        if (std.mem.eql(u8, ident, "List") or std.mem.eql(u8, ident, "Vector") or std.mem.eql(u8, ident, "Set")) {
            try self.expect('(');
            const items = try self.parseVectorOfTerms();
            try self.expect(')');
            const obj = try makeMap(self.gc);
            const tag = if (std.mem.eql(u8, ident, "List")) "list" else if (std.mem.eql(u8, ident, "Vector")) "vector" else "set";
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, tag));
            try addKV(obj, self.gc, "items", items);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Map")) {
            try self.expect('(');
            const entries = try self.parseMapEntries();
            try self.expect(')');
            const obj = try makeMap(self.gc);
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, "map"));
            try addKV(obj, self.gc, "entries", entries);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Rational")) {
            try self.expect('(');
            const num = try self.parseNumberValue();
            try self.expect(',');
            const den = try self.parseNumberValue();
            try self.expect(')');
            const obj = try makeMap(self.gc);
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, "rational"));
            try addKV(obj, self.gc, "numerator", num);
            try addKV(obj, self.gc, "denominator", den);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Color")) {
            try self.expect('(');
            const l = try self.parseNumberValue();
            try self.expect(',');
            const a = try self.parseNumberValue();
            try self.expect(',');
            const b = try self.parseNumberValue();
            try self.expect(',');
            const alpha = try self.parseNumberValue();
            try self.expect(')');
            const obj = try makeMap(self.gc);
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, "color"));
            try addKV(obj, self.gc, "l", l);
            try addKV(obj, self.gc, "a", a);
            try addKV(obj, self.gc, "b", b);
            try addKV(obj, self.gc, "alpha", alpha);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Lambda")) {
            try self.expect('(');
            const params = try self.parseVectorOfTerms();
            const body = try self.parseCommaTerm();
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "lambda");
            try addKV(obj, self.gc, "params", params);
            try addKV(obj, self.gc, "body", body);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Apply")) {
            try self.expect('(');
            const fn_term = try self.parseTerm();
            const args = try self.parseCommaTerm();
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "apply");
            try addKV(obj, self.gc, "fn", fn_term);
            try addKV(obj, self.gc, "args", args);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Ctor")) {
            try self.expect('(');
            const name = try self.parseString();
            defer self.gc.allocator.free(name);
            const args = try self.parseCommaTerm();
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "constructor");
            try addKV(obj, self.gc, "name", try str(self.gc, name));
            try addKV(obj, self.gc, "args", args);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Let")) {
            try self.expect('(');
            const name = try self.parseString();
            defer self.gc.allocator.free(name);
            const value_term = try self.parseCommaTerm();
            const body = try self.parseCommaTerm();
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "let");
            try addKV(obj, self.gc, "name", try str(self.gc, name));
            try addKV(obj, self.gc, "value", value_term);
            try addKV(obj, self.gc, "body", body);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Ann")) {
            try self.expect('(');
            const term = try self.parseTerm();
            const type_term = try self.parseCommaTerm();
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "ann");
            try addKV(obj, self.gc, "term", term);
            try addKV(obj, self.gc, "type", type_term);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "Match")) {
            try self.expect('(');
            const scrutinee = try self.parseTerm();
            try self.expect(',');
            const cases = try self.parseCasePairs();
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "match");
            try addKV(obj, self.gc, "scrutinee", scrutinee);
            try addKV(obj, self.gc, "cases", cases);
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "PatVar")) {
            try self.expect('(');
            const name = try self.parseString();
            defer self.gc.allocator.free(name);
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "pat-var");
            try addKV(obj, self.gc, "name", try str(self.gc, name));
            return Value.makeObj(obj);
        }
        if (std.mem.eql(u8, ident, "PatWildcard")) {
            return Value.makeObj(try makeTaggedTerm(self.gc, "pat-wildcard"));
        }
        if (std.mem.eql(u8, ident, "PatCtor")) {
            try self.expect('(');
            const name = try self.parseString();
            defer self.gc.allocator.free(name);
            const args = try self.parseCommaTerm();
            try self.expect(')');
            const obj = try makeTaggedTerm(self.gc, "pat-ctor");
            try addKV(obj, self.gc, "name", try str(self.gc, name));
            try addKV(obj, self.gc, "args", args);
            return Value.makeObj(obj);
        }
        return error.UnexpectedChar;
    }

    fn parseTerm(self: *TermReader) anyerror!Value {
        self.skipWs();
        if (self.pos >= self.src.len) return error.UnexpectedEOF;
        if (self.src[self.pos] == '[') return self.parseVectorOfTerms();
        if (std.mem.startsWith(u8, self.src[self.pos..], "true")) {
            self.pos += 4;
            const obj = try makeMap(self.gc);
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, "bool"));
            try addKV(obj, self.gc, "value", Value.makeBool(true));
            return Value.makeObj(obj);
        }
        if (std.mem.startsWith(u8, self.src[self.pos..], "false")) {
            self.pos += 5;
            const obj = try makeMap(self.gc);
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, "bool"));
            try addKV(obj, self.gc, "value", Value.makeBool(false));
            return Value.makeObj(obj);
        }
        if (self.src[self.pos] == '-' or std.ascii.isDigit(self.src[self.pos])) {
            const num = try self.parseNumberValue();
            const obj = try makeMap(self.gc);
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, if (num.isInt()) "int" else "double"));
            try addKV(obj, self.gc, "value", num);
            return Value.makeObj(obj);
        }
        const ident = try self.parseIdent();
        if (std.mem.eql(u8, ident, "Unit")) {
            const obj = try makeMap(self.gc);
            try addKV(obj, self.gc, "juvix/tag", try kw(self.gc, "unit"));
            return Value.makeObj(obj);
        }
        return self.parseCtor(ident);
    }
};

fn parseEncodedSource(src: []const u8, gc: *GC) anyerror!Value {
    var reader = TermReader{ .src = src, .gc = gc };
    const term = try reader.parseTerm();
    reader.skipWs();
    if (reader.pos != reader.src.len) return error.UnexpectedChar;
    return term;
}

pub fn juvixPrintFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const encoded = if (isEncodedTerm(gc, args[0])) args[0] else try encodeValue(args[0], gc);
    const src = try printEncodedSource(encoded, gc);
    defer gc.allocator.free(src);
    return str(gc, src);
}

pub fn juvixParseFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    return parseEncodedSource(gc.getString(args[0].asStringId()), gc);
}

pub fn juvixReadFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    const encoded = try parseEncodedSource(gc.getString(args[0].asStringId()), gc);
    return decodeValue(encoded, gc);
}

fn encodeTermList(gc: *GC, values: []Value) anyerror!Value {
    const vec = try makeVector(gc);
    for (values) |v| try vec.data.vector.items.append(gc.allocator, try encodeValue(v, gc));
    return Value.makeObj(vec);
}

pub fn juvixLambdaFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isObj() or args[0].asObj().kind != .vector) return error.TypeError;
    const out = try makeTaggedTerm(gc, "lambda");
    try addKV(out, gc, "params", try encodeTermList(gc, args[0].asObj().data.vector.items.items));
    try addKV(out, gc, "body", try encodeValue(args[1], gc));
    return Value.makeObj(out);
}

pub fn juvixApplyFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const out = try makeTaggedTerm(gc, "apply");
    try addKV(out, gc, "fn", try encodeValue(args[0], gc));
    try addKV(out, gc, "args", try encodeTermList(gc, args[1..]));
    return Value.makeObj(out);
}

pub fn juvixCtorFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const out = try makeTaggedTerm(gc, "constructor");
    try addKV(out, gc, "name", try str(gc, gc.getString(args[0].asStringId())));
    try addKV(out, gc, "args", try encodeTermList(gc, args[1..]));
    return Value.makeObj(out);
}

pub fn juvixLetFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3 or !args[0].isString()) return error.ArityError;
    const out = try makeTaggedTerm(gc, "let");
    try addKV(out, gc, "name", try str(gc, gc.getString(args[0].asStringId())));
    try addKV(out, gc, "value", try encodeValue(args[1], gc));
    try addKV(out, gc, "body", try encodeValue(args[2], gc));
    return Value.makeObj(out);
}

pub fn juvixAnnFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const out = try makeTaggedTerm(gc, "ann");
    try addKV(out, gc, "term", try encodeValue(args[0], gc));
    try addKV(out, gc, "type", try encodeValue(args[1], gc));
    return Value.makeObj(out);
}

pub fn juvixMatchFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[1].isObj() or args[1].asObj().kind != .vector) return error.TypeError;
    const out = try makeTaggedTerm(gc, "match");
    const cases = try makeVector(gc);
    for (args[1].asObj().data.vector.items.items) |case_term| {
        if (!case_term.isObj() or case_term.asObj().kind != .vector or case_term.asObj().data.vector.items.items.len != 2) return error.TypeError;
        const pair = try makeVector(gc);
        const lhs = case_term.asObj().data.vector.items.items[0];
        const rhs = case_term.asObj().data.vector.items.items[1];
        try pair.data.vector.items.append(gc.allocator, if (isEncodedTerm(gc, lhs)) lhs else try encodeValue(lhs, gc));
        try pair.data.vector.items.append(gc.allocator, if (isEncodedTerm(gc, rhs)) rhs else try encodeValue(rhs, gc));
        try cases.data.vector.items.append(gc.allocator, Value.makeObj(pair));
    }
    try addKV(out, gc, "scrutinee", if (isEncodedTerm(gc, args[0])) args[0] else try encodeValue(args[0], gc));
    try addKV(out, gc, "cases", Value.makeObj(cases));
    return Value.makeObj(out);
}

pub fn juvixPatVarFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    const out = try makeTaggedTerm(gc, "pat-var");
    try addKV(out, gc, "name", try str(gc, gc.getString(args[0].asStringId())));
    return Value.makeObj(out);
}

pub fn juvixPatWildcardFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return Value.makeObj(try makeTaggedTerm(gc, "pat-wildcard"));
}

pub fn juvixPatCtorFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const out = try makeTaggedTerm(gc, "pat-ctor");
    try addKV(out, gc, "name", try str(gc, gc.getString(args[0].asStringId())));
    try addKV(out, gc, "args", try encodeTermList(gc, args[1..]));
    return Value.makeObj(out);
}

test "juvix bridge roundtrips list/vector/map fragment" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.initDefault();

    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.append(gc.allocator, Value.makeInt(7));
    try vec.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString("ok")));

    const map = try gc.allocObj(.map);
    try map.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("k")));
    try map.data.map.vals.append(gc.allocator, Value.makeObj(vec));

    var args = [_]Value{Value.makeObj(map)};
    const encoded = try juvixEncodeFn(args[0..], &gc, &env, &res);
    var decode_args = [_]Value{encoded};
    const decoded = try juvixDecodeFn(decode_args[0..], &gc, &env, &res);

    try std.testing.expect(decoded.isObj());
    try std.testing.expectEqual(value.ObjKind.map, decoded.asObj().kind);
    try std.testing.expectEqual(@as(usize, 1), decoded.asObj().data.map.keys.items.len);
}

test "juvix source print/read preserves fragment" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.initDefault();

    const lst = try gc.allocObj(.list);
    try lst.data.list.items.append(gc.allocator, Value.makeInt(3));
    try lst.data.list.items.append(gc.allocator, Value.makeKeyword(try gc.internString("z")));

    var print_args = [_]Value{Value.makeObj(lst)};
    const src = try juvixPrintFn(print_args[0..], &gc, &env, &res);
    try std.testing.expect(src.isString());

    var read_args = [_]Value{src};
    const decoded = try juvixReadFn(read_args[0..], &gc, &env, &res);
    try std.testing.expect(decoded.isObj());
    try std.testing.expectEqual(value.ObjKind.list, decoded.asObj().kind);
    try std.testing.expectEqual(@as(usize, 2), decoded.asObj().data.list.items.items.len);
}

test "juvix source parse/print preserves lambda apply ctor terms" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.initDefault();

    const params = try gc.allocObj(.vector);
    try params.data.vector.items.append(gc.allocator, Value.makeSymbol(try gc.internString("x")));

    var lam_args = [_]Value{ Value.makeObj(params), Value.makeSymbol(try gc.internString("x")) };
    const lam = try juvixLambdaFn(lam_args[0..], &gc, &env, &res);

    var app_args = [_]Value{ lam, Value.makeInt(5) };
    const app = try juvixApplyFn(app_args[0..], &gc, &env, &res);

    var ctor_args = [_]Value{ try str(&gc, "Just"), Value.makeInt(9) };
    const ctor = try juvixCtorFn(ctor_args[0..], &gc, &env, &res);

    var print_args = [_]Value{ app };
    const app_src = try juvixPrintFn(print_args[0..], &gc, &env, &res);
    try std.testing.expect(app_src.isString());
    try std.testing.expect(std.mem.indexOf(u8, gc.getString(app_src.asStringId()), "Apply(") != null);

    var parse_args = [_]Value{ app_src };
    const parsed = try juvixParseFn(parse_args[0..], &gc, &env, &res);
    try std.testing.expect(parsed.isObj());
    try std.testing.expect(getMapValueByKeyword(&gc, parsed, "juvix/tag") != null);

    print_args[0] = ctor;
    const ctor_src = try juvixPrintFn(print_args[0..], &gc, &env, &res);
    try std.testing.expect(std.mem.indexOf(u8, gc.getString(ctor_src.asStringId()), "Ctor(\"Just\"") != null);
}

test "juvix source parse/print preserves let ann and match terms" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.initDefault();

    var let_args = [_]Value{ try str(&gc, "x"), Value.makeInt(1), Value.makeSymbol(try gc.internString("x")) };
    const let_term = try juvixLetFn(let_args[0..], &gc, &env, &res);

    var ann_args = [_]Value{ Value.makeInt(1), try str(&gc, "Nat") };
    const ann_term = try juvixAnnFn(ann_args[0..], &gc, &env, &res);

    const case_vec = try gc.allocObj(.vector);
    const case1 = try gc.allocObj(.vector);
    try case1.data.vector.items.append(gc.allocator, try str(&gc, "Zero"));
    try case1.data.vector.items.append(gc.allocator, Value.makeInt(0));
    try case_vec.data.vector.items.append(gc.allocator, Value.makeObj(case1));
    var match_args = [_]Value{ Value.makeSymbol(try gc.internString("n")), Value.makeObj(case_vec) };
    const match_term = try juvixMatchFn(match_args[0..], &gc, &env, &res);

    var print_args = [_]Value{let_term};
    const let_src = try juvixPrintFn(print_args[0..], &gc, &env, &res);
    try std.testing.expect(std.mem.indexOf(u8, gc.getString(let_src.asStringId()), "Let(\"x\"") != null);

    print_args[0] = ann_term;
    const ann_src = try juvixPrintFn(print_args[0..], &gc, &env, &res);
    try std.testing.expect(std.mem.indexOf(u8, gc.getString(ann_src.asStringId()), "Ann(") != null);

    print_args[0] = match_term;
    const match_src = try juvixPrintFn(print_args[0..], &gc, &env, &res);
    try std.testing.expect(std.mem.indexOf(u8, gc.getString(match_src.asStringId()), "Match(") != null);

    var parse_args = [_]Value{match_src};
    const parsed = try juvixParseFn(parse_args[0..], &gc, &env, &res);
    try std.testing.expect(parsed.isObj());
    try std.testing.expect(getMapValueByKeyword(&gc, parsed, "juvix/tag") != null);
}

test "juvix source parse/print preserves first-class match patterns" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.initDefault();

    var pat_ctor_args = [_]Value{ try str(&gc, "Succ"), Value.makeObj(try makeTaggedTerm(&gc, "pat-wildcard")) };
    const pat_ctor = try juvixPatCtorFn(pat_ctor_args[0..], &gc, &env, &res);
    var pat_var_args = [_]Value{ try str(&gc, "n") };
    const pat_var = try juvixPatVarFn(pat_var_args[0..], &gc, &env, &res);

    const cases = try gc.allocObj(.vector);
    const case1 = try gc.allocObj(.vector);
    try case1.data.vector.items.append(gc.allocator, pat_ctor);
    try case1.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try cases.data.vector.items.append(gc.allocator, Value.makeObj(case1));
    const case2 = try gc.allocObj(.vector);
    try case2.data.vector.items.append(gc.allocator, pat_var);
    try case2.data.vector.items.append(gc.allocator, Value.makeInt(2));
    try cases.data.vector.items.append(gc.allocator, Value.makeObj(case2));

    var match_args = [_]Value{ Value.makeSymbol(try gc.internString("m")), Value.makeObj(cases) };
    const match_term = try juvixMatchFn(match_args[0..], &gc, &env, &res);

    var print_args = [_]Value{match_term};
    const src = try juvixPrintFn(print_args[0..], &gc, &env, &res);
    const printed = gc.getString(src.asStringId());
    try std.testing.expect(std.mem.indexOf(u8, printed, "PatCtor(\"Succ\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "PatVar(\"n\"") != null);

    var parse_args = [_]Value{src};
    const parsed = try juvixParseFn(parse_args[0..], &gc, &env, &res);
    try std.testing.expect(parsed.isObj());
}
