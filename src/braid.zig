//! Braid-HTTP: State Synchronization for nanoclj-zig
//!
//! Implements draft-toomim-httpbis-braid-http-04:
//!   1. VERSIONING — each eval creates a version (DAG, not line)
//!   2. PATCHES — diffs between S-expression states sent as Syrup
//!   3. SUBSCRIPTIONS — long-lived GET streams of eval updates
//!   4. MERGE-TYPE — GF(3)-conserving CRDT merge for concurrent evals
//!
//! The key insight: nanoclj-zig's REPL is already a state machine.
//! Each (read-eval-print) cycle produces a new version of the environment.
//! Braid turns this into a subscribable, mergeable, versioned stream.
//!
//! Integration:
//!   syrup_bridge.zig — Clojure values ↔ Syrup bytes (wire format)
//!   core.zig         — 35 builtins become patchable operations
//!   eval.zig         — eval produces versioned state transitions
//!   tcp_transport.zig (zig-syrup) — framed transport under Braid
//!
//! Wire format: HTTP/1.1 with Braid headers over TCP
//!   Subscribe: true
//!   Version: "eval-<splitmix64-hash>"
//!   Parents: "eval-<parent-hash>"
//!   Content-Type: application/syrup
//!   Patches: 1

const std = @import("std");
const compat = @import("compat.zig");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const syrup_bridge = @import("syrup_bridge.zig");
const net = std.net;

// ============================================================================
// VERSION DAG
// ============================================================================

pub const VersionId = [16]u8; // 128-bit hash

pub const Version = struct {
    id: VersionId,
    parents: []const VersionId,
    form: []const u8,        // S-expression that produced this version
    result: []const u8,      // printed result
    env_patch: []const u8,   // Syrup-encoded env delta (new bindings only)
    trit: i8,                // GF(3) trit of this eval
    timestamp_ns: i64,       // trit-tick epoch
};

/// SplitMix64 hash of form string → version ID
pub fn hashVersion(form: []const u8, parent: ?VersionId) VersionId {
    var state: u64 = 0x9e3779b97f4a7c15;
    for (form) |byte| {
        state +%= @as(u64, byte) *% 0xbf58476d1ce4e5b9;
    }
    if (parent) |p| {
        for (p) |byte| {
            state +%= @as(u64, byte) *% 0x94d049bb133111eb;
        }
    }
    state = (state ^ (state >> 30)) *% 0xbf58476d1ce4e5b9;
    state = (state ^ (state >> 27)) *% 0x94d049bb133111eb;
    state = state ^ (state >> 31);

    var id: VersionId = undefined;
    std.mem.writeInt(u64, id[0..8], state, .little);
    std.mem.writeInt(u64, id[8..16], state *% 0x517cc1b727220a95, .little);
    return id;
}

fn versionIdToHex(id: VersionId) [32]u8 {
    var buf: [32]u8 = undefined;
    for (id, 0..) |byte, i| {
        _ = std.fmt.bufPrint(buf[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch {};
    }
    return buf;
}

// ============================================================================
// VERSION LOG (append-only, Ewig-style)
// ============================================================================

pub const VersionLog = struct {
    versions: std.ArrayListUnmanaged(Version) = compat.emptyList(Version),
    current: ?VersionId = null,
    trit_sum: i32 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) VersionLog {
        return .{ .allocator = allocator };
    }

    pub fn append(self: *VersionLog, v: Version) !void {
        try self.versions.append(self.allocator, v);
        self.current = v.id;
        self.trit_sum += v.trit;
    }

    pub fn gf3Balanced(self: *const VersionLog) bool {
        return @mod(self.trit_sum, 3) == 0;
    }

    pub fn frontier(self: *const VersionLog) ?VersionId {
        return self.current;
    }

    /// Find versions between parent and current (for Braid range GET)
    pub fn versionsSince(self: *const VersionLog, parent: VersionId) []const Version {
        var start: usize = 0;
        for (self.versions.items, 0..) |v, i| {
            if (std.mem.eql(u8, &v.id, &parent)) {
                start = i + 1;
                break;
            }
        }
        return self.versions.items[start..];
    }
};

// ============================================================================
// BRAID-HTTP RESPONSE WRITER
// ============================================================================

pub const BraidWriter = struct {
    stream: net.Stream,
    content_type: []const u8 = "application/syrup",

    pub fn init(stream: net.Stream) BraidWriter {
        return .{ .stream = stream };
    }

    /// Send subscription header (response to Subscribe: true GET)
    pub fn sendSubscriptionHeader(self: *BraidWriter) !void {
        const header =
            "HTTP/1.1 209 Subscription\r\n" ++
            "Subscribe: true\r\n" ++
            "Content-Type: multipart/mixed\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n";
        try self.stream.writeAll(header);
    }

    /// Send a single update (version) within a subscription
    pub fn sendUpdate(self: *BraidWriter, version: Version) !void {
        const id_hex = versionIdToHex(version.id);
        var parent_hex: [32]u8 = undefined;
        if (version.parents.len > 0) {
            parent_hex = versionIdToHex(version.parents[0]);
        }

        // Braid update headers
        var buf: [2048]u8 = undefined;
        var pos: usize = 0;

        // Version header
        const v_hdr = std.fmt.bufPrint(buf[pos..], "Version: \"{s}\"\r\n", .{id_hex}) catch return;
        pos += v_hdr.len;

        // Parents header
        if (version.parents.len > 0) {
            const p_hdr = std.fmt.bufPrint(buf[pos..], "Parents: \"{s}\"\r\n", .{parent_hex}) catch return;
            pos += p_hdr.len;
        }

        // Content-Type for this patch
        const ct = std.fmt.bufPrint(buf[pos..], "Content-Type: {s}\r\n", .{self.content_type}) catch return;
        pos += ct.len;

        // Merge-Type: gf3-crdt (our custom merge preserving GF(3))
        const mt = "Merge-Type: gf3-crdt\r\n";
        @memcpy(buf[pos..][0..mt.len], mt);
        pos += mt.len;

        // Patches: 1 (single patch = the Syrup-encoded env delta)
        const patches = "Patches: 1\r\n";
        @memcpy(buf[pos..][0..patches.len], patches);
        pos += patches.len;

        // Patch content-length
        const cl = std.fmt.bufPrint(buf[pos..], "\r\nContent-Length: {d}\r\n\r\n", .{version.env_patch.len}) catch return;
        pos += cl.len;

        // Write header + patch body
        try self.stream.writeAll(buf[0..pos]);
        try self.stream.writeAll(version.env_patch);
        try self.stream.writeAll("\r\n");
    }

    /// Send "caught up" signal (Braid §4.4)
    pub fn sendCaughtUp(self: *BraidWriter, current_version: VersionId) !void {
        const hex = versionIdToHex(current_version);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Current-Version: \"{s}\"\r\n\r\n", .{hex}) catch return;
        try self.stream.writeAll(msg);
    }
};

// ============================================================================
// BRAID-HTTP REQUEST PARSER (minimal)
// ============================================================================

pub const BraidRequest = struct {
    method: enum { GET, PUT } = .GET,
    path: []const u8 = "/",
    subscribe: bool = false,
    version: ?[]const u8 = null,
    parents: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub fn parseRequest(buf: []const u8) BraidRequest {
    var req = BraidRequest{};

    // Method
    if (std.mem.startsWith(u8, buf, "PUT")) {
        req.method = .PUT;
    }

    // Subscribe header
    if (std.mem.indexOf(u8, buf, "Subscribe: true")) |_| {
        req.subscribe = true;
    }

    // Version header
    if (std.mem.indexOf(u8, buf, "Version: \"")) |start| {
        const after = buf[start + 10 ..];
        if (std.mem.indexOf(u8, after, "\"")) |end| {
            req.version = after[0..end];
        }
    }

    // Parents header
    if (std.mem.indexOf(u8, buf, "Parents: \"")) |start| {
        const after = buf[start + 10 ..];
        if (std.mem.indexOf(u8, after, "\"")) |end| {
            req.parents = after[0..end];
        }
    }

    // Body (after double CRLF)
    if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |hdr_end| {
        const body = buf[hdr_end + 4 ..];
        if (body.len > 0) req.body = body;
    }

    return req;
}

// ============================================================================
// BRAID REPL SERVER
// ============================================================================
//
// GET /repl with Subscribe: true → stream of eval updates
// PUT /repl with Version/Parents → submit a form for eval
//
// Each eval:
//   1. Reads the form from PUT body (S-expression)
//   2. Evals in the current env
//   3. Creates a Version with Syrup-encoded env delta
//   4. Appends to VersionLog
//   5. Pushes update to all subscribers
//   6. GF(3) trit computed from SplitMix64 on version hash

pub const BraidRepl = struct {
    log: VersionLog,
    subscribers: std.ArrayListUnmanaged(BraidWriter) = compat.emptyList(BraidWriter),
    allocator: Allocator,

    pub fn init(allocator: Allocator) BraidRepl {
        return .{
            .log = VersionLog.init(allocator),
            .allocator = allocator,
        };
    }

    /// Process an eval and broadcast to subscribers
    pub fn eval(self: *BraidRepl, form: []const u8, result: []const u8,
                env_patch_syrup: []const u8) !VersionId {
        const parent = self.log.frontier();
        const id = hashVersion(form, parent);

        // GF(3) trit from version hash
        const h = std.mem.readInt(u64, id[0..8], .little);
        const hue: f64 = @as(f64, @floatFromInt(h >> 16 & 0xffff)) / 65535.0 * 360.0;
        const trit: i8 = if (hue < 60 or hue >= 300) 1 else if (hue < 180) 0 else -1;

        var parents_buf: [1]VersionId = undefined;
        var parents_slice: []const VersionId = &.{};
        if (parent) |p| {
            parents_buf[0] = p;
            parents_slice = &parents_buf;
        }

        const version = Version{
            .id = id,
            .parents = parents_slice,
            .form = form,
            .result = result,
            .env_patch = env_patch_syrup,
            .trit = trit,
            .timestamp_ns = std.time.nanoTimestamp(),
        };

        try self.log.append(version);

        // Push to all subscribers
        for (self.subscribers.items) |*sub| {
            sub.sendUpdate(version) catch {};
        }

        return id;
    }

    /// Add a subscriber (from GET /repl with Subscribe: true)
    pub fn subscribe(self: *BraidRepl, writer: BraidWriter) !void {
        try self.subscribers.append(self.allocator, writer);

        // Send history catch-up
        for (self.log.versions.items) |v| {
            try writer.sendUpdate(v);
        }
        if (self.log.frontier()) |current| {
            try writer.sendCaughtUp(current);
        }
    }
};

// ============================================================================
// MERGE-TYPE: gf3-crdt
// ============================================================================
//
// Custom merge type for concurrent nanoclj evals.
// When two evals happen concurrently (diverge from same parent):
//   1. Both patches are applied (last-writer-wins per binding)
//   2. GF(3) conservation check: if the merged trit sum breaks
//      conservation, insert a compensating "phantom eval" with
//      the balancing trit.
//
// This is the CRDT part: concurrent writes eventually converge
// to the same state regardless of application order.

pub fn gf3Merge(a: Version, b: Version) i8 {
    const merged_trit = @mod(@as(i32, a.trit) + @as(i32, b.trit), 3);
    return switch (merged_trit) {
        0 => 0,
        1 => 1,
        2 => -1,
        else => 0,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "version hash deterministic" {
    const id1 = hashVersion("(+ 1 2)", null);
    const id2 = hashVersion("(+ 1 2)", null);
    try std.testing.expectEqualSlices(u8, &id1, &id2);
}

test "version hash differs for different forms" {
    const id1 = hashVersion("(+ 1 2)", null);
    const id2 = hashVersion("(+ 3 4)", null);
    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "version log GF(3)" {
    const allocator = std.testing.allocator;
    var log = VersionLog.init(allocator);
    defer log.versions.deinit(allocator);

    // Append 3 versions with trits that sum to 0
    try log.append(.{ .id = hashVersion("a", null), .parents = &.{},
        .form = "a", .result = "1", .env_patch = "", .trit = 1, .timestamp_ns = 0 });
    try log.append(.{ .id = hashVersion("b", null), .parents = &.{},
        .form = "b", .result = "2", .env_patch = "", .trit = 0, .timestamp_ns = 0 });
    try log.append(.{ .id = hashVersion("c", null), .parents = &.{},
        .form = "c", .result = "3", .env_patch = "", .trit = -1, .timestamp_ns = 0 });

    try std.testing.expect(log.gf3Balanced());
    try std.testing.expectEqual(@as(usize, 3), log.versions.items.len);
}

test "braid request parse" {
    const raw =
        "GET /repl HTTP/1.1\r\n" ++
        "Subscribe: true\r\n" ++
        "Version: \"abc123\"\r\n" ++
        "\r\n";
    const req = parseRequest(raw);
    try std.testing.expect(req.subscribe);
    try std.testing.expectEqualStrings("abc123", req.version.?);
}
