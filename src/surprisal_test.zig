const std = @import("std");
const Value = @import("value.zig").Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Reader = @import("reader.zig").Reader;
const core = @import("core.zig");
const bridge = @import("surprisal_value.zig");
const legacy = @import("eval.zig");
const semantics = @import("semantics.zig");

const Interpreter = struct {
    gc: GC,
    env: Env,

    fn init() !Interpreter {
        var result = Interpreter{ .gc = GC.init(std.testing.allocator), .env = Env.init(std.testing.allocator, null) };
        result.env.is_root = true;
        errdefer result.deinit();
        try bridge.register(&result.env, &result.gc);
        return result;
    }
    fn deinit(self: *Interpreter) void {
        core.deinitCore();
        self.env.deinit();
        self.gc.deinit();
    }
    fn eval(self: *Interpreter, source: []const u8, bounded: bool) !Value {
        var r = Reader.init(source, &self.gc);
        const form = try r.readForm();
        if (!bounded) return legacy.eval(form, &self.env, &self.gc);
        var res = semantics.Resources.init(.{ .max_fuel = 100000, .max_depth = 64 });
        const result = semantics.evalBounded(form, &self.env, &self.gc, &res);
        if (result != .value) return error.EvaluationFailed;
        return result.value;
    }
};

fn field(v: Value, gc: *GC, name: []const u8) !Value {
    if (!v.isObj() or v.asObj().kind != .map) return error.ExpectedMap;
    const m = v.asObj().data.map;
    for (m.keys.items, m.vals.items) |k, val| {
        if (k.isKeyword() and std.mem.eql(u8, name, gc.getString(k.asKeywordId()))) return val;
    }
    return error.MissingField;
}

const setup =
    \\(def area (surprisal/model :area/v1 [15 15 15 15 15 15 15 15]))
    \\(def carucate (surprisal/whole area))
    \\(def virgate (surprisal/event area [0 1]))
    \\(def oxgang (surprisal/event area [0]))
;

test "surprisal Clojure: live legacy and bounded evaluators reproduce 3 = 2 + 1" {
    for ([_]bool{ false, true }) |bounded| {
        var i = try Interpreter.init();
        defer i.deinit();
        const result = try i.eval("(do " ++ setup ++
            " [(surprisal/bits oxgang)" ++
            " (surprisal/refinement-bits (surprisal/refine carucate virgate))" ++
            " (surprisal/refinement-bits (surprisal/refine virgate oxgang))" ++
            " (surprisal/refinement-bits (surprisal/compose (surprisal/refine carucate virgate) (surprisal/refine virgate oxgang)))" ++
            " (surprisal/probability oxgang)])", bounded);
        const items = result.asObj().data.vector.items.items;
        try std.testing.expectEqual(@as(usize, 5), items.len);
        for (items, [_]f64{ 3, 2, 1, 3, 0.125 }) |actual, expected|
            try std.testing.expectApproxEqAbs(expected, actual.asFloat(), 1e-12);
    }
}

test "surprisal Clojure: context, revision, weights, and endpoint checks" {
    const cases = .{
        .{ "(surprisal/refine oxgang (surprisal/event (surprisal/model :work/v1 [15 15 15 15 15 15 15 15]) [0]))", "ModelMismatch" },
        .{ "(surprisal/union oxgang (surprisal/event (surprisal/model :area/v2 [15 15 15 15 15 15 15 15]) [0]))", "ModelMismatch" },
        .{ "(surprisal/intersection oxgang (surprisal/event (surprisal/model :area/v1 [30 15 15 15 15 15 15 15]) [0]))", "ModelMismatch" },
        .{ "(surprisal/subset? oxgang (surprisal/event (surprisal/model :area/v1 [15]) [0]))", "ModelMismatch" },
        .{ "(surprisal/refine oxgang virgate)", "NonNested" },
        .{ "(surprisal/refine (surprisal/event area []) (surprisal/event area []))", "ZeroCondition" },
        .{ "(surprisal/compose (surprisal/refine carucate virgate) (surprisal/refine carucate oxgang))", "EndpointsDoNotMatch" },
        .{ "(surprisal/refinement-bits {:surprisal/type :refinement :coarse oxgang :fine virgate})", "NonNested" },
        .{ "(surprisal/compose (surprisal/refine carucate oxgang) (surprisal/refine (surprisal/whole (surprisal/model :other/v1 [1])) (surprisal/whole (surprisal/model :other/v1 [1]))))", "ModelMismatch" },
    };
    inline for (cases) |case| {
        var i = try Interpreter.init();
        defer i.deinit();
        const v = try i.eval("(do " ++ setup ++ case[0] ++ ")", true);
        const err = try field(v, &i.gc, "surprisal/error");
        try std.testing.expectEqualStrings(case[1], i.gc.getString(err.asKeywordId()));
    }
}

test "surprisal Clojure: invalid data is distinguishable from zero probability" {
    const cases = .{
        .{ "(surprisal/model :v [])", "InvalidModel" },
        .{ "(surprisal/model :v [0 0])", "ZeroTotal" },
        .{ "(surprisal/model :v [1 -1])", "NegativeWeight" },
        .{ "(surprisal/model :v [1.0])", "ExpectedIntegerWeight" },
        .{ "(surprisal/model :v [true])", "ExpectedIntegerWeight" },
        .{ "(surprisal/model nil [1])", "InvalidContext" },
        .{ "(surprisal/model :v '(1))", "ExpectedVector" },
        .{ "(surprisal/event (surprisal/model :v [1]) [-1])", "AtomOutOfRange" },
        .{ "(surprisal/event (surprisal/model :v [1]) [1])", "AtomOutOfRange" },
        .{ "(surprisal/event (surprisal/model :v [1]) [0.0])", "ExpectedIntegerIndex" },
        .{ "(surprisal/bits nil)", "InvalidRecord" },
        .{ "(surprisal/bits {:surprisal/type :event :model {:surprisal/type :model :context :v :weights [1]} :atoms [5]})", "AtomOutOfRange" },
        .{ "(surprisal/bits {:surprisal/type :event :atoms []})", "InvalidRecord" },
        .{ "(surprisal/model :v)", "ArityError" },
        .{ "(surprisal/whole)", "ArityError" },
        .{ "(surprisal/compose nil nil nil)", "ArityError" },
    };
    inline for (cases) |case| {
        var i = try Interpreter.init();
        defer i.deinit();
        const err = try field(try i.eval(case[0], true), &i.gc, "surprisal/error");
        try std.testing.expectEqualStrings(case[1], i.gc.getString(err.asKeywordId()));
    }
    var i = try Interpreter.init();
    defer i.deinit();
    const zero = try i.eval("(surprisal/score (surprisal/event (surprisal/model :v [1 0]) [1]))", true);
    try std.testing.expectEqual(@as(f64, 0), (try field(zero, &i.gc, "probability")).asFloat());
    try std.testing.expect(std.math.isPositiveInf((try field(zero, &i.gc, "bits")).asFloat()));
    const gain = try i.eval("(let* [m (surprisal/model :v [1 0])] (surprisal/refinement-bits (surprisal/refine (surprisal/whole m) (surprisal/event m [1]))))", true);
    try std.testing.expect(std.math.isPositiveInf(gain.asFloat()));
}

test "surprisal Clojure: overlap, duplicates, subset direction, and reconstruction" {
    var i = try Interpreter.init();
    defer i.deinit();
    const result = try i.eval("(let* [m (surprisal/model :v [1 2 3 4]) a (surprisal/event m [1 0 1]) b (surprisal/event m [1 2])]" ++
        " [(surprisal/probability (surprisal/union a b))" ++
        " (surprisal/probability (surprisal/intersection a b))" ++
        " (surprisal/subset? a (surprisal/whole m))" ++
        " (surprisal/subset? (surprisal/whole m) a)" ++
        " (surprisal/refinement-bits (surprisal/refine a (surprisal/event (surprisal/model :v [1 2 3 4]) [0])))])", true);
    const items = result.asObj().data.vector.items.items;
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), items[0].asFloat(), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), items[1].asFloat(), 1e-12);
    try std.testing.expect(items[2].asBool());
    try std.testing.expect(!items[3].asBool());
    try std.testing.expectApproxEqAbs(@log2(@as(f64, 3)), items[4].asFloat(), 1e-12);
}

test "surprisal Clojure: score carries its model and constructors snapshot input vectors" {
    var i = try Interpreter.init();
    defer i.deinit();
    _ = try i.eval("(do (def weights [1 3]) (def m (surprisal/model :v weights)) (def atoms [0]) (def e (surprisal/event m atoms)) e)", true);
    // Simulate a host mutating input storage after model/event construction.
    i.env.get("weights").?.asObj().data.vector.items.items[0] = Value.makeInt(100);
    i.env.get("atoms").?.asObj().data.vector.items.items[0] = Value.makeInt(1);
    const model_value = i.env.get("m").?;
    (try field(model_value, &i.gc, "weights")).asObj().data.vector.items.items[0] = Value.makeInt(40);
    const score = try i.eval("(surprisal/score e)", true);
    try std.testing.expectApproxEqAbs(@as(f64, 2), (try field(score, &i.gc, "bits")).asFloat(), 1e-12);
    const event = try field(score, &i.gc, "event");
    const model = try field(event, &i.gc, "model");
    try std.testing.expectEqualStrings("v", i.gc.getString((try field(model, &i.gc, "context")).asKeywordId()));
    const weights = (try field(model, &i.gc, "weights")).asObj().data.vector.items.items;
    try std.testing.expectEqual(@as(i48, 1), weights[0].asInt());
    try std.testing.expectEqual(@as(i48, 3), weights[1].asInt());
}

test "surprisal Clojure: 128 atoms and maximal interpreter integers" {
    var i = try Interpreter.init();
    defer i.deinit();
    var weights = try i.gc.allocObj(.vector);
    for (0..128) |_| try weights.data.vector.items.append(i.gc.allocator, Value.makeInt(std.math.maxInt(i48)));
    try i.env.set("weights", Value.makeObj(weights));
    const score = try i.eval("(surprisal/bits (surprisal/event (surprisal/model :v weights) [127]))", true);
    try std.testing.expectApproxEqAbs(@as(f64, 7), score.asFloat(), 1e-12);
    try weights.data.vector.items.append(i.gc.allocator, Value.makeInt(1));
    const err = try field(try i.eval("(surprisal/model :v weights)", true), &i.gc, "surprisal/error");
    try std.testing.expectEqualStrings("TooManyAtoms", i.gc.getString(err.asKeywordId()));
}

test "surprisal kernel" {
    _ = @import("surprisal.zig");
}

test "surprisal Clojure: event print/read roundtrip and script-visible errors" {
    const encoded = blk: {
        var first = try Interpreter.init();
        defer first.deinit();
        const event = try first.eval("(surprisal/event (surprisal/model :area/v1 [15 15 15 15 15 15 15 15]) [0])", true);
        const text = try @import("printer.zig").prStr(event, &first.gc, true);
        break :blk text;
    };
    defer std.testing.allocator.free(encoded);
    var second = try Interpreter.init();
    defer second.deinit();
    const restored = try second.eval(encoded, true);
    try second.env.set("restored", restored);
    const result = try second.eval("(surprisal/bits restored)", true);
    try std.testing.expectApproxEqAbs(@as(f64, 3), result.asFloat(), 1e-12);
    const handled = try second.eval("(if (:surprisal/error (surprisal/model :bad [0])) :handled :missed)", true);
    try std.testing.expectEqualStrings("handled", second.gc.getString(handled.asKeywordId()));
}
