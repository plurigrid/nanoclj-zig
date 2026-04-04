const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const compat = @import("compat.zig");

pub fn prStr(val: Value, gc: *GC, readably: bool) ![]const u8 {
    var buf = compat.emptyList(u8);
    try prStrInto(&buf, val, gc, readably);
    return buf.toOwnedSlice(gc.allocator);
}

pub fn prStrInto(buf: *std.ArrayListUnmanaged(u8), val: Value, gc: *GC, readably: bool) !void {
    if (val.isNil()) {
        try buf.appendSlice(gc.allocator, "nil");
    } else if (val.isBool()) {
        try buf.appendSlice(gc.allocator, if (val.asBool()) "true" else "false");
    } else if (val.isInt()) {
        var tmp: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{val.asInt()}) catch unreachable;
        try buf.appendSlice(gc.allocator, s);
    } else if (val.isSymbol()) {
        try buf.appendSlice(gc.allocator, gc.getString(val.asSymbolId()));
    } else if (val.isKeyword()) {
        try buf.append(gc.allocator, ':');
        try buf.appendSlice(gc.allocator, gc.getString(val.asKeywordId()));
    } else if (val.isString()) {
        const s = gc.getString(val.asStringId());
        if (readably) {
            try buf.append(gc.allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(gc.allocator, "\\\""),
                    '\\' => try buf.appendSlice(gc.allocator, "\\\\"),
                    '\n' => try buf.appendSlice(gc.allocator, "\\n"),
                    '\t' => try buf.appendSlice(gc.allocator, "\\t"),
                    else => try buf.append(gc.allocator, c),
                }
            }
            try buf.append(gc.allocator, '"');
        } else {
            try buf.appendSlice(gc.allocator, s);
        }
    } else if (val.isObj()) {
        const obj = val.asObj();
        switch (obj.kind) {
            .list => {
                try buf.append(gc.allocator, '(');
                for (obj.data.list.items.items, 0..) |item, i| {
                    if (i > 0) try buf.append(gc.allocator, ' ');
                    try prStrInto(buf, item, gc, readably);
                }
                try buf.append(gc.allocator, ')');
            },
            .vector => {
                try buf.append(gc.allocator, '[');
                for (obj.data.vector.items.items, 0..) |item, i| {
                    if (i > 0) try buf.append(gc.allocator, ' ');
                    try prStrInto(buf, item, gc, readably);
                }
                try buf.append(gc.allocator, ']');
            },
            .map => {
                try buf.append(gc.allocator, '{');
                for (obj.data.map.keys.items, 0..) |key, i| {
                    if (i > 0) try buf.appendSlice(gc.allocator, ", ");
                    try prStrInto(buf, key, gc, readably);
                    try buf.append(gc.allocator, ' ');
                    try prStrInto(buf, obj.data.map.vals.items[i], gc, readably);
                }
                try buf.append(gc.allocator, '}');
            },
            .set => {
                try buf.appendSlice(gc.allocator, "#{");
                for (obj.data.set.items.items, 0..) |item, i| {
                    if (i > 0) try buf.append(gc.allocator, ' ');
                    try prStrInto(buf, item, gc, readably);
                }
                try buf.append(gc.allocator, '}');
            },
            .function => {
                try buf.appendSlice(gc.allocator, "#<fn");
                if (obj.data.function.name) |n| {
                    try buf.append(gc.allocator, ' ');
                    try buf.appendSlice(gc.allocator, n);
                }
                try buf.append(gc.allocator, '>');
            },
            .macro_fn => try buf.appendSlice(gc.allocator, "#<macro>"),
            .atom => {
                try buf.appendSlice(gc.allocator, "(atom ");
                try prStrInto(buf, obj.data.atom.val, gc, readably);
                try buf.append(gc.allocator, ')');
            },
            .bc_closure => try buf.appendSlice(gc.allocator, "#<bc-fn>"),
        }
    } else {
        // float
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{val.asFloat()}) catch unreachable;
        try buf.appendSlice(gc.allocator, s);
    }
}
