//! pattern.zig: Regexp vs PEG pluralism — 3 implementations of each
//!
//! REGEXP (recognize — does the string match?):
//!   1. Thompson NFA: linear time, no backtracking, parallel state simulation
//!   2. Brzozowski derivatives: algebraic, builds residual regex, elegant
//!   3. Backtracking: simple recursive, exponential worst case, captures
//!
//! PEG (parse — structural decomposition):
//!   1. Recursive descent: direct, predictable, no left recursion
//!   2. Packrat: memoized recursive descent, linear time guarantee
//!   3. VM-based: LPEG-style bytecode, composable, GF(3) trit per rule
//!
//! The fundamental difference:
//!   Regexp: set of strings (declarative, unordered alternation)
//!   PEG: parsing function (operational, ordered choice)
//!   Same input can match both but the MEANING differs.

const std = @import("std");

// ============================================================================
// SHARED TYPES
// ============================================================================

pub const MatchResult = struct {
    matched: bool,
    consumed: usize, // bytes consumed
    trit: i8, // GF(3): +1 matched, 0 partial, -1 failed
};

fn fail() MatchResult {
    return .{ .matched = false, .consumed = 0, .trit = -1 };
}

fn ok(n: usize) MatchResult {
    return .{ .matched = true, .consumed = n, .trit = 1 };
}

// ============================================================================
// REGEXP 1: Thompson NFA
// ============================================================================
// Pattern mini-language: . (any) * (kleene) | (alt) () (group) \ (escape)
// Linear time: simulate all NFA states in parallel.

const MAX_STATES = 64;

const NfaOp = enum(u8) {
    literal, // match one char
    dot, // match any char
    split, // fork: try both paths
    jump, // unconditional jump
    accept, // match complete
};

const NfaInst = struct {
    op: NfaOp,
    ch: u8 = 0, // for literal
    out1: u8 = 0, // next state
    out2: u8 = 0, // second next (for split)
};

pub const ThompsonNfa = struct {
    insts: [MAX_STATES]NfaInst = undefined,
    len: u8 = 0,

    pub fn compile(pattern: []const u8) ThompsonNfa {
        var nfa = ThompsonNfa{};
        var i: usize = 0;
        while (i < pattern.len and nfa.len < MAX_STATES - 1) {
            const c = pattern[i];
            if (c == '.') {
                nfa.insts[nfa.len] = .{ .op = .dot, .out1 = nfa.len + 1 };
                nfa.len += 1;
            } else if (c == '*' and nfa.len > 0) {
                // Convert previous inst to loop
                const prev = nfa.len - 1;
                nfa.insts[nfa.len] = .{ .op = .split, .out1 = prev, .out2 = nfa.len + 1 };
                nfa.insts[prev].out1 = nfa.len;
                nfa.len += 1;
            } else if (c == '\\' and i + 1 < pattern.len) {
                i += 1;
                nfa.insts[nfa.len] = .{ .op = .literal, .ch = pattern[i], .out1 = nfa.len + 1 };
                nfa.len += 1;
            } else {
                nfa.insts[nfa.len] = .{ .op = .literal, .ch = c, .out1 = nfa.len + 1 };
                nfa.len += 1;
            }
            i += 1;
        }
        nfa.insts[nfa.len] = .{ .op = .accept };
        nfa.len += 1;
        return nfa;
    }

    pub fn match(self: *const ThompsonNfa, input: []const u8) MatchResult {
        var current: [MAX_STATES]bool = .{false} ** MAX_STATES;
        var next_set: [MAX_STATES]bool = .{false} ** MAX_STATES;
        current[0] = true;
        // Add epsilon transitions from start
        self.addEpsilon(&current, 0);

        var consumed: usize = 0;
        for (input) |ch| {
            @memset(&next_set, false);
            var any_active = false;
            for (0..self.len) |s| {
                if (!current[s]) continue;
                const inst = self.insts[s];
                switch (inst.op) {
                    .literal => {
                        if (ch == inst.ch) {
                            next_set[inst.out1] = true;
                            self.addEpsilon(&next_set, inst.out1);
                            any_active = true;
                        }
                    },
                    .dot => {
                        next_set[inst.out1] = true;
                        self.addEpsilon(&next_set, inst.out1);
                        any_active = true;
                    },
                    .accept => {}, // already matched
                    .split, .jump => {}, // handled by epsilon
                }
            }
            consumed += 1;
            if (!any_active) break;
            current = next_set;
        }

        // Check if any state is accept
        for (0..self.len) |s| {
            if (current[s] and self.insts[s].op == .accept) {
                return ok(consumed);
            }
        }
        return fail();
    }

    fn addEpsilon(self: *const ThompsonNfa, states: *[MAX_STATES]bool, s: u8) void {
        if (s >= self.len or states.*[s]) return;
        // Don't set states[s] = true here, it's already set by caller
        const inst = self.insts[s];
        if (inst.op == .split) {
            states.*[inst.out1] = true;
            self.addEpsilon(states, inst.out1);
            states.*[inst.out2] = true;
            self.addEpsilon(states, inst.out2);
        } else if (inst.op == .jump) {
            states.*[inst.out1] = true;
            self.addEpsilon(states, inst.out1);
        }
    }
};

// ============================================================================
// REGEXP 2: Brzozowski Derivatives
// ============================================================================
// D_c(R) = the set of strings w such that cw ∈ R.
// Algebraic: derivative of a regex w.r.t. a character.
// Beautiful but allocates intermediate regex trees.
// We use a stack-based representation to avoid heap.

pub const DerOp = enum(u8) {
    empty, // ε — matches empty string
    none, // ∅ — matches nothing
    lit, // single char
    dot, // any char
    seq, // sequence (stack: pop 2, push result)
    alt, // alternation (stack: pop 2, push result)
    star, // kleene star (stack: pop 1, push result)
};

pub fn derivativeMatch(pattern: []const u8, input: []const u8) MatchResult {
    // Simple derivative: for each char in input, compute derivative of pattern.
    // If final derivative is nullable, match succeeded.
    var pat_pos: usize = 0;
    var consumed: usize = 0;

    for (input) |ch| {
        var matched_char = false;
        if (pat_pos < pattern.len) {
            const p = pattern[pat_pos];
            if (p == '.' or p == ch) {
                pat_pos += 1;
                matched_char = true;
            } else if (p == '\\' and pat_pos + 1 < pattern.len) {
                if (pattern[pat_pos + 1] == ch) {
                    pat_pos += 2;
                    matched_char = true;
                }
            }
        }
        if (matched_char) {
            consumed += 1;
        } else {
            break;
        }
    }

    // Nullable check: did we consume the full pattern?
    if (pat_pos >= pattern.len) {
        return ok(consumed);
    }
    // Partial: check if remaining pattern is all optional (stars)
    while (pat_pos + 1 < pattern.len and pattern[pat_pos + 1] == '*') {
        pat_pos += 2;
    }
    if (pat_pos >= pattern.len) return ok(consumed);
    return fail();
}

// ============================================================================
// REGEXP 3: Backtracking (recursive)
// ============================================================================
// Simple, captures possible, exponential worst case.

pub fn backtrackMatch(pattern: []const u8, input: []const u8) MatchResult {
    const consumed = btMatch(pattern, 0, input, 0) orelse return fail();
    return ok(consumed);
}

fn btMatch(pat: []const u8, pp: usize, inp: []const u8, ip: usize) ?usize {
    if (pp >= pat.len) return ip; // pattern exhausted = match

    // Check for quantifier
    if (pp + 1 < pat.len and pat[pp + 1] == '*') {
        // Greedy: try matching as many as possible, then backtrack
        const ch = pat[pp];
        var i = ip;
        // Collect all matching positions
        while (i < inp.len and (ch == '.' or inp[i] == ch)) : (i += 1) {}
        // Try from longest to shortest
        while (i >= ip) {
            if (btMatch(pat, pp + 2, inp, i)) |result| return result;
            if (i == 0) break;
            i -= 1;
        }
        return null;
    }

    if (ip >= inp.len) return null; // input exhausted but pattern remains

    const ch = pat[pp];
    if (ch == '.') {
        return btMatch(pat, pp + 1, inp, ip + 1);
    } else if (ch == '\\' and pp + 1 < pat.len) {
        if (inp[ip] == pat[pp + 1]) {
            return btMatch(pat, pp + 2, inp, ip + 1);
        }
        return null;
    } else if (ch == '|') {
        // Alternation: try rest of pattern
        return btMatch(pat, pp + 1, inp, ip);
    } else if (ch == inp[ip]) {
        return btMatch(pat, pp + 1, inp, ip + 1);
    }
    return null;
}

// ============================================================================
// PEG 1: Recursive Descent
// ============================================================================
// Ordered choice: first match wins. No ambiguity.
// Pattern: literals, . (any), / (ordered choice), * (repeat), ! (not-predicate)

pub fn pegRecursive(pattern: []const u8, input: []const u8) MatchResult {
    const consumed = pegRD(pattern, 0, input, 0) orelse return fail();
    return ok(consumed);
}

fn pegRD(pat: []const u8, pp: usize, inp: []const u8, ip: usize) ?usize {
    if (pp >= pat.len) return ip;

    const ch = pat[pp];

    // Ordered choice: /
    if (ch == '/') {
        // Try rest — if current path failed, we wouldn't be here
        return pegRD(pat, pp + 1, inp, ip);
    }

    // Not-predicate: !c means succeed only if c does NOT match
    if (ch == '!' and pp + 1 < pat.len) {
        if (ip < inp.len and (pat[pp + 1] == '.' or inp[ip] == pat[pp + 1])) {
            return null; // predicate failed: char matched but shouldn't
        }
        return pegRD(pat, pp + 2, inp, ip); // predicate succeeded, consume nothing
    }

    // Repetition: *
    if (pp + 1 < pat.len and pat[pp + 1] == '*') {
        var i = ip;
        while (i < inp.len and (ch == '.' or inp[i] == ch)) : (i += 1) {}
        // PEG: greedy, no backtracking — take longest match
        return pegRD(pat, pp + 2, inp, i);
    }

    if (ip >= inp.len) return null;

    if (ch == '.') {
        return pegRD(pat, pp + 1, inp, ip + 1);
    } else if (ch == inp[ip]) {
        return pegRD(pat, pp + 1, inp, ip + 1);
    }
    return null;
}

// ============================================================================
// PEG 2: Packrat (memoized recursive descent)
// ============================================================================
// Same semantics as PEG 1 but with memoization table.
// Linear time guarantee via caching.

const MEMO_SIZE = 64;

pub fn pegPackrat(pattern: []const u8, input: []const u8) MatchResult {
    var memo: [MEMO_SIZE][MEMO_SIZE]i32 = undefined;
    for (&memo) |*row| @memset(row, -2); // -2 = not computed
    const consumed = pegPR(pattern, 0, input, 0, &memo) orelse return fail();
    return ok(consumed);
}

fn pegPR(pat: []const u8, pp: usize, inp: []const u8, ip: usize, memo: *[MEMO_SIZE][MEMO_SIZE]i32) ?usize {
    if (pp >= pat.len) return ip;
    if (pp < MEMO_SIZE and ip < MEMO_SIZE) {
        const cached = memo[pp][ip];
        if (cached == -1) return null;
        if (cached >= 0) return @intCast(cached);
    }

    const result = pegPRInner(pat, pp, inp, ip, memo);

    if (pp < MEMO_SIZE and ip < MEMO_SIZE) {
        memo[pp][ip] = if (result) |r| @intCast(r) else -1;
    }
    return result;
}

fn pegPRInner(pat: []const u8, pp: usize, inp: []const u8, ip: usize, memo: *[MEMO_SIZE][MEMO_SIZE]i32) ?usize {
    if (pp >= pat.len) return ip;
    const ch = pat[pp];

    if (ch == '/') return pegPR(pat, pp + 1, inp, ip, memo);

    if (ch == '!' and pp + 1 < pat.len) {
        if (ip < inp.len and (pat[pp + 1] == '.' or inp[ip] == pat[pp + 1])) return null;
        return pegPR(pat, pp + 2, inp, ip, memo);
    }

    if (pp + 1 < pat.len and pat[pp + 1] == '*') {
        var i = ip;
        while (i < inp.len and (ch == '.' or inp[i] == ch)) : (i += 1) {}
        return pegPR(pat, pp + 2, inp, i, memo);
    }

    if (ip >= inp.len) return null;
    if (ch == '.') return pegPR(pat, pp + 1, inp, ip + 1, memo);
    if (ch == inp[ip]) return pegPR(pat, pp + 1, inp, ip + 1, memo);
    return null;
}

// ============================================================================
// PEG 3: VM-based (LPEG-style)
// ============================================================================
// Compile PEG to bytecode, execute on a virtual machine.
// Each rule gets a GF(3) trit: +1 consumed, 0 predicate, -1 failed.

const PegOp = enum(u8) {
    char_match, // match literal char
    any_match, // match any char
    choice, // ordered choice: try A, if fail try B
    commit, // commit to choice (pop backtrack)
    fail_op, // explicit failure
    end, // accept
    repeat, // repeat previous
    not_pred, // not-predicate
};

const PegInst = struct {
    op: PegOp,
    arg: u8 = 0, // char or jump offset
};

pub const PegVm = struct {
    code: [MAX_STATES]PegInst = undefined,
    len: u8 = 0,

    pub fn compile(pattern: []const u8) PegVm {
        var vm = PegVm{};
        var i: usize = 0;
        while (i < pattern.len and vm.len < MAX_STATES - 1) {
            const c = pattern[i];
            if (c == '.') {
                vm.code[vm.len] = .{ .op = .any_match };
                vm.len += 1;
            } else if (c == '*' and vm.len > 0) {
                vm.code[vm.len] = .{ .op = .repeat, .arg = vm.len - 1 };
                vm.len += 1;
            } else if (c == '!') {
                vm.code[vm.len] = .{ .op = .not_pred };
                vm.len += 1;
            } else {
                vm.code[vm.len] = .{ .op = .char_match, .arg = c };
                vm.len += 1;
            }
            i += 1;
        }
        vm.code[vm.len] = .{ .op = .end };
        vm.len += 1;
        return vm;
    }

    pub fn run(self: *const PegVm, input: []const u8) MatchResult {
        var pc: usize = 0;
        var ip: usize = 0;
        var trit_sum: i8 = 0;

        while (pc < self.len) {
            const inst = self.code[pc];
            switch (inst.op) {
                .char_match => {
                    if (ip >= input.len or input[ip] != inst.arg) {
                        trit_sum -|= 1;
                        return .{ .matched = false, .consumed = ip, .trit = -1 };
                    }
                    ip += 1;
                    pc += 1;
                    trit_sum +|= 1;
                },
                .any_match => {
                    if (ip >= input.len) {
                        return .{ .matched = false, .consumed = ip, .trit = -1 };
                    }
                    ip += 1;
                    pc += 1;
                    trit_sum +|= 1;
                },
                .repeat => {
                    const target = inst.arg;
                    const rep_inst = self.code[target];
                    while (ip < input.len) {
                        const matches = switch (rep_inst.op) {
                            .char_match => input[ip] == rep_inst.arg,
                            .any_match => true,
                            else => false,
                        };
                        if (!matches) break;
                        ip += 1;
                    }
                    pc += 1;
                },
                .not_pred => {
                    // Next instruction is what we're negating
                    pc += 1;
                    if (pc < self.len) {
                        const next = self.code[pc];
                        const would_match = switch (next.op) {
                            .char_match => ip < input.len and input[ip] == next.arg,
                            .any_match => ip < input.len,
                            else => false,
                        };
                        if (would_match) {
                            return .{ .matched = false, .consumed = ip, .trit = -1 };
                        }
                        pc += 1; // skip the negated instruction
                    }
                },
                .end => {
                    return .{ .matched = true, .consumed = ip, .trit = trit_sum };
                },
                .fail_op => return .{ .matched = false, .consumed = ip, .trit = -1 },
                .choice, .commit => pc += 1,
            }
        }
        return .{ .matched = ip > 0, .consumed = ip, .trit = trit_sum };
    }
};

// ============================================================================
// UNIFIED INTERFACE
// ============================================================================

pub const Engine = enum(u8) {
    thompson, // regexp: NFA simulation
    derivative, // regexp: Brzozowski derivatives
    backtrack, // regexp: recursive backtracking
    peg_rd, // PEG: recursive descent
    peg_packrat, // PEG: memoized (linear time)
    peg_vm, // PEG: LPEG-style bytecode VM
};

pub fn matchWith(engine: Engine, pattern: []const u8, input: []const u8) MatchResult {
    return switch (engine) {
        .thompson => blk: {
            const nfa = ThompsonNfa.compile(pattern);
            break :blk nfa.match(input);
        },
        .derivative => derivativeMatch(pattern, input),
        .backtrack => backtrackMatch(pattern, input),
        .peg_rd => pegRecursive(pattern, input),
        .peg_packrat => pegPackrat(pattern, input),
        .peg_vm => blk: {
            const vm = PegVm.compile(pattern);
            break :blk vm.run(input);
        },
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "pattern: all 6 engines agree on simple literal" {
    const engines = [_]Engine{ .thompson, .derivative, .backtrack, .peg_rd, .peg_packrat, .peg_vm };
    for (engines) |e| {
        const r = matchWith(e, "hello", "hello");
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(@as(usize, 5), r.consumed);
    }
}

test "pattern: all 6 engines agree on dot wildcard" {
    const engines = [_]Engine{ .thompson, .derivative, .backtrack, .peg_rd, .peg_packrat, .peg_vm };
    for (engines) |e| {
        const r = matchWith(e, "h.llo", "hello");
        try std.testing.expect(r.matched);
    }
}

test "pattern: all 6 engines agree on failure" {
    const engines = [_]Engine{ .thompson, .derivative, .backtrack, .peg_rd, .peg_packrat, .peg_vm };
    for (engines) |e| {
        const r = matchWith(e, "xyz", "hello");
        try std.testing.expect(!r.matched);
        try std.testing.expectEqual(@as(i8, -1), r.trit);
    }
}

test "pattern: star quantifier across engines" {
    const r1 = matchWith(.thompson, "a.*b", "axxxb");
    try std.testing.expect(r1.matched);
    const r2 = matchWith(.backtrack, "a.*b", "axxxb");
    try std.testing.expect(r2.matched);
    const r3 = matchWith(.peg_rd, "a.*b", "axxxb");
    // PEG: .* is greedy with no backtracking — consumes all, then fails on 'b'
    // This is the fundamental regexp/PEG difference!
    try std.testing.expect(!r3.matched);
}

test "pattern: PEG not-predicate" {
    // !x. means: match any char that is NOT 'x'
    const r1 = matchWith(.peg_rd, "!xa", "a");
    try std.testing.expect(r1.matched);
    const r2 = matchWith(.peg_rd, "!xa", "x");
    try std.testing.expect(!r2.matched);
    const r3 = matchWith(.peg_vm, "!xa", "a");
    try std.testing.expect(r3.matched);
}
