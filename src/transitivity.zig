//! TRANSITIVITY: Equivalence closure, resource bounding, soundness
//!
//! The "when to stop" and "are they the same?" layer.
//! Mirrors bisimulation's Paige-Tarjan partition refinement:
//!   structural equality = finest partition where equivalent states
//!   cannot be distinguished by any observation sequence.
//!
//! Also houses resource limits (the immune system) and GF(3) trit semantics.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const ObjKind = value.ObjKind;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

// ============================================================================
// PSEUDO-OPERATIONAL: Resource Limits (the immune system)
// ============================================================================

/// Resource limits for adversarial defense.
/// These bound ALL execution: parsing, evaluation, GC.
pub const Limits = struct {
    /// Maximum eval recursion depth (prevents stack overflow)
    max_depth: u32 = 1024,
    /// Maximum reader nesting depth (prevents parser stack overflow)
    max_read_depth: u32 = 256,
    /// Fuel: total eval steps before forced termination
    max_fuel: u64 = 10_000_000_000,
    /// Maximum string length in bytes
    max_string_len: u32 = 1024 * 1024, // 1MB
    /// Maximum collection size (items in one list/vector/map)
    max_collection_size: u32 = 100_000,
    /// Maximum interned strings (prevents string table exhaustion)
    max_interned_strings: u32 = 100_000,
    /// Maximum live objects before forced GC
    max_live_objects: u32 = 1_000_000,
    /// Maximum environment chain depth
    max_env_depth: u32 = 512,
};

/// Runtime resource tracker (threaded through eval)
pub const Resources = struct {
    fuel: u64,
    depth: u32 = 0,
    read_depth: u32 = 0,
    steps_taken: u64 = 0,
    max_depth_seen: u32 = 0,
    limits: Limits,
    /// GF(3) balance accumulator for conservation checks
    trit_balance: i8 = 0,

    pub fn init(limits: Limits) Resources {
        return .{
            .fuel = limits.max_fuel,
            .limits = limits,
        };
    }

    pub fn initDefault() Resources {
        return init(.{});
    }

    /// Consume fuel based on color-game depth cost.
    /// Inlined LUT path for depths < 512 (hot path avoids function call).
    pub inline fn tick(self: *Resources) !void {
        if (self.fuel == 0) return error.FuelExhausted;
        const gay_skills = @import("gay_skills.zig");
        // Inline LUT access — avoids function call overhead for common depths
        const cost = if (self.depth < gay_skills.DEPTH_FUEL_LUT_SIZE)
            gay_skills.depth_fuel_lut[self.depth]
        else
            gay_skills.depthFuelCost(self.depth);
        if (self.fuel < cost) {
            self.fuel = 0;
            return error.FuelExhausted;
        }
        self.fuel -= cost;
        self.steps_taken += 1;
    }

    /// Enter a deeper eval frame
    pub fn descend(self: *Resources) !void {
        self.depth += 1;
        if (self.depth > self.max_depth_seen) self.max_depth_seen = self.depth;
        if (self.depth > self.limits.max_depth) return error.DepthExceeded;
    }

    /// Leave an eval frame
    pub fn ascend(self: *Resources) void {
        self.depth -|= 1;
    }

    /// Enter a deeper read frame
    pub fn descendRead(self: *Resources) !void {
        self.read_depth += 1;
        if (self.read_depth > self.limits.max_read_depth) return error.ReadDepthExceeded;
    }

    /// Leave a read frame
    pub fn ascendRead(self: *Resources) void {
        self.read_depth -|= 1;
    }

    /// Accumulate GF(3) balance from a trit
    pub fn accumulateTrit(self: *Resources, trit: i8) void {
        self.trit_balance = @intCast(@mod(@as(i16, self.trit_balance) + @as(i16, trit) + 3, 3));
    }

    /// Check GF(3) conservation (balance should be 0)
    pub fn isConserved(self: *const Resources) bool {
        return self.trit_balance == 0;
    }

    pub fn fuelRemaining(self: *const Resources) u64 {
        return self.fuel;
    }

    /// Fork: split resources into n independent children for parallel eval.
    /// Fuel is divided equally (adiabatic — no overhead).
    /// Each child inherits depth/limits but gets independent trit_balance.
    pub fn fork(self: *Resources, n: usize) [64]Resources {
        var children: [64]Resources = undefined;
        if (n == 0) return children;
        const fuel_each = self.fuel / @max(n, 1);
        for (0..@min(n, 64)) |i| {
            children[i] = .{
                .fuel = fuel_each,
                .depth = self.depth,
                .read_depth = self.read_depth,
                .steps_taken = 0,
                .max_depth_seen = self.depth,
                .limits = self.limits,
                .trit_balance = 0,
            };
        }
        // Remainder fuel stays with parent (Landauer: join will cost kT·ln(n))
        self.fuel -= fuel_each * @min(n, 64);
        return children;
    }

    /// Join: merge n child resources back into parent.
    /// Accumulates steps, trit_balance, tracks max_depth.
    /// Join cost = 1 fuel unit per child (approximates kT·ln(n)).
    pub fn join(self: *Resources, children: []Resources, n: usize) void {
        for (0..@min(n, 64)) |i| {
            self.steps_taken += children[i].steps_taken;
            self.fuel += children[i].fuel; // return unused fuel
            if (children[i].max_depth_seen > self.max_depth_seen) {
                self.max_depth_seen = children[i].max_depth_seen;
            }
            // Accumulate trit balance from each child
            self.accumulateTrit(children[i].trit_balance);
        }
        // Join overhead: 1 fuel per child merged (measurement cost)
        const join_cost = @min(n, self.fuel);
        self.fuel -= join_cost;
    }
};

// ============================================================================
// STRUCTURAL EQUALITY (denotational requirement)
// ============================================================================

/// Deep structural equality — the denotational semantics REQUIRES this.
/// Bitwise equality (Value.eql) is the operational approximation.
/// This function is the ground truth.
///
///   ⟦(= a b)⟧ = structuralEq(a, b)
///
/// Satisfies:
///   reflexive:  eq(v, v) = true
///   symmetric:  eq(a, b) = eq(b, a)
///   transitive: eq(a, b) ∧ eq(b, c) → eq(a, c)
///   structural: eq([1 2], [1 2]) = true (NOT pointer equality)
pub fn structuralEq(a: Value, b: Value, gc: *GC) bool {
    if (a.eql(b)) return true;
    if (a.isNil() and b.isNil()) return true;
    if (a.isBool() and b.isBool()) return a.asBool() == b.asBool();
    if (a.isInt() and b.isInt()) return a.asInt() == b.asInt();
    if (a.isFloat() and b.isFloat()) return a.asFloat() == b.asFloat();
    if ((a.isInt() and b.isFloat()) or (a.isFloat() and b.isInt())) return false;
    if (a.isString() and b.isString()) {
        return std.mem.eql(u8, gc.getString(a.asStringId()), gc.getString(b.asStringId()));
    }
    if (a.isKeyword() and b.isKeyword()) {
        return std.mem.eql(u8, gc.getString(a.asKeywordId()), gc.getString(b.asKeywordId()));
    }
    if (a.isSymbol() and b.isSymbol()) {
        return std.mem.eql(u8, gc.getString(a.asSymbolId()), gc.getString(b.asSymbolId()));
    }
    if (a.isObj() and b.isObj()) {
        return structuralEqObj(a.asObj(), b.asObj(), gc);
    }
    return false;
}

fn structuralEqObj(a: *Obj, b: *Obj, gc: *GC) bool {
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .list => structuralEqSeq(a.data.list.items.items, b.data.list.items.items, gc),
        .vector => structuralEqSeq(a.data.vector.items.items, b.data.vector.items.items, gc),
        .map => structuralEqMap(a, b, gc),
        .set => structuralEqSeq(a.data.set.items.items, b.data.set.items.items, gc),
        .function, .macro_fn, .bc_closure => false,
        .atom => structuralEq(a.data.atom.val, b.data.atom.val, gc),
    };
}

fn structuralEqSeq(as: []Value, bs: []Value, gc: *GC) bool {
    if (as.len != bs.len) return false;
    for (as, bs) |a, b| {
        if (!structuralEq(a, b, gc)) return false;
    }
    return true;
}

fn structuralEqMap(a: *Obj, b: *Obj, gc: *GC) bool {
    const a_keys = a.data.map.keys.items;
    const b_keys = b.data.map.keys.items;
    if (a_keys.len != b_keys.len) return false;
    for (a_keys, 0..) |ak, ai| {
        var found = false;
        for (b_keys, 0..) |bk, bi| {
            if (structuralEq(ak, bk, gc)) {
                if (!structuralEq(a.data.map.vals.items[ai], b.data.map.vals.items[bi], gc))
                    return false;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ============================================================================
// GF(3) TRIT SEMANTICS
// ============================================================================

/// Every value carries an implicit trit (its "charge")
pub fn valueTrit(val: Value) i8 {
    if (val.isNil()) return 0;
    if (val.isBool()) return if (val.asBool()) @as(i8, 1) else @as(i8, -1);
    if (val.isInt()) {
        const i = val.asInt();
        if (i > 0) return 1;
        if (i < 0) return -1;
        return 0;
    }
    if (val.isObj()) {
        const addr = @intFromPtr(val.asObj());
        return switch (@as(u2, @intCast(addr % 3))) {
            0 => @as(i8, 0),
            1 => @as(i8, 1),
            2 => @as(i8, -1),
            else => unreachable,
        };
    }
    return 0;
}

// ============================================================================
// SOUNDNESS CHECK: Denotational ≡ Operational
// ============================================================================

/// Check that denotational and operational semantics agree on a value.
pub fn checkSoundness(val: Value, env: *Env, gc: *GC, fuel: u64) bool {
    const transclusion = @import("transclusion.zig");
    const transduction = @import("transduction.zig");

    var res_d = Resources.init(.{ .max_fuel = fuel });
    var res_o = Resources.init(.{ .max_fuel = fuel });

    const d = transclusion.denote(val, env, gc, &res_d);
    const o = transduction.evalBounded(val, env, gc, &res_o);

    return switch (d) {
        .value => |dv| switch (o) {
            .value => |ov| structuralEq(dv, ov, gc),
            else => false,
        },
        .bottom => |dr| switch (o) {
            .bottom => |or_| dr == or_,
            else => false,
        },
        .err => |de| switch (o) {
            .err => |oe| de.kind == oe.kind,
            else => false,
        },
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "structural equality: vectors" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const v1 = try gc.allocObj(.vector);
    try v1.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try v1.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const v2 = try gc.allocObj(.vector);
    try v2.data.vector.items.append(gc.allocator, Value.makeInt(1));
    try v2.data.vector.items.append(gc.allocator, Value.makeInt(2));

    try std.testing.expect(structuralEq(Value.makeObj(v1), Value.makeObj(v2), &gc));
}

test "structural equality: maps order-independent" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const m1 = try gc.allocObj(.map);
    const ka = try gc.internString("a");
    const kb = try gc.internString("b");
    try m1.data.map.keys.append(gc.allocator, Value.makeKeyword(ka));
    try m1.data.map.vals.append(gc.allocator, Value.makeInt(1));
    try m1.data.map.keys.append(gc.allocator, Value.makeKeyword(kb));
    try m1.data.map.vals.append(gc.allocator, Value.makeInt(2));

    const m2 = try gc.allocObj(.map);
    try m2.data.map.keys.append(gc.allocator, Value.makeKeyword(kb));
    try m2.data.map.vals.append(gc.allocator, Value.makeInt(2));
    try m2.data.map.keys.append(gc.allocator, Value.makeKeyword(ka));
    try m2.data.map.vals.append(gc.allocator, Value.makeInt(1));

    try std.testing.expect(structuralEq(Value.makeObj(m1), Value.makeObj(m2), &gc));
}

test "structural equality: nested" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const inner1 = try gc.allocObj(.vector);
    try inner1.data.vector.items.append(gc.allocator, Value.makeInt(1));
    const inner2 = try gc.allocObj(.vector);
    try inner2.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const outer1 = try gc.allocObj(.vector);
    try outer1.data.vector.items.append(gc.allocator, Value.makeObj(inner1));
    try outer1.data.vector.items.append(gc.allocator, Value.makeObj(inner2));

    const inner3 = try gc.allocObj(.vector);
    try inner3.data.vector.items.append(gc.allocator, Value.makeInt(1));
    const inner4 = try gc.allocObj(.vector);
    try inner4.data.vector.items.append(gc.allocator, Value.makeInt(2));

    const outer2 = try gc.allocObj(.vector);
    try outer2.data.vector.items.append(gc.allocator, Value.makeObj(inner3));
    try outer2.data.vector.items.append(gc.allocator, Value.makeObj(inner4));

    try std.testing.expect(structuralEq(Value.makeObj(outer1), Value.makeObj(outer2), &gc));
}

test "resource limits: fuel exhaustion" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var res = Resources.init(.{ .max_fuel = 5 });
    for (0..5) |_| try res.tick();
    try std.testing.expectError(error.FuelExhausted, res.tick());
}

test "resource limits: depth exceeded" {
    var res = Resources.init(.{ .max_depth = 3 });
    try res.descend();
    try res.descend();
    try res.descend();
    try std.testing.expectError(error.DepthExceeded, res.descend());
    res.ascend();
    res.ascend();
    try res.descend();
}

test "GF(3) conservation" {
    var res = Resources.initDefault();
    res.accumulateTrit(1);
    res.accumulateTrit(1);
    res.accumulateTrit(1);
    try std.testing.expect(res.isConserved());

    res.trit_balance = 0;
    res.accumulateTrit(1);
    res.accumulateTrit(-1);
    try std.testing.expect(res.isConserved());

    res.trit_balance = 0;
    res.accumulateTrit(1);
    try std.testing.expect(!res.isConserved());
}

test "value trit assignment" {
    try std.testing.expectEqual(@as(i8, 0), valueTrit(Value.makeNil()));
    try std.testing.expectEqual(@as(i8, 1), valueTrit(Value.makeBool(true)));
    try std.testing.expectEqual(@as(i8, -1), valueTrit(Value.makeBool(false)));
    try std.testing.expectEqual(@as(i8, 0), valueTrit(Value.makeInt(0)));
    try std.testing.expectEqual(@as(i8, 1), valueTrit(Value.makeInt(42)));
    try std.testing.expectEqual(@as(i8, -1), valueTrit(Value.makeInt(-7)));
}

test "fork/join: fuel conservation" {
    var res = Resources.init(.{ .max_fuel = 1000 });
    const initial_fuel = res.fuel;

    var children = res.fork(4);
    // Each child gets 250 fuel
    try std.testing.expectEqual(@as(u64, 250), children[0].fuel);
    try std.testing.expectEqual(@as(u64, 250), children[1].fuel);

    // Simulate work: child 0 uses 100, child 1 uses 50
    children[0].fuel -= 100;
    children[0].steps_taken = 10;
    children[1].fuel -= 50;
    children[1].steps_taken = 5;

    res.join(&children, 4);
    // Total fuel used = 100 + 50 = 150, plus join cost of 4
    // Returned fuel = (250-100) + (250-50) + 250 + 250 = 850
    // Parent fuel after join = remaining + 850 - 4 (join cost)
    try std.testing.expectEqual(@as(u64, 15), res.steps_taken);
    // Conservation: no fuel created from nothing
    try std.testing.expect(res.fuel <= initial_fuel);
}

test "fork/join: trit conservation" {
    var res = Resources.init(.{ .max_fuel = 1000 });
    var children = res.fork(3);

    // Each child accumulates trits
    children[0].trit_balance = 1;
    children[1].trit_balance = 1;
    children[2].trit_balance = 1;

    res.join(&children, 3);
    // 1 + 1 + 1 = 3 ≡ 0 (mod 3) → conserved
    try std.testing.expect(res.isConserved());
}

test "soundness: literal" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();

    try std.testing.expect(checkSoundness(Value.makeInt(42), &env, &gc, 1000));
    try std.testing.expect(checkSoundness(Value.makeNil(), &env, &gc, 1000));
    try std.testing.expect(checkSoundness(Value.makeBool(true), &env, &gc, 1000));
}
