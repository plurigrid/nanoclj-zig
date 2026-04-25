//! Clojure-callable bridges into agent-o-nanoclj.
//!
//! This is the boundary that makes the aor world reachable from the
//! nanoclj REPL. Right now the bridge is intentionally minimal —
//! introspection-only — to prove the contract works without dragging the
//! GC, Env, and Resources types into every aor primitive.
//!
//! Adding a new builtin: write a function with the standard nanoclj
//! signature `fn (args, gc, env, res) anyerror!Value`, register it in
//! core.zig's builtin table.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

/// (aor-version) — returns the agent-o-nanoclj API generation as a symbol.
/// Bumped when the wire-level format of any persisted log changes.
pub fn aorVersionFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const sym_id = try gc.internString("aor-v1");
    return Value.makeSymbol(sym_id);
}

/// (aor-test-count) — returns the count of aor unit tests known to this
/// build. Useful as a smoke test that the bridge is wired and that a
/// repl session is running a binary built with aor support.
pub fn aorTestCountFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // Bumped manually when adding/removing aor tests. Source of truth is
    // `zig build aor-test --summary all`.
    return Value.makeInt(79);
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "aorVersionFn rejects extra args" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    var args = [_]Value{Value.makeInt(0)};
    try std.testing.expectError(error.ArityError, aorVersionFn(&args, &gc, &env, &res));
}

test "aorTestCountFn returns the known count" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    const out = try aorTestCountFn(&.{}, &gc, &env, &res);
    try std.testing.expect(out.isInt());
    try std.testing.expect(out.asInt() >= 1);
}
