//! Finite integer-weight probability kernel for runtime-defined Clojure models.
//! No allocation, I/O, clock, or mutable global state. Context identity belongs
//! to the value bridge; masks are meaningful only within their distribution.
const std = @import("std");

pub const max_atoms = 128;
pub const Error = error{ InvalidModel, WeightOverflow, ZeroTotal, AtomOutOfRange, InvalidEvent, NonNested, ZeroCondition, EndpointsDoNotMatch };

pub const Distribution = struct {
    weights: [max_atoms]u64 = @splat(0),
    len: usize,
    total: u64,

    pub fn init(weights: []const u64) Error!Distribution {
        if (weights.len == 0 or weights.len > max_atoms) return error.InvalidModel;
        var result = Distribution{ .len = weights.len, .total = 0 };
        for (weights, 0..) |w, i| {
            const sum = @addWithOverflow(result.total, w);
            if (sum[1] != 0) return error.WeightOverflow;
            result.total = sum[0];
            result.weights[i] = w;
        }
        if (result.total == 0) return error.ZeroTotal;
        return result;
    }

    // Public Zig fields are not proof objects. Recheck before shifts/arithmetic.
    pub fn validate(self: *const Distribution) Error!void {
        if (self.len == 0 or self.len > max_atoms) return error.InvalidModel;
        const checked = try init(self.weights[0..self.len]);
        if (checked.total != self.total) return error.InvalidModel;
    }

    pub fn whole(self: *const Distribution) Error!u128 {
        try self.validate();
        return if (self.len == max_atoms) ~@as(u128, 0) else (@as(u128, 1) << @as(u7, @intCast(self.len))) - 1;
    }

    pub fn event(self: *const Distribution, indices: []const usize) Error!u128 {
        try self.validate();
        var mask: u128 = 0;
        for (indices) |i| {
            if (i >= self.len) return error.AtomOutOfRange;
            mask |= @as(u128, 1) << @as(u7, @intCast(i));
        }
        return mask;
    }

    pub fn mass(self: *const Distribution, mask: u128) Error!u64 {
        if (mask & ~try self.whole() != 0) return error.InvalidEvent;
        var sum: u64 = 0;
        for (self.weights[0..self.len], 0..) |w, i| {
            if (mask & (@as(u128, 1) << @as(u7, @intCast(i))) != 0) sum += w;
        }
        return sum;
    }

    pub fn probability(self: *const Distribution, mask: u128) Error!f64 {
        const m: f64 = @floatFromInt(try self.mass(mask));
        return m / @as(f64, @floatFromInt(self.total));
    }

    pub fn bits(self: *const Distribution, mask: u128) Error!f64 {
        const m = try self.mass(mask);
        return information(self.total, m);
    }

    pub fn refine(self: *const Distribution, coarse: u128, fine: u128) Error!Refinement {
        const c = try self.mass(coarse);
        _ = try self.mass(fine);
        if (fine & ~coarse != 0) return error.NonNested;
        if (c == 0) return error.ZeroCondition;
        return .{ .coarse = coarse, .fine = fine };
    }

    pub fn refinementBits(self: *const Distribution, r: Refinement) Error!f64 {
        _ = try self.refine(r.coarse, r.fine);
        return information(try self.mass(r.coarse), try self.mass(r.fine));
    }

    pub fn compose(self: *const Distribution, a: Refinement, b: Refinement) Error!Refinement {
        _ = try self.refine(a.coarse, a.fine);
        _ = try self.refine(b.coarse, b.fine);
        if (a.fine != b.coarse) return error.EndpointsDoNotMatch;
        return self.refine(a.coarse, b.fine);
    }
};

pub const Refinement = struct { coarse: u128, fine: u128 };

fn information(denominator: u64, numerator: u64) f64 {
    if (numerator == 0) return std.math.inf(f64);
    if (numerator == denominator) return 0;
    // Subtract exact integers before conversion: retain tiny positive gains
    // even when the two masses round to the same f64 value.
    const difference: f64 = @floatFromInt(denominator - numerator);
    const n: f64 = @floatFromInt(numerator);
    return std.math.log1p(difference / n) / 0.6931471805599453;
}

test "surprisal kernel: land, units, and changed sampling measure" {
    const area = try Distribution.init(&.{ 15, 15, 15, 15, 15, 15, 15, 15 });
    const scaled = try Distribution.init(&.{ 555, 555, 555, 555, 555, 555, 555, 555 });
    const work = try Distribution.init(&.{ 30, 15, 15, 15, 15, 15, 15, 15 });
    const first = try area.refine(255, 3);
    const second = try area.refine(3, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 3), try area.bits(1), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), try area.refinementBits(first), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), try area.refinementBits(second), 1e-12);
    try std.testing.expectApproxEqAbs(try area.bits(1), try area.refinementBits(try area.compose(first, second)), 1e-12);
    try std.testing.expectApproxEqAbs(try area.bits(1), try scaled.bits(1), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 9.0), try work.probability(1), 1e-12);
    try std.testing.expectApproxEqAbs(@log2(@as(f64, 4.5)), try work.bits(1), 1e-12);
}

test "surprisal kernel: 256 overlapping pairs and 175 positive refinement chains" {
    const d = try Distribution.init(&.{ 1, 2, 3, 4 });
    var chains: usize = 0;
    for (0..16) |a| for (0..16) |b| {
        try std.testing.expectEqual((try d.mass(a)) + (try d.mass(b)), (try d.mass(a | b)) + (try d.mass(a & b)));
        if (b & ~a == 0 and a != 0 and b != 0) {
            try std.testing.expect(try d.bits(b) >= try d.bits(a));
            for (0..16) |c| {
                if (c & ~b != 0 or c == 0) continue;
                const ab = try d.refine(a, b);
                const bc = try d.refine(b, c);
                try std.testing.expectApproxEqAbs((try d.refinementBits(ab)) + (try d.refinementBits(bc)), try d.refinementBits(try d.compose(ab, bc)), 1e-12);
                chains += 1;
            }
        }
    };
    try std.testing.expectEqual(@as(usize, 175), chains);
}

test "surprisal kernel: limits, malformed values, zero mass, and precision" {
    try std.testing.expectError(error.InvalidModel, Distribution.init(&.{}));
    try std.testing.expectError(error.InvalidModel, Distribution.init(&(@as([129]u64, @splat(1)))));
    try std.testing.expectError(error.ZeroTotal, Distribution.init(&.{ 0, 0 }));
    try std.testing.expectError(error.WeightOverflow, Distribution.init(&.{ std.math.maxInt(u64), 1 }));
    const d = try Distribution.init(&.{ 2, 0, 3 });
    try std.testing.expectError(error.AtomOutOfRange, d.event(&.{3}));
    try std.testing.expectError(error.InvalidEvent, d.mass(8));
    try std.testing.expectError(error.NonNested, d.refine(1, 4));
    try std.testing.expectError(error.ZeroCondition, d.refine(2, 0));
    try std.testing.expectError(error.EndpointsDoNotMatch, d.compose(.{ .coarse = 7, .fine = 1 }, .{ .coarse = 5, .fine = 1 }));
    try std.testing.expectError(error.NonNested, d.refinementBits(.{ .coarse = 1, .fine = 4 }));
    try std.testing.expect(std.math.isPositiveInf(try d.bits(2)));
    try std.testing.expect(std.math.isPositiveInf(try d.refinementBits(try d.refine(7, 2))));
    try std.testing.expectEqual(@as(u128, 1), try d.event(&.{ 0, 0 }));
    const full = try Distribution.init(&(@as([128]u64, @splat(1))));
    try std.testing.expectEqual(~@as(u128, 0), try full.whole());
    try std.testing.expectEqual(@as(u64, 1), try full.mass(try full.event(&.{127})));
    const near = try Distribution.init(&.{ std.math.maxInt(u64) - 1, 1 });
    try std.testing.expect(try near.bits(1) > 0);
    var forged = d;
    forged.total = 1;
    try std.testing.expectError(error.InvalidModel, forged.bits(1));
    forged.len = 129;
    try std.testing.expectError(error.InvalidModel, forged.whole());
}
