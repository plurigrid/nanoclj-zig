const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const gc_mod = @import("gc.zig");
const GC = gc_mod.GC;

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

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    gc: *GC,

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
            '"' => self.readString(),
            ':' => self.readKeyword(),
            ';' => {
                // skip comment
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                return self.readForm();
            },
            else => self.readAtom(),
        };
    }

    fn readList(self: *Reader) ReadError!Value {
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

    fn readString(self: *Reader) ReadError!Value {
        self.pos += 1; // skip opening "
        var buf = std.ArrayListUnmanaged(u8){};
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
