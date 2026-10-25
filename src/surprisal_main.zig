//! Focused host for the existing nanoclj reader and bounded evaluator.
//! Host reads a file/argument and prints the result; evaluated code receives
//! only the pure surprisal namespace. This is not a general Babashka runtime.
const std = @import("std");
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const Value = @import("value.zig").Value;
const core = @import("core.zig");
const semantics = @import("semantics.zig");
const bridge = @import("surprisal_value.zig");
const printer = @import("printer.zig");

// Reader.skipWhitespace is private. Distinguish trailing trivia from an
// incomplete form before readForm so malformed files cannot silently truncate.
fn triviaOnly(src: []const u8) bool {
    var comment = false;
    for (src) |c| {
        if (comment) {
            if (c == '\n') comment = false;
        } else if (c == ';') {
            comment = true;
        } else if (c != ',' and !std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const source = if (args.len == 3 and std.mem.eql(u8, args[1], "-e")) args[2] else if (args.len == 2)
        try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(1024 * 1024))
    else {
        try std.Io.File.stderr().writeStreamingAll(init.io, "Usage: zig build surprisal -- FILE.clj | -e EXPR\n");
        return error.InvalidArguments;
    };
    var gc = GC.init(allocator);
    defer gc.deinit();
    var env = Env.init(allocator, null);
    env.is_root = true;
    defer env.deinit();
    defer core.deinitCore();
    try bridge.register(&env, &gc);
    var reader = Reader.init(source, &gc);
    var result = Value.makeNil();
    var res = semantics.Resources.init(.{ .max_fuel = 1000000, .max_depth = 64 });
    while (!triviaOnly(reader.src[reader.pos..])) {
        const form = try reader.readForm();
        const domain = semantics.evalBounded(form, &env, &gc, &res);
        result = switch (domain) {
            .value => |v| v,
            .bottom => return error.ResourceLimit,
            .err => return error.EvaluationFailed,
        };
        // Stop at the first domain error instead of discarding it when the
        // input contains subsequent top-level forms.
        if (isDomainError(result, &gc)) break;
    }
    const text = try printer.prStr(result, &gc, true);
    try std.Io.File.stdout().writeStreamingAll(init.io, text);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (isDomainError(result, &gc)) return error.SurprisalFailed;
}

fn isDomainError(v: Value, gc: *GC) bool {
    if (!v.isObj() or v.asObj().kind != .map) return false;
    for (v.asObj().data.map.keys.items) |k| {
        if (k.isKeyword() and std.mem.eql(u8, gc.getString(k.asKeywordId()), "surprisal/error")) return true;
    }
    return false;
}
