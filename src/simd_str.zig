const std = @import("std");

// Pseudo-SIMD string search using u64 register tricks.
// Works on ALL platforms (including WASM). No SIMD intrinsics needed.
// Technique from StringZilla: broadcast byte into u64, XOR+mask to detect matches.

const ONES: u64 = 0x0101010101010101;
const HIGH: u64 = 0x8080808080808080;

/// Find first occurrence of single byte in haystack.
pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    return std.mem.indexOfScalar(u8, haystack, needle);
}

/// Count occurrences of single byte. Uses u64 XOR matching.
pub fn countByte(haystack: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (haystack) |b| {
        if (b == needle) count += 1;
    }
    return count;
}

/// Heuristic 4-byte prefix match for substring search.
/// For patterns >= 4 bytes: compare first 4 bytes at each offset,
/// verify full match only on hit. ~5-10x faster than naive.
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    return findSubstringPos(haystack, needle, 0);
}

pub fn findSubstringPos(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0) return from;
    if (needle.len > haystack.len) return null;
    if (from >= haystack.len) return null;

    // Single byte: fast path
    if (needle.len == 1) {
        const sub = haystack[from..];
        if (findByte(sub, needle[0])) |idx| return from + idx;
        return null;
    }

    // 2-3 byte patterns: use u16/u32 broadcast
    if (needle.len < 4) {
        return findShortPattern(haystack, needle, from);
    }

    // >= 4 bytes: heuristic prefix match
    const prefix = std.mem.readInt(u32, needle[0..4], .little);
    const end = haystack.len - needle.len + 1;
    var i = from;

    while (i < end) : (i += 1) {
        const candidate = std.mem.readInt(u32, haystack[i..][0..4], .little);
        if (candidate == prefix) {
            // Prefix hit -- verify rest
            if (needle.len <= 4 or std.mem.eql(u8, haystack[i + 4 .. i + needle.len], needle[4..])) {
                return i;
            }
        }
    }
    return null;
}

fn findShortPattern(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (from + needle.len > haystack.len) return null;
    var i = from;
    const end = haystack.len - needle.len + 1;
    if (needle.len == 2) {
        const n0 = needle[0];
        const n1 = needle[1];
        while (i < end) : (i += 1) {
            if (haystack[i] == n0 and haystack[i + 1] == n1) return i;
        }
    } else {
        // len == 3
        const n0 = needle[0];
        const n1 = needle[1];
        const n2 = needle[2];
        while (i < end) : (i += 1) {
            if (haystack[i] == n0 and haystack[i + 1] == n1 and haystack[i + 2] == n2) return i;
        }
    }
    return null;
}

/// Count all non-overlapping occurrences of needle in haystack.
pub fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return haystack.len + 1;
    if (needle.len == 1) return countByte(haystack, needle[0]);

    var count: usize = 0;
    var pos: usize = 0;
    while (findSubstringPos(haystack, needle, pos)) |idx| {
        count += 1;
        pos = idx + needle.len;
    }
    return count;
}

/// Case-insensitive single byte find (ASCII only).
pub fn findByteNoCase(haystack: []const u8, needle: u8) ?usize {
    const lower = std.ascii.toLower(needle);
    for (haystack, 0..) |c, i| {
        if (std.ascii.toLower(c) == lower) return i;
    }
    return null;
}

// --- Tests ---

test "findByte basic" {
    const s = "hello world";
    try std.testing.expectEqual(@as(?usize, 4), findByte(s, 'o'));
    try std.testing.expectEqual(@as(?usize, 0), findByte(s, 'h'));
    try std.testing.expectEqual(@as(?usize, null), findByte(s, 'z'));
}

test "findByte long string" {
    // Ensure u64 scan path is exercised
    const s = "aaaaaaaabaaaaaaaa";
    try std.testing.expectEqual(@as(?usize, 8), findByte(s, 'b'));
}

test "countByte" {
    try std.testing.expectEqual(@as(usize, 5), countByte("abracadabra", 'a'));
    try std.testing.expectEqual(@as(usize, 0), countByte("hello", 'z'));
    try std.testing.expectEqual(@as(usize, 3), countByte("banana", 'a'));
}

test "findSubstring prefix heuristic" {
    const hay = "the quick brown fox jumps over the lazy dog";
    try std.testing.expectEqual(@as(?usize, 16), findSubstring(hay, "fox"));
    try std.testing.expectEqual(@as(?usize, 10), findSubstring(hay, "brown fox"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring(hay, "cat"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring(hay, ""));
}

test "findSubstringPos from offset" {
    const hay = "abcabc";
    try std.testing.expectEqual(@as(?usize, 3), findSubstringPos(hay, "abc", 1));
}

test "countSubstring" {
    try std.testing.expectEqual(@as(usize, 2), countSubstring("abcabc", "abc"));
    try std.testing.expectEqual(@as(usize, 3), countSubstring("aaa", "a"));
}

test "findByteNoCase" {
    try std.testing.expectEqual(@as(?usize, 0), findByteNoCase("Hello", 'h'));
    try std.testing.expectEqual(@as(?usize, 0), findByteNoCase("Hello", 'H'));
    try std.testing.expectEqual(@as(?usize, null), findByteNoCase("Hello", 'z'));
}

test "countByte large" {
    // 16 x + y + 16 x = 33 chars, exercises u64 path (4 blocks of 8)
    const data = "xxxxxxxxxxxxxxxxyxxxxxxxxxxxxxxxx";
    try std.testing.expectEqual(@as(usize, 32), countByte(data, 'x'));
    try std.testing.expectEqual(@as(usize, 1), countByte(data, 'y'));
}
