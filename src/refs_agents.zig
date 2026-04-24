//! Clojure-style `ref` + `dosync` for nanoclj-zig.
//!
//! Single-threaded semantic parity (no real STM, no thread pool).
//!   - Refs are atoms tagged via metadata `{:ref true}`. This keeps
//!     `ObjKind.atom` reuse and lets `deref` / `@` Just Work.
//!   - `alter` is only legal inside `(dosync ...)` — guarded by a
//!     module-local `in_transaction` flag (single-threaded == thread-local).
//!   - `dosync` snapshots each ref touched during the body; on commit it
//!     simply writes back (single-threaded → no actual retry loop needed).
//!
//! Agents live in agent.zig + core.zig already; `commute` aliases `alter`
//! and `send-off` aliases `send` in single-threaded mode.

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const eval_mod = @import("eval.zig");

// ---------------------------------------------------------------------------
// Transaction state (single-threaded → module-local; upgrade path: threadlocal).
// ---------------------------------------------------------------------------

var in_transaction: bool = false;

/// Snapshot of a ref at dosync entry, used for simple commit-or-rollback.
const Snapshot = struct {
    obj: *Obj,
    original: Value,
    proposed: Value,
};

var tx_log: std.ArrayListUnmanaged(Snapshot) = .empty;

pub fn isInTransaction() bool {
    return in_transaction;
}

fn findOrAdd(obj: *Obj, gc: *GC) !*Snapshot {
    for (tx_log.items) |*s| {
        if (s.obj == obj) return s;
    }
    try tx_log.append(gc.allocator, .{
        .obj = obj,
        .original = obj.data.atom.val,
        .proposed = obj.data.atom.val,
    });
    return &tx_log.items[tx_log.items.len - 1];
}

// ---------------------------------------------------------------------------
// Meta helpers — tag atom objects so `ref?` / `agent?` can distinguish them.
// ---------------------------------------------------------------------------

fn attachFlagMeta(obj: *Obj, gc: *GC, flag_name: []const u8) !void {
    const meta = try gc.allocObj(.map);
    const kw_id = try gc.internString(flag_name);
    try meta.data.map.keys.append(gc.allocator, Value.makeKeyword(kw_id));
    try meta.data.map.vals.append(gc.allocator, Value.makeBool(true));
    obj.meta = meta;
}

fn hasMetaFlag(obj: *const Obj, gc: *GC, flag_name: []const u8) bool {
    const m = obj.meta orelse return false;
    for (m.data.map.keys.items, 0..) |k, i| {
        if (!k.isKeyword()) continue;
        const s = gc.getString(k.asKeywordId());
        if (!std.mem.eql(u8, s, flag_name)) continue;
        const v = m.data.map.vals.items[i];
        if (v.isBool() and v.asBool()) return true;
    }
    return false;
}

pub fn isRef(v: Value, gc: *GC) bool {
    if (!v.isObj()) return false;
    const o = v.asObj();
    return o.kind == .atom and hasMetaFlag(o, gc, "ref");
}

// ---------------------------------------------------------------------------
// Builtins.
// ---------------------------------------------------------------------------

/// (ref init) — create a ref initialized to `init`.  Refs share the atom
/// internal layout; the `{:ref true}` metadata distinguishes them.
pub fn refFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const obj = try gc.allocObj(.atom);
    obj.data.atom.val = args[0];
    try attachFlagMeta(obj, gc, "ref");
    return Value.makeObj(obj);
}

/// (alter r f & args) — apply `(f @r & args)` and stage the result.
/// Must be called inside `(dosync ...)`.
pub fn alterFn(args: []Value, gc: *GC, env: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!in_transaction) return error.IllegalState;
    if (!args[0].isObj()) return error.TypeError;
    const obj = args[0].asObj();
    if (obj.kind != .atom) return error.TypeError;
    if (!hasMetaFlag(obj, gc, "ref")) return error.TypeError;

    const snap = try findOrAdd(obj, gc);

    var call_buf: [8]Value = undefined;
    call_buf[0] = snap.proposed;
    const extra = args[2..];
    const n = @min(extra.len, call_buf.len - 1);
    for (0..n) |i| call_buf[1 + i] = extra[i];
    const new_val = try eval_mod.apply(args[1], call_buf[0 .. 1 + n], env, gc);
    snap.proposed = new_val;
    return new_val;
}

/// Enter / exit transaction scope.  Callers use the special form wrapper
/// `evalDosync` in eval.zig; this pair is exposed for that.
pub fn beginTransaction() void {
    in_transaction = true;
}

/// Commit proposed values.  Single-threaded: no contention, just write.
pub fn commitTransaction(gc: *GC) void {
    for (tx_log.items) |snap| {
        snap.obj.data.atom.val = snap.proposed;
    }
    tx_log.clearAndFree(gc.allocator);
    in_transaction = false;
}

/// Abort & discard staged writes.  Used on error inside dosync body.
pub fn abortTransaction(gc: *GC) void {
    tx_log.clearAndFree(gc.allocator);
    in_transaction = false;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "ref carries :ref meta flag" {
    const allocator = std.testing.allocator;
    var gc = GC.init(allocator);
    defer gc.deinit();

    const obj = try gc.allocObj(.atom);
    obj.data.atom.val = Value.makeInt(0);
    try attachFlagMeta(obj, &gc, "ref");
    try std.testing.expect(hasMetaFlag(obj, &gc, "ref"));
    try std.testing.expect(!hasMetaFlag(obj, &gc, "agent"));
    try std.testing.expect(isRef(Value.makeObj(obj), &gc));
}

test "transaction flag toggles" {
    try std.testing.expect(!isInTransaction());
    beginTransaction();
    try std.testing.expect(isInTransaction());
    // Manually reset without a real GC.
    in_transaction = false;
    tx_log = .empty;
}
