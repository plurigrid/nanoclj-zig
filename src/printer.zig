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
            .builtin_ref => {
                try buf.appendSlice(gc.allocator, "#<builtin ");
                try buf.appendSlice(gc.allocator, obj.data.builtin_ref.name);
                try buf.append(gc.allocator, '>');
            },
            .lazy_seq => try buf.appendSlice(gc.allocator, "#<lazy-seq>"),
            .partial_fn => try buf.appendSlice(gc.allocator, "#<partial>"),
            .multimethod => {
                try buf.appendSlice(gc.allocator, "#<multimethod ");
                try buf.appendSlice(gc.allocator, obj.data.multimethod.name);
                try buf.appendSlice(gc.allocator, ">");
            },
            .protocol => {
                try buf.appendSlice(gc.allocator, "#<protocol ");
                try buf.appendSlice(gc.allocator, obj.data.protocol.name);
                try buf.appendSlice(gc.allocator, ">");
            },
            .dense_f64 => {
                try buf.appendSlice(gc.allocator, "#<dense-f64 [");
                for (0..@min(obj.data.dense_f64.len, 5)) |i| {
                    if (i > 0) try buf.append(gc.allocator, ' ');
                    var tmp: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{d}", .{obj.data.dense_f64.get(i)}) catch "?";
                    try buf.appendSlice(gc.allocator, s);
                }
                if (obj.data.dense_f64.len > 5) try buf.appendSlice(gc.allocator, " ...");
                try buf.appendSlice(gc.allocator, "]>");
            },
            .trace => {
                try buf.appendSlice(gc.allocator, "#<trace ");
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "sites={d} w={d}", .{obj.data.trace.len(), obj.data.trace.log_weight}) catch "?";
                try buf.appendSlice(gc.allocator, s);
                try buf.append(gc.allocator, '>');
            },
            .rational => {
                const r = &obj.data.rational;
                if (r.denominator == 1) {
                    // Integer promotion: 5/1 prints as "5"
                    var tmp: [21]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{d}", .{r.numerator}) catch "?";
                    try buf.appendSlice(gc.allocator, s);
                } else {
                    var tmp: [43]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{d}/{d}", .{ r.numerator, r.denominator }) catch "?";
                    try buf.appendSlice(gc.allocator, s);
                }
            },
            .channel => {
                const ch = &obj.data.channel;
                var tmp: [64]u8 = undefined;
                const status = if (ch.closed) "closed" else "open";
                const s = std.fmt.bufPrint(&tmp, "#channel[{s} buf={d} cap={d}]", .{ status, ch.buf.items.len, ch.capacity }) catch "?";
                try buf.appendSlice(gc.allocator, s);
            },
            .agent => {
                const a = &obj.data.agent;
                try buf.appendSlice(gc.allocator, "#<agent ");
                try prStrInto(buf, a.state, gc, readably);
                if (a.mailbox.items.len > 0) {
                    var tmp: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, " pending={d}", .{a.mailbox.items.len}) catch "";
                    try buf.appendSlice(gc.allocator, s);
                }
                if (a.isStopped()) try buf.appendSlice(gc.allocator, " FAILED");
                try buf.append(gc.allocator, '>');
            },
            .file_handle => {
                const h = &obj.data.file_handle;
                const status = if (h.closed) "closed" else "open";
                var tmp: [80]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "#<file {s} fd={d} {s}>", .{ status, h.fd, h.path }) catch "#<file>";
                try buf.appendSlice(gc.allocator, s);
            },
            .bytes => {
                const b = &obj.data.bytes;
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "#bytes[{d}]<", .{b.data.len}) catch "#bytes<";
                try buf.appendSlice(gc.allocator, s);
                const preview_len = @min(b.data.len, 16);
                for (b.data[0..preview_len], 0..) |byte, i| {
                    if (i > 0) try buf.append(gc.allocator, ' ');
                    var hb: [2]u8 = undefined;
                    _ = std.fmt.bufPrint(&hb, "{x:0>2}", .{byte}) catch continue;
                    try buf.appendSlice(gc.allocator, &hb);
                }
                if (b.data.len > preview_len) try buf.appendSlice(gc.allocator, " ...");
                try buf.append(gc.allocator, '>');
            },
            .color => {
                const c = &obj.data.color;
                // OKLAB → linear sRGB → sRGB for ANSI true-color swatch
                const rgb = oklabToSrgb8(c.L, c.a, c.b);
                // Emit: ██ swatch in true color, then the readable form
                var swatch: [32]u8 = undefined;
                const sw = std.fmt.bufPrint(&swatch, "\x1b[38;2;{d};{d};{d}m\u{2588}\u{2588}\x1b[0m ", .{ rgb[0], rgb[1], rgb[2] }) catch "";
                try buf.appendSlice(gc.allocator, sw);
                try buf.appendSlice(gc.allocator, "#color[");
                var tmp: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d:.3} {d:.3} {d:.3} {d:.3}", .{ c.L, c.a, c.b, c.alpha }) catch "?";
                try buf.appendSlice(gc.allocator, s);
                try buf.append(gc.allocator, ']');
            },
        }
    } else {
        // float
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{val.asFloat()}) catch unreachable;
        try buf.appendSlice(gc.allocator, s);
    }
}

/// OKLAB → linear sRGB → gamma-compressed sRGB [0..255]
fn oklabToSrgb8(L: f32, a: f32, b: f32) [3]u8 {
    // OKLAB → LMS (cube roots)
    const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    // LMS → linear sRGB
    const r_lin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const g_lin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const b_lin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
    return .{
        gammaCompress(r_lin),
        gammaCompress(g_lin),
        gammaCompress(b_lin),
    };
}

fn gammaCompress(x: f32) u8 {
    const c = if (x <= 0.0) @as(f32, 0.0) else if (x >= 1.0) @as(f32, 1.0) else x;
    const g = if (c <= 0.0031308) 12.92 * c else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(g * 255.0);
}
