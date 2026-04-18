const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const gc_mod = @import("gc.zig");
const GC = gc_mod.GC;
const compat = @import("compat.zig");

pub const ReadError = error{
    UnexpectedEOF,
    UnexpectedChar,
    UnmatchedParen,
    UnmatchedBracket,
    UnmatchedBrace,
    InvalidNumber,
    OutOfMemory,
    InvalidUtf8,
};

const MAX_READ_DEPTH: u32 = 256;

/// Sentinel symbol name for discarded reader-conditional branches.
/// Never a valid Clojure identifier (starts with __reader), so collision-free.
const SKIP_SENTINEL_NAME: []const u8 = "__reader_skip__";
/// Sentinel head marker for splice lists produced by `#?@`.
const SPLICE_SENTINEL_NAME: []const u8 = "__reader_splice__";

/// Returns true if `v` is the skip sentinel (non-matching `#?` / `#?@`).
fn isSkipSentinel(gc: *GC, v: Value) bool {
    if (!v.isSymbol()) return false;
    const name = gc.getString(v.asSymbolId());
    return std.mem.eql(u8, name, SKIP_SENTINEL_NAME);
}

/// Returns non-null splice-children slice if `v` is a splice sentinel list.
fn spliceChildren(gc: *GC, v: Value) ?[]Value {
    if (!v.isObj()) return null;
    const obj = v.asObj();
    if (obj.kind != .list) return null;
    const items = obj.data.list.items.items;
    if (items.len == 0) return null;
    if (!items[0].isSymbol()) return null;
    const name = gc.getString(items[0].asSymbolId());
    if (!std.mem.eql(u8, name, SPLICE_SENTINEL_NAME)) return null;
    return items[1..];
}

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    gc: *GC,
    depth: u32 = 0, // CVE-3 fix: track nesting depth
    line: u32 = 1,
    col: u16 = 1,
    file_id: u48 = 0, // interned string ID for source file name

    pub fn init(src: []const u8, gc: *GC) Reader {
        return .{ .src = src, .gc = gc };
    }

    pub fn initWithFile(src: []const u8, gc: *GC, file_name: []const u8) Reader {
        const fid = gc.internString(file_name) catch 0;
        return .{ .src = src, .gc = gc, .file_id = fid };
    }

    /// Capture current source location
    fn currentLoc(self: *const Reader) @import("srcloc.zig").SourceLoc {
        return .{ .line = self.line, .col = self.col, .file_id = self.file_id };
    }

    /// Attach source location metadata to a heap object
    fn attachLoc(self: *Reader, obj: *@import("value.zig").Obj) void {
        const loc = self.currentLoc();
        obj.meta = loc.toMeta(self.gc) catch null;
    }

    /// Advance pos by 1, tracking column
    fn advance(self: *Reader) void {
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    pub fn readForm(self: *Reader) ReadError!Value {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return error.UnexpectedEOF;

        const c = self.src[self.pos];
        return switch (c) {
            '(' => self.readList(),
            '[' => self.readVector(),
            '{' => self.readMap(),
            ')' => error.UnmatchedParen,
            ']' => error.UnmatchedBracket,
            '}' => error.UnmatchedBrace,
            '\'' => self.readWrapped("quote"),
            '@' => self.readWrapped("deref"),
            '`' => self.readWrapped("quasiquote"),
            '~' => blk: {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '@') {
                    break :blk self.readWrapped("splice-unquote");
                }
                self.pos -= 1;
                break :blk self.readWrapped("unquote");
            },
            '\\' => self.readCharLiteral(),
            '^' => self.readMeta(),
            '#' => self.readDispatch(),
            '"' => self.readString(),
            ':' => self.readKeyword(),
            ';' => {
                // skip comment to end of line
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                // If nothing left after comment, return nil (not EOF error)
                self.skipWhitespace();
                if (self.pos >= self.src.len) return Value.makeNil();
                return self.readForm();
            },
            else => self.readAtom(),
        };
    }

    fn readList(self: *Reader) ReadError!Value {
        self.depth += 1;
        if (self.depth > MAX_READ_DEPTH) return error.UnexpectedChar; // depth exceeded
        defer self.depth -= 1;
        const obj = self.gc.allocObj(.list) catch return error.OutOfMemory;
        self.attachLoc(obj);
        self.advance(); // skip (
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.UnexpectedEOF;
            if (self.src[self.pos] == ')') {
                self.pos += 1;
                return Value.makeObj(obj);
            }
            const v = try self.readForm();
            if (isSkipSentinel(self.gc, v)) continue;
            if (spliceChildren(self.gc, v)) |children| {
                for (children) |ch| {
                    obj.data.list.items.append(self.gc.allocator, ch) catch return error.OutOfMemory;
                }
                continue;
            }
            obj.data.list.items.append(self.gc.allocator, v) catch return error.OutOfMemory;
        }
    }

    fn readVector(self: *Reader) ReadError!Value {
        self.depth += 1;
        if (self.depth > MAX_READ_DEPTH) return error.UnexpectedChar;
        defer self.depth -= 1;
        self.pos += 1; // skip [
        const obj = self.gc.allocObj(.vector) catch return error.OutOfMemory;
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.UnexpectedEOF;
            if (self.src[self.pos] == ']') {
                self.pos += 1;
                return Value.makeObj(obj);
            }
            const v = try self.readForm();
            if (isSkipSentinel(self.gc, v)) continue;
            if (spliceChildren(self.gc, v)) |children| {
                for (children) |ch| {
                    obj.data.vector.items.append(self.gc.allocator, ch) catch return error.OutOfMemory;
                }
                continue;
            }
            obj.data.vector.items.append(self.gc.allocator, v) catch return error.OutOfMemory;
        }
    }

    fn readMap(self: *Reader) ReadError!Value {
        self.depth += 1;
        if (self.depth > MAX_READ_DEPTH) return error.UnexpectedChar;
        defer self.depth -= 1;
        self.pos += 1; // skip {
        const obj = self.gc.allocObj(.map) catch return error.OutOfMemory;
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.UnexpectedEOF;
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                return Value.makeObj(obj);
            }
            var k = try self.readForm();
            while (isSkipSentinel(self.gc, k)) {
                self.skipWhitespace();
                if (self.pos >= self.src.len) return error.UnexpectedEOF;
                if (self.src[self.pos] == '}') {
                    self.pos += 1;
                    return Value.makeObj(obj);
                }
                k = try self.readForm();
            }
            const v = try self.readForm();
            obj.data.map.keys.append(self.gc.allocator, k) catch return error.OutOfMemory;
            obj.data.map.vals.append(self.gc.allocator, v) catch return error.OutOfMemory;
        }
    }

    fn readWrapped(self: *Reader, sym_name: []const u8) ReadError!Value {
        self.pos += 1;
        const inner = try self.readForm();
        const obj = self.gc.allocObj(.list) catch return error.OutOfMemory;
        const sym_id = self.gc.internString(sym_name) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, Value.makeSymbol(sym_id)) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, inner) catch return error.OutOfMemory;
        return Value.makeObj(obj);
    }

    /// Handle # dispatch: #() anonymous fn, #{} set literal, #_ discard
    fn readDispatch(self: *Reader) ReadError!Value {
        self.pos += 1; // skip #
        if (self.pos >= self.src.len) return error.UnexpectedEOF;
        const c = self.src[self.pos];
        return switch (c) {
            '(' => self.readAnonFn(),
            '{' => self.readSet(),
            '"' => self.readRegex(),
            '?' => self.readReaderConditional(),
            '_' => {
                self.pos += 1;
                _ = try self.readForm(); // discard next form
                return self.readForm();
            },
            '\'' => {
                // #'var — resolve var reference, expand to (var name)
                self.pos += 1;
                const sym = try self.readForm();
                const var_sym = self.gc.internString("var") catch return error.OutOfMemory;
                const obj = self.gc.allocObj(.list) catch return error.OutOfMemory;
                obj.data.list.items.append(self.gc.allocator, Value.makeSymbol(var_sym)) catch return error.OutOfMemory;
                obj.data.list.items.append(self.gc.allocator, sym) catch return error.OutOfMemory;
                return Value.makeObj(obj);
            },
            else => blk: {
                // Tagged literals: #tag form → {:tag tag :value form}
                // Handles #inst "..." and #uuid "..." etc.
                if (std.ascii.isAlphabetic(c)) {
                    const start = self.pos;
                    while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '-' or self.src[self.pos] == '_' or self.src[self.pos] == '.')) {
                        self.pos += 1;
                    }
                    const tag_name = self.src[start..self.pos];
                    // #color[L a b alpha] → first-class color value
                    if (std.mem.eql(u8, tag_name, "color")) {
                        const vec = self.readForm() catch return error.UnexpectedChar;
                        if (vec.isObj() and vec.asObj().kind == .vector) {
                            const items = vec.asObj().data.vector.items.items;
                            if (items.len >= 3) {
                                const colorspace = @import("colorspace.zig");
                                const toF = struct {
                                    fn f(v: Value) f32 {
                                        if (v.isFloat()) return @floatCast(v.asFloat());
                                        if (v.isInt()) return @floatFromInt(v.asInt());
                                        return 0;
                                    }
                                }.f;
                                const color_obj = self.gc.allocObj(.color) catch return error.OutOfMemory;
                                color_obj.data = .{ .color = colorspace.Color{
                                    .L = toF(items[0]),
                                    .a = toF(items[1]),
                                    .b = toF(items[2]),
                                    .alpha = if (items.len > 3) toF(items[3]) else 1.0,
                                } };
                                break :blk Value.makeObj(color_obj);
                            }
                        }
                        break :blk error.UnexpectedChar;
                    }
                    const form = self.readForm() catch return error.UnexpectedChar;
                    // Build {:tag "tag" :value form}
                    const m = self.gc.allocObj(.map) catch return error.OutOfMemory;
                    const tag_kw = self.gc.internString("tag") catch return error.OutOfMemory;
                    const val_kw = self.gc.internString("value") catch return error.OutOfMemory;
                    m.data.map.keys.append(self.gc.allocator, Value.makeKeyword(tag_kw)) catch return error.OutOfMemory;
                    const tag_str_id = self.gc.internString(tag_name) catch return error.OutOfMemory;
                    m.data.map.vals.append(self.gc.allocator, Value.makeString(tag_str_id)) catch return error.OutOfMemory;
                    m.data.map.keys.append(self.gc.allocator, Value.makeKeyword(val_kw)) catch return error.OutOfMemory;
                    m.data.map.vals.append(self.gc.allocator, form) catch return error.OutOfMemory;
                    break :blk Value.makeObj(m);
                }
                break :blk error.UnexpectedChar;
            },
        };
    }

    /// ^meta form — attach parsed metadata to the next form.
    /// Normalizations:
    ///   ^{:k v} form     → meta = {:k v}
    ///   ^:kw form        → meta = {:kw true}
    ///   ^Sym form        → meta = {:tag Sym}
    ///   ^"Str" form      → meta = {:tag "Str"}
    /// Heap-object targets (list/vector/map/set/fn/…) get the meta attached
    /// directly via `obj.meta`. NaN-boxed atoms (symbol/keyword/string) fall
    /// back to `(with-meta target meta-map)` so downstream can still see the
    /// metadata — `(meta x)` on a bare symbol would otherwise be unreachable.
    /// Stacked `^` merge into one meta map; OUTERMOST wins on collision.
    fn readMeta(self: *Reader) ReadError!Value {
        self.pos += 1; // skip ^
        const meta_val = try self.readForm();
        const target = try self.readForm();
        const meta_map = try self.normalizeMeta(meta_val);

        // Merge outer-wins if target already has meta attached (inner ^).
        var final_target = target;
        if (final_target.isObj() and final_target.asObj().meta != null) {
            try self.mergeMetaInto(meta_map, final_target.asObj().meta.?);
        }
        // If inner expanded to (with-meta inner-target inner-meta), unwrap+merge.
        if (isWithMetaForm(final_target, self.gc)) {
            const items = final_target.asObj().data.list.items.items;
            const inner_meta = items[2];
            if (inner_meta.isObj() and inner_meta.asObj().kind == .map) {
                try self.mergeMetaInto(meta_map, inner_meta.asObj());
            }
            final_target = items[1];
        }

        // Attach directly if possible.
        if (final_target.isObj() and canHoldMeta(final_target.asObj().kind)
            and meta_map.isObj() and meta_map.asObj().kind == .map)
        {
            final_target.asObj().meta = meta_map.asObj();
            return final_target;
        }

        // Otherwise wrap so the information is preserved through evaluation.
        const wm_sym = self.gc.internString("with-meta") catch return error.OutOfMemory;
        const obj = self.gc.allocObj(.list) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, Value.makeSymbol(wm_sym)) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, final_target) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, meta_map) catch return error.OutOfMemory;
        return Value.makeObj(obj);
    }

    /// Normalize raw metadata (map/keyword/symbol/string) into a map Value.
    fn normalizeMeta(self: *Reader, meta_val: Value) ReadError!Value {
        if (meta_val.isObj() and meta_val.asObj().kind == .map) return meta_val;
        if (meta_val.isKeyword()) {
            const m = self.gc.allocObj(.map) catch return error.OutOfMemory;
            m.data.map.keys.append(self.gc.allocator, meta_val) catch return error.OutOfMemory;
            m.data.map.vals.append(self.gc.allocator, Value.makeBool(true)) catch return error.OutOfMemory;
            return Value.makeObj(m);
        }
        if (meta_val.isSymbol() or meta_val.isString()) {
            const m = self.gc.allocObj(.map) catch return error.OutOfMemory;
            const tag_kw = self.gc.internString("tag") catch return error.OutOfMemory;
            m.data.map.keys.append(self.gc.allocator, Value.makeKeyword(tag_kw)) catch return error.OutOfMemory;
            m.data.map.vals.append(self.gc.allocator, meta_val) catch return error.OutOfMemory;
            return Value.makeObj(m);
        }
        return meta_val; // fallback
    }

    /// Merge keys from `src` into `dst` map, outer/earlier wins (dst keeps
    /// its value on collision).
    fn mergeMetaInto(self: *Reader, dst_val: Value, src: *@import("value.zig").Obj) ReadError!void {
        if (!(dst_val.isObj() and dst_val.asObj().kind == .map)) return;
        const dst = dst_val.asObj();
        const semantics = @import("semantics.zig");
        src_loop: for (src.data.map.keys.items, 0..) |sk, i| {
            for (dst.data.map.keys.items) |dk| {
                if (semantics.structuralEq(dk, sk, self.gc)) continue :src_loop;
            }
            dst.data.map.keys.append(self.gc.allocator, sk) catch return error.OutOfMemory;
            dst.data.map.vals.append(self.gc.allocator, src.data.map.vals.items[i]) catch return error.OutOfMemory;
        }
    }

    /// #?(:clj a :cljs b :default c) — select form by platform key.
    /// True if `v` is a (with-meta target meta) list produced by readMeta.
    fn isWithMetaForm(v: Value, gc: *GC) bool {
        if (!(v.isObj() and v.asObj().kind == .list)) return false;
        const items = v.asObj().data.list.items.items;
        if (items.len != 3) return false;
        if (!items[0].isSymbol()) return false;
        return std.mem.eql(u8, gc.getString(items[0].asSymbolId()), "with-meta");
    }

    /// Which ObjKinds can safely carry metadata via `obj.meta`.
    fn canHoldMeta(kind: @import("value.zig").ObjKind) bool {
        return switch (kind) {
            .list, .vector, .map, .set, .function, .macro_fn => true,
            else => false,
        };
    }

    /// #?@(:clj [x y])              — splice sequence into surrounding list/vector.
    /// Current platform set: :nanoclj, :clj, :default.
    /// No match → returns skip-sentinel symbol that list/vector loops drop.
    /// Splicing match → returns list with splice-sentinel head that the parent inlines.
    fn readReaderConditional(self: *Reader) ReadError!Value {
        self.pos += 1; // skip '?'
        if (self.pos >= self.src.len) return error.UnexpectedEOF;
        var splicing = false;
        if (self.src[self.pos] == '@') {
            splicing = true;
            self.pos += 1;
            if (self.pos >= self.src.len) return error.UnexpectedEOF;
        }
        self.skipWhitespace();
        if (self.pos >= self.src.len or self.src[self.pos] != '(') return error.UnexpectedChar;
        // Read body as a plain list of alternating keyword/form pairs.
        const body = try self.readList();
        if (!body.isObj() or body.asObj().kind != .list) return error.UnexpectedChar;
        const items = body.asObj().data.list.items.items;

        // Prioritized platform matching: :nanoclj (primary) > :clj > :default.
        // Scan each priority across all pairs so a later :nanoclj beats an earlier :clj.
        const priorities = [_][]const u8{ "nanoclj", "clj", "default" };
        for (priorities) |want| {
            var i: usize = 0;
            while (i + 1 < items.len) : (i += 2) {
                const k = items[i];
                if (!k.isKeyword()) return error.UnexpectedChar;
                const name = self.gc.getString(k.asKeywordId());
                if (!std.mem.eql(u8, name, want)) continue;
                const form = items[i + 1];
                if (!splicing) return form;
                // Splicing: wrap the form's children in a splice-sentinel list.
                if (!form.isObj() or (form.asObj().kind != .list and form.asObj().kind != .vector)) {
                    return error.UnexpectedChar;
                }
                const child_items = switch (form.asObj().kind) {
                    .list => form.asObj().data.list.items.items,
                    .vector => form.asObj().data.vector.items.items,
                    else => unreachable,
                };
                const wrap = self.gc.allocObj(.list) catch return error.OutOfMemory;
                const marker_id = self.gc.internString(SPLICE_SENTINEL_NAME) catch return error.OutOfMemory;
                wrap.data.list.items.append(self.gc.allocator, Value.makeSymbol(marker_id)) catch return error.OutOfMemory;
                for (child_items) |ci| {
                    wrap.data.list.items.append(self.gc.allocator, ci) catch return error.OutOfMemory;
                }
                return Value.makeObj(wrap);
            }
        }
        // No match: produce skip sentinel; list/vector loops ignore it.
        const skip_id = self.gc.internString(SKIP_SENTINEL_NAME) catch return error.OutOfMemory;
        return Value.makeSymbol(skip_id);
    }

    /// #"pattern" => (re-pattern "pattern")
    fn readRegex(self: *Reader) ReadError!Value {
        // Read the string content (readString handles the opening ")
        const str_val = try self.readString();
        // Wrap as (re-pattern "...")
        const re_sym = self.gc.internString("re-pattern") catch return error.OutOfMemory;
        const obj = self.gc.allocObj(.list) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, Value.makeSymbol(re_sym)) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, str_val) catch return error.OutOfMemory;
        return Value.makeObj(obj);
    }

    /// #(...) => (fn* [%1 %2 ...] (...))
    /// Scans body for %, %1-%9, %&; builds param vector automatically.
    fn readAnonFn(self: *Reader) ReadError!Value {
        // Read the body list (reusing readList which consumes '(' .. ')')
        const body = try self.readList();
        // Scan body for % references to determine arity
        var max_arg: u8 = 0;
        var has_rest = false;
        self.scanPercents(body, &max_arg, &has_rest);
        // Rewrite bare % → %1 in the body
        if (max_arg >= 1) self.rewriteBarePercent(body);
        // Build params vector: [%1 %2 ... %N] or [%1 ... %N & %&]
        const params_obj = self.gc.allocObj(.vector) catch return error.OutOfMemory;
        var i: u8 = 1;
        while (i <= max_arg) : (i += 1) {
            var name_buf: [3]u8 = undefined;
            name_buf[0] = '%';
            name_buf[1] = '0' + i;
            const id = self.gc.internString(name_buf[0..2]) catch return error.OutOfMemory;
            params_obj.data.vector.items.append(self.gc.allocator, Value.makeSymbol(id)) catch return error.OutOfMemory;
        }
        if (has_rest) {
            const amp_id = self.gc.internString("&") catch return error.OutOfMemory;
            params_obj.data.vector.items.append(self.gc.allocator, Value.makeSymbol(amp_id)) catch return error.OutOfMemory;
            const rest_id = self.gc.internString("%&") catch return error.OutOfMemory;
            params_obj.data.vector.items.append(self.gc.allocator, Value.makeSymbol(rest_id)) catch return error.OutOfMemory;
        }
        // Build (fn* [params] body)
        const fn_list = self.gc.allocObj(.list) catch return error.OutOfMemory;
        const fn_sym = self.gc.internString("fn*") catch return error.OutOfMemory;
        fn_list.data.list.items.append(self.gc.allocator, Value.makeSymbol(fn_sym)) catch return error.OutOfMemory;
        fn_list.data.list.items.append(self.gc.allocator, Value.makeObj(params_obj)) catch return error.OutOfMemory;
        fn_list.data.list.items.append(self.gc.allocator, body) catch return error.OutOfMemory;
        return Value.makeObj(fn_list);
    }

    fn rewriteBarePercent(self: *Reader, val: Value) void {
        if (!val.isObj()) return;
        const obj = val.asObj();
        var items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return,
        };
        for (items, 0..) |item, idx| {
            if (item.isSymbol()) {
                const name = self.gc.getString(item.asSymbolId());
                if (name.len == 1 and name[0] == '%') {
                    const id = self.gc.internString("%1") catch return;
                    items[idx] = Value.makeSymbol(id);
                }
            } else {
                self.rewriteBarePercent(item);
            }
        }
    }

    fn scanPercents(self: *Reader, val: Value, max_arg: *u8, has_rest: *bool) void {
        if (val.isSymbol()) {
            const gc = self.gc;
            const name = gc.getString(val.asSymbolId());
            if (name.len == 1 and name[0] == '%') {
                if (max_arg.* < 1) max_arg.* = 1;
            } else if (name.len == 2 and name[0] == '%') {
                if (name[1] == '&') {
                    has_rest.* = true;
                } else if (name[1] >= '1' and name[1] <= '9') {
                    const n = name[1] - '0';
                    if (n > max_arg.*) max_arg.* = n;
                }
            }
            return;
        }
        if (!val.isObj()) return;
        const obj = val.asObj();
        const items = switch (obj.kind) {
            .list => obj.data.list.items.items,
            .vector => obj.data.vector.items.items,
            else => return,
        };
        for (items) |item| self.scanPercents(item, max_arg, has_rest);
    }

    /// #{...} => set literal
    fn readSet(self: *Reader) ReadError!Value {
        self.depth += 1;
        if (self.depth > MAX_READ_DEPTH) return error.UnexpectedChar;
        defer self.depth -= 1;
        self.pos += 1; // skip {
        const obj = self.gc.allocObj(.set) catch return error.OutOfMemory;
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.UnexpectedEOF;
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                return Value.makeObj(obj);
            }
            const v = try self.readForm();
            obj.data.set.items.append(self.gc.allocator, v) catch return error.OutOfMemory;
        }
    }

    fn readString(self: *Reader) ReadError!Value {
        self.pos += 1; // skip opening "
        var buf = compat.emptyList(u8);
        defer buf.deinit(self.gc.allocator);
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                const id = self.gc.internString(buf.items) catch return error.OutOfMemory;
                return Value.makeString(id);
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.UnexpectedEOF;
                const esc = self.src[self.pos];
                const actual: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    else => esc,
                };
                buf.append(self.gc.allocator, actual) catch return error.OutOfMemory;
            } else {
                buf.append(self.gc.allocator, c) catch return error.OutOfMemory;
            }
            self.pos += 1;
        }
        return error.UnexpectedEOF;
    }

    fn readCharLiteral(self: *Reader) ReadError!Value {
        self.pos += 1; // skip backslash
        if (self.pos >= self.src.len) return error.UnexpectedEOF;
        const start = self.pos;
        // Check for named characters (space, newline, tab, etc.)
        if (std.ascii.isAlphabetic(self.src[self.pos])) {
            while (self.pos < self.src.len and std.ascii.isAlphabetic(self.src[self.pos])) self.pos += 1;
            const name = self.src[start..self.pos];
            if (name.len == 1) {
                // Single alpha char: \a, \b, etc.
                const id = self.gc.internString(name) catch return error.OutOfMemory;
                return Value.makeString(id);
            }
            const ch: u8 = if (std.mem.eql(u8, name, "space")) ' '
                else if (std.mem.eql(u8, name, "newline")) '\n'
                else if (std.mem.eql(u8, name, "tab")) '\t'
                else if (std.mem.eql(u8, name, "return")) '\r'
                else if (std.mem.eql(u8, name, "backspace")) 8
                else if (std.mem.eql(u8, name, "formfeed")) 12
                else return error.UnexpectedChar;
            const buf = [_]u8{ch};
            const id = self.gc.internString(&buf) catch return error.OutOfMemory;
            return Value.makeString(id);
        }
        // Single non-alpha char: \(, \), \[, \], \{, \}, etc.
        const buf = [_]u8{self.src[self.pos]};
        self.pos += 1;
        const id = self.gc.internString(&buf) catch return error.OutOfMemory;
        return Value.makeString(id);
    }

    fn readKeyword(self: *Reader) ReadError!Value {
        self.pos += 1; // skip :
        const start = self.pos;
        while (self.pos < self.src.len and isSymChar(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) return error.UnexpectedChar;
        const id = self.gc.internString(self.src[start..self.pos]) catch return error.OutOfMemory;
        return Value.makeKeyword(id);
    }

    fn readAtom(self: *Reader) ReadError!Value {
        const start = self.pos;
        // Handle negative numbers
        if (self.src[self.pos] == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
            self.pos += 1;
        }
        if (std.ascii.isDigit(self.src[self.pos])) {
            return self.readNumber(start);
        }
        // Symbol
        while (self.pos < self.src.len and isSymChar(self.src[self.pos])) self.pos += 1;
        const token = self.src[start..self.pos];
        if (token.len == 0) return error.UnexpectedChar;

        if (std.mem.eql(u8, token, "nil")) return Value.makeNil();
        if (std.mem.eql(u8, token, "true")) return Value.makeBool(true);
        if (std.mem.eql(u8, token, "false")) return Value.makeBool(false);

        const id = self.gc.internString(token) catch return error.OutOfMemory;
        return Value.makeSymbol(id);
    }

    fn readNumber(self: *Reader, start: usize) ReadError!Value {
        var is_float = false;
        while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) {
            if (self.src[self.pos] == '.') is_float = true;
            self.pos += 1;
        }
        const token = self.src[start..self.pos];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, token) catch return error.InvalidNumber;
            return Value.makeFloat(f);
        } else {
            const i = std.fmt.parseInt(i48, token, 10) catch return error.InvalidNumber;
            return Value.makeInt(i);
        }
    }

    fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',') {
                if (c == '\n') {
                    self.line += 1;
                    self.col = 1;
                } else {
                    self.col += 1;
                }
                self.pos += 1;
            } else break;
        }
    }

    fn isSymChar(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', ',', '(', ')', '[', ']', '{', '}', '"', ';' => false,
            else => c > 32 and c < 127,
        };
    }

    pub fn atEnd(self: *Reader) bool {
        self.skipWhitespace();
        return self.pos >= self.src.len;
    }
};

test "read basic forms" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("(+ 1 2)", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isObj());
    try std.testing.expect(v.asObj().kind == .list);
    try std.testing.expectEqual(@as(usize, 3), v.asObj().data.list.items.items.len);
}

test "read vector" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("[1 2 3]", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.asObj().kind == .vector);
    try std.testing.expectEqual(@as(usize, 3), v.asObj().data.vector.items.items.len);
}

test "read string" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("\"hello world\"", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isString());
    try std.testing.expectEqualStrings("hello world", gc.getString(v.asStringId()));
}

test "read #() anonymous fn" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // #(+ %1 %2) => (fn* [%1 %2] (+ %1 %2))
    var r = Reader.init("#(+ %1 %2)", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isObj());
    const items = v.asObj().data.list.items.items;
    // First item should be fn* symbol
    try std.testing.expect(items[0].isSymbol());
    try std.testing.expectEqualStrings("fn*", gc.getString(items[0].asSymbolId()));
    // Second item should be params vector [%1 %2]
    try std.testing.expect(items[1].isObj());
    try std.testing.expectEqual(@as(usize, 2), items[1].asObj().data.vector.items.items.len);
    // Third item should be body (+ %1 %2)
    try std.testing.expect(items[2].isObj());
}

test "read #() bare percent" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // #(inc %) => (fn* [%1] (inc %1))
    var r = Reader.init("#(inc %)", &gc);
    const v = try r.readForm();
    const items = v.asObj().data.list.items.items;
    // Params should be [%1]
    const params = items[1].asObj().data.vector.items.items;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("%1", gc.getString(params[0].asSymbolId()));
    // Body: bare % rewritten to %1
    const body = items[2].asObj().data.list.items.items;
    try std.testing.expectEqualStrings("%1", gc.getString(body[1].asSymbolId()));
}

test "read #{} set literal" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("#{1 2 3}", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isObj());
    try std.testing.expect(v.asObj().kind == .set);
    try std.testing.expectEqual(@as(usize, 3), v.asObj().data.set.items.items.len);
}

test "read #_ discard" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("#_foo bar", &gc);
    const v = try r.readForm();
    // Should return bar (foo is discarded)
    try std.testing.expect(v.isSymbol());
    try std.testing.expectEqualStrings("bar", gc.getString(v.asSymbolId()));
}

test "read #? selects :nanoclj" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("#?(:clj 1 :nanoclj 2 :default 3)", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isInt());
    try std.testing.expectEqual(@as(i48, 2), v.asInt());
}

test "read #? no match inside list is discarded" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("(1 #?(:cljs x) 2)", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isObj());
    try std.testing.expect(v.asObj().kind == .list);
    const items = v.asObj().data.list.items.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i48, 1), items[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), items[1].asInt());
}

test "read #?@ splices into vector" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("[1 #?@(:nanoclj [2 3]) 4]", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isObj());
    try std.testing.expect(v.asObj().kind == .vector);
    const items = v.asObj().data.vector.items.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqual(@as(i48, 1), items[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), items[1].asInt());
    try std.testing.expectEqual(@as(i48, 3), items[2].asInt());
    try std.testing.expectEqual(@as(i48, 4), items[3].asInt());
}

test "read #? top-level no-match returns skip sentinel" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("#?(:cljs 1)", &gc);
    const v = try r.readForm();
    try std.testing.expect(isSkipSentinel(&gc, v));
}

test "read #? :clj also matches" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("#?(:clj 42)", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isInt());
    try std.testing.expectEqual(@as(i48, 42), v.asInt());
}

test "read #?@ splices inside list" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("(a #?@(:nanoclj [b c]) d)", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.asObj().kind == .list);
    const items = v.asObj().data.list.items.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
}

// --- Type-hint metadata tests --------------------------------------------

/// Extract effective meta map from a reader result regardless of whether
/// meta was attached directly (heap obj) or wrapped in (with-meta ...).
fn extractMeta(v: Value, gc: *GC) ?*@import("value.zig").Obj {
    if (!v.isObj()) return null;
    if (v.asObj().meta) |m| return m;
    if (v.asObj().kind == .list) {
        const items = v.asObj().data.list.items.items;
        if (items.len == 3 and items[0].isSymbol()
            and std.mem.eql(u8, gc.getString(items[0].asSymbolId()), "with-meta"))
        {
            if (items[2].isObj() and items[2].asObj().kind == .map) {
                return items[2].asObj();
            }
        }
    }
    return null;
}

fn metaLookupKeyword(m: *@import("value.zig").Obj, gc: *GC, name: []const u8) ?Value {
    for (m.data.map.keys.items, 0..) |k, i| {
        if (k.isKeyword() and std.mem.eql(u8, gc.getString(k.asKeywordId()), name)) {
            return m.data.map.vals.items[i];
        }
    }
    return null;
}

test "type hint: ^:dynamic *x* attaches {:dynamic true}" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("^:dynamic *x*", &gc);
    const v = try r.readForm();
    const m = extractMeta(v, &gc) orelse return error.TestExpectedEqual;
    const dyn = metaLookupKeyword(m, &gc, "dynamic") orelse return error.TestExpectedEqual;
    try std.testing.expect(dyn.isBool());
    try std.testing.expect(dyn.asBool());
}

test "type hint: ^String s attaches {:tag String}" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("^String s", &gc);
    const v = try r.readForm();
    const m = extractMeta(v, &gc) orelse return error.TestExpectedEqual;
    const tag = metaLookupKeyword(m, &gc, "tag") orelse return error.TestExpectedEqual;
    try std.testing.expect(tag.isSymbol());
    try std.testing.expectEqualStrings("String", gc.getString(tag.asSymbolId()));
}

test "type hint: ^\"String\" s attaches {:tag \"String\"}" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("^\"String\" s", &gc);
    const v = try r.readForm();
    const m = extractMeta(v, &gc) orelse return error.TestExpectedEqual;
    const tag = metaLookupKeyword(m, &gc, "tag") orelse return error.TestExpectedEqual;
    try std.testing.expect(tag.isString());
    try std.testing.expectEqualStrings("String", gc.getString(tag.asStringId()));
}

test "type hint: ^{:doc \"d\" :tag Long} v attaches full map" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("^{:doc \"d\" :tag Long} v", &gc);
    const v = try r.readForm();
    const m = extractMeta(v, &gc) orelse return error.TestExpectedEqual;
    const doc = metaLookupKeyword(m, &gc, "doc") orelse return error.TestExpectedEqual;
    try std.testing.expect(doc.isString());
    const tag = metaLookupKeyword(m, &gc, "tag") orelse return error.TestExpectedEqual;
    try std.testing.expect(tag.isSymbol());
}

test "type hint: heap target (vector) has meta attached directly" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var r = Reader.init("^:const [1 2 3]", &gc);
    const v = try r.readForm();
    try std.testing.expect(v.isObj());
    try std.testing.expect(v.asObj().kind == .vector);
    const m = v.asObj().meta orelse return error.TestExpectedEqual;
    const c = metaLookupKeyword(m, &gc, "const") orelse return error.TestExpectedEqual;
    try std.testing.expect(c.isBool());
    try std.testing.expect(c.asBool());
}

test "type hint: stacked ^ merges, outermost wins on collision" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Outer ^{:tag Long} should win over inner ^{:tag String}; :private flows in.
    var r = Reader.init("^{:tag Long} ^:private ^{:tag String} x", &gc);
    const v = try r.readForm();
    const m = extractMeta(v, &gc) orelse return error.TestExpectedEqual;
    const tag = metaLookupKeyword(m, &gc, "tag") orelse return error.TestExpectedEqual;
    try std.testing.expect(tag.isSymbol());
    try std.testing.expectEqualStrings("Long", gc.getString(tag.asSymbolId()));
    const priv = metaLookupKeyword(m, &gc, "private") orelse return error.TestExpectedEqual;
    try std.testing.expect(priv.isBool());
    try std.testing.expect(priv.asBool());
}
