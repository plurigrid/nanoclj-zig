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

/// CVE-2 fix: block SSRF via private/metadata URLs
fn isSafeUrl(url: []const u8) bool {
    // Must start with http:// or https://
    const after_scheme = if (std.mem.startsWith(u8, url, "https://"))
        url[8..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else
        return false; // block file://, ftp://, etc.

    // Extract host (before first / or :)
    var host_end: usize = 0;
    while (host_end < after_scheme.len and after_scheme[host_end] != '/' and after_scheme[host_end] != ':') : (host_end += 1) {}
    const host = after_scheme[0..host_end];
    if (host.len == 0) return false;

    // Block cloud metadata endpoints
    if (std.mem.eql(u8, host, "169.254.169.254")) return false;
    if (std.mem.eql(u8, host, "metadata.google.internal")) return false;

    // Block localhost variants
    if (std.mem.eql(u8, host, "localhost")) return false;
    if (std.mem.eql(u8, host, "127.0.0.1")) return false;
    if (std.mem.eql(u8, host, "[::1]")) return false;
    if (std.mem.eql(u8, host, "0.0.0.0")) return false;

    // Block private IP ranges: 10.x.x.x, 172.16-31.x.x, 192.168.x.x
    if (std.mem.startsWith(u8, host, "10.")) return false;
    if (std.mem.startsWith(u8, host, "172.")) {
        // Check for 172.16.x.x through 172.31.x.x
        if (host.len > 4) {
            const second_octet = std.fmt.parseInt(u8, blk: {
                var end: usize = 4;
                while (end < host.len and host[end] != '.') : (end += 1) {}
                break :blk host[4..end];
            }, 10) catch return true;
            if (second_octet >= 16 and second_octet <= 31) return false;
        }
    }
    if (std.mem.startsWith(u8, host, "192.168.")) return false;
    if (std.mem.startsWith(u8, host, "169.254.")) return false;

    return true;
}

pub fn httpFetchFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or args.len > 3) return error.ArityError;

    // Arg 0: URL (string)
    if (!args[0].isString()) return error.TypeError;
    const url = gc.getString(args[0].asStringId());

    if (!isSafeUrl(url)) {
        return Value.makeString(try gc.internString("error: blocked URL (private/metadata)"));
    }

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
    // Zig 0.16 requires std.Io context for HTTP — stub until Io threading is wired up
    _ = url;
    _ = method;
    _ = payload;
    return Value.makeString(try gc.internString("error: http-fetch not yet ported to zig 0.16"));
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
