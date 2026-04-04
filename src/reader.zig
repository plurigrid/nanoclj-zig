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

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    gc: *GC,
    depth: u32 = 0, // CVE-3 fix: track nesting depth

    pub fn init(src: []const u8, gc: *GC) Reader {
        return .{ .src = src, .gc = gc };
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
        self.pos += 1; // skip (
        const obj = self.gc.allocObj(.list) catch return error.OutOfMemory;
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.UnexpectedEOF;
            if (self.src[self.pos] == ')') {
                self.pos += 1;
                return Value.makeObj(obj);
            }
            const v = try self.readForm();
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
            const k = try self.readForm();
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

    /// ^meta form → (with-meta form meta)
    /// ^{:k v} form, ^:keyword form → {:keyword true}, ^Type form → {:tag Type}
    fn readMeta(self: *Reader) ReadError!Value {
        self.pos += 1; // skip ^
        // Read the metadata
        const meta_val = try self.readForm();
        // Read the target form
        const target = try self.readForm();
        // Normalize metadata:
        // - map → use as-is
        // - keyword → {:keyword true}
        // - symbol → {:tag symbol}
        var meta_map: Value = undefined;
        if (meta_val.isObj() and meta_val.asObj().kind == .map) {
            meta_map = meta_val;
        } else if (meta_val.isKeyword()) {
            const m = self.gc.allocObj(.map) catch return error.OutOfMemory;
            m.data.map.keys.append(self.gc.allocator, meta_val) catch return error.OutOfMemory;
            m.data.map.vals.append(self.gc.allocator, Value.makeBool(true)) catch return error.OutOfMemory;
            meta_map = Value.makeObj(m);
        } else if (meta_val.isSymbol()) {
            const m = self.gc.allocObj(.map) catch return error.OutOfMemory;
            const tag_kw = self.gc.internString("tag") catch return error.OutOfMemory;
            m.data.map.keys.append(self.gc.allocator, Value.makeKeyword(tag_kw)) catch return error.OutOfMemory;
            m.data.map.vals.append(self.gc.allocator, meta_val) catch return error.OutOfMemory;
            meta_map = Value.makeObj(m);
        } else {
            meta_map = meta_val; // fallback
        }
        // Build (with-meta target meta-map)
        const wm_sym = self.gc.internString("with-meta") catch return error.OutOfMemory;
        const obj = self.gc.allocObj(.list) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, Value.makeSymbol(wm_sym)) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, target) catch return error.OutOfMemory;
        obj.data.list.items.append(self.gc.allocator, meta_map) catch return error.OutOfMemory;
        return Value.makeObj(obj);
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
