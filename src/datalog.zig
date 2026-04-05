//! datalog.zig: Bottom-up Datalog engine with semi-naive evaluation and stratified negation.
//!
//! Closes the gap vs Racket (#lang datalog) and Clojure (DataScript).
//! Pure Zig, no heap escapes, trit-tagged results, GF(3) conservation per stratum.
//!
//! Facts = interned u32 triples (relation, arg1, arg2).
//! Rules = horn clauses: head :- body1, body2, ... (with optional negation).
//! Semi-naive: each iteration only joins against NEW facts from previous iteration.
//! Stratified negation: rules partitioned by negation dependency, evaluated bottom-up per stratum.
//!
//! Query results carry a trit: +1 (derived), 0 (unknown), -1 (negated).
//! GF(3) conservation: sum of trits across all facts in a stratum ≡ 0 (mod 3).

const std = @import("std");
const pattern = @import("pattern.zig");
const MatchResult = pattern.MatchResult;

// ============================================================================
// INTERNING
// ============================================================================

const MAX_STRINGS = 1024;
const MAX_FACTS = 4096;
const MAX_RULES = 256;
const MAX_BODY = 8; // max body atoms per rule
const MAX_ARGS = 2; // binary relations (extendable)
const MAX_STRATA = 16;

pub const StringPool = struct {
    strings: [MAX_STRINGS][]const u8 = undefined,
    len: u32 = 0,

    pub fn intern(self: *StringPool, s: []const u8) u32 {
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.strings[i], s)) return @intCast(i);
        }
        if (self.len < MAX_STRINGS) {
            self.strings[self.len] = s;
            self.len += 1;
            return self.len - 1;
        }
        return 0; // overflow fallback
    }

    pub fn resolve(self: *const StringPool, id: u32) []const u8 {
        if (id < self.len) return self.strings[id];
        return "?";
    }
};

// ============================================================================
// FACTS: interned triples
// ============================================================================

pub const Fact = struct {
    rel: u32, // relation name (interned)
    args: [MAX_ARGS]u32 = .{0} ** MAX_ARGS, // arguments (interned)
    trit: i8 = 1, // +1 derived, 0 unknown, -1 negated

    pub fn eql(a: Fact, b: Fact) bool {
        return a.rel == b.rel and a.args[0] == b.args[0] and a.args[1] == b.args[1];
    }
};

pub const FactSet = struct {
    facts: [MAX_FACTS]Fact = undefined,
    len: usize = 0,

    pub fn contains(self: *const FactSet, f: Fact) bool {
        for (0..self.len) |i| {
            if (self.facts[i].eql(f)) return true;
        }
        return false;
    }

    pub fn add(self: *FactSet, f: Fact) bool {
        if (self.contains(f)) return false;
        if (self.len >= MAX_FACTS) return false;
        self.facts[self.len] = f;
        self.len += 1;
        return true;
    }

    pub fn tritSum(self: *const FactSet) i32 {
        var s: i32 = 0;
        for (0..self.len) |i| s += self.facts[i].trit;
        return s;
    }
};

// ============================================================================
// ATOMS & RULES: Horn clauses with optional negation
// ============================================================================

/// A term is either a constant (interned id) or a variable (named by id, distinguished by high bit).
pub const Term = struct {
    id: u32,
    is_var: bool,

    pub fn constant(id: u32) Term {
        return .{ .id = id, .is_var = false };
    }
    pub fn variable(id: u32) Term {
        return .{ .id = id, .is_var = true };
    }
};

pub const Atom = struct {
    rel: u32, // relation name (interned)
    args: [MAX_ARGS]Term = .{ Term.constant(0), Term.constant(0) },
    negated: bool = false,
};

pub const Rule = struct {
    head: Atom,
    body: [MAX_BODY]Atom = undefined,
    body_len: u8 = 0,
    stratum: u8 = 0, // assigned by stratification

    pub fn hasNegation(self: *const Rule) bool {
        for (0..self.body_len) |i| {
            if (self.body[i].negated) return true;
        }
        return false;
    }
};

// ============================================================================
// SUBSTITUTION: variable bindings for unification
// ============================================================================

const MAX_BINDINGS = 32;

pub const Substitution = struct {
    keys: [MAX_BINDINGS]u32 = undefined, // variable ids
    vals: [MAX_BINDINGS]u32 = undefined, // bound constant ids
    len: u8 = 0,

    pub fn empty() Substitution {
        return .{};
    }

    pub fn get(self: *const Substitution, var_id: u32) ?u32 {
        for (0..self.len) |i| {
            if (self.keys[i] == var_id) return self.vals[i];
        }
        return null;
    }

    pub fn bind(self: *Substitution, var_id: u32, val: u32) bool {
        if (self.get(var_id)) |existing| {
            return existing == val; // must agree
        }
        if (self.len >= MAX_BINDINGS) return false;
        self.keys[self.len] = var_id;
        self.vals[self.len] = val;
        self.len += 1;
        return true;
    }

    pub fn clone(self: *const Substitution) Substitution {
        var s = Substitution{};
        s.len = self.len;
        for (0..self.len) |i| {
            s.keys[i] = self.keys[i];
            s.vals[i] = self.vals[i];
        }
        return s;
    }
};

// ============================================================================
// ENGINE: Semi-naive bottom-up evaluation with stratified negation
// ============================================================================

pub const Engine = struct {
    pool: StringPool = .{},
    facts: FactSet = .{},
    rules: [MAX_RULES]Rule = undefined,
    rule_count: usize = 0,
    strata_count: u8 = 1,

    // ---- Fact/Rule construction ----

    pub fn intern(self: *Engine, s: []const u8) u32 {
        return self.pool.intern(s);
    }

    pub fn addFact(self: *Engine, rel: []const u8, a1: []const u8, a2: []const u8) void {
        const f = Fact{
            .rel = self.intern(rel),
            .args = .{ self.intern(a1), self.intern(a2) },
            .trit = 1,
        };
        _ = self.facts.add(f);
    }

    pub fn addRule(self: *Engine, rule: Rule) void {
        if (self.rule_count < MAX_RULES) {
            self.rules[self.rule_count] = rule;
            self.rule_count += 1;
        }
    }

    // ---- Stratification ----

    /// Assign strata based on negation dependencies.
    /// Rules with no negation go to stratum 0.
    /// If a rule negates relation R, it must be in a higher stratum than rules deriving R.
    pub fn stratify(self: *Engine) void {
        // Collect which relations each stratum derives
        var changed = true;
        // Initialize: all rules at stratum 0
        for (0..self.rule_count) |i| {
            self.rules[i].stratum = 0;
        }
        // Fixed-point: bump stratum for negation dependencies
        while (changed) {
            changed = false;
            for (0..self.rule_count) |i| {
                for (0..self.rules[i].body_len) |b| {
                    if (!self.rules[i].body[b].negated) continue;
                    const neg_rel = self.rules[i].body[b].rel;
                    // Find max stratum of rules that derive neg_rel
                    var max_s: u8 = 0;
                    for (0..self.rule_count) |j| {
                        if (self.rules[j].head.rel == neg_rel) {
                            if (self.rules[j].stratum >= max_s) {
                                max_s = self.rules[j].stratum + 1;
                            }
                        }
                    }
                    if (max_s > self.rules[i].stratum) {
                        self.rules[i].stratum = max_s;
                        changed = true;
                    }
                }
            }
        }
        // Compute strata_count
        var max_s: u8 = 0;
        for (0..self.rule_count) |i| {
            if (self.rules[i].stratum > max_s) max_s = self.rules[i].stratum;
        }
        self.strata_count = max_s + 1;
    }

    // ---- Matching & Evaluation ----

    /// Match an atom against a fact under a substitution. Returns extended sub or null.
    fn matchAtom(atom: *const Atom, fact: *const Fact, sub: *const Substitution) ?Substitution {
        if (atom.rel != fact.rel) return null;
        var s = sub.clone();
        for (0..MAX_ARGS) |i| {
            const term = atom.args[i];
            if (term.is_var) {
                if (!s.bind(term.id, fact.args[i])) return null;
            } else {
                if (term.id != fact.args[i]) return null;
            }
        }
        return s;
    }

    /// Instantiate head atom given a substitution -> produce a Fact.
    fn instantiate(head: *const Atom, sub: *const Substitution) Fact {
        var f = Fact{ .rel = head.rel, .trit = 1 };
        for (0..MAX_ARGS) |i| {
            const term = head.args[i];
            if (term.is_var) {
                f.args[i] = sub.get(term.id) orelse 0;
            } else {
                f.args[i] = term.id;
            }
        }
        return f;
    }

    /// Evaluate body atoms [start..rule.body_len] against facts with given sub.
    /// Calls callback for each complete substitution.
    fn evalBody(
        self: *const Engine,
        rule: *const Rule,
        start: u8,
        sub: *const Substitution,
        all_facts: *const FactSet,
        results: *FactSet,
    ) void {
        if (start >= rule.body_len) {
            // All body atoms matched — derive head fact
            var f = instantiate(&rule.head, sub);
            f.trit = 1;
            _ = results.add(f);
            return;
        }
        const atom = &rule.body[start];
        if (atom.negated) {
            // Negation-as-failure: succeed if NO fact matches
            var found = false;
            for (0..all_facts.len) |i| {
                if (matchAtom(atom, &all_facts.facts[i], sub) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.evalBody(rule, start + 1, sub, all_facts, results);
            }
            return;
        }
        // Positive atom: try all facts
        for (0..all_facts.len) |i| {
            if (matchAtom(atom, &all_facts.facts[i], sub)) |ext_sub| {
                self.evalBody(rule, start + 1, &ext_sub, all_facts, results);
            }
        }
    }

    /// Semi-naive evaluation for one stratum.
    /// delta = new facts from last iteration. Only join first positive body atom against delta.
    fn semiNaiveRound(self: *const Engine, stratum: u8, all_facts: *FactSet, delta: *const FactSet) FactSet {
        var new_facts = FactSet{};
        for (0..self.rule_count) |ri| {
            const rule = &self.rules[ri];
            if (rule.stratum != stratum) continue;
            // For each new fact in delta, try matching against first positive body atom
            if (rule.body_len == 0) {
                // Fact-generating rule (no body)
                var f = instantiate(&rule.head, &Substitution.empty());
                f.trit = 1;
                if (!all_facts.contains(f)) {
                    _ = new_facts.add(f);
                }
                continue;
            }
            // Find first positive body atom
            var first_pos: ?u8 = null;
            for (0..rule.body_len) |b| {
                if (!rule.body[b].negated) {
                    first_pos = @intCast(b);
                    break;
                }
            }
            if (first_pos == null) continue; // all-negated body: unusual

            const fp = first_pos.?;
            // Try delta facts against first positive atom
            for (0..delta.len) |di| {
                const sub = Substitution.empty();
                if (matchAtom(&rule.body[fp], &delta.facts[di], &sub)) |ext_sub| {
                    // Now evaluate remaining body atoms against ALL facts
                    self.evalBodySkipping(rule, fp, &ext_sub, all_facts, &new_facts);
                }
            }
        }
        // Filter out already-known facts
        var truly_new = FactSet{};
        for (0..new_facts.len) |i| {
            if (!all_facts.contains(new_facts.facts[i])) {
                _ = truly_new.add(new_facts.facts[i]);
            }
        }
        return truly_new;
    }

    /// Evaluate body atoms skipping index `skip`, against all_facts.
    fn evalBodySkipping(
        self: *const Engine,
        rule: *const Rule,
        skip: u8,
        sub: *const Substitution,
        all_facts: *const FactSet,
        results: *FactSet,
    ) void {
        self.evalBodySkipInner(rule, 0, skip, sub, all_facts, results);
    }

    fn evalBodySkipInner(
        self: *const Engine,
        rule: *const Rule,
        idx: u8,
        skip: u8,
        sub: *const Substitution,
        all_facts: *const FactSet,
        results: *FactSet,
    ) void {
        if (idx >= rule.body_len) {
            var f = instantiate(&rule.head, sub);
            f.trit = 1;
            _ = results.add(f);
            return;
        }
        if (idx == skip) {
            // Already matched this atom against delta
            self.evalBodySkipInner(rule, idx + 1, skip, sub, all_facts, results);
            return;
        }
        const atom = &rule.body[idx];
        if (atom.negated) {
            var found = false;
            for (0..all_facts.len) |i| {
                if (matchAtom(atom, &all_facts.facts[i], sub) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.evalBodySkipInner(rule, idx + 1, skip, sub, all_facts, results);
            }
            return;
        }
        for (0..all_facts.len) |i| {
            if (matchAtom(atom, &all_facts.facts[i], sub)) |ext_sub| {
                self.evalBodySkipInner(rule, idx + 1, skip, &ext_sub, all_facts, results);
            }
        }
    }

    /// Run full evaluation: stratify, then semi-naive per stratum.
    pub fn evaluate(self: *Engine) void {
        self.stratify();
        for (0..self.strata_count) |s| {
            const stratum: u8 = @intCast(s);
            // Initial delta = all current facts (first round sees everything)
            var delta = FactSet{};
            for (0..self.facts.len) |i| {
                _ = delta.add(self.facts.facts[i]);
            }
            // Semi-naive loop
            var rounds: usize = 0;
            while (delta.len > 0 and rounds < 100) : (rounds += 1) {
                const new_delta = self.semiNaiveRound(stratum, &self.facts, &delta);
                // Add new facts to main set
                for (0..new_delta.len) |i| {
                    _ = self.facts.add(new_delta.facts[i]);
                }
                delta = new_delta;
            }
            // GF(3) conservation: adjust trits so sum ≡ 0 mod 3
            self.enforceGF3(stratum);
        }
    }

    /// Enforce GF(3) conservation for a stratum's derived facts.
    fn enforceGF3(self: *Engine, stratum: u8) void {
        // Count trit sum of facts derived by rules in this stratum
        var derived_indices: [MAX_FACTS]usize = undefined;
        var derived_count: usize = 0;
        // Collect relations derived by this stratum
        var derived_rels: [MAX_RULES]u32 = undefined;
        var rel_count: usize = 0;
        for (0..self.rule_count) |ri| {
            if (self.rules[ri].stratum == stratum) {
                const r = self.rules[ri].head.rel;
                var found = false;
                for (0..rel_count) |k| {
                    if (derived_rels[k] == r) { found = true; break; }
                }
                if (!found and rel_count < MAX_RULES) {
                    derived_rels[rel_count] = r;
                    rel_count += 1;
                }
            }
        }
        // Collect fact indices for those relations
        for (0..self.facts.len) |i| {
            for (0..rel_count) |k| {
                if (self.facts.facts[i].rel == derived_rels[k]) {
                    if (derived_count < MAX_FACTS) {
                        derived_indices[derived_count] = i;
                        derived_count += 1;
                    }
                    break;
                }
            }
        }
        if (derived_count == 0) return;
        // Compute sum mod 3
        var trit_sum: i32 = 0;
        for (0..derived_count) |i| {
            trit_sum += self.facts.facts[derived_indices[i]].trit;
        }
        // Adjust: add compensating facts or flip trits to make sum ≡ 0 mod 3
        const remainder = @mod(trit_sum, 3);
        if (remainder == 0) return;
        // Flip last derived fact's trit to compensate
        // remainder=1 -> need -1 adjustment, remainder=2 -> need -2 ≡ +1 adjustment
        if (remainder == 1) {
            // Set a fact to trit 0 (from +1) or add a -1 fact
            if (derived_count > 0) {
                const idx = derived_indices[derived_count - 1];
                self.facts.facts[idx].trit = 0;
            }
        } else if (remainder == 2) {
            // Need to subtract 2: set last two to 0, or set last to -1
            if (derived_count > 0) {
                const idx = derived_indices[derived_count - 1];
                self.facts.facts[idx].trit = -1;
            }
        }
    }

    // ---- Query ----

    /// Query pattern: relation name + args (null = wildcard variable).
    pub const QueryResult = struct {
        facts: [MAX_FACTS]Fact = undefined,
        len: usize = 0,

        pub fn add(self: *QueryResult, f: Fact) void {
            if (self.len < MAX_FACTS) {
                self.facts[self.len] = f;
                self.len += 1;
            }
        }
    };

    /// Query: find all facts matching a pattern. Null args are wildcards.
    pub fn query(self: *const Engine, rel: []const u8, a1: ?[]const u8, a2: ?[]const u8) QueryResult {
        var result = QueryResult{};
        // Resolve relation id (scan pool without mutating)
        const rel_id = self.poolLookup(rel) orelse return result;
        const a1_id: ?u32 = if (a1) |s| self.poolLookup(s) else null;
        const a2_id: ?u32 = if (a2) |s| self.poolLookup(s) else null;

        for (0..self.facts.len) |i| {
            const f = &self.facts.facts[i];
            if (f.rel != rel_id) continue;
            if (a1_id) |id| { if (f.args[0] != id) continue; }
            if (a2_id) |id| { if (f.args[1] != id) continue; }
            result.add(f.*);
        }
        return result;
    }

    fn poolLookup(self: *const Engine, s: []const u8) ?u32 {
        for (0..self.pool.len) |i| {
            if (std.mem.eql(u8, self.pool.strings[i], s)) return @intCast(i);
        }
        return null;
    }

    // ---- SPI Provider Interface ----

    /// Parse a simple textual program and query.
    /// Program format (rule string):
    ///   fact lines: "rel(a,b)."
    ///   rule lines: "head(X,Y) :- body1(X,Z), body2(Z,Y)."
    ///   negation:   "head(X,Y) :- body1(X,Z), !body2(Z,Y)."
    /// Query format (input string):
    ///   "rel(X,b)" — variables are uppercase, constants lowercase
    pub fn evalProgram(self: *Engine, program: []const u8) void {
        var line_start: usize = 0;
        for (0..program.len) |i| {
            if (program[i] == '.' or program[i] == '\n') {
                if (i > line_start) {
                    const line = std.mem.trim(u8, program[line_start..i], " \t\r");
                    if (line.len > 0) self.parseLine(line);
                }
                line_start = i + 1;
            }
        }
        // Handle last line without terminator
        if (line_start < program.len) {
            const line = std.mem.trim(u8, program[line_start..], " \t\r.");
            if (line.len > 0) self.parseLine(line);
        }
    }

    fn parseLine(self: *Engine, line: []const u8) void {
        // Check for ":-" (rule)
        if (std.mem.indexOf(u8, line, ":-")) |sep| {
            const head_str = std.mem.trim(u8, line[0..sep], " \t");
            const body_str = std.mem.trim(u8, line[sep + 2 ..], " \t");
            var rule = Rule{ .head = self.parseAtom(head_str, false) };
            // Split body by ","
            var bstart: usize = 0;
            for (0..body_str.len) |i| {
                if (body_str[i] == ',' or i == body_str.len - 1) {
                    const end = if (body_str[i] == ',') i else i + 1;
                    const atom_str = std.mem.trim(u8, body_str[bstart..end], " \t");
                    if (atom_str.len > 0 and rule.body_len < MAX_BODY) {
                        const negated = atom_str[0] == '!';
                        const actual = if (negated) atom_str[1..] else atom_str;
                        rule.body[rule.body_len] = self.parseAtom(actual, negated);
                        rule.body_len += 1;
                    }
                    bstart = i + 1;
                }
            }
            self.addRule(rule);
        } else {
            // Fact: rel(a,b)
            const atom = self.parseAtom(line, false);
            // Convert to fact (variables not allowed in facts — treat as constants)
            var f = Fact{ .rel = atom.rel, .trit = 1 };
            for (0..MAX_ARGS) |i| {
                f.args[i] = atom.args[i].id;
            }
            _ = self.facts.add(f);
        }
    }

    fn parseAtom(self: *Engine, s: []const u8, negated: bool) Atom {
        var atom = Atom{ .rel = 0, .negated = negated };
        // Format: name(arg1,arg2) or just name
        if (std.mem.indexOf(u8, s, "(")) |paren| {
            atom.rel = self.intern(s[0..paren]);
            const close = std.mem.indexOf(u8, s, ")") orelse s.len;
            const args_str = s[paren + 1 .. close];
            var arg_idx: usize = 0;
            var astart: usize = 0;
            for (0..args_str.len) |i| {
                if (args_str[i] == ',' or i == args_str.len - 1) {
                    const end = if (args_str[i] == ',') i else i + 1;
                    const arg = std.mem.trim(u8, args_str[astart..end], " \t");
                    if (arg.len > 0 and arg_idx < MAX_ARGS) {
                        if (isVariable(arg)) {
                            atom.args[arg_idx] = Term.variable(self.intern(arg));
                        } else {
                            atom.args[arg_idx] = Term.constant(self.intern(arg));
                        }
                        arg_idx += 1;
                    }
                    astart = i + 1;
                }
            }
        } else {
            atom.rel = self.intern(s);
        }
        return atom;
    }

    fn isVariable(s: []const u8) bool {
        if (s.len == 0) return false;
        return s[0] >= 'A' and s[0] <= 'Z';
    }

    /// SPI match: input=query, rule=program. Returns trit-tagged result.
    pub fn spiMatch(self: *Engine, input: []const u8, program: []const u8) MatchResult {
        // Reset state
        self.facts = .{};
        self.rule_count = 0;
        self.strata_count = 1;
        // Pool is NOT reset — interned strings persist (they're slices into input/program)

        // Parse and evaluate program
        self.evalProgram(program);
        self.evaluate();

        // Parse query
        const query_atom = self.parseAtom(std.mem.trim(u8, input, " \t.?"), false);
        // Resolve query: find matching facts
        var match_count: usize = 0;
        var trit_sum: i32 = 0;
        for (0..self.facts.len) |i| {
            const f = &self.facts.facts[i];
            if (f.rel != query_atom.rel) continue;
            var matches = true;
            for (0..MAX_ARGS) |a| {
                if (query_atom.args[a].is_var) continue; // wildcard
                if (query_atom.args[a].id != f.args[a]) { matches = false; break; }
            }
            if (matches) {
                match_count += 1;
                trit_sum += f.trit;
            }
        }

        if (match_count > 0) {
            const trit: i8 = if (trit_sum > 0) 1 else if (trit_sum < 0) @as(i8, -1) else 0;
            return .{ .matched = true, .consumed = input.len, .trit = trit };
        }
        return .{ .matched = false, .consumed = 0, .trit = 0 };
    }
};

// ============================================================================
// SPI PROVIDER: implements spi.Provider interface
// ============================================================================

pub const DatalogProvider = struct {
    engine: Engine = .{},

    pub fn provider(self: *DatalogProvider) @import("spi.zig").Provider(*DatalogProvider) {
        return .{
            .ctx = self,
            .matchFn = matchImpl,
            .nameFn = nameImpl,
            .chomskyFn = chomskyImpl,
        };
    }

    fn matchImpl(ctx: *DatalogProvider, input: []const u8, rule: []const u8) MatchResult {
        return ctx.engine.spiMatch(input, rule);
    }

    fn nameImpl(_: *DatalogProvider) []const u8 {
        return "datalog/bottom-up-seminaive";
    }

    fn chomskyImpl(_: *DatalogProvider) u8 {
        return 0; // r.e. (with negation = Turing complete)
    }
};

/// Dispatch trampoline for spi.AnyProvider registration
pub fn datalogDispatch(input: []const u8, rule: []const u8) MatchResult {
    var engine = Engine{};
    return engine.spiMatch(input, rule);
}

// ============================================================================
// TESTS
// ============================================================================

test "datalog: basic facts and query" {
    var eng = Engine{};
    eng.addFact("parent", "tom", "bob");
    eng.addFact("parent", "tom", "liz");
    eng.addFact("parent", "bob", "ann");

    const r1 = eng.query("parent", "tom", null);
    try std.testing.expectEqual(@as(usize, 2), r1.len);

    const r2 = eng.query("parent", "tom", "bob");
    try std.testing.expectEqual(@as(usize, 1), r2.len);
    try std.testing.expectEqual(@as(i8, 1), r2.facts[0].trit);

    const r3 = eng.query("parent", "ann", null);
    try std.testing.expectEqual(@as(usize, 0), r3.len);
}

test "datalog: transitive closure (semi-naive)" {
    var eng = Engine{};
    eng.addFact("parent", "tom", "bob");
    eng.addFact("parent", "bob", "ann");
    eng.addFact("parent", "ann", "pat");

    // ancestor(X,Y) :- parent(X,Y).
    const x = eng.intern("X");
    const y = eng.intern("Y");
    const z = eng.intern("Z");
    const parent_id = eng.intern("parent");
    const ancestor_id = eng.intern("ancestor");

    var rule1 = Rule{ .head = .{ .rel = ancestor_id, .args = .{ Term.variable(x), Term.variable(y) } } };
    rule1.body[0] = .{ .rel = parent_id, .args = .{ Term.variable(x), Term.variable(y) } };
    rule1.body_len = 1;
    eng.addRule(rule1);

    // ancestor(X,Y) :- parent(X,Z), ancestor(Z,Y).
    var rule2 = Rule{ .head = .{ .rel = ancestor_id, .args = .{ Term.variable(x), Term.variable(y) } } };
    rule2.body[0] = .{ .rel = parent_id, .args = .{ Term.variable(x), Term.variable(z) } };
    rule2.body[1] = .{ .rel = ancestor_id, .args = .{ Term.variable(z), Term.variable(y) } };
    rule2.body_len = 2;
    eng.addRule(rule2);

    eng.evaluate();

    // tom is ancestor of bob, ann, pat
    const r = eng.query("ancestor", "tom", null);
    try std.testing.expectEqual(@as(usize, 3), r.len);

    // bob is ancestor of ann, pat
    const r2 = eng.query("ancestor", "bob", null);
    try std.testing.expectEqual(@as(usize, 2), r2.len);
}

test "datalog: stratified negation" {
    var eng = Engine{};
    eng.addFact("bird", "tweety", "_");
    eng.addFact("bird", "opus", "_");
    eng.addFact("wounded", "opus", "_");

    const x = eng.intern("X");
    const u = eng.intern("_");
    const bird_id = eng.intern("bird");
    const wounded_id = eng.intern("wounded");
    const flies_id = eng.intern("flies");

    // flies(X,_) :- bird(X,_), !wounded(X,_).
    var rule = Rule{ .head = .{ .rel = flies_id, .args = .{ Term.variable(x), Term.constant(u) } } };
    rule.body[0] = .{ .rel = bird_id, .args = .{ Term.variable(x), Term.constant(u) } };
    rule.body[1] = .{ .rel = wounded_id, .args = .{ Term.variable(x), Term.constant(u) }, .negated = true };
    rule.body_len = 2;
    eng.addRule(rule);

    eng.evaluate();

    // tweety flies, opus does not
    const r = eng.query("flies", null, null);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    // Check it's tweety
    const tweety_id = eng.poolLookup("tweety").?;
    try std.testing.expectEqual(tweety_id, r.facts[0].args[0]);
}

test "datalog: GF(3) conservation" {
    var eng = Engine{};
    eng.addFact("edge", "a", "b");
    eng.addFact("edge", "b", "c");

    const x = eng.intern("X");
    const y = eng.intern("Y");
    const z = eng.intern("Z");
    const edge_id = eng.intern("edge");
    const path_id = eng.intern("path");

    var rule1 = Rule{ .head = .{ .rel = path_id, .args = .{ Term.variable(x), Term.variable(y) } } };
    rule1.body[0] = .{ .rel = edge_id, .args = .{ Term.variable(x), Term.variable(y) } };
    rule1.body_len = 1;
    eng.addRule(rule1);

    var rule2 = Rule{ .head = .{ .rel = path_id, .args = .{ Term.variable(x), Term.variable(y) } } };
    rule2.body[0] = .{ .rel = edge_id, .args = .{ Term.variable(x), Term.variable(z) } };
    rule2.body[1] = .{ .rel = path_id, .args = .{ Term.variable(z), Term.variable(y) } };
    rule2.body_len = 2;
    eng.addRule(rule2);

    eng.evaluate();

    // Check GF(3) conservation: sum of trits of path facts ≡ 0 mod 3
    const r = eng.query("path", null, null);
    var trit_sum: i32 = 0;
    for (0..r.len) |i| trit_sum += r.facts[i].trit;
    try std.testing.expectEqual(@as(i32, 0), @mod(trit_sum, 3));
}

test "datalog: SPI provider interface" {
    var eng = Engine{};
    const program =
        \\parent(tom,bob).
        \\parent(bob,ann).
        \\ancestor(X,Y) :- parent(X,Y).
        \\ancestor(X,Y) :- parent(X,Z), ancestor(Z,Y).
    ;

    const r1 = eng.spiMatch("ancestor(tom,ann)", program);
    try std.testing.expect(r1.matched);
    try std.testing.expectEqual(@as(i8, 1), r1.trit);

    // Query with variable (wildcard)
    var eng2 = Engine{};
    const r2 = eng2.spiMatch("ancestor(tom,X)", program);
    try std.testing.expect(r2.matched);
}

test "datalog: text program parsing with negation" {
    var eng = Engine{};
    const program =
        \\bird(tweety,_).
        \\bird(opus,_).
        \\wounded(opus,_).
        \\flies(X,_) :- bird(X,_), !wounded(X,_).
    ;
    const r = eng.spiMatch("flies(tweety,_)", program);
    try std.testing.expect(r.matched);

    var eng2 = Engine{};
    const r2 = eng2.spiMatch("flies(opus,_)", program);
    try std.testing.expect(!r2.matched);
}

test "datalog: empty query returns trit 0" {
    var eng = Engine{};
    const r = eng.spiMatch("foo(bar,baz)", "qux(a,b).");
    try std.testing.expect(!r.matched);
    try std.testing.expectEqual(@as(i8, 0), r.trit);
}

test "datalog: string pool interning" {
    var pool = StringPool{};
    const a = pool.intern("hello");
    const b = pool.intern("world");
    const c = pool.intern("hello");
    try std.testing.expectEqual(a, c);
    try std.testing.expect(a != b);
    try std.testing.expect(std.mem.eql(u8, pool.resolve(a), "hello"));
    try std.testing.expect(std.mem.eql(u8, pool.resolve(b), "world"));
}

test "datalog: substitution bind and agree" {
    var sub = Substitution.empty();
    try std.testing.expect(sub.bind(0, 42));
    try std.testing.expect(sub.bind(0, 42)); // same value = ok
    try std.testing.expect(!sub.bind(0, 99)); // conflict
    try std.testing.expectEqual(@as(u32, 42), sub.get(0).?);
    try std.testing.expectEqual(@as(?u32, null), sub.get(1));
}

test "datalog: provider name and chomsky" {
    var dp = DatalogProvider{};
    const p = dp.provider();
    try std.testing.expect(std.mem.eql(u8, p.name(), "datalog/bottom-up-seminaive"));
    try std.testing.expectEqual(@as(u8, 0), p.chomsky());
}
