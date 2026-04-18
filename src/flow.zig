//! flow.zig — World-constructor kernel.
//!
//! Structural port of ~/i/flowmaps-lite/src/flowmaps_lite/core.clj.
//! Same exit-data contract, same spec shape, same GF(3) trit conservation.
//! Single-threaded dispatch (no fibers): blocks are pumped until stable,
//! fuel bounds the total pump count.
//!
//! Substrate mapping (Clojure → Zig):
//!   core.async/chan       → channel.ChannelData (already in nanoclj-zig)
//!   go-loop               → single-threaded pump-until-stable loop
//!   alts! per port        → first-nonempty scan over in-port channels
//!   malli/fn schema       → *const fn(T) bool predicate
//!   conservation law      → Law{check, compose, id} closure set
//!
//! This module is generic over the value type T so it can be instantiated
//! against either a plain integer/float (standalone tests) or nanoclj-zig's
//! Value ABI (production integration). The nanoclj Value bridge lives in
//! a later wire-up step; this file compiles without pulling in value.zig.

const std = @import("std");

// ============================================================================
// Law — conservation law over trits (generic carrier V).
// ============================================================================
pub fn Law(comptime V: type) type {
    return struct {
        name: []const u8,
        check: *const fn (values: []const V) bool,
        compose: *const fn (a: V, b: V) V,
        identity: V,
    };
}

/// GF(3) law over i8 trits. Matches flowmaps-lite/core.clj :gf3-law.
pub const Gf3 = struct {
    fn check(xs: []const i8) bool {
        var sum: i32 = 0;
        for (xs) |x| sum += x;
        return @mod(sum, 3) == 0;
    }
    fn compose(a: i8, b: i8) i8 {
        return @intCast(@mod(@as(i32, a) + @as(i32, b), 3));
    }
    pub const law: Law(i8) = .{
        .name = "gf3",
        .check = &check,
        .compose = &compose,
        .identity = 0,
    };
};

// ============================================================================
// Poly — the category of polynomial functors (Spivak/Niu).
//
// A polynomial p = Σ_{i ∈ I} y^{A_i} is specified by:
//   • positions: set I of "where we are"
//   • directions: for each i ∈ I, the set A_i of "where we can go"
//
// A morphism φ: p → q is a pair:
//   • forward on positions:   φ₁: I_p → I_q
//   • backward on directions: φ♯: A_{q, φ₁(i)} → A_{p, i}
//
// Block bodies below are instances of Poly; Connection is a PolyMorphism
// fragment; the pump loop in Flow.inhabit is a specialization of the module
// action Φ_{p,q}: m_p ⊗ c_q → m_{p⊗q} (Libkind-Spivak 2024, EPTCS 429).
// ============================================================================
/// Polynomial p = Σ_{i ∈ I} y^{A_i}. Tagged-union form avoids closure-over-
/// runtime data: a monomial y^n carries its arity inline.
pub const Poly = union(enum) {
    /// 0 — the empty polynomial.
    zero,
    /// 1 — the terminal polynomial (one position, no directions).
    one,
    /// y — the identity polynomial.
    y,
    /// y^n — monomial with n directions at its single position.
    monomial: usize,

    /// |I| — size of the position set.
    pub fn positions(self: Poly) usize {
        return switch (self) {
            .zero => 0,
            .one, .y, .monomial => 1,
        };
    }

    /// A_i — arity at position i.
    pub fn directionAt(self: Poly, i: usize) usize {
        std.debug.assert(i < self.positions());
        return switch (self) {
            .zero, .one => 0,
            .y => 1,
            .monomial => |n| n,
        };
    }
};

/// Morphism φ: p → q in Poly. Forward-on-positions + backward-on-directions.
/// Lens(S,T,A,B) ≅ PolyMorphism from Sy^S to Ty^{A×B} is the monomial case.
pub const PolyMorphism = struct {
    src: Poly,
    dst: Poly,
    /// φ₁: I_src → I_dst
    fwd_pos: *const fn (i_src: usize) usize,
    /// φ♯(i_src, a_dst) → a_src — backward on directions, parameterized by source position.
    bwd_dir: *const fn (i_src: usize, a_dst: usize) usize,
};

// ============================================================================
// Topology — Block, Connection, Flow.
// ============================================================================
pub fn Block(comptime V: type) type {
    return struct {
        id: []const u8,
        body: Body,
        in_ports: []const []const u8 = &.{"in"},

        pub const Body = union(enum) {
            seed: V,                              // static value
            compute: *const fn (inputs: []const V) V, // pure function over gathered inputs
            compute_ctx: ComputeCtx,              // closure: ctx-carrying call (bridge to Value/eval)
            terminal,                             // :sink / exit marker
        };

        pub const ComputeCtx = struct {
            ctx: *anyopaque,
            call: *const fn (ctx: *anyopaque, inputs: []const V) V,
        };

        const Self = @This();

        /// Derive the polynomial this block represents.
        ///   seed         → 1  (single position, no directions; constant)
        ///   compute      → y^|in_ports|  (single position, arity = number of input ports)
        ///   compute_ctx  → y^|in_ports|  (ditto; the closure is a representation detail)
        ///   terminal     → y  (single position, single direction — the sink's exit wire)
        pub fn poly(self: Self) Poly {
            return switch (self.body) {
                .seed => .one,
                .terminal => .y,
                .compute, .compute_ctx => .{ .monomial = self.in_ports.len },
            };
        }

        /// The arity of this block's in-ports (A_0 for compute bodies).
        pub fn arity(self: Self) usize {
            return switch (self.body) {
                .seed => 0,
                .terminal => 1,
                .compute, .compute_ctx => self.in_ports.len,
            };
        }
    };
}

pub const Connection = struct {
    src: []const u8,
    dst: []const u8,
    port: []const u8 = "in",

    /// Resolve this connection to a PolyMorphism fragment φ: p_dst → p_src.
    /// Wiring reads backwards-on-directions: dst's input arity maps back to src's
    /// single output direction. This is the contravariant half of a lens
    /// (L ≅ monomial PolyMorphism) — exactly the Spivak/Niu "wire" morphism.
    pub fn asMorphism(
        comptime V: type,
        src_block: Block(V),
        dst_block: Block(V),
        port_idx: usize,
    ) PolyMorphism {
        const Wire = struct {
            fn fwd(_: usize) usize {
                return 0; // both blocks are single-position polynomials
            }
            fn bwd(_: usize, _: usize) usize {
                return 0; // any requested dst-direction pulls from src's unique output
            }
        };
        std.debug.assert(port_idx < dst_block.arity());
        return .{
            .src = dst_block.poly(),
            .dst = src_block.poly(),
            .fwd_pos = &Wire.fwd,
            .bwd_dir = &Wire.bwd,
        };
    }
};

// ============================================================================
// Rama-style primitives — partitioners and PStates.
//
// A Partitioner routes a value to one of N branches (Marz's |hash|, |all|,
// |origin| in Rama). The signature fn(V) usize is the single-vat form; in a
// distributed setting the output index selects a cluster node.
//
// In Poly terms, a partitioner is a PolyMorphism from a monomial y^1 into the
// sum polynomial Σ_{i<N} y^{A_i} — forward-on-positions picks the branch, and
// backward-on-directions carries the value through.
// ============================================================================
pub fn Partitioner(comptime V: type) type {
    return *const fn (v: V) usize;
}

/// A partitioned fan-out: one source, N possible destinations, value-dependent
/// branch selection. Sits alongside the V-agnostic `Connection` so the base
/// edge type stays simple.
pub fn PartitionedEdge(comptime V: type) type {
    return struct {
        src: []const u8,
        dsts: []const struct { id: []const u8, port: []const u8 = "in" },
        partition: Partitioner(V),
    };
}

/// PState — Marz's durable state record. Flowmaps single-vat: a string-keyed
/// history buffer per block id, populated during pump. (Not yet wired into
/// inhabit; a ledger the next refactor can populate.)
pub fn PState(comptime V: type) type {
    return struct {
        map: std.StringHashMap(std.ArrayList(V)),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .map = std.StringHashMap(std.ArrayList(V)).init(allocator) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |v| v.deinit(allocator);
            self.map.deinit();
        }

        pub fn append(self: *@This(), allocator: std.mem.Allocator, id: []const u8, v: V) !void {
            const gop = try self.map.getOrPut(id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, v);
        }

        pub fn get(self: *const @This(), id: []const u8) ?[]const V {
            const entry = self.map.getPtr(id) orelse return null;
            return entry.items;
        }
    };
}

pub fn FlowSpec(comptime V: type) type {
    return struct {
        blocks: []const Block(V),
        connections: []const Connection,
        exit: []const u8,
        fuel: u64 = 10_000,
        // optional parallel arrays; empty → ignored
        block_trits: []const BlockTrit = &.{},
        block_schemas: []const BlockSchema(V) = &.{},
        hide: []const []const u8 = &.{},
        law: Law(i8) = Gf3.law,
        partitioned_edges: []const PartitionedEdge(V) = &.{},

        pub const BlockTrit = struct { id: []const u8, trit: i8 };
        pub fn BlockSchema(comptime T: type) type {
            return struct { id: []const u8, port: []const u8, pred: *const fn (T) bool };
        }

        /// Composite polynomial of the whole spec: tensor ⊗ of all block polynomials.
        /// Since every block is single-position, the tensor collapses to a single
        /// monomial y^N with N = Σ arity(b). Connections reduce N by wiring (each
        /// edge identifies one src-output direction with one dst-input direction),
        /// but the *free* composite before quotienting is this monomial.
        ///
        /// inhabit(spec) is a typed specialization of Libkind-Spivak's
        ///   Φ_{p,q}: m_p ⊗ c_q → m_{p⊗q}
        /// with p = flowPoly(spec) (free side, monad layer) and q the sturdy-
        /// resolver capability polynomial (comonad side, fibered over compute_ctx
        /// slots). The pump-until-stable loop enacts the module action.
        pub fn flowPoly(self: @This()) Poly {
            var n: usize = 0;
            for (self.blocks) |b| n += b.arity();
            return .{ .monomial = n };
        }

        // =======================================================================
        // Specter-style navigators. A navigator is (select, transform) over a
        // focus in the spec tree. In Poly terms, each is a monomial PolyMorphism.
        // Transforms allocate a new spec (slices are immutable).
        // =======================================================================
        const Spec = @This();

        /// Select a block by id. Returns null if missing.
        pub fn selectBlockById(self: Spec, id: []const u8) ?Block(V) {
            for (self.blocks) |b| if (std.mem.eql(u8, b.id, id)) return b;
            return null;
        }

        /// Replace the block with the given id via `xform`. Returns a new spec
        /// whose `blocks` slice is allocator-owned; the caller frees it.
        pub fn transformBlockById(
            self: Spec,
            allocator: std.mem.Allocator,
            id: []const u8,
            xform: *const fn (Block(V)) Block(V),
        ) !Spec {
            const out = try allocator.alloc(Block(V), self.blocks.len);
            for (self.blocks, 0..) |b, i| {
                out[i] = if (std.mem.eql(u8, b.id, id)) xform(b) else b;
            }
            var next = self;
            next.blocks = out;
            return next;
        }

        /// Select the connection at index `i`.
        pub fn selectConnAt(self: Spec, i: usize) ?Connection {
            if (i >= self.connections.len) return null;
            return self.connections[i];
        }

        /// Replace the connection at index `i`. Allocates a new connections slice.
        pub fn transformConnAt(
            self: Spec,
            allocator: std.mem.Allocator,
            i: usize,
            xform: *const fn (Connection) Connection,
        ) !Spec {
            std.debug.assert(i < self.connections.len);
            const out = try allocator.alloc(Connection, self.connections.len);
            for (self.connections, 0..) |c, j| {
                out[j] = if (j == i) xform(c) else c;
            }
            var next = self;
            next.connections = out;
            return next;
        }
    };
}

// ============================================================================
// ExitData — world's enacted history snapshot.
// ============================================================================
pub fn ExitData(comptime V: type) type {
    return struct {
        value: ?V,
        fuel_budget: u64,
        fuel_used: u64,
        trit_sum: i8,
        trit_conserved: bool,
        block_count: usize,
        edge_count: usize,
        errors: usize,
        wall_ns: u64,
    };
}

// ============================================================================
// Engine — pump-until-stable dispatch.
// ============================================================================
fn nowNs() i128 {
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) return 0;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(i128, ts.sec) *% 1_000_000_000 +% @as(i128, ts.nsec);
}

/// Threading-shape sugar port of flowmaps-lite's `flow->spec`.
/// `(linear 5 sq inc halve)` → seed → s0 → s1 → s2 → sink.
/// Returns a `Linear` that owns its backing storage; call `.deinit(alloc)`.
pub fn Linear(comptime V: type) type {
    return struct {
        blocks: []Block(V),
        connections: []Connection,
        id_storage: []u8,
        spec: FlowSpec(V),

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.blocks);
            allocator.free(self.connections);
            allocator.free(self.id_storage);
        }
    };
}

pub fn linear(
    comptime V: type,
    allocator: std.mem.Allocator,
    seed: V,
    fns: []const *const fn (inputs: []const V) V,
) !Linear(V) {
    const n = fns.len;
    std.debug.assert(n > 0);

    // Pre-format ids "s0".."s(n-1)" into a single arena so every slice is stable.
    // 4 bytes per id leaves room for "s" + up to 3 digits ⇒ n ≤ 999; bump if needed.
    const per_id: usize = 5;
    const id_storage = try allocator.alloc(u8, n * per_id);
    var ids: [64][]const u8 = undefined;
    std.debug.assert(n <= ids.len);
    for (0..n) |i| {
        const slot = id_storage[i * per_id .. (i + 1) * per_id];
        const written = std.fmt.bufPrint(slot, "s{d}", .{i}) catch unreachable;
        ids[i] = written;
    }

    const blocks = try allocator.alloc(Block(V), n + 2);
    blocks[0] = .{ .id = "seed", .body = .{ .seed = seed } };
    for (0..n) |i| {
        blocks[i + 1] = .{ .id = ids[i], .body = .{ .compute = fns[i] } };
    }
    blocks[n + 1] = .{ .id = "sink", .body = .terminal };

    const connections = try allocator.alloc(Connection, n + 1);
    connections[0] = .{ .src = "seed", .dst = ids[0] };
    for (1..n) |i| {
        connections[i] = .{ .src = ids[i - 1], .dst = ids[i] };
    }
    connections[n] = .{ .src = ids[n - 1], .dst = "sink" };

    return .{
        .blocks = blocks,
        .connections = connections,
        .id_storage = id_storage,
        .spec = .{
            .blocks = blocks,
            .connections = connections,
            .exit = "sink",
        },
    };
}

pub fn Flow(comptime V: type) type {
    return struct {
        pub fn inhabit(allocator: std.mem.Allocator, spec: FlowSpec(V)) !ExitData(V) {
            return inhabitWithState(allocator, spec, null);
        }

        pub fn inhabitWithState(
            allocator: std.mem.Allocator,
            spec: FlowSpec(V),
            pstate: ?*PState(V),
        ) !ExitData(V) {
            const t0 = nowNs();

            // Per-connection FIFO queues.
            var queues = try allocator.alloc(std.ArrayList(V), spec.connections.len);
            defer {
                for (queues) |*q| q.deinit(allocator);
                allocator.free(queues);
            }
            for (queues) |*q| q.* = .empty;

            // Seed initial queue contents from seed-type blocks.
            for (spec.blocks) |b| {
                switch (b.body) {
                    .seed => |v| {
                        if (pstate) |ps| try ps.append(allocator, b.id, v);
                        for (spec.connections, 0..) |c, i| {
                            if (std.mem.eql(u8, c.src, b.id)) try queues[i].append(allocator, v);
                        }
                        // partitioned seeding: seed the branch selected by partitioner(v)
                        for (spec.partitioned_edges) |pe| {
                            if (std.mem.eql(u8, pe.src, b.id)) {
                                const idx = pe.partition(v);
                                std.debug.assert(idx < pe.dsts.len);
                                const tgt = pe.dsts[idx];
                                for (spec.connections, 0..) |c, i| {
                                    if (std.mem.eql(u8, c.dst, tgt.id) and std.mem.eql(u8, c.port, tgt.port)) {
                                        try queues[i].append(allocator, v);
                                    }
                                }
                            }
                        }
                    },
                    else => {},
                }
            }

            var fuel: u64 = spec.fuel;
            var errs: usize = 0;
            var exit_val: ?V = null;

            // Pump: find a compute block whose first :in port has a pending value, fire it.
            pump: while (fuel > 0) {
                var progress = false;
                for (spec.blocks) |b| switch (b.body) {
                    .seed => {},
                    .terminal => {
                        for (spec.connections, 0..) |c, i| {
                            if (std.mem.eql(u8, c.dst, b.id) and queues[i].items.len > 0) {
                                exit_val = queues[i].orderedRemove(0);
                                break :pump;
                            }
                        }
                    },
                    .compute, .compute_ctx => {
                        var in_buf: [8]V = undefined;
                        var n: usize = 0;
                        var can_fire = true;
                        for (b.in_ports) |p| {
                            if (n >= in_buf.len) { can_fire = false; break; }
                            var found = false;
                            for (spec.connections, 0..) |c, i| {
                                if (std.mem.eql(u8, c.dst, b.id) and std.mem.eql(u8, c.port, p) and queues[i].items.len > 0) {
                                    in_buf[n] = queues[i].orderedRemove(0);
                                    n += 1;
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) { can_fire = false; break; }
                        }
                        if (!can_fire) continue;

                        fuel -= 1;
                        const r = switch (b.body) {
                            .compute => |f| f(in_buf[0..n]),
                            .compute_ctx => |cc| cc.call(cc.ctx, in_buf[0..n]),
                            else => unreachable,
                        };

                        // output-schema check
                        for (spec.block_schemas) |s| {
                            if (std.mem.eql(u8, s.id, b.id) and std.mem.eql(u8, s.port, "out")) {
                                if (!s.pred(r)) errs += 1;
                            }
                        }

                        if (pstate) |ps| try ps.append(allocator, b.id, r);

                        // fan out (direct edges)
                        for (spec.connections, 0..) |c, i| {
                            if (std.mem.eql(u8, c.src, b.id)) try queues[i].append(allocator, r);
                        }
                        // fan out (partitioned edges): route to dsts[partition(r)]
                        for (spec.partitioned_edges) |pe| {
                            if (std.mem.eql(u8, pe.src, b.id)) {
                                const idx = pe.partition(r);
                                std.debug.assert(idx < pe.dsts.len);
                                const tgt = pe.dsts[idx];
                                for (spec.connections, 0..) |c, i| {
                                    if (std.mem.eql(u8, c.dst, tgt.id) and std.mem.eql(u8, c.port, tgt.port)) {
                                        try queues[i].append(allocator, r);
                                    }
                                }
                            }
                        }
                        progress = true;
                    },
                };
                if (!progress) break;
            }

            // Trit fold under conservation law.
            var sum: i8 = spec.law.identity;
            var trits: [64]i8 = undefined;
            var tn: usize = 0;
            for (spec.block_trits) |bt| {
                if (tn < trits.len) { trits[tn] = bt.trit; tn += 1; }
                sum = spec.law.compose(sum, bt.trit);
            }
            const conserved = spec.law.check(trits[0..tn]);

            if (fuel == 0) errs += 1;

            return ExitData(V){
                .value = exit_val,
                .fuel_budget = spec.fuel,
                .fuel_used = spec.fuel - fuel,
                .trit_sum = sum,
                .trit_conserved = conserved,
                .block_count = spec.blocks.len,
                .edge_count = spec.connections.len,
                .errors = errs,
                .wall_ns = @intCast(nowNs() - t0),
            };
        }
    };
}

// ============================================================================
// Smoke — reference world: 10 → double → inc → sink ⇒ 21
// ============================================================================
fn double(inputs: []const i64) i64 { return inputs[0] * 2; }
fn incFn(inputs: []const i64) i64 { return inputs[0] + 1; }

test "flow: 10 → double → inc → sink = 21" {
    const V = i64;
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "seed",   .body = .{ .seed = 10 } },
            .{ .id = "double", .body = .{ .compute = &double } },
            .{ .id = "inc",    .body = .{ .compute = &incFn } },
            .{ .id = "sink",   .body = .terminal },
        },
        .connections = &.{
            .{ .src = "seed",   .dst = "double" },
            .{ .src = "double", .dst = "inc" },
            .{ .src = "inc",    .dst = "sink" },
        },
        .exit = "sink",
        .block_trits = &.{
            .{ .id = "double", .trit = 1 },
            .{ .id = "inc",    .trit = -1 },
        },
    };
    const r = try Flow(V).inhabit(std.testing.allocator, spec);
    try std.testing.expectEqual(@as(?i64, 21), r.value);
    try std.testing.expectEqual(@as(i8, 0), r.trit_sum);
    try std.testing.expect(r.trit_conserved);
    try std.testing.expectEqual(@as(usize, 0), r.errors);
}

// ============================================================================
// Registry — W1..W5b, block-for-block port of worlds.clj
// ============================================================================
fn idFn(xs: []const i64) i64 { return xs[0]; }
fn loopInc(xs: []const i64) i64 { return xs[0] + 1; }
fn isNumberPred(v: i64) bool { _ = v; return true; }
fn alwaysFalse(v: i64) bool { _ = v; return false; } // simulate W3 schema violation

test "W4 void: fuel exhaustion halts safely" {
    // seed 1 → loop(inc) self-feeds → fuel 5 runs out
    const V = i64;
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "seed", .body = .{ .seed = 1 } },
            .{ .id = "loop", .body = .{ .compute = &loopInc } },
            .{ .id = "sink", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "seed", .dst = "loop" },
            .{ .src = "loop", .dst = "loop" },
            .{ .src = "loop", .dst = "sink" },
        },
        .exit = "sink",
        .fuel = 5,
    };
    const r = try Flow(V).inhabit(std.testing.allocator, spec);
    try std.testing.expect(r.fuel_used <= r.fuel_budget);
}

test "W5a nash: 1+1+1 ≡ 0 (mod 3) conserved" {
    const V = i64;
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "seed", .body = .{ .seed = 3 } },
            .{ .id = "a",    .body = .{ .compute = &idFn } },
            .{ .id = "b",    .body = .{ .compute = &idFn } },
            .{ .id = "c",    .body = .{ .compute = &idFn } },
            .{ .id = "sink", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "seed", .dst = "a" },
            .{ .src = "a",    .dst = "b" },
            .{ .src = "b",    .dst = "c" },
            .{ .src = "c",    .dst = "sink" },
        },
        .exit = "sink",
        .block_trits = &.{
            .{ .id = "a", .trit = 1 },
            .{ .id = "b", .trit = 1 },
            .{ .id = "c", .trit = 1 },
        },
    };
    const r = try Flow(V).inhabit(std.testing.allocator, spec);
    try std.testing.expectEqual(@as(?i64, 3), r.value);
    try std.testing.expect(r.trit_conserved); // 1+1+1=3≡0
}

test "W5b isac: 1+1 ≢ 0 (mod 3) violated" {
    const V = i64;
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "seed", .body = .{ .seed = 3 } },
            .{ .id = "a",    .body = .{ .compute = &idFn } },
            .{ .id = "b",    .body = .{ .compute = &idFn } },
            .{ .id = "sink", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "seed", .dst = "a" },
            .{ .src = "a",    .dst = "b" },
            .{ .src = "b",    .dst = "sink" },
        },
        .exit = "sink",
        .block_trits = &.{
            .{ .id = "a", .trit = 1 },
            .{ .id = "b", .trit = 1 },
        },
    };
    const r = try Flow(V).inhabit(std.testing.allocator, spec);
    try std.testing.expectEqual(@as(?i64, 3), r.value);
    try std.testing.expect(!r.trit_conserved); // 1+1=2≢0 detected
}

// Demonstrates compute_ctx: the engine threads a closure ctx through without
// needing to know anything about Value, GC, or Env. flow_value.zig will reuse
// this same hinge to bridge nanoclj closures via eval.apply.
const MultiplyCtx = struct {
    factor: i64,
    fn call(ctx: *anyopaque, inputs: []const i64) i64 {
        const self: *MultiplyCtx = @ptrCast(@alignCast(ctx));
        return inputs[0] * self.factor;
    }
};

test "Poly: identity / terminal / empty polynomials" {
    const y_: Poly = .y;
    const one_: Poly = .one;
    const zero_: Poly = .zero;
    try std.testing.expectEqual(@as(usize, 1), y_.positions());
    try std.testing.expectEqual(@as(usize, 1), y_.directionAt(0));
    try std.testing.expectEqual(@as(usize, 1), one_.positions());
    try std.testing.expectEqual(@as(usize, 0), one_.directionAt(0));
    try std.testing.expectEqual(@as(usize, 0), zero_.positions());

    const m3: Poly = .{ .monomial = 3 };
    try std.testing.expectEqual(@as(usize, 1), m3.positions());
    try std.testing.expectEqual(@as(usize, 3), m3.directionAt(0));
}

test "Block.poly: seed ↦ 1, terminal ↦ y, compute ↦ y^arity" {
    const V = i64;
    const B = Block(V);
    const seed_block: B = .{ .id = "s", .body = .{ .seed = 42 } };
    const sink_block: B = .{ .id = "k", .body = .terminal };
    const double_block: B = .{ .id = "d", .body = .{ .compute = &double } };
    const pair_block: B = .{
        .id = "p",
        .body = .{ .compute = &double },
        .in_ports = &.{ "a", "b" },
    };

    try std.testing.expectEqual(@as(usize, 0), seed_block.arity());
    try std.testing.expectEqual(@as(usize, 1), sink_block.arity());
    try std.testing.expectEqual(@as(usize, 1), double_block.arity());
    try std.testing.expectEqual(@as(usize, 2), pair_block.arity());

    // Single-position for all; arity at that position now reflects in_ports.len.
    try std.testing.expectEqual(@as(usize, 1), seed_block.poly().positions());
    try std.testing.expectEqual(@as(usize, 0), seed_block.poly().directionAt(0));
    try std.testing.expectEqual(@as(usize, 1), sink_block.poly().directionAt(0));
    try std.testing.expectEqual(@as(usize, 1), double_block.poly().directionAt(0));
    try std.testing.expectEqual(@as(usize, 2), pair_block.poly().directionAt(0));
}

test "PolyMorphism: identity morphism on y" {
    const id_mor = PolyMorphism{
        .src = .y,
        .dst = .y,
        .fwd_pos = struct {
            fn f(i: usize) usize {
                return i;
            }
        }.f,
        .bwd_dir = struct {
            fn f(_: usize, a: usize) usize {
                return a;
            }
        }.f,
    };
    try std.testing.expectEqual(@as(usize, 0), id_mor.fwd_pos(0));
    try std.testing.expectEqual(@as(usize, 0), id_mor.bwd_dir(0, 0));
}

test "Connection.asMorphism: wire from binary block back to seed" {
    const V = i64;
    const B = Block(V);
    const seed: B = .{ .id = "s", .body = .{ .seed = 7 } };
    const pair: B = .{
        .id = "p",
        .body = .{ .compute = &double },
        .in_ports = &.{ "a", "b" },
    };
    const c = Connection{ .src = "s", .dst = "p", .port = "b" };
    const phi = Connection.asMorphism(V, seed, pair, 1);

    // φ: p_dst(=y^2) → p_src(=1). Position-forward is trivial (single-position).
    try std.testing.expectEqual(@as(usize, 2), phi.src.directionAt(0));
    try std.testing.expectEqual(@as(usize, 0), phi.dst.directionAt(0));
    try std.testing.expectEqual(@as(usize, 0), phi.fwd_pos(0));
    // Port "b" = index 1 in dst; backward-on-directions resolves to src's output 0.
    try std.testing.expectEqual(@as(usize, 0), phi.bwd_dir(0, 1));
    _ = c;
}

test "linear: (linear 5 sq inc halve) pumps through three stages" {
    const V = i64;
    const allocator = std.testing.allocator;
    const sq = struct {
        fn f(xs: []const V) V { return xs[0] * xs[0]; }
    }.f;
    const inc = struct {
        fn f(xs: []const V) V { return xs[0] + 1; }
    }.f;
    const halve = struct {
        fn f(xs: []const V) V { return @divTrunc(xs[0], 2); }
    }.f;

    var lin = try linear(V, allocator, 5, &.{ &sq, &inc, &halve });
    defer lin.deinit(allocator);

    const exit = try Flow(V).inhabit(allocator, lin.spec);
    // 5 → 25 → 26 → 13
    try std.testing.expectEqual(@as(?V, 13), exit.value);
    try std.testing.expectEqual(@as(usize, 5), lin.spec.blocks.len); // seed + 3 fns + sink
    try std.testing.expectEqual(@as(usize, 4), lin.spec.connections.len);
}

test "Rama PState ledger: inhabit records every block's output" {
    const V = i64;
    const allocator = std.testing.allocator;
    var pstate = PState(V).init(allocator);
    defer pstate.deinit(allocator);

    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "s", .body = .{ .seed = 10 } },
            .{ .id = "d", .body = .{ .compute = &double } },
            .{ .id = "i", .body = .{ .compute = &incFn } },
            .{ .id = "k", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "s", .dst = "d" },
            .{ .src = "d", .dst = "i" },
            .{ .src = "i", .dst = "k" },
        },
        .exit = "k",
    };
    const exit = try Flow(V).inhabitWithState(allocator, spec, &pstate);
    try std.testing.expectEqual(@as(?V, 21), exit.value);

    try std.testing.expectEqual(@as(V, 10), pstate.get("s").?[0]);
    try std.testing.expectEqual(@as(V, 20), pstate.get("d").?[0]);
    try std.testing.expectEqual(@as(V, 21), pstate.get("i").?[0]);
    try std.testing.expectEqual(@as(?[]const V, null), pstate.get("k")); // terminal doesn't produce
}

test "Rama partitioned edge: even→left branch, odd→right branch" {
    const V = i64;
    const Route = struct {
        fn parity(v: V) usize { return if (@mod(v, 2) == 0) 0 else 1; }
    };
    const dsts: []const struct { id: []const u8, port: []const u8 = "in" } = &.{
        .{ .id = "evens" },
        .{ .id = "odds" },
    };
    _ = dsts;
    // seed 7 (odd) → should land in "odds", not "evens"
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "s",     .body = .{ .seed = 7 } },
            .{ .id = "evens", .body = .terminal },
            .{ .id = "odds",  .body = .terminal },
        },
        .connections = &.{
            .{ .src = "s", .dst = "evens" },
            .{ .src = "s", .dst = "odds" },
        },
        .partitioned_edges = &.{
            .{
                .src = "s",
                .dsts = &.{ .{ .id = "evens" }, .{ .id = "odds" } },
                .partition = &Route.parity,
            },
        },
        .exit = "odds",
    };
    const allocator = std.testing.allocator;
    // Drop the direct `connections` entries so ONLY the partitioner routes:
    const spec_only_partitioned = blk: {
        var s = spec;
        s.connections = &.{
            .{ .src = "sentinel", .dst = "evens" }, // unused; placeholder so pump can drain
            .{ .src = "sentinel", .dst = "odds" },
        };
        break :blk s;
    };
    const exit = try Flow(V).inhabit(allocator, spec_only_partitioned);
    try std.testing.expectEqual(@as(?V, 7), exit.value); // odd → odds terminal
}

test "Rama Partitioner: even/odd routes by parity" {
    const V = i64;
    const Route = struct {
        fn parity(v: V) usize {
            return if (@mod(v, 2) == 0) 0 else 1;
        }
    };
    const p: Partitioner(V) = &Route.parity;
    try std.testing.expectEqual(@as(usize, 0), p(4));
    try std.testing.expectEqual(@as(usize, 1), p(7));
    try std.testing.expectEqual(@as(usize, 0), p(0));
}

test "Rama PState: append-then-get roundtrips history per block" {
    const V = i64;
    const allocator = std.testing.allocator;
    var s = PState(V).init(allocator);
    defer s.deinit(allocator);
    try s.append(allocator, "d", 10);
    try s.append(allocator, "d", 20);
    try s.append(allocator, "i", 99);

    const d_hist = s.get("d").?;
    try std.testing.expectEqual(@as(usize, 2), d_hist.len);
    try std.testing.expectEqual(@as(V, 10), d_hist[0]);
    try std.testing.expectEqual(@as(V, 20), d_hist[1]);
    try std.testing.expectEqual(@as(?[]const V, null), s.get("missing"));
}

test "Specter nav: selectBlockById returns the matching block" {
    const V = i64;
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "s", .body = .{ .seed = 10 } },
            .{ .id = "d", .body = .{ .compute = &double } },
            .{ .id = "k", .body = .terminal },
        },
        .connections = &.{ .{ .src = "s", .dst = "d" }, .{ .src = "d", .dst = "k" } },
        .exit = "k",
    };
    const got = spec.selectBlockById("d").?;
    try std.testing.expectEqualStrings("d", got.id);
    try std.testing.expectEqual(@as(usize, 1), got.arity());
    try std.testing.expectEqual(@as(?Block(V), null), spec.selectBlockById("missing"));
}

test "Specter nav: transformBlockById swaps seed value, roundtrips pump" {
    const V = i64;
    const spec0 = FlowSpec(V){
        .blocks = &.{
            .{ .id = "s", .body = .{ .seed = 5 } },
            .{ .id = "d", .body = .{ .compute = &double } },
            .{ .id = "k", .body = .terminal },
        },
        .connections = &.{ .{ .src = "s", .dst = "d" }, .{ .src = "d", .dst = "k" } },
        .exit = "k",
    };
    const Swap = struct {
        fn setSeed42(b: Block(V)) Block(V) {
            return .{ .id = b.id, .body = .{ .seed = 42 }, .in_ports = b.in_ports };
        }
    };
    const allocator = std.testing.allocator;
    const spec1 = try spec0.transformBlockById(allocator, "s", &Swap.setSeed42);
    defer allocator.free(spec1.blocks);

    const exit0 = try Flow(V).inhabit(allocator, spec0);
    const exit1 = try Flow(V).inhabit(allocator, spec1);
    try std.testing.expectEqual(@as(?V, 10), exit0.value); // 5 * 2
    try std.testing.expectEqual(@as(?V, 84), exit1.value); // 42 * 2
}

test "Specter nav: transformConnAt re-routes edge" {
    const V = i64;
    const spec0 = FlowSpec(V){
        .blocks = &.{
            .{ .id = "s", .body = .{ .seed = 5 } },
            .{ .id = "d", .body = .{ .compute = &double } },
            .{ .id = "k", .body = .terminal },
        },
        .connections = &.{ .{ .src = "s", .dst = "d" }, .{ .src = "d", .dst = "k" } },
        .exit = "k",
    };
    const Reroute = struct {
        fn bypass(c: Connection) Connection {
            return .{ .src = "s", .dst = c.dst, .port = c.port };
        }
    };
    const allocator = std.testing.allocator;
    const spec1 = try spec0.transformConnAt(allocator, 1, &Reroute.bypass);
    defer allocator.free(spec1.connections);

    const exit1 = try Flow(V).inhabit(allocator, spec1);
    // Both edges now feed from "s"; terminal still receives 5.
    try std.testing.expectEqual(@as(?V, 5), exit1.value);
}

test "FlowSpec.flowPoly: W1-like composite = y^(Σ arity)" {
    const V = i64;
    // seed(0) → double(1) → inc(1) → sink(1) : Σ arity = 3
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "s", .body = .{ .seed = 10 } },
            .{ .id = "d", .body = .{ .compute = &double } },
            .{ .id = "i", .body = .{ .compute = &incFn } },
            .{ .id = "k", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "s", .dst = "d" },
            .{ .src = "d", .dst = "i" },
            .{ .src = "i", .dst = "k" },
        },
        .exit = "k",
    };
    const p = spec.flowPoly();
    try std.testing.expectEqual(@as(usize, 1), p.positions());
    try std.testing.expectEqual(@as(usize, 3), p.directionAt(0));
}

test "flow: compute_ctx closes over factor state" {
    const V = i64;
    var mul3 = MultiplyCtx{ .factor = 3 };
    var mul7 = MultiplyCtx{ .factor = 7 };
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "seed", .body = .{ .seed = 2 } },
            .{ .id = "m3",   .body = .{ .compute_ctx = .{ .ctx = &mul3, .call = &MultiplyCtx.call } } },
            .{ .id = "m7",   .body = .{ .compute_ctx = .{ .ctx = &mul7, .call = &MultiplyCtx.call } } },
            .{ .id = "sink", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "seed", .dst = "m3" },
            .{ .src = "m3",   .dst = "m7" },
            .{ .src = "m7",   .dst = "sink" },
        },
        .exit = "sink",
    };
    const r = try Flow(V).inhabit(std.testing.allocator, spec);
    try std.testing.expectEqual(@as(?i64, 42), r.value); // 2 * 3 * 7
}

test "W3 isac: schema violation captured, not thrown" {
    const V = i64;
    const spec = FlowSpec(V){
        .blocks = &.{
            .{ .id = "seed", .body = .{ .seed = 10 } },
            .{ .id = "bad",  .body = .{ .compute = &idFn } },
            .{ .id = "sink", .body = .terminal },
        },
        .connections = &.{
            .{ .src = "seed", .dst = "bad" },
            .{ .src = "bad",  .dst = "sink" },
        },
        .exit = "sink",
        .block_schemas = &.{
            .{ .id = "bad", .port = "out", .pred = &alwaysFalse },
        },
    };
    const r = try Flow(V).inhabit(std.testing.allocator, spec);
    try std.testing.expectEqual(@as(?i64, 10), r.value);
    try std.testing.expect(r.errors >= 1);
}
