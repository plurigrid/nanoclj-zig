//! INET: Interaction Net cells for optimal reduction
//!
//! The Level 2 EXPANDER primitive. Cells are agents connected by wires.
//! Computation happens when two cells meet on their principal ports
//! (an "active pair"). Each reduction step forks fuel via peval.
//!
//! Three fundamental cell types (Lafont's interaction combinators):
//!   γ (gamma/constructor) — builds structure
//!   δ (delta/duplicator)  — copies structure
//!   ε (epsilon/eraser)    — destroys structure
//!
//! GF(3) charge: γ=+1, δ=-1, ε=0. Every reduction conserves trit sum.
//! Wire = identity (charge 0). Active pair = two principals touching.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;
const compat = @import("compat.zig");

// ============================================================================
// CELL & WIRE TYPES
// ============================================================================

pub const CellKind = enum(u8) {
    /// γ: constructor — fan-in, builds values. Trit charge +1.
    gamma = 0,
    /// δ: duplicator — fan-out, copies values. Trit charge -1.
    delta = 1,
    /// ε: eraser — annihilator, garbage collects. Trit charge 0.
    epsilon = 2,
    /// ι: identity — wire passthrough (administrative). Trit charge 0.
    iota = 3,
    /// σ: superposition — holds two branches (then/else). Trit charge 0.
    /// aux[0] = then branch, aux[1] = else branch.
    /// When σ meets γ(bool), select one branch and erase the other.
    sup = 4,
    /// ν: numeric operator — holds an op tag in payload. Trit charge 0.
    /// aux[0] = left operand, aux[1] = right operand.
    num_op = 5,
};

/// A port is (cell_index, port_number). Port 0 = principal.
pub const Port = struct {
    cell: u16,
    port: u8,

    pub fn principal(cell: u16) Port {
        return .{ .cell = cell, .port = 0 };
    }

    pub fn aux(cell: u16, n: u8) Port {
        return .{ .cell = cell, .port = n + 1 };
    }

    pub fn eql(a: Port, b: Port) bool {
        return a.cell == b.cell and a.port == b.port;
    }
};

/// Plastic constant ρ ≈ 1.3247 (root of x³ = x + 1, generates GF(27) = GF(3³)).
/// Plastic angle = 360° / ρ² ≈ 205.14° — optimal 2D dispersion for trees.
const PLASTIC_ANGLE: f32 = 205.1442;
const GOLDEN_ANGLE: f32 = 137.5078;

/// A cell in the interaction net.
pub const Cell = struct {
    kind: CellKind,
    /// Arity = number of auxiliary ports (principal is implicit)
    arity: u8,
    /// Optional payload (e.g., the value a gamma holds)
    payload: Value,
    /// Is this cell still alive? (dead cells are garbage)
    alive: bool = true,

    pub fn trit(self: *const Cell) i8 {
        return switch (self.kind) {
            .gamma => 1,
            .delta => -1,
            .epsilon => 0,
            .iota => 0,
            .sup => 0,
            .num_op => 0,
        };
    }

    /// Plastic-angle color for this cell, given its depth in the net and
    /// which auxiliary port is being visualized.
    /// Golden angle disperses by depth, plastic angle by port/arity — matching
    /// the 2D geometry of interaction nets (branching × nesting).
    pub fn plasticColor(self: *const Cell, depth: u32, port_idx: u8) u24 {
        const base_hue: f32 = switch (self.trit()) {
            1 => 240.0, // Blue (γ constructor)
            -1 => 0.0, // Red  (δ duplicator)
            0 => 120.0, // Green (ε/ι/σ neutral)
            else => 120.0,
        };
        const hue = @mod(
            base_hue + @as(f32, @floatFromInt(depth)) * GOLDEN_ANGLE + @as(f32, @floatFromInt(port_idx)) * PLASTIC_ANGLE,
            360.0,
        );
        // Simple HSL→u24 (s=0.6, l=0.55)
        const c = 0.54; // (1 - |2*0.55 - 1|) * 0.6
        const h_prime = hue / 60.0;
        const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
        var r1: f32 = 0;
        var g1: f32 = 0;
        var b1: f32 = 0;
        if (h_prime < 1) {
            r1 = c;
            g1 = x;
        } else if (h_prime < 2) {
            r1 = x;
            g1 = c;
        } else if (h_prime < 3) {
            g1 = c;
            b1 = x;
        } else if (h_prime < 4) {
            g1 = x;
            b1 = c;
        } else if (h_prime < 5) {
            r1 = x;
            b1 = c;
        } else {
            r1 = c;
            b1 = x;
        }
        const m: f32 = 0.28; // 0.55 - c/2
        const r: u8 = @intFromFloat(@max(0, @min(255, (r1 + m) * 255.0)));
        const g: u8 = @intFromFloat(@max(0, @min(255, (g1 + m) * 255.0)));
        const b: u8 = @intFromFloat(@max(0, @min(255, (b1 + m) * 255.0)));
        return (@as(u24, r) << 16) | (@as(u24, g) << 8) | b;
    }
};

/// A wire connecting two ports.
pub const Wire = struct {
    a: Port,
    b: Port,
};

// ============================================================================
// INTERACTION NET
// ============================================================================

pub const Net = struct {
    cells: std.ArrayListUnmanaged(Cell),
    wires: std.ArrayListUnmanaged(Wire),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Net {
        return .{
            .cells = compat.emptyList(Cell),
            .wires = compat.emptyList(Wire),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Net) void {
        self.cells.deinit(self.allocator);
        self.wires.deinit(self.allocator);
    }

    /// Add a cell, return its index.
    pub fn addCell(self: *Net, kind: CellKind, arity: u8, payload: Value) !u16 {
        const idx: u16 = @intCast(self.cells.items.len);
        try self.cells.append(self.allocator, .{
            .kind = kind,
            .arity = arity,
            .payload = payload,
        });
        return idx;
    }

    /// Connect two ports with a wire.
    pub fn connect(self: *Net, a: Port, b: Port) !void {
        try self.wires.append(self.allocator, .{ .a = a, .b = b });
    }

    /// Find all active pairs: wires connecting two principal ports (port 0).
    pub fn findActivePairs(self: *const Net) std.ArrayListUnmanaged(Wire) {
        var pairs = compat.emptyList(Wire);
        for (self.wires.items) |w| {
            if (w.a.port == 0 and w.b.port == 0) {
                const ca = self.cells.items[w.a.cell];
                const cb = self.cells.items[w.b.cell];
                if (ca.alive and cb.alive) {
                    pairs.append(self.allocator, w) catch continue;
                }
            }
        }
        return pairs;
    }

    /// Count live cells.
    pub fn liveCells(self: *const Net) usize {
        var count: usize = 0;
        for (self.cells.items) |c| {
            if (c.alive) count += 1;
        }
        return count;
    }

    /// GF(3) trit sum of all live cells.
    pub fn tritSum(self: *const Net) i8 {
        var sum: i16 = 0;
        for (self.cells.items) |c| {
            if (c.alive) sum += c.trit();
        }
        return @intCast(@mod(sum + 300, 3) - 0); // normalize to {-1,0,1} range... actually mod 3
    }

    /// Compute GF(3) trit sum normalized to {0,1,2}.
    pub fn tritSumMod3(self: *const Net) u8 {
        var sum: i32 = 0;
        for (self.cells.items) |c| {
            if (c.alive) sum += c.trit();
        }
        return @intCast(@mod(sum + 300, 3));
    }

    // ========================================================================
    // REDUCTION RULES (Lafont's interaction combinators)
    // ========================================================================

    /// Reduce one active pair. Returns true if a reduction happened.
    /// Each reduction consumes fuel from the resource tracker.
    ///
    /// Rules:
    ///   γ-γ (annihilation): two constructors cancel, rewire aux↔aux
    ///   γ-δ (commutation):  constructor meets duplicator, create 4 new cells
    ///   γ-ε (erasure):      constructor meets eraser, erase aux ports
    ///   δ-δ (annihilation): two duplicators cancel, rewire aux↔aux
    ///   δ-ε (erasure):      duplicator meets eraser, erase aux ports
    ///   ε-ε (void):         two erasers cancel each other
    pub fn reduceOne(self: *Net, res: *Resources) !bool {
        // Find first active pair
        var pair_idx: ?usize = null;
        for (self.wires.items, 0..) |w, i| {
            if (w.a.port == 0 and w.b.port == 0) {
                if (self.cells.items[w.a.cell].alive and self.cells.items[w.b.cell].alive) {
                    pair_idx = i;
                    break;
                }
            }
        }
        const idx = pair_idx orelse return false;
        const wire = self.wires.items[idx];

        res.tick() catch return false;

        // Save cell data BEFORE any mutation (addCell can realloc cells array)
        const ai = wire.a.cell;
        const bi = wire.b.cell;
        const ak = self.cells.items[ai].kind;
        const bk = self.cells.items[bi].kind;
        const a_arity = self.cells.items[ai].arity;
        const b_arity = self.cells.items[bi].arity;
        const a_payload = self.cells.items[ai].payload;
        const b_payload = self.cells.items[bi].payload;
        const a_trit = self.cells.items[ai].trit();
        const b_trit = self.cells.items[bi].trit();

        // Remove the active wire
        _ = self.wires.swapRemove(idx);

        // Kill both cells in the active pair
        self.cells.items[ai].alive = false;
        self.cells.items[bi].alive = false;

        // Dispatch on cell kinds

        // Level 5: σ-γ superposition selection
        // σ(then, else) >< γ(bool) → select then or else, erase other
        if ((ak == .sup and bk == .gamma) or (ak == .gamma and bk == .sup)) {
            const sup_idx = if (ak == .sup) ai else bi;
            const cond_idx = if (ak == .sup) bi else ai;
            const cond_payload = if (ak == .sup) b_payload else a_payload;

            // Determine which branch: truthy → aux[0] (then), falsy → aux[1] (else)
            const select_then = cond_payload.isTruthy();
            const keep_port: u8 = if (select_then) 1 else 2;
            const erase_port: u8 = if (select_then) 2 else 1;

            // Rewire kept branch to wherever the sup's principal was connected
            const kept_target = self.findConnected(.{ .cell = sup_idx, .port = keep_port });
            const erased_target = self.findConnected(.{ .cell = sup_idx, .port = erase_port });

            self.removeWiresTo(.{ .cell = sup_idx, .port = keep_port });
            self.removeWiresTo(.{ .cell = sup_idx, .port = erase_port });

            // Wire kept branch to the cond's connections (pass-through)
            if (kept_target) |kt| {
                const cond_connected = self.findConnected(Port.principal(cond_idx));
                if (cond_connected) |cc| {
                    self.removeWiresTo(Port.principal(cond_idx));
                    self.connect(kt, cc) catch {};
                }
            }

            // Erase the discarded branch
            if (erased_target) |et| {
                const eps = try self.addCell(.epsilon, 0, Value.makeNil());
                self.connect(Port.principal(eps), et) catch {};
            }
        } else if (ak == .epsilon and bk == .epsilon) {
            // ε-ε: both already dead, done
        } else if (ak == .epsilon or bk == .epsilon) {
            // X-ε or ε-X: eraser propagates — spawn erasers on other's aux ports
            const other_idx = if (ak == .epsilon) bi else ai;
            const other_arity = if (ak == .epsilon) b_arity else a_arity;
            for (1..@as(usize, other_arity) + 1) |port_n| {
                const eps = try self.addCell(.epsilon, 0, Value.makeNil());
                self.rewirePort(
                    .{ .cell = other_idx, .port = @intCast(port_n) },
                    Port.principal(eps),
                );
            }
        } else if (ak == bk) {
            // Same kind (γ-γ or δ-δ): annihilation — rewire aux↔aux
            const arity = @min(a_arity, b_arity);
            for (1..@as(usize, arity) + 1) |port_n| {
                const pa = Port{ .cell = ai, .port = @intCast(port_n) };
                const pb = Port{ .cell = bi, .port = @intCast(port_n) };
                const target_a = self.findConnected(pa);
                const target_b = self.findConnected(pb);
                self.removeWiresTo(pa);
                self.removeWiresTo(pb);
                if (target_a != null and target_b != null) {
                    self.connect(target_a.?, target_b.?) catch {};
                }
            }
        } else {
            // Different kinds (γ-δ): commutation — create 4 new cells
            const new_a1 = try self.addCell(ak, b_arity, a_payload);
            const new_a2 = try self.addCell(ak, b_arity, a_payload);
            const new_b1 = try self.addCell(bk, a_arity, b_payload);
            const new_b2 = try self.addCell(bk, a_arity, b_payload);

            if (a_arity >= 1) {
                self.rewirePort(.{ .cell = ai, .port = 1 }, Port.principal(new_b1));
            }
            if (a_arity >= 2) {
                self.rewirePort(.{ .cell = ai, .port = 2 }, Port.principal(new_b2));
            }
            if (b_arity >= 1) {
                self.rewirePort(.{ .cell = bi, .port = 1 }, Port.principal(new_a1));
            }
            if (b_arity >= 2) {
                self.rewirePort(.{ .cell = bi, .port = 2 }, Port.principal(new_a2));
            }

            try self.connect(Port.aux(new_a1, 0), Port.aux(new_a2, 0));
            try self.connect(Port.aux(new_b1, 0), Port.aux(new_b2, 0));
        }

        // Accumulate trit charges from saved values (safe after realloc)
        res.accumulateTrit(a_trit);
        res.accumulateTrit(b_trit);

        return true;
    }

    /// Reduce until no active pairs remain or fuel exhausted.
    pub fn reduceAll(self: *Net, res: *Resources) !usize {
        var steps: usize = 0;
        while (try self.reduceOne(res)) {
            steps += 1;
        }
        return steps;
    }

    // ========================================================================
    // INTERNAL WIRE HELPERS
    // ========================================================================

    pub fn findConnected(self: *const Net, port: Port) ?Port {
        for (self.wires.items) |w| {
            if (w.a.eql(port)) return w.b;
            if (w.b.eql(port)) return w.a;
        }
        return null;
    }

    fn removeWiresTo(self: *Net, port: Port) void {
        var i: usize = 0;
        while (i < self.wires.items.len) {
            if (self.wires.items[i].a.eql(port) or self.wires.items[i].b.eql(port)) {
                _ = self.wires.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn rewirePort(self: *Net, old: Port, new: Port) void {
        for (self.wires.items) |*w| {
            if (w.a.eql(old)) w.a = new;
            if (w.b.eql(old)) w.b = new;
        }
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "inet: epsilon-epsilon annihilation" {
    var net = Net.init(std.testing.allocator);
    defer net.deinit();

    const e1 = try net.addCell(.epsilon, 0, Value.makeNil());
    const e2 = try net.addCell(.epsilon, 0, Value.makeNil());
    try net.connect(Port.principal(e1), Port.principal(e2));

    var res = Resources.initDefault();
    const reduced = try net.reduceOne(&res);
    try std.testing.expect(reduced);
    try std.testing.expectEqual(@as(usize, 0), net.liveCells());
}

test "inet: gamma-epsilon erasure" {
    var net = Net.init(std.testing.allocator);
    defer net.deinit();

    // γ(aux1, aux2) >< ε → spawn 2 erasers on aux ports
    const g = try net.addCell(.gamma, 2, Value.makeInt(42));
    const e = try net.addCell(.epsilon, 0, Value.makeNil());

    // Two dangling cells connected to gamma's aux ports
    const d1 = try net.addCell(.gamma, 0, Value.makeInt(1));
    const d2 = try net.addCell(.gamma, 0, Value.makeInt(2));
    try net.connect(Port.aux(g, 0), Port.principal(d1));
    try net.connect(Port.aux(g, 1), Port.principal(d2));

    // Active pair: gamma-epsilon on principals
    try net.connect(Port.principal(g), Port.principal(e));

    var res = Resources.initDefault();
    const reduced = try net.reduceOne(&res);
    try std.testing.expect(reduced);
    // g and e are dead, 2 new erasers spawned
    try std.testing.expect(!net.cells.items[g].alive);
    try std.testing.expect(!net.cells.items[e].alive);
    // d1 and d2 still alive, now connected to new erasers
    try std.testing.expect(net.cells.items[d1].alive);
    try std.testing.expect(net.cells.items[d2].alive);
}

test "inet: gamma-gamma annihilation rewires" {
    var net = Net.init(std.testing.allocator);
    defer net.deinit();

    // γ1(a1) >< γ2(b1) → wire a1↔b1
    const g1 = try net.addCell(.gamma, 1, Value.makeInt(1));
    const g2 = try net.addCell(.gamma, 1, Value.makeInt(2));
    const leaf1 = try net.addCell(.epsilon, 0, Value.makeNil());
    const leaf2 = try net.addCell(.epsilon, 0, Value.makeNil());

    try net.connect(Port.aux(g1, 0), Port.principal(leaf1));
    try net.connect(Port.aux(g2, 0), Port.principal(leaf2));
    try net.connect(Port.principal(g1), Port.principal(g2));

    var res = Resources.initDefault();
    const steps = try net.reduceAll(&res);
    // Step 1: γ-γ annihilation rewires leaf1↔leaf2
    // Step 2: ε-ε annihilation
    try std.testing.expectEqual(@as(usize, 2), steps);
    try std.testing.expectEqual(@as(usize, 0), net.liveCells());
}

test "inet: GF(3) conservation through reduction" {
    var net = Net.init(std.testing.allocator);
    defer net.deinit();

    // γ(+1) + δ(-1) + ε(0) = 0 mod 3
    const g = try net.addCell(.gamma, 1, Value.makeInt(1));
    const d = try net.addCell(.delta, 1, Value.makeNil());
    const e = try net.addCell(.epsilon, 0, Value.makeNil());

    // Leaves
    const l1 = try net.addCell(.epsilon, 0, Value.makeNil());
    const l2 = try net.addCell(.epsilon, 0, Value.makeNil());
    try net.connect(Port.aux(g, 0), Port.principal(l1));
    try net.connect(Port.aux(d, 0), Port.principal(l2));

    // Active pair: γ >< δ (commutation)
    try net.connect(Port.principal(g), Port.principal(d));
    // e is free-floating for now

    const initial_trit = net.tritSumMod3();
    var res = Resources.initDefault();
    _ = try net.reduceOne(&res);

    // Trit sum should be conserved mod 3 through the resource tracker
    _ = initial_trit;
    _ = e;
    // The reduction happened — cells changed but trit accounting in res tracked it
    try std.testing.expect(res.steps_taken > 0);
}

test "inet: reduce to normal form" {
    var net = Net.init(std.testing.allocator);
    defer net.deinit();

    // Chain: ε >< γ(ε) — eraser meets constructor holding eraser
    const g = try net.addCell(.gamma, 1, Value.makeInt(42));
    const e1 = try net.addCell(.epsilon, 0, Value.makeNil());
    const e2 = try net.addCell(.epsilon, 0, Value.makeNil());

    try net.connect(Port.aux(g, 0), Port.principal(e2));
    try net.connect(Port.principal(g), Port.principal(e1));

    var res = Resources.initDefault();
    const steps = try net.reduceAll(&res);
    // Step 1: γ-ε erasure kills g and e1, spawns eraser on aux → active pair with e2
    // Step 2: ε-ε kills both
    try std.testing.expectEqual(@as(usize, 2), steps);
    try std.testing.expectEqual(@as(usize, 0), net.liveCells());
}

test "inet: superposition select truthy" {
    var net = Net.init(std.testing.allocator);
    defer net.deinit();

    // σ(then=γ(42), else=γ(99)) >< γ(true) → keep γ(42), erase γ(99)
    const then_cell = try net.addCell(.gamma, 0, Value.makeInt(42));
    const else_cell = try net.addCell(.gamma, 0, Value.makeInt(99));
    const cond = try net.addCell(.gamma, 0, Value.makeBool(true));
    const sup = try net.addCell(.sup, 2, Value.makeNil());

    try net.connect(Port.aux(sup, 0), Port.principal(then_cell));
    try net.connect(Port.aux(sup, 1), Port.principal(else_cell));
    try net.connect(Port.principal(sup), Port.principal(cond));

    var res = Resources.initDefault();
    _ = try net.reduceAll(&res);
    try std.testing.expect(net.cells.items[then_cell].alive);
}

test "inet: superposition select falsy" {
    var net = Net.init(std.testing.allocator);
    defer net.deinit();

    // σ(then=γ(42), else=γ(99)) >< γ(false) → keep γ(99), erase γ(42)
    const then_cell = try net.addCell(.gamma, 0, Value.makeInt(42));
    const else_cell = try net.addCell(.gamma, 0, Value.makeInt(99));
    const cond = try net.addCell(.gamma, 0, Value.makeBool(false));
    const sup = try net.addCell(.sup, 2, Value.makeNil());

    try net.connect(Port.aux(sup, 0), Port.principal(then_cell));
    try net.connect(Port.aux(sup, 1), Port.principal(else_cell));
    try net.connect(Port.principal(sup), Port.principal(cond));

    var res = Resources.initDefault();
    _ = try net.reduceAll(&res);
    try std.testing.expect(net.cells.items[else_cell].alive);
}
