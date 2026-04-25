//! Clojure-callable bridges into the agent-o-nanoclj feedback-loop core.
//!
//! This is the boundary that makes the `loop` world reachable from the
//! nanoclj REPL. The bridge is intentionally minimal — introspection-only —
//! to prove the contract works without dragging GC/Env/Resources into every
//! loop primitive.
//!
//! Adding a new builtin: write a function with the standard nanoclj
//! signature `fn (args, gc, env, res) anyerror!Value`, register it in
//! core.zig's builtin table.

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const GC = @import("../gc.zig").GC;
const Env = @import("../env.zig").Env;
const Resources = @import("../transitivity.zig").Resources;
const skill = @import("skill.zig");
const Skill = skill.Skill;

/// Skills exposed to the nanoclj REPL by this submodule.
/// Add a new bridge: declare its `pub fn ...Fn(...)` above and append a
/// `Skill{...}` here. No edit to `core.zig` required.
pub const skills = [_]Skill{
    .{
        .name = "loop-version",
        .doc = "(loop-version) — return the agent-o-nanoclj API generation symbol",
        .body = loopVersionFn,
    },
    .{
        .name = "loop-test-count",
        .doc = "(loop-test-count) — return count of loop unit tests in this build",
        .body = loopTestCountFn,
    },
};

/// (loop-version) — returns the loop API generation as a symbol.
/// Bumped when the wire-level format of any persisted log changes.
pub fn loopVersionFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const sym_id = try gc.internString("loop-v1");
    return Value.makeSymbol(sym_id);
}

/// (loop-test-count) — returns the count of loop unit tests known to this
/// build. Smoke test that the bridge is wired and that a REPL session is
/// running a binary built with loop support.
pub fn loopTestCountFn(args: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // Bumped manually when adding/removing loop tests. Source of truth is
    // `zig build loop-test --summary all`.
    return Value.makeInt(83);
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "loopVersionFn rejects extra args" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    var args = [_]Value{Value.makeInt(0)};
    try std.testing.expectError(error.ArityError, loopVersionFn(&args, &gc, &env, &res));
}

test "loopTestCountFn returns the known count" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();
    var res = Resources.unmetered();
    const out = try loopTestCountFn(&.{}, &gc, &env, &res);
    try std.testing.expect(out.isInt());
    try std.testing.expect(out.asInt() >= 1);
}
