//! jepsen.zig: Embedded linearizability testing for nanoclj-zig
//!
//! Not the JVM Jepsen tool — a Zig-native adversarial test harness that
//! uses the same conceptual stack: nemesis, generator, history, checker.
//!
//! Target under test: the interpreter's own mutable state.
//!   - GF(3) trit conservation (trit_sum = 0 mod 3)
//!   - Causal ordering (monotonic version IDs)
//!   - Syrup round-trip identity (encode ∘ decode = id)
//!   - Eval determinism (same expr → same result)
//!
//! No networking needed. Chaos lives in the interleaving of eval calls
//! and nemesis injections within a single dispatch loop.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const transitivity = @import("transitivity.zig");

// ============================================================================
// HISTORY: append-only ring buffer of operation records
// ============================================================================

pub const OpKind = enum(u8) {
    eval,       // normal eval
    nemesis,    // fault injection
    recover,    // recovery from fault
    check,      // invariant check
};

pub const OpResult = enum(u8) {
    ok,
    fail,
    info,       // nemesis-generated informational
};

pub const HistoryEntry = struct {
    op: OpKind,
    result: OpResult,
    trit_before: i8,
    trit_after: i8,
    version_id: u64,
    causal_ts: u64,     // monotonic timestamp
    detail: u32,        // op-specific detail (e.g., nemesis type)
};

const HISTORY_SIZE = 4096;

var history: [HISTORY_SIZE]HistoryEntry = undefined;
var history_len: usize = 0;
var history_wrap: usize = 0; // total entries ever written
pub var causal_clock: u64 = 0;

pub fn record(op: OpKind, result: OpResult, trit_before: i8, trit_after: i8, version_id: u64, detail: u32) void {
    causal_clock += 1;
    const idx = history_len % HISTORY_SIZE;
    history[idx] = .{
        .op = op,
        .result = result,
        .trit_before = trit_before,
        .trit_after = trit_after,
        .version_id = version_id,
        .causal_ts = causal_clock,
        .detail = detail,
    };
    history_len += 1;
    history_wrap += 1;
}

pub fn getHistory() []const HistoryEntry {
    if (history_len <= HISTORY_SIZE) {
        return history[0..history_len];
    }
    // wrapped — return from current position
    return history[0..HISTORY_SIZE];
}

pub fn resetHistory() void {
    history_len = 0;
    history_wrap = 0;
    causal_clock = 0;
    nemesis_active = false;
    nemesis_kind = .none;
}

// ============================================================================
// NEMESIS: fault injection into interpreter state
// ============================================================================

pub const NemesisKind = enum(u8) {
    none,
    trit_corrupt,       // flip a trit value (+1 → -1)
    trit_duplicate,     // duplicate a trit (breaks conservation)
    version_rewind,     // rewind version counter (breaks monotonicity)
    eval_drop,          // silently drop an eval result
    causal_invert,      // swap causal ordering of two events
};

var nemesis_active: bool = false;
var nemesis_kind: NemesisKind = .none;
var nemesis_count: u64 = 0;

/// Activate a nemesis. Returns the previous state.
pub fn activateNemesis(kind: NemesisKind) NemesisKind {
    const prev = nemesis_kind;
    nemesis_kind = kind;
    nemesis_active = kind != .none;
    nemesis_count += 1;
    record(.nemesis, .info, 0, 0, 0, @intFromEnum(kind));
    return prev;
}

/// Deactivate nemesis, returning to normal operation.
pub fn deactivateNemesis() void {
    record(.recover, .info, 0, 0, 0, @intFromEnum(nemesis_kind));
    nemesis_kind = .none;
    nemesis_active = false;
}

/// Apply nemesis corruption to a trit value (if active).
/// Returns the (possibly corrupted) trit.
pub fn applyNemesis(trit: i8) i8 {
    if (!nemesis_active) return trit;
    return switch (nemesis_kind) {
        .trit_corrupt => -trit, // flip sign
        .trit_duplicate => trit, // return same value (caller duplicates)
        else => trit,
    };
}

/// Check if nemesis wants to drop this eval result.
pub fn shouldDropEval() bool {
    if (!nemesis_active) return false;
    return nemesis_kind == .eval_drop;
}

/// Check if nemesis wants to rewind version.
pub fn shouldRewindVersion() bool {
    if (!nemesis_active) return false;
    return nemesis_kind == .version_rewind;
}

pub fn isNemesisActive() bool {
    return nemesis_active;
}

// ============================================================================
// GENERATOR: deterministic pseudorandom operation sequences
// ============================================================================

/// SplitMix64 — deterministic PRNG for reproducible test sequences
fn splitMix(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Generate a test plan: sequence of (op_kind, detail) pairs.
/// Nemesis injection rate is ~20% of operations.
pub fn generatePlan(seed: u64, count: usize, buf: []HistoryEntry) usize {
    var state = seed;
    const n = @min(count, buf.len);
    for (0..n) |i| {
        const r = splitMix(&state);
        const kind: OpKind = if (r % 5 == 0) .nemesis else .eval;
        const detail: u32 = if (kind == .nemesis)
            @intCast((r >> 8) % 5 + 1) // nemesis kind 1-5
        else
            @intCast((r >> 16) % 100); // eval variant
        buf[i] = .{
            .op = kind,
            .result = .ok,
            .trit_before = 0,
            .trit_after = 0,
            .version_id = 0,
            .causal_ts = 0,
            .detail = detail,
        };
    }
    return n;
}

// ============================================================================
// CHECKER: verify invariants over history
// ============================================================================

pub const Violation = struct {
    index: usize,
    kind: ViolationKind,
    causal_ts: u64,
};

pub const ViolationKind = enum(u8) {
    gf3_broken,         // trit_sum != 0 mod 3 after an eval
    causal_inversion,   // causal_ts decreased
    version_regression, // version_id decreased without nemesis
    trit_drift,         // trit changed without corresponding op
};

const MAX_VIOLATIONS = 256;

pub const CheckResult = struct {
    valid: bool,
    violations: [MAX_VIOLATIONS]Violation,
    violation_count: usize,
    ops_checked: usize,
    nemesis_events: usize,
    max_trit_drift: i8,
};

/// Check the history for linearizability violations.
/// Model: GF(3) conservation, causal monotonicity, version monotonicity.
pub fn check() CheckResult {
    var result = CheckResult{
        .valid = true,
        .violations = undefined,
        .violation_count = 0,
        .ops_checked = 0,
        .nemesis_events = 0,
        .max_trit_drift = 0,
    };

    const hist = getHistory();
    var last_causal_ts: u64 = 0;
    var last_version: u64 = 0;
    var in_nemesis = false;

    for (hist, 0..) |entry, i| {
        result.ops_checked += 1;

        if (entry.op == .nemesis) {
            result.nemesis_events += 1;
            in_nemesis = true;
            continue;
        }
        if (entry.op == .recover) {
            in_nemesis = false;
            continue;
        }

        // Check causal monotonicity
        if (entry.causal_ts < last_causal_ts and !in_nemesis) {
            addViolation(&result, i, .causal_inversion, entry.causal_ts);
        }
        last_causal_ts = entry.causal_ts;

        // Check version monotonicity (only for eval ops)
        if (entry.op == .eval and entry.version_id > 0) {
            if (entry.version_id < last_version and !in_nemesis) {
                addViolation(&result, i, .version_regression, entry.causal_ts);
            }
            last_version = entry.version_id;
        }

        // Check GF(3) conservation: trit_after should be 0 mod 3
        if (entry.op == .eval and entry.result == .ok) {
            if (@mod(@as(i16, entry.trit_after) + 3, 3) != 0 and !in_nemesis) {
                addViolation(&result, i, .gf3_broken, entry.causal_ts);
            }
        }

        // Check trit drift
        const drift = entry.trit_after - entry.trit_before;
        if (drift > result.max_trit_drift) result.max_trit_drift = drift;
        if (-drift > result.max_trit_drift) result.max_trit_drift = -drift;
    }

    return result;
}

fn addViolation(result: *CheckResult, index: usize, kind: ViolationKind, ts: u64) void {
    if (result.violation_count < MAX_VIOLATIONS) {
        result.violations[result.violation_count] = .{
            .index = index,
            .kind = kind,
            .causal_ts = ts,
        };
        result.violation_count += 1;
    }
    result.valid = false;
}

// ============================================================================
// TESTS
// ============================================================================

test "jepsen: clean history passes check" {
    resetHistory();
    record(.eval, .ok, 0, 0, 1, 0);
    record(.eval, .ok, 0, 0, 2, 0);
    record(.eval, .ok, 0, 0, 3, 0);
    const result = check();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 3), result.ops_checked);
    try std.testing.expectEqual(@as(usize, 0), result.violation_count);
}

test "jepsen: gf3 violation detected" {
    resetHistory();
    record(.eval, .ok, 0, 0, 1, 0); // trit_after=0, conserved
    record(.eval, .ok, 0, 1, 2, 0); // trit_after=1, BROKEN
    const result = check();
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.violation_count);
    try std.testing.expectEqual(ViolationKind.gf3_broken, result.violations[0].kind);
}

test "jepsen: causal inversion detected" {
    resetHistory();
    causal_clock = 10; // force high ts
    record(.eval, .ok, 0, 0, 1, 0); // ts=11
    causal_clock = 5; // rewind clock
    record(.eval, .ok, 0, 0, 2, 0); // ts=6 < 11
    const result = check();
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(ViolationKind.causal_inversion, result.violations[0].kind);
}

test "jepsen: nemesis suppresses violations" {
    resetHistory();
    record(.eval, .ok, 0, 0, 1, 0);
    record(.nemesis, .info, 0, 0, 0, @intFromEnum(NemesisKind.trit_corrupt));
    record(.eval, .ok, 0, 1, 2, 0); // gf3 broken but nemesis active
    record(.recover, .info, 0, 0, 0, 0);
    record(.eval, .ok, 0, 0, 3, 0);
    const result = check();
    try std.testing.expect(result.valid); // nemesis window suppresses violation
}

test "jepsen: generator produces reproducible plans" {
    var buf1: [100]HistoryEntry = undefined;
    var buf2: [100]HistoryEntry = undefined;
    const n1 = generatePlan(42, 100, &buf1);
    const n2 = generatePlan(42, 100, &buf2);
    try std.testing.expectEqual(n1, n2);
    for (0..n1) |i| {
        try std.testing.expectEqual(buf1[i].op, buf2[i].op);
        try std.testing.expectEqual(buf1[i].detail, buf2[i].detail);
    }
}

test "jepsen: nemesis apply flips trit" {
    _ = activateNemesis(.trit_corrupt);
    try std.testing.expectEqual(@as(i8, -1), applyNemesis(1));
    try std.testing.expectEqual(@as(i8, 1), applyNemesis(-1));
    deactivateNemesis();
    try std.testing.expectEqual(@as(i8, 1), applyNemesis(1)); // no corruption
}
