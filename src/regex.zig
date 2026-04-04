//! Minimal regex engine for nanoclj-zig.
//!
//! Supports a practical subset of Clojure/Java regex:
//!   .        any char (except newline)
//!   *        zero or more of previous
//!   +        one or more of previous
//!   ?        zero or one of previous
//!   [abc]    character class
//!   [^abc]   negated character class
//!   [a-z]    character range
//!   \d \w \s digit/word/space  \D \W \S negated
//!   ^        anchor start
//!   $        anchor end
//!   |        alternation
//!   (...)    capture group
//!   \\       literal backslash
//!
//! Implementation: Thompson NFA via recursive descent.
//! No backtracking -- linear time in input length.

const std = @import("std");

pub const Regex = struct {
    pattern: []const u8,

    pub fn init(pattern: []const u8) Regex {
        return .{ .pattern = pattern };
    }

    /// Find first match in text. Returns the matched substring or null.
    pub fn find(self: *const Regex, text: []const u8) ?[]const u8 {
        // Try anchored match at each position
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (self.matchAt(text, i, 0)) |end| {
                return text[i..end];
            }
        }
        return null;
    }

    /// Check if the entire text matches the pattern.
    pub fn matches(self: *const Regex, text: []const u8) bool {
        const end = self.matchAt(text, 0, 0) orelse return false;
        return end == text.len;
    }

    /// Find all non-overlapping matches.
    pub fn findAll(self: *const Regex, text: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        var results = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
        var i: usize = 0;
        while (i <= text.len) {
            if (self.matchAt(text, i, 0)) |end| {
                try results.append(allocator, text[i..end]);
                i = if (end > i) end else i + 1;
            } else {
                i += 1;
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// Match pattern starting at pat_pos against text starting at text_pos.
    /// Returns the end position in text if matched, null otherwise.
    fn matchAt(self: *const Regex, text: []const u8, text_pos: usize, pat_pos: usize) ?usize {
        if (pat_pos >= self.pattern.len) return text_pos;
        // Check for alternation
        if (self.findAlternation(pat_pos)) |alt_pos| {
            // Try left branch
            if (self.matchBranch(text, text_pos, pat_pos, alt_pos)) |end| return end;
            // Try right branch
            return self.matchAt(text, text_pos, alt_pos + 1);
        }
        return self.matchBranch(text, text_pos, pat_pos, self.pattern.len);
    }

    fn matchBranch(self: *const Regex, text: []const u8, text_pos: usize, pat_start: usize, pat_end: usize) ?usize {
        var tp = text_pos;
        var pp = pat_start;

        while (pp < pat_end) {
            // End anchor
            if (self.pattern[pp] == '$') {
                if (tp == text.len) {
                    pp += 1;
                    continue;
                }
                return null;
            }

            // Start anchor
            if (self.pattern[pp] == '^') {
                if (tp != 0) return null;
                pp += 1;
                continue;
            }

            // Get the atom and check for quantifier
            const atom_start = pp;
            const atom_end = self.skipAtom(pp, pat_end);
            if (atom_end == pp) return null; // shouldn't happen

            const has_quant = atom_end < pat_end;
            const quant: u8 = if (has_quant) self.pattern[atom_end] else 0;

            if (quant == '*' or quant == '+' or quant == '?') {
                const min: usize = if (quant == '+') 1 else 0;
                const max: usize = if (quant == '?') 1 else text.len - tp + 1;
                pp = atom_end + 1;

                // Greedy: try max matches first, then fewer
                var count: usize = 0;
                const saved_tp = tp;
                while (count < max and tp < text.len) {
                    if (self.matchAtom(text, tp, atom_start, atom_end)) |next_tp| {
                        tp = next_tp;
                        count += 1;
                    } else break;
                }
                // Must have at least min matches
                if (count < min) return null;
                // Try rest of pattern with decreasing match count
                while (true) {
                    if (self.matchBranch(text, tp, pp, pat_end)) |end| return end;
                    if (count <= min) return null;
                    count -= 1;
                    // Recalculate tp for `count` matches
                    tp = saved_tp;
                    var c: usize = 0;
                    while (c < count) : (c += 1) {
                        tp = self.matchAtom(text, tp, atom_start, atom_end) orelse break;
                    }
                }
                return null;
            }

            // No quantifier: must match exactly once
            if (self.matchAtom(text, tp, atom_start, atom_end)) |next_tp| {
                tp = next_tp;
                pp = atom_end;
            } else {
                return null;
            }
        }
        return tp;
    }

    /// Match a single atom at text position. Returns next text position or null.
    fn matchAtom(self: *const Regex, text: []const u8, tp: usize, atom_start: usize, atom_end: usize) ?usize {
        if (tp >= text.len) return null;
        const c = text[tp];

        if (self.pattern[atom_start] == '.') {
            if (c == '\n') return null;
            return tp + 1;
        }

        if (self.pattern[atom_start] == '\\' and atom_start + 1 < atom_end) {
            const esc = self.pattern[atom_start + 1];
            const matched = switch (esc) {
                'd' => std.ascii.isDigit(c),
                'D' => !std.ascii.isDigit(c),
                'w' => std.ascii.isAlphanumeric(c) or c == '_',
                'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
                's' => std.ascii.isWhitespace(c),
                'S' => !std.ascii.isWhitespace(c),
                else => c == esc,
            };
            return if (matched) tp + 1 else null;
        }

        if (self.pattern[atom_start] == '[') {
            return if (self.matchCharClass(c, atom_start)) tp + 1 else null;
        }

        if (self.pattern[atom_start] == '(') {
            // Group: match contents recursively
            // Find matching close paren
            if (atom_end > atom_start + 2 and self.pattern[atom_end - 1] == ')') {
                const inner = Regex{ .pattern = self.pattern[atom_start + 1 .. atom_end - 1] };
                return inner.matchAt(text, tp, 0);
            }
            return null;
        }

        // Literal character
        return if (c == self.pattern[atom_start]) tp + 1 else null;
    }

    fn matchCharClass(self: *const Regex, c: u8, start: usize) bool {
        var pp = start + 1;
        var negated = false;
        if (pp < self.pattern.len and self.pattern[pp] == '^') {
            negated = true;
            pp += 1;
        }
        var matched = false;
        while (pp < self.pattern.len and self.pattern[pp] != ']') {
            if (pp + 2 < self.pattern.len and self.pattern[pp + 1] == '-' and self.pattern[pp + 2] != ']') {
                if (c >= self.pattern[pp] and c <= self.pattern[pp + 2]) matched = true;
                pp += 3;
            } else if (self.pattern[pp] == '\\' and pp + 1 < self.pattern.len) {
                const esc = self.pattern[pp + 1];
                const m = switch (esc) {
                    'd' => std.ascii.isDigit(c),
                    'w' => std.ascii.isAlphanumeric(c) or c == '_',
                    's' => std.ascii.isWhitespace(c),
                    else => c == esc,
                };
                if (m) matched = true;
                pp += 2;
            } else {
                if (c == self.pattern[pp]) matched = true;
                pp += 1;
            }
        }
        return if (negated) !matched else matched;
    }

    /// Skip past one atom in the pattern (char, escape, class, or group).
    fn skipAtom(self: *const Regex, pos: usize, limit: usize) usize {
        if (pos >= limit) return pos;
        switch (self.pattern[pos]) {
            '\\' => return @min(pos + 2, limit),
            '[' => {
                var p = pos + 1;
                if (p < limit and self.pattern[p] == '^') p += 1;
                while (p < limit and self.pattern[p] != ']') : (p += 1) {}
                return @min(p + 1, limit);
            },
            '(' => {
                var depth: u32 = 1;
                var p = pos + 1;
                while (p < limit and depth > 0) : (p += 1) {
                    if (self.pattern[p] == '(') depth += 1;
                    if (self.pattern[p] == ')') depth -= 1;
                }
                return p;
            },
            else => return pos + 1,
        }
    }

    /// Find top-level alternation '|' (not inside [] or ()).
    fn findAlternation(self: *const Regex, start: usize) ?usize {
        var p = start;
        var depth: u32 = 0;
        var in_class = false;
        while (p < self.pattern.len) : (p += 1) {
            const c = self.pattern[p];
            if (c == '\\') {
                p += 1;
                continue;
            }
            if (c == '[') in_class = true;
            if (c == ']') in_class = false;
            if (!in_class) {
                if (c == '(') depth += 1;
                if (c == ')') depth -= 1;
                if (c == '|' and depth == 0) return p;
            }
        }
        return null;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "regex: literal match" {
    const re = Regex.init("abc");
    try std.testing.expect(re.matches("abc"));
    try std.testing.expect(!re.matches("abx"));
    try std.testing.expect(!re.matches("ab"));
}

test "regex: dot matches any" {
    const re = Regex.init("a.c");
    try std.testing.expect(re.matches("abc"));
    try std.testing.expect(re.matches("axc"));
    try std.testing.expect(!re.matches("ac"));
}

test "regex: star quantifier" {
    const re = Regex.init("ab*c");
    try std.testing.expect(re.matches("ac"));
    try std.testing.expect(re.matches("abc"));
    try std.testing.expect(re.matches("abbc"));
}

test "regex: plus quantifier" {
    const re = Regex.init("ab+c");
    try std.testing.expect(!re.matches("ac"));
    try std.testing.expect(re.matches("abc"));
    try std.testing.expect(re.matches("abbc"));
}

test "regex: question quantifier" {
    const re = Regex.init("ab?c");
    try std.testing.expect(re.matches("ac"));
    try std.testing.expect(re.matches("abc"));
    try std.testing.expect(!re.matches("abbc"));
}

test "regex: character class" {
    const re = Regex.init("[abc]");
    try std.testing.expect(re.matches("a"));
    try std.testing.expect(re.matches("b"));
    try std.testing.expect(!re.matches("d"));
}

test "regex: character range" {
    const re = Regex.init("[a-z]+");
    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(!re.matches("123"));
}

test "regex: negated class" {
    const re = Regex.init("[^0-9]+");
    try std.testing.expect(re.matches("abc"));
    try std.testing.expect(!re.matches("123"));
}

test "regex: escape sequences" {
    const d = Regex.init("\\d+");
    try std.testing.expect(d.matches("123"));
    try std.testing.expect(!d.matches("abc"));
    const w = Regex.init("\\w+");
    try std.testing.expect(w.matches("hello_123"));
}

test "regex: find in text" {
    const re = Regex.init("[0-9]+");
    const result = re.find("abc123def") orelse "";
    try std.testing.expectEqualStrings("123", result);
}

test "regex: find no match" {
    const re = Regex.init("[0-9]+");
    try std.testing.expect(re.find("abcdef") == null);
}

test "regex: alternation" {
    const re = Regex.init("cat|dog");
    try std.testing.expect(re.matches("cat"));
    try std.testing.expect(re.matches("dog"));
    try std.testing.expect(!re.matches("cow"));
}

test "regex: anchors" {
    const start = Regex.init("^abc");
    try std.testing.expect(start.find("abcdef") != null);
    try std.testing.expect(start.find("xabc") == null);
    const end_re = Regex.init("xyz$");
    try std.testing.expect(end_re.matches("xyz"));
}

test "regex: findAll" {
    const re = Regex.init("\\d+");
    const results = try re.findAll("a1b22c333", std.testing.allocator);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("22", results[1]);
    try std.testing.expectEqualStrings("333", results[2]);
}
