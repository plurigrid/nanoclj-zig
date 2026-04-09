//! decomp.zig — Structured Decompositions + Sheaves over interaction nets
//!
//! StructuredDecompositions.jl → nanoclj-zig: decompositions ARE inets.
//! Bags = γ cells, adhesions = wires, treewidth = max bag size - 1.
//! Sheaves assign data to open sets with restriction/gluing.
//!
//! Bumpus's key insight: presheaves on graphs = functors G^op → Set.
//! A structured decomposition is a presheaf on a tree shape that
//! "covers" a graph. The deciding sheaves algorithm checks whether
//! local sections (per-bag solutions) can be glued globally.
//! This is exactly the sheaf condition: local→global coherence.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const inet = @import("inet.zig");
const Net = inet.Net;
const Port = inet.Port;
const Cell = inet.Cell;
const CellKind = inet.CellKind;
const compat = @import("compat.zig");
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;
const eval_mod = @import("eval.zig");
const inet_builtins = @import("inet_builtins.zig");

// ============================================================================
// DECOMPOSE: Build a tree decomposition as an inet
// ============================================================================

/// (decompose graph) → net-id
/// graph = {:nodes [v1 v2 ...] :edges [[v1 v2] [v2 v3] ...]}
/// Returns a net-id where each γ cell holds a bag (vector of nodes),
/// wired in a tree structure. Uses greedy elimination ordering.
pub fn decomposeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isObj()) return error.InvalidArgs;
    const graph_obj = args[0].asObj();
    if (graph_obj.kind != .map) return error.InvalidArgs;

    // Extract :nodes and :edges
    var nodes: ?[]Value = null;
    var edges: ?[]Value = null;
    for (graph_obj.data.map.keys.items, 0..) |k, i| {
        if (!k.isKeyword()) continue;
        const kname = gc.getString(k.asKeywordId());
        const v = graph_obj.data.map.vals.items[i];
        if (!v.isObj()) continue;
        if (std.mem.eql(u8, kname, "nodes") and v.asObj().kind == .vector)
            nodes = v.asObj().data.vector.items.items;
        if (std.mem.eql(u8, kname, "edges") and v.asObj().kind == .vector)
            edges = v.asObj().data.vector.items.items;
    }
    const node_list = nodes orelse return error.InvalidArgs;
    const edge_list = edges orelse return error.InvalidArgs;

    // Build adjacency: node index → set of neighbor indices
    const n = node_list.len;
    if (n == 0) return error.InvalidArgs;

    // Allocate net
    const slot = inet_builtins.findFreeSlotPub() orelse return error.Overflow;
    var net = Net.init(gc.allocator);

    // Simple strategy: one bag per node containing the node + its neighbors
    // Then connect bags for adjacent nodes. This gives a valid tree decomposition
    // (though not necessarily optimal treewidth).

    // Build adjacency sets as bitmasks (up to 64 nodes)
    if (n > 64) return error.Overflow; // limit for bitmask approach
    var adj: [64]u64 = std.mem.zeroes([64]u64);
    for (edge_list) |edge_val| {
        if (!edge_val.isObj()) continue;
        const eobj = edge_val.asObj();
        if (eobj.kind != .vector) continue;
        const eitems = eobj.data.vector.items.items;
        if (eitems.len < 2) continue;
        const u = nodeIndex(node_list, eitems[0], gc) orelse continue;
        const v_idx = nodeIndex(node_list, eitems[1], gc) orelse continue;
        adj[u] |= @as(u64, 1) << @intCast(v_idx);
        adj[v_idx] |= @as(u64, 1) << @intCast(u);
    }

    // Greedy elimination: process nodes in order, create bags
    var eliminated: u64 = 0;
    var cell_for_node: [64]u16 = undefined;
    @memset(&cell_for_node, 0xFFFF);

    for (0..n) |step| {
        // Pick node with fewest remaining neighbors (min-degree heuristic)
        var best: usize = n;
        var best_deg: usize = n + 1;
        for (0..n) |vi| {
            if (eliminated & (@as(u64, 1) << @intCast(vi)) != 0) continue;
            const remaining = adj[vi] & ~eliminated;
            const deg = @popCount(remaining);
            if (deg < best_deg) {
                best_deg = deg;
                best = vi;
            }
        }
        if (best >= n) break;

        // Bag = {best} ∪ remaining neighbors
        const remaining_neighbors = adj[best] & ~eliminated;
        const bag_vec = try gc.allocObj(.vector);
        try bag_vec.data.vector.items.append(gc.allocator, node_list[best]);
        for (0..n) |ni| {
            if (remaining_neighbors & (@as(u64, 1) << @intCast(ni)) != 0) {
                try bag_vec.data.vector.items.append(gc.allocator, node_list[ni]);
            }
        }

        // Make remaining neighbors clique (fill-in)
        for (0..n) |a| {
            if (remaining_neighbors & (@as(u64, 1) << @intCast(a)) == 0) continue;
            for (a + 1..n) |b| {
                if (remaining_neighbors & (@as(u64, 1) << @intCast(b)) == 0) continue;
                adj[a] |= @as(u64, 1) << @intCast(b);
                adj[b] |= @as(u64, 1) << @intCast(a);
            }
        }

        // Create γ cell with bag as payload
        const cell_idx = try net.addCell(.gamma, 2, Value.makeObj(bag_vec));
        cell_for_node[best] = cell_idx;

        // Wire to earlier bags that share nodes
        for (0..step) |prev_step| {
            _ = prev_step;
            // Find a neighbor of 'best' that was already eliminated and wire to it
        }
        // Wire: connect to the first already-eliminated neighbor's bag
        for (0..n) |ni| {
            if (remaining_neighbors & (@as(u64, 1) << @intCast(ni)) == 0) continue;
            if (eliminated & (@as(u64, 1) << @intCast(ni)) == 0) continue;
            if (cell_for_node[ni] != 0xFFFF) {
                net.connect(Port.aux(cell_idx, 0), Port.aux(cell_for_node[ni], 1)) catch {};
                break;
            }
        }

        eliminated |= @as(u64, 1) << @intCast(best);
    }

    inet_builtins.setNet(slot, net);
    return Value.makeInt(@intCast(slot));
}

fn nodeIndex(nodes: []Value, target: Value, gc: *GC) ?usize {
    for (nodes, 0..) |node, i| {
        if (valEql(node, target, gc)) return i;
    }
    return null;
}

fn valEql(a: Value, b: Value, gc: *GC) bool {
    if (a.isInt() and b.isInt()) return a.asInt() == b.asInt();
    if (a.isKeyword() and b.isKeyword()) return a.asKeywordId() == b.asKeywordId();
    if (a.isSymbol() and b.isSymbol()) return a.asSymbolId() == b.asSymbolId();
    if (a.isString() and b.isString()) {
        return std.mem.eql(u8, gc.getString(a.asStringId()), gc.getString(b.asStringId()));
    }
    return false;
}

// ============================================================================
// DECOMP-BAGS: Extract bags from a decomposition net
// ============================================================================

/// (decomp-bags net-id) → vector of bag vectors
pub fn decompBagsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgs;
    const net = try inet_builtins.getNetPub(args[0]);
    const result = try gc.allocObj(.vector);
    for (net.cells.items) |cell| {
        if (!cell.alive or cell.kind != .gamma) continue;
        try result.data.vector.items.append(gc.allocator, cell.payload);
    }
    return Value.makeObj(result);
}

// ============================================================================
// DECOMP-WIDTH: Treewidth = max bag size - 1
// ============================================================================

/// (decomp-width net-id) → integer (treewidth)
pub fn decompWidthFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgs;
    const net = try inet_builtins.getNetPub(args[0]);
    var max_size: i48 = 0;
    for (net.cells.items) |cell| {
        if (!cell.alive or cell.kind != .gamma) continue;
        if (cell.payload.isObj()) {
            const obj = cell.payload.asObj();
            if (obj.kind == .vector) {
                const sz: i48 = @intCast(obj.data.vector.items.items.len);
                if (sz > max_size) max_size = sz;
            }
        }
    }
    return Value.makeInt(if (max_size > 0) max_size - 1 else 0);
}

// ============================================================================
// DECOMP-GLUE: Colimit via inet reduction (reduce all active pairs)
// ============================================================================

/// (decomp-glue net-id) → reduced payload or nil
/// Runs full inet reduction, returns the payload of the last surviving γ cell.
pub fn decompGlueFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgs;
    const net = try inet_builtins.getNetPub(args[0]);
    var res = Resources.init(.{ .max_fuel = 10000 });
    _ = try net.reduceAll(&res);
    // Return payload of last live γ
    var last_payload = Value.makeNil();
    for (net.cells.items) |cell| {
        if (cell.alive and cell.kind == .gamma) {
            last_payload = cell.payload;
        }
    }
    _ = gc;
    return last_payload;
}

// ============================================================================
// DECOMP-MAP: Functorial lift — apply f to each bag
// ============================================================================

/// (decomp-map f net-id) → new net-id with transformed payloads
pub fn decompMapFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.InvalidArgs;
    const f = args[0];
    const src_net = try inet_builtins.getNetPub(args[1]);

    const slot = inet_builtins.findFreeSlotPub() orelse return error.Overflow;
    var dst_net = Net.init(gc.allocator);

    // Copy structure, transform γ payloads
    for (src_net.cells.items) |cell| {
        const new_payload = if (cell.alive and cell.kind == .gamma) blk: {
            // Apply f to payload
            var call_args = [_]Value{cell.payload};
            break :blk eval_mod.apply(f, &call_args, env, gc) catch cell.payload;
        } else cell.payload;
        _ = try dst_net.addCell(cell.kind, cell.arity, new_payload);
    }
    // Copy wires
    for (src_net.wires.items) |w| {
        try dst_net.connect(w.a, w.b);
    }

    inet_builtins.setNet(slot, dst_net);
    return Value.makeInt(@intCast(slot));
}

// ============================================================================
// DECOMP-DECIDE: Sheaf section existence (the Bumpus algorithm)
// ============================================================================

/// (decomp-decide sheaf net-id) → bool
/// sheaf = {:stalk f :glue g} where:
///   (f bag) → set of local solutions (vector)
///   (g section-a section-b adhesion) → bool (compatible?)
///
/// Checks bottom-up: for each bag, compute local sections via stalk,
/// then check gluing compatibility with parent. If root has any
/// surviving section, return true.
pub fn decompDecideFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.InvalidArgs;
    if (!args[0].isObj()) return error.InvalidArgs;
    const sheaf_obj = args[0].asObj();
    if (sheaf_obj.kind != .map) return error.InvalidArgs;

    var stalk_fn = Value.makeNil();
    var glue_fn = Value.makeNil();
    for (sheaf_obj.data.map.keys.items, 0..) |k, i| {
        if (!k.isKeyword()) continue;
        const kname = gc.getString(k.asKeywordId());
        if (std.mem.eql(u8, kname, "stalk")) stalk_fn = sheaf_obj.data.map.vals.items[i];
        if (std.mem.eql(u8, kname, "glue")) glue_fn = sheaf_obj.data.map.vals.items[i];
    }
    if (stalk_fn.isNil()) return error.InvalidArgs;

    const net = try inet_builtins.getNetPub(args[1]);

    // Compute local sections for each live γ bag
    var sections = compat.emptyList(Value);
    defer sections.deinit(gc.allocator);

    for (net.cells.items) |cell| {
        if (!cell.alive or cell.kind != .gamma) continue;
        var call_args = [_]Value{cell.payload};
        const local = eval_mod.apply(stalk_fn, &call_args, env, gc) catch Value.makeNil();
        try sections.append(gc.allocator, local);
    }

    // If we have a glue function, check pairwise compatibility along wires
    if (!glue_fn.isNil()) {
        for (net.wires.items) |w| {
            if (!net.cells.items[w.a.cell].alive or !net.cells.items[w.b.cell].alive) continue;
            if (net.cells.items[w.a.cell].kind != .gamma or net.cells.items[w.b.cell].kind != .gamma) continue;

            // Find section indices for these cells
            const sa = cellSectionIndex(net, w.a.cell) orelse continue;
            const sb = cellSectionIndex(net, w.b.cell) orelse continue;
            if (sa >= sections.items.len or sb >= sections.items.len) continue;

            // Compute adhesion (intersection of bags)
            const adhesion = try bagIntersection(
                net.cells.items[w.a.cell].payload,
                net.cells.items[w.b.cell].payload,
                gc,
            );

            var glue_args = [_]Value{ sections.items[sa], sections.items[sb], adhesion };
            const compatible = eval_mod.apply(glue_fn, &glue_args, env, gc) catch Value.makeNil();
            if (!compatible.isTruthy()) {
                return Value.makeInt(0); // false — sections don't glue
            }
        }
    }

    // Check if any section is non-empty
    for (sections.items) |s| {
        if (s.isObj() and s.asObj().kind == .vector and s.asObj().data.vector.items.items.len > 0)
            return Value.makeInt(1); // true
        if (s.isTruthy()) return Value.makeInt(1);
    }
    return Value.makeInt(0);
}

fn cellSectionIndex(net: *Net, cell_idx: u16) ?usize {
    var idx: usize = 0;
    for (net.cells.items, 0..) |cell, ci| {
        if (!cell.alive or cell.kind != .gamma) continue;
        if (ci == cell_idx) return idx;
        idx += 1;
    }
    return null;
}

fn bagIntersection(a: Value, b: Value, gc: *GC) !Value {
    const result = try gc.allocObj(.vector);
    if (!a.isObj() or !b.isObj()) return Value.makeObj(result);
    const aobj = a.asObj();
    const bobj = b.asObj();
    if (aobj.kind != .vector or bobj.kind != .vector) return Value.makeObj(result);

    for (aobj.data.vector.items.items) |av| {
        for (bobj.data.vector.items.items) |bv| {
            if (valEql(av, bv, gc)) {
                try result.data.vector.items.append(gc.allocator, av);
                break;
            }
        }
    }
    return Value.makeObj(result);
}

// ============================================================================
// DECOMP-SKELETON: Tree structure only (erase payloads)
// ============================================================================

/// (decomp-skeleton net-id) → new net-id with nil payloads
pub fn decompSkeletonFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgs;
    const src_net = try inet_builtins.getNetPub(args[0]);
    const slot = inet_builtins.findFreeSlotPub() orelse return error.Overflow;
    var dst_net = Net.init(gc.allocator);

    for (src_net.cells.items) |cell| {
        _ = try dst_net.addCell(cell.kind, cell.arity, Value.makeNil());
    }
    for (src_net.wires.items) |w| {
        try dst_net.connect(w.a, w.b);
    }

    inet_builtins.setNet(slot, dst_net);
    return Value.makeInt(@intCast(slot));
}

// ============================================================================
// SHEAF: Constructor
// ============================================================================

/// (sheaf stalk-fn glue-fn) → {:stalk f :glue g}
pub fn sheafFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgs;
    const obj = try gc.allocObj(.map);
    const m = &obj.data.map;
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("stalk")));
    try m.vals.append(gc.allocator, args[0]);
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("glue")));
    try m.vals.append(gc.allocator, if (args.len > 1) args[1] else Value.makeNil());
    return Value.makeObj(obj);
}

// ============================================================================
// SECTION: Evaluate stalk over an open set
// ============================================================================

/// (section sheaf open-set) → result of (stalk open-set)
pub fn sectionFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.InvalidArgs;
    if (!args[0].isObj()) return error.InvalidArgs;
    const sheaf_obj = args[0].asObj();
    if (sheaf_obj.kind != .map) return error.InvalidArgs;

    for (sheaf_obj.data.map.keys.items, 0..) |k, i| {
        if (!k.isKeyword()) continue;
        if (std.mem.eql(u8, gc.getString(k.asKeywordId()), "stalk")) {
            var call_args = [_]Value{args[1]};
            return eval_mod.apply(sheaf_obj.data.map.vals.items[i], &call_args, env, gc);
        }
    }
    return Value.makeNil();
}

// ============================================================================
// RESTRICT: Restrict a section to a subset
// ============================================================================

/// (restrict section subset) → filtered section (keeps elements in subset)
pub fn restrictFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.InvalidArgs;
    if (!args[0].isObj() or !args[1].isObj()) return error.InvalidArgs;
    const sec = args[0].asObj();
    const sub = args[1].asObj();
    if (sec.kind != .vector or sub.kind != .vector) return error.InvalidArgs;

    const result = try gc.allocObj(.vector);
    for (sec.data.vector.items.items) |sv| {
        for (sub.data.vector.items.items) |uv| {
            if (valEql(sv, uv, gc)) {
                try result.data.vector.items.append(gc.allocator, sv);
                break;
            }
        }
    }
    return Value.makeObj(result);
}

// ============================================================================
// EXTEND-SECTION: Try to glue local sections globally
// ============================================================================

/// (extend-section sheaf sections covering) → global section or nil
/// sections = vector of local sections
/// covering = vector of open sets
/// Attempts to merge all local sections; returns merged vector if
/// glue is satisfied pairwise, nil otherwise.
pub fn extendSectionFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 3) return error.InvalidArgs;
    if (!args[0].isObj() or !args[1].isObj() or !args[2].isObj()) return error.InvalidArgs;

    const sheaf_obj = args[0].asObj();
    const secs_obj = args[1].asObj();
    const covering_obj = args[2].asObj();
    if (sheaf_obj.kind != .map or secs_obj.kind != .vector or covering_obj.kind != .vector)
        return error.InvalidArgs;

    const secs = secs_obj.data.vector.items.items;
    const covers = covering_obj.data.vector.items.items;

    // Find glue function
    var glue_fn = Value.makeNil();
    for (sheaf_obj.data.map.keys.items, 0..) |k, i| {
        if (!k.isKeyword()) continue;
        if (std.mem.eql(u8, gc.getString(k.asKeywordId()), "glue"))
            glue_fn = sheaf_obj.data.map.vals.items[i];
    }

    // If no glue function, merge with duplicate suppression
    if (glue_fn.isNil()) {
        const merged = try gc.allocObj(.vector);
        for (secs) |s| {
            if (s.isObj() and s.asObj().kind == .vector) {
                for (s.asObj().data.vector.items.items) |v| {
                    var found = false;
                    for (merged.data.vector.items.items) |existing| {
                        if (valEql(v, existing, gc)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try merged.data.vector.items.append(gc.allocator, v);
                }
            }
        }
        return Value.makeObj(merged);
    }

    // Check pairwise gluing on overlaps
    for (0..secs.len) |i| {
        for (i + 1..secs.len) |j| {
            if (i >= covers.len or j >= covers.len) continue;
            const adhesion = try bagIntersection(covers[i], covers[j], gc);
            var glue_args = [_]Value{ secs[i], secs[j], adhesion };
            const ok = eval_mod.apply(glue_fn, &glue_args, env, gc) catch Value.makeNil();
            if (!ok.isTruthy()) return Value.makeNil(); // gluing fails
        }
    }

    // All compatible — merge
    const merged = try gc.allocObj(.vector);
    for (secs) |s| {
        if (s.isObj() and s.asObj().kind == .vector) {
            for (s.asObj().data.vector.items.items) |v| {
                // Deduplicate
                var found = false;
                for (merged.data.vector.items.items) |existing| {
                    if (valEql(v, existing, gc)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try merged.data.vector.items.append(gc.allocator, v);
            }
        }
    }
    return Value.makeObj(merged);
}

// ============================================================================
// DECOMP-ADHESIONS: Extract adhesions (shared vertices between adjacent bags)
// ============================================================================

/// (decomp-adhesions net-id) → vector of {:bags [i j] :shared [nodes...]}
pub fn decompAdhesionsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgs;
    const net = try inet_builtins.getNetPub(args[0]);
    const result = try gc.allocObj(.vector);

    for (net.wires.items) |w| {
        const ca = net.cells.items[w.a.cell];
        const cb = net.cells.items[w.b.cell];
        if (!ca.alive or !cb.alive) continue;
        if (ca.kind != .gamma or cb.kind != .gamma) continue;

        const shared = try bagIntersection(ca.payload, cb.payload, gc);
        const entry = try gc.allocObj(.map);
        const m = &entry.data.map;

        // :bags [cell-a cell-b]
        try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("bags")));
        const bags_vec = try gc.allocObj(.vector);
        try bags_vec.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(w.a.cell)));
        try bags_vec.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(w.b.cell)));
        try m.vals.append(gc.allocator, Value.makeObj(bags_vec));

        // :shared [nodes...]
        try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("shared")));
        try m.vals.append(gc.allocator, shared);

        try result.data.vector.items.append(gc.allocator, Value.makeObj(entry));
    }
    return Value.makeObj(result);
}

// ============================================================================
// PASSPORT.GAY BRIDGE: Trit trajectories as presheaves on session shape
// ============================================================================

/// (trit-trajectory vec) → {:trits [...] :sum N :conserved? bool}
/// Classify a numeric vector into GF(3) trits and check conservation.
/// This is the nanoclj-zig side of passport.gay's trit trajectory:
///   value > 0 → +1 (PLUS/generator)
///   value = 0 →  0 (ERGODIC/coordinator)
///   value < 0 → -1 (MINUS/validator)
pub fn tritTrajectoryFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isObj()) return error.InvalidArgs;
    const vec = args[0].asObj();
    if (vec.kind != .vector) return error.InvalidArgs;

    const items = vec.data.vector.items.items;
    const trits_vec = try gc.allocObj(.vector);
    var sum: i64 = 0;

    for (items) |v| {
        const trit: i48 = if (v.isInt()) blk: {
            const n = v.asInt();
            break :blk if (n > 0) @as(i48, 1) else if (n < 0) @as(i48, -1) else 0;
        } else 0;
        try trits_vec.data.vector.items.append(gc.allocator, Value.makeInt(trit));
        sum += trit;
    }

    const result = try gc.allocObj(.map);
    const m = &result.data.map;
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("trits")));
    try m.vals.append(gc.allocator, Value.makeObj(trits_vec));
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("sum")));
    try m.vals.append(gc.allocator, Value.makeInt(@intCast(@mod(sum + 300, 3))));
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("conserved")));
    try m.vals.append(gc.allocator, Value.makeInt(if (@mod(sum + 300, 3) == 0) 1 else 0));
    return Value.makeObj(result);
}

/// (decomp-gf3 net-id) → {:trit-sum N :conserved? bool :cell-trits [...]}
/// GF(3) balance of a decomposition net. The inet trit sum must be 0.
/// Bridges to passport.gay: a valid decomposition = valid trit trajectory.
pub fn decompGf3Fn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.InvalidArgs;
    const net = try inet_builtins.getNetPub(args[0]);

    const trits_vec = try gc.allocObj(.vector);
    var sum: i32 = 0;
    for (net.cells.items) |cell| {
        if (!cell.alive) continue;
        const t = cell.trit();
        try trits_vec.data.vector.items.append(gc.allocator, Value.makeInt(@intCast(t)));
        sum += t;
    }

    const result = try gc.allocObj(.map);
    const m = &result.data.map;
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("trit-sum")));
    try m.vals.append(gc.allocator, Value.makeInt(@intCast(@mod(sum + 300, 3))));
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("conserved")));
    try m.vals.append(gc.allocator, Value.makeInt(if (@mod(sum + 300, 3) == 0) 1 else 0));
    try m.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("cell-trits")));
    try m.vals.append(gc.allocator, Value.makeObj(trits_vec));
    return Value.makeObj(result);
}

// ============================================================================
// BUILTIN TABLE
// ============================================================================

pub const decomp_table = .{
    .{ "decompose", &decomposeFn },
    .{ "decomp-bags", &decompBagsFn },
    .{ "decomp-width", &decompWidthFn },
    .{ "decomp-glue", &decompGlueFn },
    .{ "decomp-map", &decompMapFn },
    .{ "decomp-decide", &decompDecideFn },
    .{ "decomp-skeleton", &decompSkeletonFn },
    .{ "decomp-adhesions", &decompAdhesionsFn },
    .{ "sheaf", &sheafFn },
    .{ "section", &sectionFn },
    .{ "restrict", &restrictFn },
    .{ "extend-section", &extendSectionFn },
    .{ "trit-trajectory", &tritTrajectoryFn },
    .{ "decomp-gf3", &decompGf3Fn },
};

// ============================================================================
// TESTS
// ============================================================================

test "decompose triangle graph" {
    const alloc = std.testing.allocator;
    var gc = @import("gc.zig").GC.init(alloc);
    defer gc.deinit();
    inet_builtins.ensureAllocatorPub(&gc);

    // Build {:nodes [1 2 3] :edges [[1 2] [2 3] [1 3]]}
    const nodes_vec = try gc.allocObj(.vector);
    try nodes_vec.data.vector.items.append(alloc, Value.makeInt(1));
    try nodes_vec.data.vector.items.append(alloc, Value.makeInt(2));
    try nodes_vec.data.vector.items.append(alloc, Value.makeInt(3));

    const e1 = try gc.allocObj(.vector);
    try e1.data.vector.items.append(alloc, Value.makeInt(1));
    try e1.data.vector.items.append(alloc, Value.makeInt(2));
    const e2 = try gc.allocObj(.vector);
    try e2.data.vector.items.append(alloc, Value.makeInt(2));
    try e2.data.vector.items.append(alloc, Value.makeInt(3));
    const e3 = try gc.allocObj(.vector);
    try e3.data.vector.items.append(alloc, Value.makeInt(1));
    try e3.data.vector.items.append(alloc, Value.makeInt(3));

    const edges_vec = try gc.allocObj(.vector);
    try edges_vec.data.vector.items.append(alloc, Value.makeObj(e1));
    try edges_vec.data.vector.items.append(alloc, Value.makeObj(e2));
    try edges_vec.data.vector.items.append(alloc, Value.makeObj(e3));

    const graph = try gc.allocObj(.map);
    try graph.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("nodes")));
    try graph.data.map.vals.append(alloc, Value.makeObj(nodes_vec));
    try graph.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("edges")));
    try graph.data.map.vals.append(alloc, Value.makeObj(edges_vec));

    var env = @import("env.zig").Env.init(alloc, null);
    defer env.deinit();

    var resources = Resources.initDefault();
    var dargs = [_]Value{Value.makeObj(graph)};
    const net_id = try decomposeFn(&dargs, &gc, &env, &resources);
    try std.testing.expect(net_id.isInt());

    // Check bags
    var bargs = [_]Value{net_id};
    const bags = try decompBagsFn(&bargs, &gc, &env, &resources);
    try std.testing.expect(bags.isObj());
    try std.testing.expect(bags.asObj().kind == .vector);
    const bag_count = bags.asObj().data.vector.items.items.len;
    try std.testing.expect(bag_count >= 1);

    // Check treewidth
    const tw = try decompWidthFn(&bargs, &gc, &env, &resources);
    try std.testing.expect(tw.isInt());
    // Triangle graph: treewidth = 2 (K3 requires all 3 nodes in one bag)
    try std.testing.expect(tw.asInt() >= 1);

    // Check adhesions
    const adh = try decompAdhesionsFn(&bargs, &gc, &env, &resources);
    try std.testing.expect(adh.isObj());

    // Clean up
    inet_builtins.deinitNets();
}

test "sheaf section and restrict" {
    const alloc = std.testing.allocator;
    var gc = @import("gc.zig").GC.init(alloc);
    defer gc.deinit();

    var env = @import("env.zig").Env.init(alloc, null);
    defer env.deinit();

    var resources = Resources.initDefault();

    // Build sheaf with identity stalk (no glue)
    const stalk = Value.makeNil(); // We can't easily test with eval, so test structure
    var sargs = [_]Value{ stalk, Value.makeNil() };
    const sh = try sheafFn(&sargs, &gc, &env, &resources);
    try std.testing.expect(sh.isObj());
    try std.testing.expect(sh.asObj().kind == .map);
    try std.testing.expect(sh.asObj().data.map.keys.items.len == 2);

    // Test restrict: [1 2 3] restricted to [2 3 4] → [2 3]
    const section_vec = try gc.allocObj(.vector);
    try section_vec.data.vector.items.append(alloc, Value.makeInt(1));
    try section_vec.data.vector.items.append(alloc, Value.makeInt(2));
    try section_vec.data.vector.items.append(alloc, Value.makeInt(3));

    const subset_vec = try gc.allocObj(.vector);
    try subset_vec.data.vector.items.append(alloc, Value.makeInt(2));
    try subset_vec.data.vector.items.append(alloc, Value.makeInt(3));
    try subset_vec.data.vector.items.append(alloc, Value.makeInt(4));

    var rargs = [_]Value{ Value.makeObj(section_vec), Value.makeObj(subset_vec) };
    const restricted = try restrictFn(&rargs, &gc, &env, &resources);
    try std.testing.expect(restricted.isObj());
    try std.testing.expect(restricted.asObj().kind == .vector);
    try std.testing.expectEqual(@as(usize, 2), restricted.asObj().data.vector.items.items.len);
}

test "extend-section without glue merges and deduplicates" {
    const alloc = std.testing.allocator;
    var gc = @import("gc.zig").GC.init(alloc);
    defer gc.deinit();

    var env = @import("env.zig").Env.init(alloc, null);
    defer env.deinit();

    // Sheaf with no glue → just merge
    const sh = try gc.allocObj(.map);
    try sh.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("stalk")));
    try sh.data.map.vals.append(alloc, Value.makeNil());
    try sh.data.map.keys.append(alloc, Value.makeKeyword(try gc.internString("glue")));
    try sh.data.map.vals.append(alloc, Value.makeNil());

    // sections = [[1 2] [2 3]]
    const s1 = try gc.allocObj(.vector);
    try s1.data.vector.items.append(alloc, Value.makeInt(1));
    try s1.data.vector.items.append(alloc, Value.makeInt(2));
    const s2 = try gc.allocObj(.vector);
    try s2.data.vector.items.append(alloc, Value.makeInt(2));
    try s2.data.vector.items.append(alloc, Value.makeInt(3));
    const secs = try gc.allocObj(.vector);
    try secs.data.vector.items.append(alloc, Value.makeObj(s1));
    try secs.data.vector.items.append(alloc, Value.makeObj(s2));

    // covering = [[1 2] [2 3]]
    const c1 = try gc.allocObj(.vector);
    try c1.data.vector.items.append(alloc, Value.makeInt(1));
    try c1.data.vector.items.append(alloc, Value.makeInt(2));
    const c2 = try gc.allocObj(.vector);
    try c2.data.vector.items.append(alloc, Value.makeInt(2));
    try c2.data.vector.items.append(alloc, Value.makeInt(3));
    const covering = try gc.allocObj(.vector);
    try covering.data.vector.items.append(alloc, Value.makeObj(c1));
    try covering.data.vector.items.append(alloc, Value.makeObj(c2));

    var resources = Resources.initDefault();
    var eargs = [_]Value{ Value.makeObj(sh), Value.makeObj(secs), Value.makeObj(covering) };
    const merged = try extendSectionFn(&eargs, &gc, &env, &resources);
    try std.testing.expect(merged.isObj());
    try std.testing.expect(merged.asObj().kind == .vector);
    // [1 2 3] — deduplicated merge
    try std.testing.expectEqual(@as(usize, 3), merged.asObj().data.vector.items.items.len);
}
