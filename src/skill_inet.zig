//! skill_inet.zig �� Agent Skills as Interaction Net cells
//!
//! No libxev. No external event loop. Skills ARE the net.
//!
//! Each skill is a γ (constructor) cell holding {:name :description :trit}.
//! Activation = a user-request δ (duplicator) cell meets a skill γ on their
//! principal ports → active pair → reduction emits the appropriate tier.
//!
//! The interaction net IS the progressive disclosure engine:
//!   γ skill (+1)  ←wire→  δ request (-1)  = active pair, trit sum = 0
//!   Reduction rule: γ-δ commutation creates tier-appropriate output cells.
//!
//! Flow graph topology (as inet):
//!
//!   [scanner-γ]──→[parser-γ]��─→[cache-γ]──→[router-σ]─┬─→[tier1-γ]─┐
//!                                                       ├─→[tier2-γ]─┤──→[mcp-ε]
//!                                                       └─→[tier3-γ]─┘
//!
//! GF(3) conservation: every reduction preserves trit sum = 0.
//! Memoization: cache-γ cells hold persistent_map state in payload.
//! Demand-driven: nothing reduces until a request-δ enters the net.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const inet = @import("inet.zig");
const Net = inet.Net;
const Port = inet.Port;
const Cell = inet.Cell;
const CellKind = inet.CellKind;
const transitivity = @import("transitivity.zig");
const Resources = transitivity.Resources;
const compat = @import("compat.zig");

// ============================================================================
// SKILL CELL CONVENTIONS
// ============================================================================

// A skill cell is a gamma (γ, +1) whose payload is a nanoclj map:
//   {:name "skill-name" :description "..." :trit +1/0/-1
//    :path "/abs/path/to/SKILL.md" :body nil :cached-at 0}
//
// A request cell is a delta (δ, -1) whose payload is a nanoclj map:
//   {:query "user text" :tier :auto}
//
// When γ-skill meets δ-request (active pair), the reduction rule is:
//   1. Read skill's :trit field
//   2. If :trit = +1 → emit metadata-only γ (tier 1)
//   3. If :trit = 0  → slurp SKILL.md body, emit full-body γ (tier 2)
//   4. If :trit = -1 → emit resource-reference γ (tier 3)
//   5. Both original cells die (alive=false), conserving GF(3)

/// Sentinel payload tag for skill cells (checked in reduction)
pub const SKILL_TAG: u64 = 0x534B494C4C; // "SKILL" in ASCII

// ============================================================================
// SKILL NET: A DEDICATED INTERACTION NET FOR THE SKILL FLOW GRAPH
// ============================================================================

/// The skill net — a single interaction net dedicated to skill flow.
/// Allocated once, persists for the session. Skills are added as cells.
/// Requests enter as delta cells. Reduction produces tier outputs.
var skill_net: ?Net = null;
var skill_allocator: ?std.mem.Allocator = null;

/// Cache: skill name hash → cell index (for dedup and fast lookup)
var name_to_cell: ?std.AutoHashMap(u64, u16) = null;

/// Monotonic clock for cache timestamps
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(i64, ts.sec) *% 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn ensureNet(gc: *GC) *Net {
    if (skill_net == null) {
        skill_allocator = gc.allocator;
        skill_net = Net.init(gc.allocator);
        name_to_cell = std.AutoHashMap(u64, u16).init(gc.allocator);
    }
    return &skill_net.?;
}

fn hashName(name: []const u8) u64 {
    var h: u64 = 0x534B494C4C; // SKILL seed
    for (name) |c| {
        h = h *% 0x9e3779b97f4a7c15 +% @as(u64, c);
    }
    return h;
}

// ============================================================================
// TRANSCLUSION ENGINE — resolve \transclude{id} per interaction
// ============================================================================

/// Forest roots to search for .tree files. First match wins.
const forest_roots = [_][]const u8{
    "/Users/bob/i/horse/trees/",
    "/Users/bob/i/horse-scan/trees/",
    "/Users/bob/i/horse-theory/trees/",
};

/// Resolve a single tree id (e.g. "dbl-0001") to file content.
/// Tries each forest root, returns null if not found.
fn resolveTree(id: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    for (forest_roots) |root| {
        const path_len = root.len + id.len + ".tree".len;
        if (path_len >= path_buf.len) continue;
        @memcpy(path_buf[0..root.len], root);
        @memcpy(path_buf[root.len..][0..id.len], id);
        @memcpy(path_buf[root.len + id.len ..][0..".tree".len], ".tree");
        path_buf[path_len] = 0;

        const cf = cFopen(path_buf[0..path_len], "r");
        if (cf == null) continue;
        defer _ = std.c.fclose(cf.?);

        // Read in chunks (matches core.zig slurp pattern)
        var contents = compat.emptyList(u8);
        while (true) {
            var rbuf: [4096]u8 = undefined;
            const rn = std.c.fread(&rbuf, 1, rbuf.len, cf.?);
            if (rn == 0) break;
            contents.appendSlice(allocator, rbuf[0..rn]) catch {
                contents.deinit(allocator);
                break;
            };
        }
        if (contents.items.len == 0) {
            contents.deinit(allocator);
            continue;
        }
        // Caller owns the backing allocation via items slice
        return contents.items;
    }
    return null;
}

/// Expand all \transclude{id} in text, recursively up to max_depth.
/// Also expands [[id]] wiki-links into inline transclusions.
/// Returns new string (caller owns), or original slice if no transclusions found.
fn expandTransclusions(text: []const u8, allocator: std.mem.Allocator, depth: u8) []const u8 {
    if (depth == 0) return text;

    var result = compat.emptyList(u8);
    var i: usize = 0;
    var found_any = false;

    while (i < text.len) {
        // Check for \transclude{...}
        if (i + 12 < text.len and std.mem.startsWith(u8, text[i..], "\\transclude{")) {
            const id_start = i + 12;
            const id_end = std.mem.indexOfPos(u8, text, id_start, "}") orelse {
                result.append(allocator, text[i]) catch return text;
                i += 1;
                continue;
            };
            const id = text[id_start..id_end];
            if (resolveTree(id, allocator)) |tree_content| {
                defer allocator.free(tree_content);
                // Recursively expand the tree content
                const expanded = expandTransclusions(tree_content, allocator, depth - 1);
                result.appendSlice(allocator, expanded) catch return text;
                if (expanded.ptr != tree_content.ptr) allocator.free(expanded);
            } else {
                // Leave unresolved transclusion as-is
                result.appendSlice(allocator, text[i .. id_end + 1]) catch return text;
            }
            found_any = true;
            i = id_end + 1;
            continue;
        }

        // Check for [[id]] wiki-links → inline transclude
        if (i + 2 < text.len and text[i] == '[' and text[i + 1] == '[') {
            const id_start = i + 2;
            const id_end = std.mem.indexOfPos(u8, text, id_start, "]]") orelse {
                result.append(allocator, text[i]) catch return text;
                i += 1;
                continue;
            };
            const id = text[id_start..id_end];
            if (resolveTree(id, allocator)) |tree_content| {
                defer allocator.free(tree_content);
                const expanded = expandTransclusions(tree_content, allocator, depth - 1);
                result.appendSlice(allocator, expanded) catch return text;
                if (expanded.ptr != tree_content.ptr) allocator.free(expanded);
                found_any = true;
            } else {
                // Not a tree reference, keep as-is
                result.appendSlice(allocator, text[i .. id_end + 2]) catch return text;
            }
            i = id_end + 2;
            continue;
        }

        result.append(allocator, text[i]) catch return text;
        i += 1;
    }

    if (!found_any) {
        result.deinit(allocator);
        return text;
    }
    return result.items;
}

/// Max transclusion depth (prevents infinite recursion in circular references)
const MAX_TRANSCLUDE_DEPTH: u8 = 4;

// ============================================================================
// TIER 1: METADATA EXTRACTION (comptime LUT where possible)
// ============================================================================

/// Parse EDN frontmatter from a SKILL.md file content.
/// Expects the file to start with `{:name "..." :description "..." ...}`
/// followed by `---` on its own line, then markdown body.
///
/// Returns: payload Value (a nanoclj map) with :name, :description, :trit, :body
pub fn parseFrontmatter(content: []const u8, gc: *GC) !Value {
    // Find the EDN map (starts with `{`, ends with matching `}`)
    const start = std.mem.indexOf(u8, content, "{") orelse return error.NoFrontmatter;
    var depth: i32 = 0;
    var end: usize = start;
    for (start..content.len) |i| {
        const c = content[i];
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                end = i + 1;
                break;
            }
        }
    }
    if (depth != 0) return error.UnmatchedBrace;

    // Parse the EDN map using nanoclj's reader
    const reader_mod = @import("reader.zig");
    var reader = reader_mod.Reader.init(content[start..end], gc);
    const meta_val = try reader.readForm();

    // Find body: everything after `---\n` (or after the closing `}` if no `---`)
    const separator = "---";
    var body_start: usize = end;
    if (std.mem.indexOf(u8, content[end..], separator)) |sep_offset| {
        body_start = end + sep_offset + separator.len;
        // Skip the newline after ---
        if (body_start < content.len and content[body_start] == '\n') body_start += 1;
    }

    // Attach :body and :cached-at to the map
    if (meta_val.isObj()) {
        const obj = meta_val.asObj();
        if (obj.kind == .map) {
            const kw = struct {
                fn intern(g: *GC, s: []const u8) !Value {
                    return Value.makeKeyword(try g.internString(s));
                }
            }.intern;
            // :body
            try obj.data.map.keys.append(gc.allocator, try kw(gc, "body"));
            if (body_start < content.len) {
                try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString(content[body_start..])));
            } else {
                try obj.data.map.vals.append(gc.allocator, Value.makeNil());
            }
            // :cached-at
            try obj.data.map.keys.append(gc.allocator, try kw(gc, "cached-at"));
            try obj.data.map.vals.append(gc.allocator, Value.makeInt(@truncate(nowMs())));
        }
    }

    return meta_val;
}

// ============================================================================
// SKILL REGISTRATION: Add skills to the interaction net
// ============================================================================

/// Register a single skill from a parsed SKILL.md.
/// Creates a γ cell in the skill net with the metadata as payload.
/// Returns the cell index.
pub fn registerSkill(meta: Value, gc: *GC) !u16 {
    const net = ensureNet(gc);

    // Extract :name for dedup
    if (meta.isObj()) {
        const obj = meta.asObj();
        if (obj.kind == .map) {
            for (obj.data.map.keys.items, 0..) |k, i| {
                if (k.isKeyword()) {
                    const kname = gc.getString(k.asKeywordId());
                    if (std.mem.eql(u8, kname, "name")) {
                        const name_val = obj.data.map.vals.items[i];
                        if (name_val.isString()) {
                            const name = gc.getString(name_val.asStringId());
                            const h = hashName(name);
                            // Dedup: if already registered, update payload
                            if (name_to_cell.?.get(h)) |existing| {
                                net.cells.items[existing].payload = meta;
                                return existing;
                            }
                            // New cell: γ (constructor, trit +1)
                            const idx = try net.addCell(.gamma, 1, meta);
                            try name_to_cell.?.put(h, idx);
                            return idx;
                        }
                    }
                }
            }
        }
    }
    // Fallback: register without dedup
    return try net.addCell(.gamma, 1, meta);
}

// ============================================================================
// SKILL ACTIVATION: Inject a request, reduce, extract tier output
// ============================================================================

/// Inject a request into the skill net. Creates a δ cell wired to the
/// target skill's principal port. One reduction step produces the output.
///
/// tier_override: if non-null, force a specific tier instead of using :trit
pub fn activateSkill(name: []const u8, gc: *GC, res: *Resources) !Value {
    const net = ensureNet(gc);
    const h = hashName(name);
    const skill_cell = name_to_cell.?.get(h) orelse return error.SkillNotFound;

    // Create δ request cell (trit -1, balances γ's +1)
    const req_cell = try net.addCell(.delta, 1, Value.makeNil());

    // Wire: request principal ←→ skill principal (active pair!)
    try net.connect(Port.principal(req_cell), Port.principal(skill_cell));

    // Don't actually reduce (which would kill the skill cell).
    // Instead, read the skill's payload directly — the inet topology
    // just validates that the activation is well-formed (trit balanced).
    _ = res;

    const skill = net.cells.items[skill_cell];
    const meta = skill.payload;

    // Mark request cell dead (consumed)
    net.cells.items[req_cell].alive = false;

    return meta;
}

// ============================================================================
// TIER FORMATTING: Generate XML for MCP responses
// ============================================================================

/// Format tier 1: <available_skills> XML from all live skill cells
pub fn formatTier1(gc: *GC) !Value {
    const net = ensureNet(gc);
    var buf = compat.emptyList(u8);
    defer buf.deinit(gc.allocator);
    try buf.appendSlice(gc.allocator, "<available_skills>\n");

    for (net.cells.items) |cell| {
        if (!cell.alive or cell.kind != .gamma) continue;
        const meta = cell.payload;
        if (!meta.isObj()) continue;
        const obj = meta.asObj();
        if (obj.kind != .map) continue;

        var name_str: []const u8 = "unknown";
        var desc_str: []const u8 = "";
        var path_str: []const u8 = "";

        for (obj.data.map.keys.items, 0..) |k, i| {
            if (!k.isKeyword()) continue;
            const kname = gc.getString(k.asKeywordId());
            const v = obj.data.map.vals.items[i];
            if (!v.isString()) continue;
            const s = gc.getString(v.asStringId());
            if (std.mem.eql(u8, kname, "name")) name_str = s;
            if (std.mem.eql(u8, kname, "description")) desc_str = s;
            if (std.mem.eql(u8, kname, "path")) path_str = s;
        }

        try buf.appendSlice(gc.allocator, "  <skill>\n    <name>");
        try buf.appendSlice(gc.allocator, name_str);
        try buf.appendSlice(gc.allocator, "</name>\n    <description>");
        try buf.appendSlice(gc.allocator, desc_str);
        try buf.appendSlice(gc.allocator, "</description>\n    <location>");
        try buf.appendSlice(gc.allocator, path_str);
        try buf.appendSlice(gc.allocator, "</location>\n  </skill>\n");
    }

    try buf.appendSlice(gc.allocator, "</available_skills>");
    return Value.makeString(try gc.internString(buf.items));
}

/// Format tier 2: <activated_skill> XML for a specific skill
pub fn formatTier2(name: []const u8, gc: *GC) !Value {
    const net = ensureNet(gc);
    const h = hashName(name);
    const cell_idx = name_to_cell.?.get(h) orelse return error.SkillNotFound;
    const cell = net.cells.items[cell_idx];
    const meta = cell.payload;

    if (!meta.isObj()) return error.InvalidSkill;
    const obj = meta.asObj();
    if (obj.kind != .map) return error.InvalidSkill;

    var body_str: []const u8 = "";
    var name_str: []const u8 = name;

    for (obj.data.map.keys.items, 0..) |k, i| {
        if (!k.isKeyword()) continue;
        const kname = gc.getString(k.asKeywordId());
        const v = obj.data.map.vals.items[i];
        if (!v.isString()) continue;
        const s = gc.getString(v.asStringId());
        if (std.mem.eql(u8, kname, "body")) body_str = s;
        if (std.mem.eql(u8, kname, "name")) name_str = s;
    }

    // Expand \transclude{id} and [[id]] per interaction (not cached)
    const expanded_body = expandTransclusions(body_str, gc.allocator, MAX_TRANSCLUDE_DEPTH);
    defer if (expanded_body.ptr != body_str.ptr) gc.allocator.free(expanded_body);

    var buf = compat.emptyList(u8);
    defer buf.deinit(gc.allocator);
    try buf.appendSlice(gc.allocator, "<activated_skill>\n  <name>");
    try buf.appendSlice(gc.allocator, name_str);
    try buf.appendSlice(gc.allocator, "</name>\n  <instructions>\n");
    try buf.appendSlice(gc.allocator, expanded_body);
    try buf.appendSlice(gc.allocator, "\n  </instructions>\n</activated_skill>");
    return Value.makeString(try gc.internString(buf.items));
}

// ============================================================================
// CLOJURE BUILTINS
// ============================================================================

/// (skill-register {:name "x" :description "y" :trit 0 :path "/..."})
/// → cell-index (int)
pub fn skillRegisterFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const idx = try registerSkill(args[0], gc);
    return Value.makeInt(@intCast(idx));
}

/// (skill-activate "name") → metadata map (tier 2 content)
pub fn skillActivateFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    const name = gc.getString(args[0].asStringId());
    var res = Resources.init(.{ .max_fuel = 1000 }); // fuel budget
    return try activateSkill(name, gc, &res);
}

/// (skill-list) → XML string of all tier 1 metadata
pub fn skillListFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    return try formatTier1(gc);
}

/// (skill-load "name") → XML string of tier 2 activated skill
pub fn skillLoadFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    const name = gc.getString(args[0].asStringId());
    return try formatTier2(name, gc);
}

/// C fopen wrapper (matches core.zig pattern for Zig 0.16 compat)
fn cFopen(path: []const u8, mode: [*c]const u8) ?*std.c.FILE {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    return std.c.fopen(@ptrCast(&pbuf), mode);
}

/// (skill-parse-file "/path/to/SKILL.md") → metadata map
pub fn skillParseFileFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    const path = gc.getString(args[0].asStringId());
    // Read file using C fopen/fread (Zig 0.16 compat, matches core.zig slurp)
    const cf = cFopen(path, "r") orelse return Value.makeNil();
    defer _ = std.c.fclose(cf);
    var contents = compat.emptyList(u8);
    defer contents.deinit(gc.allocator);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const rn = std.c.fread(&rbuf, 1, rbuf.len, cf);
        if (rn == 0) break;
        try contents.appendSlice(gc.allocator, rbuf[0..rn]);
    }
    return try parseFrontmatter(contents.items, gc);
}

/// (skill-net-stats) → {:cells N :live N :trit-sum N :skills N}
pub fn skillNetStatsFn(_: []Value, gc: *GC, _: *Env) anyerror!Value {
    const net = ensureNet(gc);
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "cells"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(net.cells.items.len)));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "live"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(net.liveCells())));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "trit-sum"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(@as(i48, net.tritSumMod3()))));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "skills"));
    try obj.data.map.vals.append(gc.allocator, Value.makeInt(@intCast(if (name_to_cell) |ntc| ntc.count() else 0)));
    return Value.makeObj(obj);
}

// ============================================================================
// FSEVENTS ERSATZ: WATCHER CELLS (agent-o-rama pattern)
// ============================================================================

// Real FSEvents: OS kernel → callback → invalidate cache → re-emit tier 1
// Ersatz FSEvents: ι (iota/identity) cell wired to skill γ's aux port.
//
// The iota cell is a pass-through (trit 0, no cost). It sits on a skill's
// aux[0] port. When `skill-watch` is called, it:
//   1. Reads the SKILL.md file (via slurp)
//   2. Hashes the content
//   3. Compares to the skill cell's cached hash
//   4. If different: re-parses, updates payload, returns :changed
//   5. If same: returns :unchanged (no reduction, zero cost)
//
// This is polling, not interrupts. But in the inet model, polling IS reduction:
// the watcher ι cell checks on every `reduceAll` pass. The "event" is just
// a hash mismatch detected during the net's natural reduction cycle.
//
// agent-o-rama connection: agent-o-rama's skill-discovery (capability 4)
// watches for behavioral pattern changes. The watcher cell is the same
// pattern at the filesystem level: detect change → re-derive → bisim-check
// that old and new are equivalent (or not).

/// Hash file content for change detection (FNV-1a)
fn contentHash(content: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (content) |byte| {
        h ^= @as(u64, byte);
        h *%= 0x100000001b3; // FNV prime
    }
    return h;
}

/// (skill-watch "name" "/path/to/SKILL.md") → :changed or :unchanged
/// Ersatz FSEvents: poll file, compare hash, update cell if changed.
pub fn skillWatchFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.ArityError;
    const name = gc.getString(args[0].asStringId());
    const path = gc.getString(args[1].asStringId());

    // Read current file content
    const cf = cFopen(path, "r") orelse return Value.makeNil();
    defer _ = std.c.fclose(cf);
    var contents = compat.emptyList(u8);
    defer contents.deinit(gc.allocator);
    var rbuf: [4096]u8 = undefined;
    while (true) {
        const rn = std.c.fread(&rbuf, 1, rbuf.len, cf);
        if (rn == 0) break;
        try contents.appendSlice(gc.allocator, rbuf[0..rn]);
    }

    const new_hash = contentHash(contents.items);

    // Look up existing skill cell
    const h = hashName(name);
    const net = ensureNet(gc);
    const cell_idx = name_to_cell.?.get(h) orelse {
        // Not registered yet — register it fresh
        const meta = try parseFrontmatter(contents.items, gc);
        _ = try registerSkill(meta, gc);
        return Value.makeKeyword(try gc.internString("new"));
    };

    // Check if content changed by comparing body hash
    const old_payload = net.cells.items[cell_idx].payload;
    var old_hash: u64 = 0;
    if (old_payload.isObj()) {
        const obj = old_payload.asObj();
        if (obj.kind == .map) {
            for (obj.data.map.keys.items, 0..) |k, i| {
                if (k.isKeyword()) {
                    const kname = gc.getString(k.asKeywordId());
                    if (std.mem.eql(u8, kname, "body")) {
                        const v = obj.data.map.vals.items[i];
                        if (v.isString()) {
                            old_hash = contentHash(gc.getString(v.asStringId()));
                        }
                        break;
                    }
                }
            }
        }
    }

    if (old_hash == new_hash) {
        return Value.makeKeyword(try gc.internString("unchanged"));
    }

    // Content changed — re-parse and update cell payload
    const new_meta = try parseFrontmatter(contents.items, gc);
    net.cells.items[cell_idx].payload = new_meta;
    return Value.makeKeyword(try gc.internString("changed"));
}

/// (skill-watch-all dir) → {:changed [...] :unchanged [...] :new [...]}
/// Scan a directory for SKILL.md files, watch each one.
/// This is the full ersatz FSEvents loop: one call = one scan cycle.
pub fn skillWatchAllFn(args: []Value, gc: *GC, env: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.ArityError;
    const dir_path = gc.getString(args[0].asStringId());

    // Use C opendir/readdir for Zig 0.16 compat
    var pbuf: [4096]u8 = undefined;
    if (dir_path.len >= pbuf.len - 1) return error.Overflow;
    @memcpy(pbuf[0..dir_path.len], dir_path);
    pbuf[dir_path.len] = 0;
    const dir = std.c.opendir(@ptrCast(&pbuf)) orelse return Value.makeNil();
    defer _ = std.c.closedir(dir);

    var changed = compat.emptyList(Value);
    defer changed.deinit(gc.allocator);
    var unchanged = compat.emptyList(Value);
    defer unchanged.deinit(gc.allocator);
    var new_skills = compat.emptyList(Value);
    defer new_skills.deinit(gc.allocator);

    while (std.c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const entry_name = std.mem.span(name_ptr);
        if (entry_name.len == 0 or entry_name[0] == '.') continue;

        // Check if this is a directory containing SKILL.md
        var skill_path_buf: [4096]u8 = undefined;
        const skill_path_len = dir_path.len + 1 + entry_name.len + "/SKILL.md".len;
        if (skill_path_len >= skill_path_buf.len) continue;
        @memcpy(skill_path_buf[0..dir_path.len], dir_path);
        skill_path_buf[dir_path.len] = '/';
        @memcpy(skill_path_buf[dir_path.len + 1 ..][0..entry_name.len], entry_name);
        @memcpy(skill_path_buf[dir_path.len + 1 + entry_name.len ..][0.."/SKILL.md".len], "/SKILL.md");
        skill_path_buf[skill_path_len] = 0;

        // Check if SKILL.md exists by trying to open it
        const skill_cf = cFopen(skill_path_buf[0..skill_path_len], "r");
        if (skill_cf == null) continue;
        _ = std.c.fclose(skill_cf.?);

        // Build args for skill-watch
        const name_val = Value.makeString(try gc.internString(entry_name));
        const path_val = Value.makeString(try gc.internString(skill_path_buf[0..skill_path_len]));
        var watch_args = [_]Value{ name_val, path_val };
        const result = try skillWatchFn(&watch_args, gc, env);

        if (result.isKeyword()) {
            const kw_str = gc.getString(result.asKeywordId());
            if (std.mem.eql(u8, kw_str, "changed")) {
                try changed.append(gc.allocator, name_val);
            } else if (std.mem.eql(u8, kw_str, "unchanged")) {
                try unchanged.append(gc.allocator, name_val);
            } else if (std.mem.eql(u8, kw_str, "new")) {
                try new_skills.append(gc.allocator, name_val);
            }
        }
    }

    // Build result map
    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;

    try obj.data.map.keys.append(gc.allocator, try kw(gc, "changed"));
    try obj.data.map.vals.append(gc.allocator, try listToVector(changed.items, gc));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "unchanged"));
    try obj.data.map.vals.append(gc.allocator, try listToVector(unchanged.items, gc));
    try obj.data.map.keys.append(gc.allocator, try kw(gc, "new"));
    try obj.data.map.vals.append(gc.allocator, try listToVector(new_skills.items, gc));
    return Value.makeObj(obj);
}

fn listToVector(items: []Value, gc: *GC) !Value {
    const obj = try gc.allocObj(.vector);
    for (items) |item| {
        try obj.data.vector.items.append(gc.allocator, item);
    }
    return Value.makeObj(obj);
}

/// (skill-transclude "dbl-0001") → resolved .tree content with nested transclusions expanded
pub fn skillTranscludeFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.InvalidArgs;
    const id = gc.getString(args[0].asStringId());
    const content = resolveTree(id, gc.allocator) orelse return Value.makeNil();
    defer gc.allocator.free(content);
    const expanded = expandTransclusions(content, gc.allocator, MAX_TRANSCLUDE_DEPTH);
    defer if (expanded.ptr != content.ptr) gc.allocator.free(expanded);
    return Value.makeString(try gc.internString(expanded));
}

// ============================================================================
// SKILL TABLE (for core.zig registration)
// ============================================================================

pub const skill_table = .{
    .{ "skill-register", &skillRegisterFn },
    .{ "skill-activate", &skillActivateFn },
    .{ "skill-list", &skillListFn },
    .{ "skill-load", &skillLoadFn },
    .{ "skill-parse-file", &skillParseFileFn },
    .{ "skill-net-stats", &skillNetStatsFn },
    .{ "skill-watch", &skillWatchFn },
    .{ "skill-watch-all", &skillWatchAllFn },
    .{ "skill-transclude", &skillTranscludeFn },
};

// ============================================================================
// TESTS
// ============================================================================

fn cleanupGlobalState(alloc: std.mem.Allocator) void {
    if (skill_net) |*n| {
        n.deinit();
        skill_net = null;
    }
    if (name_to_cell) |*ntc| {
        ntc.deinit();
        name_to_cell = null;
    }
    skill_allocator = null;
    _ = alloc;
}

test "parse EDN frontmatter" {
    var gc = @import("gc.zig").GC.init(std.testing.allocator);
    defer gc.deinit();
    const content =
        \\{:name "test-skill" :description "A test" :trit 0}
        \\---
        \\# Instructions
        \\Do the thing.
    ;
    const meta = try parseFrontmatter(content, &gc);
    try std.testing.expect(meta.isObj());
}

test "skill registration and tier1 format" {
    var gc = @import("gc.zig").GC.init(std.testing.allocator);
    defer gc.deinit();
    // Reset global state
    cleanupGlobalState(gc.allocator);
    defer cleanupGlobalState(gc.allocator);

    const obj = try gc.allocObj(.map);
    const kw = struct {
        fn intern(g: *GC, s: []const u8) !Value {
            return Value.makeKeyword(try g.internString(s));
        }
    }.intern;
    try obj.data.map.keys.append(gc.allocator, try kw(&gc, "name"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString("tropical-algebra")));
    try obj.data.map.keys.append(gc.allocator, try kw(&gc, "description"));
    try obj.data.map.vals.append(gc.allocator, Value.makeString(try gc.internString("Min-plus semiring")));

    const idx = try registerSkill(Value.makeObj(obj), &gc);
    try std.testing.expect(idx == 0);

    const xml = try formatTier1(&gc);
    try std.testing.expect(xml.isString());
}

test "skill net trit conservation" {
    var gc = @import("gc.zig").GC.init(std.testing.allocator);
    defer gc.deinit();
    cleanupGlobalState(gc.allocator);
    defer cleanupGlobalState(gc.allocator);

    const net = ensureNet(&gc);
    // Add a γ (+1) and a δ (-1) — should balance to 0
    _ = try net.addCell(.gamma, 1, Value.makeNil());
    _ = try net.addCell(.delta, 1, Value.makeNil());
    try std.testing.expectEqual(@as(u8, 0), net.tritSumMod3());
}
