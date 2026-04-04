const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

fn kw(gc: *GC, name: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(name));
}

fn strVal(gc: *GC, s: []const u8) !Value {
    return Value.makeString(try gc.internString(s));
}

fn put(map_obj: *Obj, gc: *GC, key: []const u8, val: Value) !void {
    try map_obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try map_obj.data.map.vals.append(gc.allocator, val);
}

fn vecOfStrings(gc: *GC, items: []const []const u8) !Value {
    const vec = try gc.allocObj(.vector);
    for (items) |item| {
        try vec.data.vector.items.append(gc.allocator, try strVal(gc, item));
    }
    return Value.makeObj(vec);
}

fn endpoint(
    gc: *GC,
    name: []const u8,
    method: []const u8,
    path: []const u8,
    query_params: []const []const u8,
    notes: ?[]const u8,
) !Value {
    const obj = try gc.allocObj(.map);
    try put(obj, gc, "name", try strVal(gc, name));
    try put(obj, gc, "method", Value.makeKeyword(try gc.internString(method)));
    try put(obj, gc, "path", try strVal(gc, path));
    try put(obj, gc, "auth", Value.makeKeyword(try gc.internString("bearer")));
    try put(obj, gc, "query", try vecOfStrings(gc, query_params));
    if (notes) |n| {
        try put(obj, gc, "notes", try strVal(gc, n));
    }
    return Value.makeObj(obj);
}

fn buildAvalonSpec(gc: *GC) !Value {
    const spec = try gc.allocObj(.map);
    try put(spec, gc, "title", try strVal(gc, "Avalon Integration API"));
    try put(spec, gc, "source", try strVal(gc, "https://api-avalon.avionsoftware.com/"));
    try put(spec, gc, "api-base-env", try strVal(gc, "apiBaseUrl"));

    const auth = try gc.allocObj(.map);
    try put(auth, gc, "method", Value.makeKeyword(try gc.internString("post")));
    try put(auth, gc, "path", try strVal(gc, "/api/auth"));
    const auth_body = try gc.allocObj(.map);
    try put(auth_body, gc, "User", try strVal(gc, "apiKey"));
    try put(auth_body, gc, "Password", try strVal(gc, "{{apiKey}}"));
    try put(auth, gc, "body", Value.makeObj(auth_body));
    try put(auth, gc, "response", try strVal(gc, "plain token"));
    try put(spec, gc, "auth", Value.makeObj(auth));

    const ops = try gc.allocObj(.vector);
    try ops.data.vector.items.append(gc.allocator, try endpoint(gc, "Packages", "get", "/api/packages", &.{ "startDate", "endDate" }, null));
    try ops.data.vector.items.append(gc.allocator, try endpoint(gc, "Transactions", "get", "/api/transactions", &.{ "startDate", "endDate" }, null));
    try ops.data.vector.items.append(gc.allocator, try endpoint(gc, "Consumers", "get", "/api/consumers", &.{ "startDate", "endDate" }, null));
    try ops.data.vector.items.append(gc.allocator, try endpoint(gc, "Reports", "get", "/api/reports", &.{ "startDate", "endDate" }, "Postman page lists Reports but sample request mirrors /api/consumers."));
    try ops.data.vector.items.append(gc.allocator, try endpoint(gc, "Consumers/save", "post", "/api/consumers/save", &[_][]const u8{}, "Body contains consumers array payload."));
    try put(spec, gc, "operations", Value.makeObj(ops));

    return Value.makeObj(spec);
}

/// (avalon-api-spec) -> map
/// Encodes a compact spec from https://api-avalon.avionsoftware.com/
pub fn avalonApiSpecFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return buildAvalonSpec(gc);
}

/// (avalon-api-example) -> map
/// Returns a minimal nanoclj-oriented request flow using the Avalon spec.
pub fn avalonApiExampleFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 0) return error.ArityError;

    const root = try gc.allocObj(.map);
    try put(root, gc, "spec", try buildAvalonSpec(gc));
    try put(root, gc, "nanoclj-snippet", try strVal(
        gc,
        "(let [spec (avalon-api-spec)] {:auth (get spec :auth) :op-count (count (get spec :operations))})",
    ));

    const flow = try gc.allocObj(.vector);

    const step1 = try gc.allocObj(.map);
    try put(step1, gc, "step", Value.makeInt(1));
    try put(step1, gc, "name", try strVal(gc, "Authenticate"));
    try put(step1, gc, "method", Value.makeKeyword(try gc.internString("post")));
    try put(step1, gc, "path", try strVal(gc, "/api/auth"));
    try put(step1, gc, "result", try strVal(gc, "token"));
    try flow.data.vector.items.append(gc.allocator, Value.makeObj(step1));

    const step2 = try gc.allocObj(.map);
    try put(step2, gc, "step", Value.makeInt(2));
    try put(step2, gc, "name", try strVal(gc, "List packages by date range"));
    try put(step2, gc, "method", Value.makeKeyword(try gc.internString("get")));
    try put(step2, gc, "path", try strVal(gc, "/api/packages"));
    try put(step2, gc, "query", try vecOfStrings(gc, &.{ "startDate=YYYYMMDD", "endDate=YYYYMMDD" }));
    try flow.data.vector.items.append(gc.allocator, Value.makeObj(step2));

    try put(root, gc, "flow", Value.makeObj(flow));
    return Value.makeObj(root);
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

test "avalon-api-spec: returns map with auth and operations" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const spec_val = try avalonApiSpecFn(&.{}, &gc, &env);
    try std.testing.expect(spec_val.isObj());
    const spec_obj = spec_val.asObj();
    try std.testing.expectEqual(ObjKind.map, spec_obj.kind);

    const auth_val = mapGetByKeyword(spec_obj, &gc, "auth") orelse return error.TestExpectedEqual;
    try std.testing.expect(auth_val.isObj());
    try std.testing.expectEqual(ObjKind.map, auth_val.asObj().kind);

    const ops_val = mapGetByKeyword(spec_obj, &gc, "operations") orelse return error.TestExpectedEqual;
    try std.testing.expect(ops_val.isObj());
    try std.testing.expectEqual(ObjKind.vector, ops_val.asObj().kind);
    try std.testing.expect(ops_val.asObj().data.vector.items.items.len >= 5);
}

test "avalon-api-example: includes 2-step flow" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    const ex_val = try avalonApiExampleFn(&.{}, &gc, &env);
    try std.testing.expect(ex_val.isObj());
    const ex_obj = ex_val.asObj();
    try std.testing.expectEqual(ObjKind.map, ex_obj.kind);

    const flow_val = mapGetByKeyword(ex_obj, &gc, "flow") orelse return error.TestExpectedEqual;
    try std.testing.expect(flow_val.isObj());
    const flow_obj = flow_val.asObj();
    try std.testing.expectEqual(ObjKind.vector, flow_obj.kind);
    try std.testing.expectEqual(@as(usize, 2), flow_obj.data.vector.items.items.len);
}
