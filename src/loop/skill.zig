//! Skill — the SDF-style extension interface for the agent-o-nanoclj loop.
//!
//! A Skill is a named Clojure-callable bridge: `(name, doc, body)`. Each
//! `loop/*.zig` submodule that wants to expose a function to the nanoclj
//! REPL declares `pub const skills: []const Skill = &.{...}`. The umbrella
//! `loop.zig` concatenates these at comptime; `core.zig` iterates the
//! umbrella's slice once when `initCore` populates the builtin table.
//!
//! The point: adding a new Clojure-callable is ONE edit to a `loop/*.zig`
//! file. No edit to `core.zig`. No edit to anything outside `loop/`.
//!
//! SDF mapping (Sussman & Hanson, *Software Design for Flexibility*):
//!
//!  - **Generic dispatch.** `name → body` is predicate dispatch on string.
//!    Each Skill is a handler attached at registration time; the registry
//!    is its dispatch table.
//!
//!  - **Egalitarian data.** Skills are first-class plain structs. They can
//!    be sliced, filtered, concatenated, looked up — by anyone, anywhere,
//!    without core involvement.
//!
//!  - **Combinator-closed.** `combine(a, b) : []Skill × []Skill → []Skill`.
//!    The umbrella's `skills` is `combine(builtins.skills, gradient.skills,
//!    ...)` — a fold under `combine`. Adding a submodule adds one term.
//!
//!  - **Layered.** `doc` is an attribute layer on top of `(name, body)`.
//!    Future layers (e.g., trit-classification, latency budget, cap-secure
//!    audience) attach the same way: extend the struct, default-init in
//!    existing call sites, the new layer simply rides along.
//!
//! See also `goblins-adapter/propagator-nash.scm:140` (`merge-with-law`):
//! the categorical anchor for `Skill` is the same shape — a layered
//! handler keyed by a discriminator (there: a conservation law; here: a
//! name).

const std = @import("std");
const value = @import("../value.zig");
const Value = value.Value;
const GC = @import("../gc.zig").GC;
const Env = @import("../env.zig").Env;
const Resources = @import("../transitivity.zig").Resources;

/// Standard nanoclj builtin signature: `(args, gc, env, res) → !Value`.
/// Structurally identical to `core.zig`'s `BuiltinFn`. We declare it here
/// rather than importing `core.zig` to avoid the loop ↔ core import cycle.
pub const SkillFn = *const fn (
    args: []Value,
    gc: *GC,
    env: *Env,
    res: *Resources,
) anyerror!Value;

/// One registerable Clojure-callable extension.
/// `name`: the symbol exposed to the REPL (e.g., `"loop-version"`).
/// `doc`: human-readable one-liner; consumed by future `(loop-doc 'loop-version)`.
/// `body`: the actual Zig function pointer.
pub const Skill = struct {
    name: []const u8,
    doc: []const u8,
    body: SkillFn,
};

/// Comptime concatenation. `combine(a, b)` is the monoid sum of two skill
/// slices. The umbrella uses this to fold per-submodule slices into one.
pub fn combine(comptime a: []const Skill, comptime b: []const Skill) []const Skill {
    return a ++ b;
}

/// Linear-scan lookup by name. The registry is small (<100 skills today),
/// so O(n) is fine and avoids a runtime hashmap. If profiling ever flags
/// this, swap for a comptime-built perfect hash.
pub fn lookup(skills: []const Skill, name: []const u8) ?*const Skill {
    for (skills) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

fn nilFn(_: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    return Value.makeNil();
}

test "Skill record carries name + doc + body" {
    const s = Skill{ .name = "test-skill", .doc = "test doc", .body = nilFn };
    try std.testing.expectEqualStrings("test-skill", s.name);
    try std.testing.expectEqualStrings("test doc", s.doc);
}

test "combine concatenates two skill slices at comptime" {
    const a = [_]Skill{.{ .name = "a", .doc = "", .body = nilFn }};
    const b = [_]Skill{.{ .name = "b", .doc = "", .body = nilFn }};
    const ab = comptime combine(&a, &b);
    try std.testing.expectEqual(@as(usize, 2), ab.len);
    try std.testing.expectEqualStrings("a", ab[0].name);
    try std.testing.expectEqualStrings("b", ab[1].name);
}

test "combine is associative (left and right fold agree)" {
    const a = [_]Skill{.{ .name = "x", .doc = "", .body = nilFn }};
    const b = [_]Skill{.{ .name = "y", .doc = "", .body = nilFn }};
    const c = [_]Skill{.{ .name = "z", .doc = "", .body = nilFn }};
    const left = comptime combine(combine(&a, &b), &c);
    const right = comptime combine(&a, combine(&b, &c));
    try std.testing.expectEqual(left.len, right.len);
    for (left, 0..) |s, i| {
        try std.testing.expectEqualStrings(s.name, right[i].name);
    }
}

test "lookup finds present skill, misses absent one" {
    const skills = [_]Skill{
        .{ .name = "first", .doc = "", .body = nilFn },
        .{ .name = "second", .doc = "", .body = nilFn },
    };
    try std.testing.expect(lookup(&skills, "first") != null);
    try std.testing.expect(lookup(&skills, "second") != null);
    try std.testing.expect(lookup(&skills, "missing") == null);
}

test "lookup returned pointer references the original slice element" {
    const skills = [_]Skill{
        .{ .name = "alpha", .doc = "doc-a", .body = nilFn },
        .{ .name = "beta", .doc = "doc-b", .body = nilFn },
    };
    const found = lookup(&skills, "beta") orelse return error.TestExpectedNonNull;
    try std.testing.expectEqualStrings("doc-b", found.doc);
}
