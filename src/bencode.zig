//! BENCODE: nREPL wire format codec.
//!
//! Integers:  i<digits>e        (i42e, i-7e)
//! Strings:   <len>:<data>      (5:hello)
//! Lists:     l<items>e         (li1e5:helloe)
//! Dicts:     d<key><val>...e   (d3:foo3:bare) — keys sorted lexicographically
//!
//! This is the standard nREPL transport encoding. We add nothing to the wire
//! format itself — the superstructure lives in the message payloads.

const std = @import("std");

pub const BValue = union(enum) {
    integer: i64,
    string: []const u8,
    list: []BValue,
    dict: []DictEntry,

    pub const DictEntry = struct {
        key: []const u8,
        val: BValue,
    };

    /// Get a string value from a dict by key. Returns null if not found.
    pub fn dictGet(self: BValue, key: []const u8) ?BValue {
        if (self != .dict) return null;
        for (self.dict) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.val;
        }
        return null;
    }

    /// Get a string value from a dict by key, returning the string. Null if missing or wrong type.
    pub fn dictGetStr(self: BValue, key: []const u8) ?[]const u8 {
        const v = self.dictGet(key) orelse return null;
        if (v == .string) return v.string;
        return null;
    }

    pub fn dictGetInt(self: BValue, key: []const u8) ?i64 {
        const v = self.dictGet(key) orelse return null;
        if (v == .integer) return v.integer;
        return null;
    }
};

// ============================================================================
// DECODER
// ============================================================================

pub const DecodeError = error{
    UnexpectedEnd,
    InvalidFormat,
    Overflow,
    OutOfMemory,
};

pub const DecodeResult = struct { val: BValue, consumed: usize };

pub fn decode(data: []const u8, allocator: std.mem.Allocator) DecodeError!DecodeResult {
    if (data.len == 0) return error.UnexpectedEnd;
    return switch (data[0]) {
        'i' => decodeInt(data),
        'l' => decodeList(data, allocator),
        'd' => decodeDict(data, allocator),
        '0'...'9' => decodeString(data),
        else => error.InvalidFormat,
    };
}

fn decodeInt(data: []const u8) DecodeError!DecodeResult {
    // i<digits>e
    const end = std.mem.indexOfScalar(u8, data, 'e') orelse return error.InvalidFormat;
    const num_str = data[1..end];
    const val = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidFormat;
    return .{ .val = .{ .integer = val }, .consumed = end + 1 };
}

fn decodeString(data: []const u8) DecodeError!DecodeResult {
    // <len>:<data>
    const colon = std.mem.indexOfScalar(u8, data, ':') orelse return error.InvalidFormat;
    const len = std.fmt.parseInt(usize, data[0..colon], 10) catch return error.InvalidFormat;
    const start = colon + 1;
    if (start + len > data.len) return error.UnexpectedEnd;
    return .{ .val = .{ .string = data[start .. start + len] }, .consumed = start + len };
}

fn decodeList(data: []const u8, allocator: std.mem.Allocator) DecodeError!DecodeResult {
    var items = std.ArrayListUnmanaged(BValue).empty;
    var pos: usize = 1; // skip 'l'
    while (pos < data.len and data[pos] != 'e') {
        const result = try decode(data[pos..], allocator);
        items.append(allocator, result.val) catch return error.OutOfMemory;
        pos += result.consumed;
    }
    if (pos >= data.len) return error.UnexpectedEnd;
    return .{ .val = .{ .list = items.toOwnedSlice(allocator) catch return error.OutOfMemory }, .consumed = pos + 1 };
}

fn decodeDict(data: []const u8, allocator: std.mem.Allocator) DecodeError!DecodeResult {
    var entries = std.ArrayListUnmanaged(BValue.DictEntry).empty;
    var pos: usize = 1; // skip 'd'
    while (pos < data.len and data[pos] != 'e') {
        const key_result = try decodeString(data[pos..]);
        pos += key_result.consumed;
        const key_str = key_result.val.string;
        const val_result = try decode(data[pos..], allocator);
        pos += val_result.consumed;
        entries.append(allocator, .{ .key = key_str, .val = val_result.val }) catch return error.OutOfMemory;
    }
    if (pos >= data.len) return error.UnexpectedEnd;
    return .{ .val = .{ .dict = entries.toOwnedSlice(allocator) catch return error.OutOfMemory }, .consumed = pos + 1 };
}

// ============================================================================
// ENCODER
// ============================================================================

pub fn encode(val: BValue, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    var tmp: [32]u8 = undefined;
    switch (val) {
        .integer => |i| {
            const s = try std.fmt.bufPrint(&tmp, "i{d}e", .{i});
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            const hdr = try std.fmt.bufPrint(&tmp, "{d}:", .{s.len});
            try buf.appendSlice(allocator, hdr);
            try buf.appendSlice(allocator, s);
        },
        .list => |items| {
            try buf.append(allocator, 'l');
            for (items) |item| {
                try encode(item, buf, allocator);
            }
            try buf.append(allocator, 'e');
        },
        .dict => |entries| {
            try buf.append(allocator, 'd');
            for (entries) |entry| {
                const hdr = try std.fmt.bufPrint(&tmp, "{d}:", .{entry.key.len});
                try buf.appendSlice(allocator, hdr);
                try buf.appendSlice(allocator, entry.key);
                try encode(entry.val, buf, allocator);
            }
            try buf.append(allocator, 'e');
        },
    }
}

/// Build a dict from key-value pairs. Keys must be provided sorted.
pub fn makeDict(allocator: std.mem.Allocator, pairs: []const struct { []const u8, BValue }) !BValue {
    const entries = try allocator.alloc(BValue.DictEntry, pairs.len);
    for (pairs, 0..) |pair, i| {
        entries[i] = .{ .key = pair[0], .val = pair[1] };
    }
    return BValue{ .dict = entries };
}

pub fn makeStr(s: []const u8) BValue {
    return BValue{ .string = s };
}

pub fn makeInt(i: i64) BValue {
    return BValue{ .integer = i };
}

// ============================================================================
// TESTS
// ============================================================================

test "decode integer" {
    const result = try decode("i42e", std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), result.val.integer);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "decode negative integer" {
    const result = try decode("i-7e", std.testing.allocator);
    try std.testing.expectEqual(@as(i64, -7), result.val.integer);
}

test "decode string" {
    const result = try decode("5:hello", std.testing.allocator);
    try std.testing.expectEqualStrings("hello", result.val.string);
    try std.testing.expectEqual(@as(usize, 7), result.consumed);
}

test "decode dict" {
    const result = try decode("d3:foo3:bare", std.testing.allocator);
    defer std.testing.allocator.free(result.val.dict);
    try std.testing.expectEqual(@as(usize, 1), result.val.dict.len);
    try std.testing.expectEqualStrings("foo", result.val.dict[0].key);
    try std.testing.expectEqualStrings("bar", result.val.dict[0].val.string);
}

test "decode list" {
    const result = try decode("li1ei2ee", std.testing.allocator);
    defer std.testing.allocator.free(result.val.list);
    try std.testing.expectEqual(@as(usize, 2), result.val.list.len);
    try std.testing.expectEqual(@as(i64, 1), result.val.list[0].integer);
    try std.testing.expectEqual(@as(i64, 2), result.val.list[1].integer);
}

test "encode roundtrip" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const original = "d2:idi42e2:op4:evale";
    const result = try decode(original, std.testing.allocator);
    defer std.testing.allocator.free(result.val.dict);
    try encode(result.val, &buf, std.testing.allocator);
    try std.testing.expectEqualStrings(original, buf.items);
}

test "dictGet" {
    const result = try decode("d2:op4:eval7:session3:abce", std.testing.allocator);
    defer std.testing.allocator.free(result.val.dict);
    try std.testing.expectEqualStrings("eval", result.val.dictGetStr("op").?);
    try std.testing.expectEqualStrings("abc", result.val.dictGetStr("session").?);
    try std.testing.expect(result.val.dictGetStr("missing") == null);
}
