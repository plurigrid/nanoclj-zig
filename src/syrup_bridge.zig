const std = @import("std");
const syrup = @import("syrup");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;

pub fn nanoclj_to_syrup(v: Value, gc: *GC, alloc: std.mem.Allocator) !syrup.Value {
    if (v.isNil()) return syrup.Value{ .@"null" = {} };
    if (v.isBool()) return syrup.Value.fromBool(v.asBool());
    if (v.isInt()) return syrup.Value.fromInteger(@as(i64, v.asInt()));
    if (v.isFloat()) return syrup.Value{ .float = v.asFloat() };
    if (v.isSymbol()) {
        const name = gc.getString(v.asSymbolId());
        return syrup.Value.fromSymbol(name);
    }
    if (v.isKeyword()) {
        const name = gc.getString(v.asKeywordId());
        return syrup.Value.fromSymbol(name);
    }
    if (v.isString()) {
        const s = gc.getString(v.asStringId());
        return syrup.Value.fromString(s);
    }
    if (v.isObj()) {
        const obj = v.asObj();
        switch (obj.kind) {
            .list, .vector => {
                const items = if (obj.kind == .list) obj.data.list.items.items else obj.data.vector.items.items;
                var syrup_items = try alloc.alloc(syrup.Value, items.len);
                for (items, 0..) |item, i| {
                    syrup_items[i] = try nanoclj_to_syrup(item, gc, alloc);
                }
                return syrup.Value.fromList(syrup_items);
            },
            .map => {
                const keys = obj.data.map.keys.items;
                const vals = obj.data.map.vals.items;
                var entries = try alloc.alloc(syrup.Value.DictEntry, keys.len);
                for (keys, vals, 0..) |k, vl, i| {
                    entries[i] = .{
                        .key = try nanoclj_to_syrup(k, gc, alloc),
                        .value = try nanoclj_to_syrup(vl, gc, alloc),
                    };
                }
                return syrup.Value.fromDictionary(entries);
            },
            .set => {
                const items = obj.data.set.items.items;
                var syrup_items = try alloc.alloc(syrup.Value, items.len);
                for (items, 0..) |item, i| {
                    syrup_items[i] = try nanoclj_to_syrup(item, gc, alloc);
                }
                return syrup.Value.fromSet(syrup_items);
            },
            else => return syrup.Value.fromString("<fn>"),
        }
    }
    return syrup.Value{ .@"null" = {} };
}

pub fn encode_to_bytes(v: Value, gc: *GC, alloc: std.mem.Allocator) ![]const u8 {
    const sv = try nanoclj_to_syrup(v, gc, alloc);
    return sv.encodeAlloc(alloc);
}

pub fn syrup_to_nanoclj(sv: syrup.Value, gc: *GC) !Value {
    switch (sv) {
        .@"null" => return Value.makeNil(),
        .bool => |b| return Value.makeBool(b),
        .integer => |i| return Value.makeInt(@intCast(@min(i, std.math.maxInt(i48)))),
        .float => |f| return Value.makeFloat(f),
        .string => |s| return Value.makeString(try gc.internString(s)),
        .symbol => |s| return Value.makeSymbol(try gc.internString(s)),
        .list => |items| {
            const obj = try gc.allocObj(.list);
            for (items) |item| {
                try obj.data.list.items.append(gc.allocator, try syrup_to_nanoclj(item, gc));
            }
            return Value.makeObj(obj);
        },
        .dictionary => |entries| {
            const obj = try gc.allocObj(.map);
            for (entries) |entry| {
                try obj.data.map.keys.append(gc.allocator, try syrup_to_nanoclj(entry.key, gc));
                try obj.data.map.vals.append(gc.allocator, try syrup_to_nanoclj(entry.value, gc));
            }
            return Value.makeObj(obj);
        },
        .set => |items| {
            const obj = try gc.allocObj(.set);
            for (items) |item| {
                try obj.data.set.items.append(gc.allocator, try syrup_to_nanoclj(item, gc));
            }
            return Value.makeObj(obj);
        },
        else => return Value.makeNil(),
    }
}

pub fn decode_from_bytes(raw: []const u8, gc: *GC, alloc: std.mem.Allocator) !Value {
    const sv = try syrup.decode(raw, alloc);
    return syrup_to_nanoclj(sv, gc);
}
