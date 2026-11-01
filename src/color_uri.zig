//! Strict, local color://trit resolution. Addresses and visual representations
//! are data; neither resolution nor GF(3) consistency confers authority.
const std = @import("std");
const Color = @import("colorspace.zig").Color;
const substrate = @import("substrate.zig");

pub const Trit = enum(i2) { negative = -1, neutral = 0, positive = 1 };
pub const Domain = enum { trit };
pub const Rule = enum { oklch_equal_sectors_v1 };
pub const ResolveError = error{ InvalidScheme, MalformedPath, UnsupportedDomain, InvalidTrit };

pub const Resolution = struct {
    /// Canonical static address, independent of the input buffer's lifetime.
    address: []const u8,
    domain: Domain = .trit,
    trit: Trit,
    oklab: Color,
    rule: Rule = .oklch_equal_sectors_v1,
};

/// Accept only color://<lowercase-domain>/<single-value>. No decoding,
/// normalization, query, fragment, userinfo, port, or external dispatch.
/// Error precedence: scheme, path syntax, domain, then exact trit spelling.
pub fn resolve(uri: []const u8) ResolveError!Resolution {
    const prefix = "color://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.InvalidScheme;
    const rest = uri[prefix.len..];
    for (rest) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "%?#\\", byte) != null)
            return error.MalformedPath;
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.MalformedPath;
    const domain = rest[0..slash];
    const path = rest[slash + 1 ..];
    if (domain.len == 0 or path.len == 0 or std.mem.indexOfScalar(u8, path, '/') != null)
        return error.MalformedPath;
    for (domain, 0..) |byte, i| {
        if (!(byte >= 'a' and byte <= 'z') and
            !(i > 0 and ((byte >= '0' and byte <= '9') or byte == '-')))
            return error.MalformedPath;
    }
    if (!std.mem.eql(u8, domain, "trit")) return error.UnsupportedDomain;
    const trit: Trit = if (std.mem.eql(u8, path, "-1")) .negative else if (std.mem.eql(u8, path, "0")) .neutral else if (std.mem.eql(u8, path, "1")) .positive else return error.InvalidTrit;

    // Versioned display convention, not learned perceptual boundaries:
    // substrate.hueToTrit sectors [0,120), [120,240), [240,360), applied
    // to OKLCH hue. Their centers are 60, 180, 300 degrees respectively.
    // L=0.65, C=0.10, alpha=1 keep these representatives inside sRGB.
    const hue: f32 = switch (trit) {
        .negative => 300,
        .neutral => 180,
        .positive => 60,
    };
    return .{
        .address = switch (trit) {
            .negative => "color://trit/-1",
            .neutral => "color://trit/0",
            .positive => "color://trit/1",
        },
        .trit = trit,
        .oklab = (Color{ .L = 0.65, .a = 0.10 }).analogous(hue),
    };
}

test "color URI: exact trits, coordinates, classification and GF(3) balance" {
    const cases = .{
        .{ "color://trit/-1", Trit.negative, @as(f32, 300), @as(f32, 0.05), @as(f32, -0.08660254) },
        .{ "color://trit/0", Trit.neutral, @as(f32, 180), @as(f32, -0.1), @as(f32, 0) },
        .{ "color://trit/1", Trit.positive, @as(f32, 60), @as(f32, 0.05), @as(f32, 0.08660254) },
    };
    inline for (cases) |case| {
        const result = try resolve(case[0]);
        try std.testing.expectEqualStrings(case[0], result.address);
        try std.testing.expectEqual(case[1], result.trit);
        try std.testing.expectEqual(Domain.trit, result.domain);
        try std.testing.expectEqual(Rule.oklch_equal_sectors_v1, result.rule);
        try std.testing.expectEqual(@as(f32, 0.65), result.oklab.L);
        try std.testing.expectEqual(@as(f32, 1), result.oklab.alpha);
        try std.testing.expectApproxEqAbs(case[3], result.oklab.a, 0.000001);
        try std.testing.expectApproxEqAbs(case[4], result.oklab.b, 0.000001);
        try std.testing.expectApproxEqAbs(case[2], result.oklab.hue(), 0.0001);
        try std.testing.expectEqual(@intFromEnum(result.trit), substrate.hueToTrit(result.oklab.hue()));
        const rgb = result.oklab.toSRGB();
        try std.testing.expectEqual(@intFromEnum(result.trit), substrate.hueToTrit(substrate.rgbToHue(rgb[0], rgb[1], rgb[2])));
        const displayed = Color.fromSRGB(rgb[0], rgb[1], rgb[2]);
        try std.testing.expectEqual(@intFromEnum(result.trit), substrate.hueToTrit(displayed.hue()));
    }
    const a = try resolve("color://trit/-1");
    const b = try resolve("color://trit/0");
    const c = try resolve("color://trit/1");
    try std.testing.expectEqual(@as(i8, @intFromEnum(c.trit)), substrate.findBalancer(@intFromEnum(a.trit), @intFromEnum(b.trit)));
}

test "color URI: malformed scheme and paths" {
    for ([_][]const u8{ "", "trit/1", "COLOR://trit/1", "color:/trit/1", "https://trit/1", " color://trit/1" }) |uri|
        try std.testing.expectError(error.InvalidScheme, resolve(uri));
    for ([_][]const u8{
        "color://",         "color://trit",         "color:///1",         "color://trit/",    "color://trit//1",
        "color://trit/1/",  "color://trit/1/extra", "color://trit/1?x=1", "color://trit/1#x", "color://trit/%31",
        "color://trit/ 1",  "color://trit/1\n",     "color://trit/1\x00",
        "color://trit/１",
        "color://TRIT/1",   "color://user@trit/1",  "color://trit:80/1",  "color://trit\\1",  "color://trit/1\\",
        "color://%74rit/1",
    }) |uri| try std.testing.expectError(error.MalformedPath, resolve(uri));
}

test "color URI: unsupported domains and noncanonical or invalid trits" {
    for ([_][]const u8{ "color://rider/alice", "color://world/a", "color://capability/1", "color://unknown/1" }) |uri|
        try std.testing.expectError(error.UnsupportedDomain, resolve(uri));
    for ([_][]const u8{
        "color://trit/2",                                          "color://trit/-2",  "color://trit/+1",   "color://trit/-0", "color://trit/01",
        "color://trit/1.0",                                        "color://trit/1e0", "color://trit/true", "color://trit/.",  "color://trit/..",
        "color://trit/999999999999999999999999999999999999999999",
    }) |uri| try std.testing.expectError(error.InvalidTrit, resolve(uri));
}

test "color URI: repeated and interleaved resolutions are stable" {
    const uris = [_][]const u8{ "color://trit/-1", "color://trit/0", "color://trit/1" };
    for (uris) |uri| {
        const expected = try resolve(uri);
        for (0..100) |_| {
            for (uris) |other| _ = try resolve(other);
            try std.testing.expectError(error.InvalidTrit, resolve("color://trit/2"));
            const actual = try resolve(uri);
            try std.testing.expectEqualDeep(expected, actual);
        }
    }
}
