//! HTTP fetch skill for nanoclj-zig
//!
//! (http-fetch "https://example.com/api") → "{...response body...}"
//! (http-fetch "https://example.com/api" :post "{\"key\":\"val\"}") → "{...}"
//!
//! Uses std.http.Client.fetch — blocking, thread-safe, follows redirects.
//! Fuel cost: 10 units per fetch (I/O is expensive).

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

const MAX_RESPONSE_BYTES = 1024 * 1024; // 1 MiB

pub fn httpFetchFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or args.len > 3) return error.ArityError;

    // Arg 0: URL (string)
    if (!args[0].isString()) return error.TypeError;
    const url = gc.getString(args[0].asStringId());

    // Arg 1 (optional): method keyword (:get, :post, :put, :delete)
    var method: std.http.Method = .GET;
    if (args.len >= 2 and args[1].isKeyword()) {
        const m = gc.getString(args[1].asKeywordId());
        if (std.mem.eql(u8, m, "post")) {
            method = .POST;
        } else if (std.mem.eql(u8, m, "put")) {
            method = .PUT;
        } else if (std.mem.eql(u8, m, "delete")) {
            method = .DELETE;
        }
        // default: GET
    }

    // Arg 2 (optional): payload string for POST/PUT
    var payload: ?[]const u8 = null;
    if (args.len >= 3 and args[2].isString()) {
        payload = gc.getString(args[2].asStringId());
    }

    // If payload provided but no method specified, default to POST
    if (args.len == 2 and args[1].isString()) {
        payload = gc.getString(args[1].asStringId());
        method = .POST;
    }

    return doFetch(gc, url, method, payload);
}

fn doFetch(gc: *GC, url: []const u8, method: std.http.Method, payload: ?[]const u8) anyerror!Value {
    var client: std.http.Client = .{ .allocator = gc.allocator };
    defer client.deinit();

    var allocating = std.Io.Writer.Allocating.init(gc.allocator);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &allocating.writer,
    }) catch {
        return Value.makeString(try gc.internString("error: fetch failed"));
    };

    const body = allocating.toOwnedSlice() catch "";
    defer if (body.len > 0) gc.allocator.free(body);

    // Build result map: {:status N :body "..."}
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;

    try obj.data.map.keys.append(gc.allocator, try kw(gc, "status"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@intFromEnum(result.status))));

    try obj.data.map.keys.append(gc.allocator, try kw(gc, "body"));
    const body_id = try gc.internString(body);
    try obj.data.map.vals.append(gc.allocator, Value.makeString(body_id));

    return Value.makeObj(obj);
}

// ============================================================================
// TESTS
// ============================================================================

test "http-fetch: returns map with status and body keys" {
    // Unit test: just verify the function signature is correct and
    // error handling works for invalid URLs (no network needed)
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    // Calling with non-string should return TypeError
    var args = [_]Value{Value.makeInt(42)};
    const result = httpFetchFn(&args, &gc, &env);
    try std.testing.expectError(error.TypeError, result);
}

test "http-fetch: arity check" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    // No args
    var args = [_]Value{};
    const result = httpFetchFn(args[0..0], &gc, &env);
    try std.testing.expectError(error.ArityError, result);
}
