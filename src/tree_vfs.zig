//! tree_vfs.zig — Virtual filesystem for Forester .tree files
//!
//! Provides nanoclj-zig builtins for reading, querying, and traversing
//! the horse/ Forester forest at Zig speed. The transclusion graph
//! (built from \transclude{} directives) is materialized at load time
//! as an adjacency list for O(1) neighbor lookup.
//!
//! Builtins:
//!   (tree-read "horse-0001")       → string content of the .tree file
//!   (tree-title "horse-0001")      → extracted \title{...}
//!   (tree-transcluded "horse-0001") → list of IDs this tree transcludes
//!   (tree-transcluders "horse-0001") → list of IDs that transclude this tree
//!   (tree-ids)                     → list of all known tree IDs
//!   (tree-isolated)               → list of trees with no edges
//!   (tree-chain "horse-0001")     → longest transclusion chain from this node

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

/// Parsed tree entry
const TreeEntry = struct {
    id: []const u8,
    path: []const u8,
    content: []const u8,
    title: ?[]const u8,
    taxon: ?[]const u8,
    author: ?[]const u8,
    /// IDs this tree transcludes (outgoing edges)
    transcludes: std.ArrayListUnmanaged([]const u8),
    /// IDs this tree imports (\import{id})
    imports: std.ArrayListUnmanaged([]const u8),
    /// \meta{key}{val} pairs
    meta_keys: std.ArrayListUnmanaged([]const u8),
    meta_vals: std.ArrayListUnmanaged([]const u8),
};

/// The materialized forest
var forest: ?Forest = null;

const Forest = struct {
    allocator: std.mem.Allocator,
    /// id → entry
    entries: std.StringHashMap(TreeEntry),
    /// id → list of IDs that transclude it (reverse edges)
    transcluders: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    fn deinit(self: *Forest) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            e.value_ptr.transcludes.deinit(self.allocator);
            e.value_ptr.imports.deinit(self.allocator);
            e.value_ptr.meta_keys.deinit(self.allocator);
            e.value_ptr.meta_vals.deinit(self.allocator);
            self.allocator.free(e.value_ptr.content);
        }
        self.entries.deinit();
        var it2 = self.transcluders.iterator();
        while (it2.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.transcluders.deinit();
    }
};

/// Extract tree ID from a filename like "horse-0001.tree" → "horse-0001"
fn treeIdFromPath(path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, basename, ".tree")) {
        return basename[0 .. basename.len - 5];
    }
    return null;
}

/// Extract \title{...} from content (first occurrence, no nesting)
fn extractTitle(content: []const u8) ?[]const u8 {
    const marker = "\\title{";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const after = start + marker.len;
    // Find matching }
    var depth: u32 = 1;
    var i: usize = after;
    while (i < content.len and depth > 0) : (i += 1) {
        if (content[i] == '{') depth += 1;
        if (content[i] == '}') depth -= 1;
    }
    if (depth == 0) return content[after .. i - 1];
    return null;
}

/// Extract all \transclude{ID} targets from content
fn extractTranscludes(allocator: std.mem.Allocator, content: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var result = compat.emptyList([]const u8);
    const marker = "\\transclude{";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, marker)) |start| {
        const after = start + marker.len;
        const end = std.mem.indexOfPos(u8, content, after, "}") orelse break;
        try result.append(allocator, content[after..end]);
        pos = end + 1;
    }
    return result;
}

/// Extract \taxon{...} from content
fn extractTaxon(content: []const u8) ?[]const u8 {
    return extractSimpleDirective(content, "\\taxon{");
}

/// Extract \author{...} from content
fn extractAuthor(content: []const u8) ?[]const u8 {
    return extractSimpleDirective(content, "\\author{");
}

/// Extract a simple \directive{value} (no nesting expected)
fn extractSimpleDirective(content: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const after = start + marker.len;
    var depth: u32 = 1;
    var i: usize = after;
    while (i < content.len and depth > 0) : (i += 1) {
        if (content[i] == '{') depth += 1;
        if (content[i] == '}') depth -= 1;
    }
    if (depth == 0) return content[after .. i - 1];
    return null;
}

/// Extract all \import{ID} targets from content
fn extractImports(allocator: std.mem.Allocator, content: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var result = compat.emptyList([]const u8);
    const marker = "\\import{";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, marker)) |start| {
        const after = start + marker.len;
        const end = std.mem.indexOfPos(u8, content, after, "}") orelse break;
        try result.append(allocator, content[after..end]);
        pos = end + 1;
    }
    return result;
}

/// Extract all \meta{key}{val} pairs from content
fn extractMeta(allocator: std.mem.Allocator, content: []const u8) !struct {
    keys: std.ArrayListUnmanaged([]const u8),
    vals: std.ArrayListUnmanaged([]const u8),
} {
    var keys = compat.emptyList([]const u8);
    var vals = compat.emptyList([]const u8);
    const marker = "\\meta{";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, marker)) |start| {
        const k_after = start + marker.len;
        // Find end of key
        var depth: u32 = 1;
        var i: usize = k_after;
        while (i < content.len and depth > 0) : (i += 1) {
            if (content[i] == '{') depth += 1;
            if (content[i] == '}') depth -= 1;
        }
        if (depth != 0) break;
        const key = content[k_after .. i - 1];
        // Expect {val} immediately after
        if (i < content.len and content[i] == '{') {
            const v_after = i + 1;
            depth = 1;
            i = v_after;
            while (i < content.len and depth > 0) : (i += 1) {
                if (content[i] == '{') depth += 1;
                if (content[i] == '}') depth -= 1;
            }
            if (depth == 0) {
                const val = content[v_after .. i - 1];
                try keys.append(allocator, key);
                try vals.append(allocator, val);
            }
        }
        pos = i;
    }
    return .{ .keys = keys, .vals = vals };
}

/// Recursively scan a directory for .tree files
fn scanDir(allocator: std.mem.Allocator, dir_path: []const u8, entries: *std.StringHashMap(TreeEntry)) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Collect all entries first to avoid iterator invalidation
    var subdirs = compat.emptyList([]const u8);
    defer {
        for (subdirs.items) |s| allocator.free(s);
        subdirs.deinit(allocator);
    }
    var files = compat.emptyList(struct { id: []const u8, path: []const u8 });
    defer {
        // Only free entries not consumed
        files.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            var path_buf: [4096]u8 = undefined;
            const child_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            try subdirs.append(allocator, try allocator.dupe(u8, child_path));
        } else if (entry.kind == .file) {
            const raw_id = treeIdFromPath(entry.name) orelse continue;
            if (entries.contains(raw_id)) continue; // skip duplicates
            var path_buf: [4096]u8 = undefined;
            const child_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            const id = try allocator.dupe(u8, raw_id);
            const file = dir.openFile(entry.name, .{}) catch {
                allocator.free(id);
                continue;
            };
            defer file.close();
            const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
                allocator.free(id);
                continue;
            };
            const transcludes = try extractTranscludes(allocator, content);
            const imports = try extractImports(allocator, content);
            const meta = try extractMeta(allocator, content);
            const title = extractTitle(content);
            const taxon = extractTaxon(content);
            const author = extractAuthor(content);

            try entries.put(id, .{
                .id = id,
                .path = try allocator.dupe(u8, child_path),
                .content = content,
                .title = title,
                .taxon = taxon,
                .author = author,
                .transcludes = transcludes,
                .imports = imports,
                .meta_keys = meta.keys,
                .meta_vals = meta.vals,
            });
        }
    }

    // Recurse into subdirectories after iterator is done
    for (subdirs.items) |subdir| {
        try scanDir(allocator, subdir, entries);
    }
}

pub fn deinitForest() void {
    if (forest) |*f| {
        f.deinit();
        forest = null;
    }
}

/// Load the forest from ~/i/horse/
fn loadForest(allocator: std.mem.Allocator) !*Forest {
    if (forest) |*f| return f;

    forest = Forest{
        .allocator = allocator,
        .entries = std.StringHashMap(TreeEntry).init(allocator),
        .transcluders = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
    };
    var f = &forest.?;

    // Scan horse directories
    const home_c = std.c.getenv("HOME") orelse return f;
    const home = std.mem.span(home_c);

    var horse_path_buf: [4096]u8 = undefined;
    const horse_path = std.fmt.bufPrint(&horse_path_buf, "{s}/i/horse", .{home}) catch return f;

    try scanDir(allocator, horse_path, &f.entries);

    // Build reverse index
    var it = f.entries.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.transcludes.items) |target| {
            const gop = try f.transcluders.getOrPut(target);
            if (!gop.found_existing) {
                gop.value_ptr.* = compat.emptyList([]const u8);
            }
            try gop.value_ptr.append(allocator, e.value_ptr.id);
        }
    }

    return f;
}

// ============================================================================
// Public accessors (for inet_builtins, etc.)
// ============================================================================

/// Get all tree IDs as a slice. Returns null if forest not loaded.
pub fn getAllIds() ?[][]const u8 {
    const f = &(forest orelse return null);
    // Return the keys from entries. We collect into a static buffer.
    const S = struct {
        var id_buf: [8192][]const u8 = undefined;
    };
    var count: usize = 0;
    var it = f.entries.iterator();
    while (it.next()) |e| {
        if (count >= 8192) break;
        S.id_buf[count] = e.key_ptr.*;
        count += 1;
    }
    return S.id_buf[0..count];
}

/// Get transclusion count for a tree ID.
pub fn getTranscludeCount(id: []const u8) ?usize {
    const f = &(forest orelse return null);
    const entry = f.entries.get(id) orelse return null;
    return entry.transcludes.items.len;
}

/// Get transclusion targets for a tree ID.
pub fn getTranscludes(id: []const u8) ?[][]const u8 {
    const f = &(forest orelse return null);
    const entry = f.entries.get(id) orelse return null;
    return entry.transcludes.items;
}

// ============================================================================
// Builtins for nanoclj-zig
// ============================================================================

/// (tree-read "horse-0001") → string content
pub fn treeReadFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const entry = f.entries.get(id) orelse return Value.makeNil();
    const sid = try gc.internString(entry.content);
    return Value.makeString(sid);
}

/// (tree-title "horse-0001") → title string or nil
pub fn treeTitleFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const entry = f.entries.get(id) orelse return Value.makeNil();
    const title = entry.title orelse return Value.makeNil();
    const sid = try gc.internString(title);
    return Value.makeString(sid);
}

/// (tree-transcluded "horse-0001") → list of IDs this tree transcludes
pub fn treeTranscludedFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const entry = f.entries.get(id) orelse return Value.makeNil();
    const list_obj = try gc.allocObj(.list);
    for (entry.transcludes.items) |tid| {
        const sid = try gc.internString(tid);
        try list_obj.data.list.items.append(gc.allocator, Value.makeString(sid));
    }
    return Value.makeObj(list_obj);
}

/// (tree-transcluders "xref-0001") → list of IDs that transclude this tree
pub fn treeTranscludersFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const list_obj = try gc.allocObj(.list);
    if (f.transcluders.get(id)) |sources| {
        for (sources.items) |sid_str| {
            const sid = try gc.internString(sid_str);
            try list_obj.data.list.items.append(gc.allocator, Value.makeString(sid));
        }
    }
    return Value.makeObj(list_obj);
}

/// (tree-ids) → list of all known tree IDs
pub fn treeIdsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const f = try loadForest(gc.allocator);
    const list_obj = try gc.allocObj(.list);
    var it = f.entries.iterator();
    while (it.next()) |e| {
        const sid = try gc.internString(e.value_ptr.id);
        try list_obj.data.list.items.append(gc.allocator, Value.makeString(sid));
    }
    return Value.makeObj(list_obj);
}

/// (tree-isolated) → list of tree IDs with no incoming or outgoing edges
pub fn treeIsolatedFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    _ = args;
    const f = try loadForest(gc.allocator);
    const list_obj = try gc.allocObj(.list);
    var it = f.entries.iterator();
    while (it.next()) |e| {
        const has_out = e.value_ptr.transcludes.items.len > 0;
        const has_in = f.transcluders.contains(e.value_ptr.id);
        if (!has_out and !has_in) {
            const sid = try gc.internString(e.value_ptr.id);
            try list_obj.data.list.items.append(gc.allocator, Value.makeString(sid));
        }
    }
    return Value.makeObj(list_obj);
}

/// (tree-chain "horse-0001") → longest transclusion chain as list of IDs (DFS)
pub fn treeChainFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);

    // DFS to find longest path
    var best = compat.emptyList([]const u8);
    var current = compat.emptyList([]const u8);
    defer best.deinit(gc.allocator);
    defer current.deinit(gc.allocator);

    try longestChainDFS(f, id, &current, &best, gc.allocator, 0);

    const list_obj = try gc.allocObj(.list);
    for (best.items) |node_id| {
        const sid = try gc.internString(node_id);
        try list_obj.data.list.items.append(gc.allocator, Value.makeString(sid));
    }
    return Value.makeObj(list_obj);
}

fn longestChainDFS(
    f: *Forest,
    id: []const u8,
    current: *std.ArrayListUnmanaged([]const u8),
    best: *std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    depth: u32,
) !void {
    if (depth > 100) return; // cycle/depth guard
    try current.append(allocator, id);

    const entry = f.entries.get(id);
    const children = if (entry) |e| e.transcludes.items else &[_][]const u8{};

    if (children.len == 0) {
        // Leaf — check if this path is longest
        if (current.items.len > best.items.len) {
            best.clearRetainingCapacity();
            try best.appendSlice(allocator, current.items);
        }
    } else {
        for (children) |child| {
            try longestChainDFS(f, child, current, best, allocator, depth + 1);
        }
    }

    _ = current.pop();
}

/// (tree-taxon "dct-0001") → taxon string (e.g. "doctrine") or nil
pub fn treeTaxonFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const entry = f.entries.get(id) orelse return Value.makeNil();
    const taxon = entry.taxon orelse return Value.makeNil();
    return Value.makeString(try gc.internString(taxon));
}

/// (tree-author "bci-0001") → author string or nil
pub fn treeAuthorFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const entry = f.entries.get(id) orelse return Value.makeNil();
    const author = entry.author orelse return Value.makeNil();
    return Value.makeString(try gc.internString(author));
}

/// (tree-meta "dct-0001") → {:key1 "val1" :key2 "val2"} or nil
pub fn treeMetaFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const entry = f.entries.get(id) orelse return Value.makeNil();
    if (entry.meta_keys.items.len == 0) return Value.makeNil();
    const map_obj = try gc.allocObj(.map);
    for (entry.meta_keys.items, 0..) |key, i| {
        const kw = Value.makeKeyword(try gc.internString(key));
        const val = Value.makeString(try gc.internString(entry.meta_vals.items[i]));
        try map_obj.data.map.keys.append(gc.allocator, kw);
        try map_obj.data.map.vals.append(gc.allocator, val);
    }
    return Value.makeObj(map_obj);
}

/// (tree-imports "horse-0001") → list of IDs this tree imports
pub fn treeImportsFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const id = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const entry = f.entries.get(id) orelse return Value.makeNil();
    const list_obj = try gc.allocObj(.list);
    for (entry.imports.items) |imp| {
        const sid = try gc.internString(imp);
        try list_obj.data.list.items.append(gc.allocator, Value.makeString(sid));
    }
    return Value.makeObj(list_obj);
}

/// (tree-by-taxon "doctrine") → list of tree IDs with that taxon
pub fn treeByTaxonFn(args: []Value, gc: *GC, _: *Env) anyerror!Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    const taxon = gc.getString(args[0].asStringId());
    const f = try loadForest(gc.allocator);
    const list_obj = try gc.allocObj(.list);
    var it = f.entries.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.taxon) |t| {
            if (std.mem.eql(u8, t, taxon)) {
                const sid = try gc.internString(e.value_ptr.id);
                try list_obj.data.list.items.append(gc.allocator, Value.makeString(sid));
            }
        }
    }
    return Value.makeObj(list_obj);
}

/// Skill table for registration in core.zig
pub const skill_table = .{
    .{ "tree-read", &treeReadFn },
    .{ "tree-title", &treeTitleFn },
    .{ "tree-transcluded", &treeTranscludedFn },
    .{ "tree-transcluders", &treeTranscludersFn },
    .{ "tree-ids", &treeIdsFn },
    .{ "tree-isolated", &treeIsolatedFn },
    .{ "tree-chain", &treeChainFn },
    .{ "tree-taxon", &treeTaxonFn },
    .{ "tree-author", &treeAuthorFn },
    .{ "tree-meta", &treeMetaFn },
    .{ "tree-imports", &treeImportsFn },
    .{ "tree-by-taxon", &treeByTaxonFn },
};
