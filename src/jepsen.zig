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
// JEPSEN CHECKER FIXTURES (lifted from jepsen.checker)
// ============================================================================

// --- UniqueIds (jepsen.checker/unique-ids) ---
// Checks that a generator emits unique IDs.
// History entries with op=eval and detail used as the generated ID.

pub const UniqueIdsResult = struct {
    valid: bool,
    attempted: usize,
    acknowledged: usize,
    duplicated: usize,
    min_id: u32,
    max_id: u32,
};

pub fn checkUniqueIds() UniqueIdsResult {
    const hist = getHistory();
    var seen: [HISTORY_SIZE]u32 = undefined;
    var seen_len: usize = 0;
    var attempted: usize = 0;
    var min_id: u32 = std.math.maxInt(u32);
    var max_id: u32 = 0;

    for (hist) |entry| {
        if (entry.op != .eval or entry.result != .ok) continue;
        attempted += 1;
        const id = entry.detail;
        if (id < min_id) min_id = id;
        if (id > max_id) max_id = id;
        if (seen_len < HISTORY_SIZE) {
            seen[seen_len] = id;
            seen_len += 1;
        }
    }

    // Count duplicates (O(n²) but history is bounded)
    var dups: usize = 0;
    for (0..seen_len) |i| {
        for (i + 1..seen_len) |j| {
            if (seen[i] == seen[j]) {
                dups += 1;
                break; // count each dup once
            }
        }
    }

    return .{
        .valid = dups == 0,
        .attempted = attempted,
        .acknowledged = attempted,
        .duplicated = dups,
        .min_id = if (attempted > 0) min_id else 0,
        .max_id = max_id,
    };
}

// --- Counter (jepsen.checker/counter) ---
// Monotonic counter: adds increment, reads should be between
// lower bound (sum of :ok adds) and upper bound (sum of all attempted adds).
// We encode: op=eval + detail=value for add, op=check + detail=read_value for read.

pub const CounterResult = struct {
    valid: bool,
    reads: usize,
    errors: usize,
    lower_bound: u64,
    upper_bound: u64,
    final_read: u64,
};

pub fn checkCounter() CounterResult {
    const hist = getHistory();
    var lower: u64 = 0; // sum of confirmed adds
    var upper: u64 = 0; // sum of all attempted adds
    var reads: usize = 0;
    var errors: usize = 0;
    var final_read: u64 = 0;

    for (hist) |entry| {
        if (entry.op == .eval and entry.result == .ok) {
            // Successful add
            lower += entry.detail;
            upper += entry.detail;
        } else if (entry.op == .eval and entry.result == .fail) {
            // Failed add — only upper bound increases
            upper += entry.detail;
        } else if (entry.op == .check) {
            // Read operation
            const read_val: u64 = entry.detail;
            reads += 1;
            final_read = read_val;
            if (read_val < lower or read_val > upper) {
                errors += 1;
            }
        }
    }

    return .{
        .valid = errors == 0,
        .reads = reads,
        .errors = errors,
        .lower_bound = lower,
        .upper_bound = upper,
        .final_read = final_read,
    };
}

// --- CAS Register (jepsen.tests/linearizable-register) ---
// Single register supporting read, write, CAS.
// We check sequential consistency (not full linearizability — no Knossos).
// History: op=eval for write (detail=new_val), op=check for read (detail=read_val).
// CAS: we use a special encoding via version_id field (expected in low 16, new in high 16).

pub const CasRegisterResult = struct {
    valid: bool,
    reads: usize,
    writes: usize,
    cas_ops: usize,
    stale_reads: usize,     // read returned a value that was already overwritten
    lost_writes: usize,     // write acknowledged but never observed
    register_value: u32,    // final register state
};

pub fn checkCasRegister() CasRegisterResult {
    const hist = getHistory();
    var reg: u32 = 0; // current register value
    var reads: usize = 0;
    var writes: usize = 0;
    var cas_ops: usize = 0;
    var stale_reads: usize = 0;
    var lost_writes: usize = 0;
    var last_write: u32 = 0;
    var write_observed = true;

    for (hist) |entry| {
        if (entry.op == .eval and entry.result == .ok) {
            // Write operation
            if (!write_observed and last_write != reg) {
                lost_writes += 1;
            }
            reg = entry.detail;
            last_write = entry.detail;
            write_observed = false;
            writes += 1;
        } else if (entry.op == .check and entry.result == .ok) {
            // Read operation
            const read_val = entry.detail;
            reads += 1;
            if (read_val == last_write) write_observed = true;
            if (read_val != reg and entry.trit_before == 0) {
                // Stale read outside nemesis
                stale_reads += 1;
            }
        } else if (entry.op == .eval and entry.result == .info) {
            // CAS operation (encoded in version_id: low16=expected, high16=new)
            const expected: u32 = @truncate(@as(u64, entry.version_id) & 0xFFFF);
            const new_val: u32 = @truncate((@as(u64, entry.version_id) >> 16) & 0xFFFF);
            cas_ops += 1;
            if (reg == expected) {
                reg = new_val;
                last_write = new_val;
                write_observed = false;
            }
        }
    }

    return .{
        .valid = stale_reads == 0 and lost_writes == 0,
        .reads = reads,
        .writes = writes,
        .cas_ops = cas_ops,
        .stale_reads = stale_reads,
        .lost_writes = lost_writes,
        .register_value = reg,
    };
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

// --- Checker fixture tests ---

test "jepsen: unique-ids — all unique passes" {
    resetHistory();
    record(.eval, .ok, 0, 0, 0, 1);
    record(.eval, .ok, 0, 0, 0, 2);
    record(.eval, .ok, 0, 0, 0, 3);
    record(.eval, .ok, 0, 0, 0, 4);
    const result = checkUniqueIds();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 4), result.attempted);
    try std.testing.expectEqual(@as(usize, 0), result.duplicated);
    try std.testing.expectEqual(@as(u32, 1), result.min_id);
    try std.testing.expectEqual(@as(u32, 4), result.max_id);
}

test "jepsen: unique-ids — duplicate detected" {
    resetHistory();
    record(.eval, .ok, 0, 0, 0, 1);
    record(.eval, .ok, 0, 0, 0, 2);
    record(.eval, .ok, 0, 0, 0, 2); // dup!
    record(.eval, .ok, 0, 0, 0, 3);
    const result = checkUniqueIds();
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.duplicated);
}

test "jepsen: counter — clean increments pass" {
    resetHistory();
    record(.eval, .ok, 0, 0, 0, 5);   // add 5
    record(.eval, .ok, 0, 0, 0, 3);   // add 3
    record(.check, .ok, 0, 0, 0, 8);  // read 8 (= 5+3, within bounds)
    const result = checkCounter();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u64, 8), result.lower_bound);
    try std.testing.expectEqual(@as(u64, 8), result.upper_bound);
    try std.testing.expectEqual(@as(usize, 0), result.errors);
}

test "jepsen: counter — read out of bounds detected" {
    resetHistory();
    record(.eval, .ok, 0, 0, 0, 5);   // add 5
    record(.eval, .ok, 0, 0, 0, 3);   // add 3
    record(.check, .ok, 0, 0, 0, 10); // read 10, but upper=8
    const result = checkCounter();
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.errors);
}

test "jepsen: counter — failed add widens bounds" {
    resetHistory();
    record(.eval, .ok, 0, 0, 0, 5);    // add 5 (ok)
    record(.eval, .fail, 0, 0, 0, 3);  // add 3 (failed)
    record(.check, .ok, 0, 0, 0, 7);   // read 7: lower=5, upper=8, valid
    const result = checkCounter();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u64, 5), result.lower_bound);
    try std.testing.expectEqual(@as(u64, 8), result.upper_bound);
}

test "jepsen: cas-register — clean writes and reads" {
    resetHistory();
    record(.eval, .ok, 0, 0, 0, 42);  // write 42
    record(.check, .ok, 0, 0, 0, 42); // read 42
    record(.eval, .ok, 0, 0, 0, 99);  // write 99
    record(.check, .ok, 0, 0, 0, 99); // read 99
    const result = checkCasRegister();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 2), result.writes);
    try std.testing.expectEqual(@as(usize, 2), result.reads);
    try std.testing.expectEqual(@as(u32, 99), result.register_value);
}

test "jepsen: cas-register — CAS success" {
    resetHistory();
    record(.eval, .ok, 0, 0, 0, 10);             // write 10
    // CAS: expect 10, set 20 — encoded as version_id = (20 << 16) | 10
    record(.eval, .info, 0, 0, (20 << 16) | 10, 0);
    record(.check, .ok, 0, 0, 0, 20);            // read 20
    const result = checkCasRegister();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 20), result.register_value);
    try std.testing.expectEqual(@as(usize, 1), result.cas_ops);
}
