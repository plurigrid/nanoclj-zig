//! CongruNet — summarize top-level source history as a tiny congruence network.
//!
//! Initial surface:
//! - each top-level form = a node
//! - consecutive forms = edges
//! - shared symbols between neighboring forms = adhesions
//! - summary is a map, not a full net encoding

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn isDelimiter(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}';
}

fn isNumeric(tok: []const u8) bool {
    if (tok.len == 0) return false;
    var i: usize = if (tok[0] == '-') 1 else 0;
    if (i >= tok.len) return false;
    while (i < tok.len) : (i += 1) {
        if (!std.ascii.isDigit(tok[i])) return false;
    }
    return true;
}

fn tokenInList(tokens: []const []const u8, tok: []const u8) bool {
    for (tokens) |existing| {
        if (std.mem.eql(u8, existing, tok)) return true;
    }
    return false;
}

pub const Summary = struct {
    forms: usize,
    edges: usize,
    adhesions: usize,
    defs: usize,
    unique_symbols: usize,
    reused_symbols: usize,
    max_depth: usize,
    max_bag_size: usize,
    fingerprint: u64,
    bag_sizes: []usize,
    adhesion_sizes: []usize,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.bag_sizes);
        allocator.free(self.adhesion_sizes);
    }
};

pub const TraceEntry = struct {
    bag_size: usize,
    adhesion_size: usize,
    max_depth: usize,
    defs: usize,
    symbols: []const []const u8,
};

fn summarizeSource(src: []const u8, allocator: std.mem.Allocator) !Summary {
    var unique_symbols = std.ArrayListUnmanaged([]const u8).empty;
    defer unique_symbols.deinit(allocator);
    var prev_symbols = std.ArrayListUnmanaged([]const u8).empty;
    defer prev_symbols.deinit(allocator);
    var curr_symbols = std.ArrayListUnmanaged([]const u8).empty;
    defer curr_symbols.deinit(allocator);
    var bag_sizes = std.ArrayListUnmanaged(usize).empty;
    defer bag_sizes.deinit(allocator);
    var adhesion_sizes = std.ArrayListUnmanaged(usize).empty;
    defer adhesion_sizes.deinit(allocator);

    var forms: usize = 0;
    var adhesions: usize = 0;
    var defs: usize = 0;
    var depth: usize = 0;
    var max_depth: usize = 0;
    var max_bag_size: usize = 0;
    var reused_symbols: usize = 0;
    var in_form = false;
    var first_token_in_form = true;
    var i: usize = 0;
    var fingerprint = std.hash.Fnv1a_64.init();

    while (i < src.len) {
        const c = src[i];
        fingerprint.update(&[_]u8{c});

        switch (c) {
            '(', '[', '{' => {
                depth += 1;
                if (depth > max_depth) max_depth = depth;
                if (!in_form and depth == 1) {
                    in_form = true;
                    first_token_in_form = true;
                    prev_symbols.deinit(allocator);
                    prev_symbols = curr_symbols;
                    curr_symbols = .empty;
                    forms += 1;
                }
                i += 1;
            },
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
                if (in_form and depth == 0) {
                    const bag_size = curr_symbols.items.len;
                    try bag_sizes.append(allocator, bag_size);
                    if (bag_size > max_bag_size) max_bag_size = bag_size;
                    if (forms > 1) {
                        var shared_count: usize = 0;
                        for (curr_symbols.items) |tok| {
                            if (tokenInList(prev_symbols.items, tok)) {
                                adhesions += 1;
                                shared_count += 1;
                            }
                        }
                        try adhesion_sizes.append(allocator, shared_count);
                        reused_symbols += shared_count;
                    }
                    in_form = false;
                }
                i += 1;
            },
            ';' => {
                while (i < src.len and src[i] != '\n') : (i += 1) {}
            },
            else => {
                if (isDelimiter(c)) {
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < src.len and !isDelimiter(src[i]) and src[i] != ';') : (i += 1) {}
                const tok = src[start..i];
                if (in_form and tok.len > 0 and !isNumeric(tok)) {
                    if (first_token_in_form and std.mem.eql(u8, tok, "def")) defs += 1;
                    first_token_in_form = false;
                    if (!tokenInList(curr_symbols.items, tok)) try curr_symbols.append(allocator, tok);
                    if (!tokenInList(unique_symbols.items, tok)) try unique_symbols.append(allocator, tok);
                }
            },
        }
    }

    return .{
        .forms = forms,
        .edges = if (forms > 0) forms - 1 else 0,
        .adhesions = adhesions,
        .defs = defs,
        .unique_symbols = unique_symbols.items.len,
        .reused_symbols = reused_symbols,
        .max_depth = max_depth,
        .max_bag_size = max_bag_size,
        .fingerprint = fingerprint.final(),
        .bag_sizes = try allocator.dupe(usize, bag_sizes.items),
        .adhesion_sizes = try allocator.dupe(usize, adhesion_sizes.items),
    };
}

fn makeIntVector(gc: *GC, vals: []const usize) !Value {
    const vec = try gc.allocObj(.vector);
    for (vals) |v| {
        try vec.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(v)));
    }
    return Value.makeObj(vec);
}

fn makeStringVector(gc: *GC, vals: []const []const u8) !Value {
    const vec = try gc.allocObj(.vector);
    for (vals) |v| {
        try vec.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(v)));
    }
    return Value.makeObj(vec);
}

fn appendTraceEntry(
    entries: *std.ArrayListUnmanaged(TraceEntry),
    allocator: std.mem.Allocator,
    prev_symbols: []const []const u8,
    curr_symbols: []const []const u8,
    defs: usize,
    form_max_depth: usize,
) !void {
    var adhesion_size: usize = 0;
    for (curr_symbols) |tok| {
        if (tokenInList(prev_symbols, tok)) adhesion_size += 1;
    }
    try entries.append(allocator, .{
        .bag_size = curr_symbols.len,
        .adhesion_size = adhesion_size,
        .max_depth = form_max_depth,
        .defs = defs,
        .symbols = try allocator.dupe([]const u8, curr_symbols),
    });
}

fn freeTrace(entries: []TraceEntry, allocator: std.mem.Allocator) void {
    for (entries) |entry| allocator.free(entry.symbols);
    allocator.free(entries);
}

fn traceSource(src: []const u8, allocator: std.mem.Allocator) ![]TraceEntry {
    var prev_symbols = std.ArrayListUnmanaged([]const u8).empty;
    defer prev_symbols.deinit(allocator);
    var curr_symbols = std.ArrayListUnmanaged([]const u8).empty;
    defer curr_symbols.deinit(allocator);
    var entries = std.ArrayListUnmanaged(TraceEntry).empty;
    defer entries.deinit(allocator);

    var depth: usize = 0;
    var in_form = false;
    var first_token_in_form = true;
    var form_defs: usize = 0;
    var form_max_depth: usize = 0;
    var i: usize = 0;

    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '(', '[', '{' => {
                depth += 1;
                if (in_form and depth > form_max_depth) form_max_depth = depth;
                if (!in_form and depth == 1) {
                    in_form = true;
                    first_token_in_form = true;
                    form_defs = 0;
                    form_max_depth = 1;
                    prev_symbols.deinit(allocator);
                    prev_symbols = curr_symbols;
                    curr_symbols = .empty;
                }
                i += 1;
            },
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
                if (in_form and depth == 0) {
                    try appendTraceEntry(&entries, allocator, prev_symbols.items, curr_symbols.items, form_defs, form_max_depth);
                    in_form = false;
                }
                i += 1;
            },
            ';' => while (i < src.len and src[i] != '\n') : (i += 1) {},
            else => {
                if (isDelimiter(c)) {
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < src.len and !isDelimiter(src[i]) and src[i] != ';') : (i += 1) {}
                const tok = src[start..i];
                if (in_form and tok.len > 0 and !isNumeric(tok)) {
                    if (first_token_in_form and std.mem.eql(u8, tok, "def")) form_defs += 1;
                    first_token_in_form = false;
                    if (!tokenInList(curr_symbols.items, tok)) try curr_symbols.append(allocator, tok);
                }
            },
        }
    }

    return try allocator.dupe(TraceEntry, entries.items);
}

pub fn congrunetSummaryFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const src = gc.getString(args[0].asStringId());
    var summary = try summarizeSource(src, gc.allocator);
    defer summary.deinit(gc.allocator);

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "forms", Value.makeInt(@intCast(summary.forms)));
    try addKV(obj, gc, "edges", Value.makeInt(@intCast(summary.edges)));
    try addKV(obj, gc, "adhesions", Value.makeInt(@intCast(summary.adhesions)));
    try addKV(obj, gc, "defs", Value.makeInt(@intCast(summary.defs)));
    try addKV(obj, gc, "unique-symbols", Value.makeInt(@intCast(summary.unique_symbols)));
    try addKV(obj, gc, "reused-symbols", Value.makeInt(@intCast(summary.reused_symbols)));
    try addKV(obj, gc, "max-depth", Value.makeInt(@intCast(summary.max_depth)));
    try addKV(obj, gc, "max-bag-size", Value.makeInt(@intCast(summary.max_bag_size)));
    try addKV(obj, gc, "bag-sizes", try makeIntVector(gc, summary.bag_sizes));
    try addKV(obj, gc, "adhesion-sizes", try makeIntVector(gc, summary.adhesion_sizes));
    try addKV(obj, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(summary.fingerprint)))));
    return Value.makeObj(obj);
}

pub fn congrunetTraceFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const src = gc.getString(args[0].asStringId());
    const trace = try traceSource(src, gc.allocator);
    defer freeTrace(trace, gc.allocator);

    const vec = try gc.allocObj(.vector);
    for (trace, 0..) |entry, i| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "index", Value.makeInt(@intCast(i)));
        try addKV(obj, gc, "bag-size", Value.makeInt(@intCast(entry.bag_size)));
        try addKV(obj, gc, "adhesion-size", Value.makeInt(@intCast(entry.adhesion_size)));
        try addKV(obj, gc, "max-depth", Value.makeInt(@intCast(entry.max_depth)));
        try addKV(obj, gc, "defs", Value.makeInt(@intCast(entry.defs)));
        try addKV(obj, gc, "symbols", try makeStringVector(gc, entry.symbols));
        try vec.data.vector.items.append(gc.allocator, Value.makeObj(obj));
    }
    return Value.makeObj(vec);
}

pub fn congrunetPresheafFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (!args[0].isString()) return error.TypeError;

    const src = gc.getString(args[0].asStringId());
    const trace = try traceSource(src, gc.allocator);
    defer freeTrace(trace, gc.allocator);

    const bags = try gc.allocObj(.vector);
    for (trace, 0..) |entry, i| {
        const bag = try gc.allocObj(.map);
        try addKV(bag, gc, "node", Value.makeInt(@intCast(i)));
        try addKV(bag, gc, "bag-size", Value.makeInt(@intCast(entry.bag_size)));
        try addKV(bag, gc, "symbols", try makeStringVector(gc, entry.symbols));
        try bags.data.vector.items.append(gc.allocator, Value.makeObj(bag));
    }

    const adhesions = try gc.allocObj(.vector);
    if (trace.len > 1) {
        for (1..trace.len) |i| {
            const adhesion = try gc.allocObj(.map);
            try addKV(adhesion, gc, "from", Value.makeInt(@intCast(i - 1)));
            try addKV(adhesion, gc, "to", Value.makeInt(@intCast(i)));
            try addKV(adhesion, gc, "adhesion-size", Value.makeInt(@intCast(trace[i].adhesion_size)));

            const overlap = try gc.allocObj(.vector);
            for (trace[i].symbols) |tok| {
                if (tokenInList(trace[i - 1].symbols, tok)) {
                    try overlap.data.vector.items.append(gc.allocator, Value.makeString(try gc.internString(tok)));
                }
            }
            try addKV(adhesion, gc, "overlap", Value.makeObj(overlap));
            try adhesions.data.vector.items.append(gc.allocator, Value.makeObj(adhesion));
        }
    }

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "bags", Value.makeObj(bags));
    try addKV(obj, gc, "adhesions", Value.makeObj(adhesions));
    try addKV(obj, gc, "nodes", Value.makeInt(@intCast(trace.len)));
    try addKV(obj, gc, "morphisms", Value.makeInt(@intCast(if (trace.len > 0) trace.len - 1 else 0)));
    return Value.makeObj(obj);
}

test "congrunet summarizes top-level source history" {
    var summary = try summarizeSource("(def answer 42)\n(+ answer 8)", std.testing.allocator);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), summary.forms);
    try std.testing.expectEqual(@as(usize, 1), summary.edges);
    try std.testing.expectEqual(@as(usize, 1), summary.defs);
    try std.testing.expect(summary.adhesions >= 1);
    try std.testing.expect(summary.unique_symbols >= 2);
    try std.testing.expectEqual(@as(usize, 2), summary.bag_sizes.len);
    try std.testing.expectEqual(@as(usize, 1), summary.adhesion_sizes.len);
}

test "congrunet builtin returns map" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(def answer 42)\n(+ answer 8)");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try congrunetSummaryFn(&args, &gc, &env);
    try std.testing.expect(out.isObj());
    try std.testing.expect(out.asObj().kind == .map);
}

test "congrunet trace returns one node per top-level form" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(def answer 42)\n(+ answer 8)");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try congrunetTraceFn(&args, &gc, &env);
    try std.testing.expect(out.isObj());
    try std.testing.expect(out.asObj().kind == .vector);
    try std.testing.expectEqual(@as(usize, 2), out.asObj().data.vector.items.items.len);
}

test "congrunet presheaf returns bags and adhesions" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const src_id = try gc.internString("(def answer 42)\n(+ answer 8)");
    var args = [_]Value{Value.makeString(src_id)};
    const out = try congrunetPresheafFn(&args, &gc, &env);
    try std.testing.expect(out.isObj());
    try std.testing.expect(out.asObj().kind == .map);
}
