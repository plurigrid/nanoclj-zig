//! NREPL: Superstructure over classic nREPL.
//!
//! Standard nREPL protocol (bencode over TCP) with extensions:
//!   - Color identity: each session gets a deterministic RGB from SplitMix64
//!   - Trit phase: every eval response includes GF(3) phase of the session
//!   - Hyperreal timestamps: eval timing in standard + infinitesimal parts
//!   - .nrepl-port file: written on start, deleted on stop (standard discovery)
//!   - Port allocation: color-entropy deconfliction via time_units.nreplPortFromPath
//!
//! Ops: eval, clone, close, describe, ls-sessions, interrupt, completions, lookup, load-file, stdin
//!
//! Architecture:
//!   Server thread → accept loop → per-connection thread → read bencode → dispatch op
//!   Each session has: own Env (child of root), own GC arena, trit accumulator, color

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const transduction = @import("transduction.zig");
const transclusion = @import("transclusion.zig");
const Domain = transclusion.Domain;
const printer = @import("printer.zig");
const reader_mod = @import("reader.zig");
const bencode = @import("bencode.zig");
const substrate = @import("substrate.zig");
const time_units = @import("time_units.zig");
const transitivity = @import("transitivity.zig");
const plural = @import("plural.zig");
const colorspace = @import("colorspace.zig");

// ============================================================================
// C SOCKET CONSTANTS (macOS/Darwin)
// ============================================================================

const sys = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});
const fd_t = std.c.fd_t;

// ============================================================================
// SESSION
// ============================================================================

pub const Session = struct {
    id: [32]u8, // hex UUID
    id_len: u8,
    env: Env,
    gc: GC,
    /// GF(3) trit accumulator — tracks conservation across evals
    trit_balance: i8 = 0,
    /// Eval counter (monotonic)
    eval_count: u64 = 0,
    /// Color identity (deterministic from session ID)
    color: substrate.Color,
    /// OKLAB color — perceptual identity, zero-copy stamped onto eval results
    oklab: colorspace.Color = .{},
    /// Cancel flag — checked in eval fuel loop
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// *1, *2, *3 history
    history: [3]Value = .{ Value.makeNil(), Value.makeNil(), Value.makeNil() },
    /// Current namespace name
    ns: []const u8 = "user",

    pub fn init(allocator: std.mem.Allocator, root_env: *Env, id_seed: u64) Session {
        var id_buf: [32]u8 = undefined;
        // Generate hex ID from seed
        const hash = substrate.mix64(id_seed);
        const hash2 = substrate.mix64(hash);
        const id_slice = std.fmt.bufPrint(&id_buf, "{x:0>16}{x:0>16}", .{ hash, hash2 }) catch &id_buf;
        _ = id_slice;

        var session = Session{
            .id = id_buf,
            .id_len = 32,
            .env = Env.init(allocator, root_env),
            .gc = GC.init(allocator),
            .color = substrate.colorAt(substrate.CANONICAL_SEED, hash % 65536),
        };
        // Derive OKLAB from substrate RGB — zero-copy color identity
        session.oklab = colorspace.Color.fromSRGB(session.color.r, session.color.g, session.color.b);
        // Mark as child env
        session.env.is_root = false;
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.env.deinit();
        self.gc.deinit();
    }

    pub fn idSlice(self: *const Session) []const u8 {
        return self.id[0..self.id_len];
    }

    /// Accumulate GF(3) trit from an eval result
    pub fn accumulateTrit(self: *Session, val: Value) void {
        const t = transitivity.valueTrit(val);
        self.trit_balance = @intCast(@mod(@as(i16, self.trit_balance) + @as(i16, t) + 3, 3));
    }

    /// Rotate history: *3 ← *2, *2 ← *1, *1 ← new
    pub fn pushHistory(self: *Session, val: Value) void {
        self.history[2] = self.history[1];
        self.history[1] = self.history[0];
        self.history[0] = val;
    }
};

// ============================================================================
// SERVER
// ============================================================================

pub const Server = struct {
    allocator: std.mem.Allocator,
    root_env: *Env,
    root_gc: *GC,
    sessions: std.StringHashMap(*Session),
    port: u16,
    listen_fd: ?std.posix.fd_t = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: ?std.Thread = null,
    /// Seed for session ID generation (monotonic)
    session_seed: u64 = 0,
    mutex: compat.Mutex = .{},
    /// Path to .nrepl-port file (for discovery)
    port_file_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, root_env: *Env, root_gc: *GC, port: u16) Server {
        return .{
            .allocator = allocator,
            .root_env = root_env,
            .root_gc = root_gc,
            .sessions = std.StringHashMap(*Session).init(allocator),
            .port = port,
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        var it = self.sessions.valueIterator();
        while (it.next()) |session_ptr| {
            session_ptr.*.deinit();
            self.allocator.destroy(session_ptr.*);
        }
        self.sessions.deinit();
    }

    /// Start listening. Writes .nrepl-port file for discovery.
    pub fn start(self: *Server) !void {
        if (self.running.load(.acquire)) return;

        // Create socket via C API
        const raw_fd = sys.socket(sys.AF_INET, sys.SOCK_STREAM, 0);
        if (raw_fd < 0) return error.SocketCreateFailed;
        const sock_fd: fd_t = raw_fd;
        errdefer _ = sys.close(sock_fd);

        // SO_REUSEADDR
        const optval: c_int = 1;
        _ = sys.setsockopt(sock_fd, sys.SOL_SOCKET, sys.SO_REUSEADDR, &optval, @sizeOf(c_int));

        // Bind
        var addr: sys.sockaddr_in = std.mem.zeroes(sys.sockaddr_in);
        addr.sin_family = sys.AF_INET;
        addr.sin_port = std.mem.nativeToBig(u16, self.port);
        addr.sin_addr.s_addr = sys.INADDR_ANY;
        if (sys.bind(sock_fd, @ptrCast(&addr), @sizeOf(sys.sockaddr_in)) < 0)
            return error.BindFailed;

        // Listen
        if (sys.listen(sock_fd, 8) < 0)
            return error.ListenFailed;

        self.listen_fd = sock_fd;
        self.running.store(true, .release);

        // Write .nrepl-port
        self.writePortFile();

        // Create default session
        _ = try self.createSession();

        // Accept thread
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *Server) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);

        // Close listen socket to unblock accept
        if (self.listen_fd) |sock_fd| {
            _ = sys.close(sock_fd);
            self.listen_fd = null;
        }

        // Remove .nrepl-port file
        self.removePortFile();

        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
    }

    fn writePortFile(self: *Server) void {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{self.port}) catch return;
        const fd = sys.open(".nrepl-port", sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, @as(sys.mode_t, 0o644));
        if (fd < 0) return;
        defer _ = sys.close(fd);
        _ = sys.write(fd, s.ptr, s.len);
        self.port_file_path = ".nrepl-port";
    }

    fn removePortFile(self: *Server) void {
        if (self.port_file_path) |_| {
            _ = sys.unlink(".nrepl-port");
            self.port_file_path = null;
        }
    }

    pub fn createSession(self: *Server) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session_seed +%= substrate.GOLDEN;
        const session = try self.allocator.create(Session);
        session.* = Session.init(self.allocator, self.root_env, self.session_seed);
        const id = try self.allocator.dupe(u8, session.idSlice());
        try self.sessions.put(id, session);
        return id;
    }

    pub fn getSession(self: *Server, id: []const u8) ?*Session {
        return self.sessions.get(id);
    }

    pub fn closeSession(self: *Server, id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sessions.fetchRemove(id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }
    }
};

// ============================================================================
// ACCEPT LOOP
// ============================================================================

fn acceptLoop(server: *Server) void {
    while (server.running.load(.acquire)) {
        const sock_fd = server.listen_fd orelse return;
        var client_addr: sys.sockaddr_in = std.mem.zeroes(sys.sockaddr_in);
        var addr_len: sys.socklen_t = @sizeOf(sys.sockaddr_in);
        const client_fd = sys.accept(sock_fd, @ptrCast(&client_addr), &addr_len);
        if (client_fd < 0) {
            if (!server.running.load(.acquire)) return; // shutdown
            continue;
        }
        // Spawn per-connection handler
        _ = std.Thread.spawn(.{}, connectionHandler, .{ server, client_fd }) catch {
            _ = sys.close(client_fd);
            continue;
        };
    }
}

// ============================================================================
// CONNECTION HANDLER
// ============================================================================

fn connectionHandler(server: *Server, conn_fd: fd_t) void {
    defer _ = sys.close(conn_fd);
    var recv_buf: [65536]u8 = undefined;
    var accum = compat.emptyList(u8);
    defer accum.deinit(server.allocator);

    while (server.running.load(.acquire)) {
        const rc = sys.read(conn_fd, &recv_buf, recv_buf.len);
        if (rc <= 0) break; // client closed or error
        const n: usize = @intCast(rc);
        accum.appendSlice(server.allocator, recv_buf[0..n]) catch break;

        // Try to decode complete bencode messages
        while (accum.items.len > 0) {
            const result = bencode.decode(accum.items, server.allocator) catch break;
            const msg = result.val;
            const consumed = result.consumed;

            // Dispatch — may send multiple responses (eval sends out/value/done)
            dispatch(server, msg, conn_fd) catch break;

            // Remove consumed bytes
            if (consumed >= accum.items.len) {
                accum.clearRetainingCapacity();
            } else {
                std.mem.copyForwards(u8, accum.items[0..], accum.items[consumed..]);
                accum.shrinkRetainingCapacity(accum.items.len - consumed);
            }
        }
    }
}

fn writeFd(write_fd: fd_t, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = sys.write(write_fd, data.ptr + written, data.len - written);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

/// Encode and send a single bencode response on a connection fd.
fn sendResponse(conn_fd: fd_t, response: bencode.BValue, allocator: std.mem.Allocator) void {
    var send_buf = compat.emptyList(u8);
    defer send_buf.deinit(allocator);
    bencode.encode(response, &send_buf, allocator) catch return;
    writeFd(conn_fd, send_buf.items);
}

// ============================================================================
// OP DISPATCH
// ============================================================================

fn dispatch(server: *Server, msg: bencode.BValue, conn_fd: fd_t) !void {
    const op = msg.dictGetStr("op") orelse {
        sendResponse(conn_fd, try makeErrorResponse(server.allocator, "unknown", "no-op", "Missing op field"), server.allocator);
        return;
    };
    const session_id = msg.dictGetStr("session");
    const msg_id = msg.dictGetStr("id") orelse "unknown";

    if (std.mem.eql(u8, op, "clone")) {
        sendResponse(conn_fd, try opClone(server, msg, session_id, msg_id), server.allocator);
    } else if (std.mem.eql(u8, op, "close")) {
        sendResponse(conn_fd, try opClose(server, session_id, msg_id), server.allocator);
    } else if (std.mem.eql(u8, op, "describe")) {
        sendResponse(conn_fd, try opDescribe(server, msg_id), server.allocator);
    } else if (std.mem.eql(u8, op, "ls-sessions")) {
        sendResponse(conn_fd, try opLsSessions(server, msg_id), server.allocator);
    } else if (std.mem.eql(u8, op, "eval")) {
        // eval sends multiple messages: out (if any), value, done
        try opEval(server, msg, session_id, msg_id, conn_fd);
    } else if (std.mem.eql(u8, op, "interrupt")) {
        sendResponse(conn_fd, try opInterrupt(server, session_id, msg_id), server.allocator);
    } else if (std.mem.eql(u8, op, "completions")) {
        sendResponse(conn_fd, try opCompletions(server, msg, session_id, msg_id), server.allocator);
    } else if (std.mem.eql(u8, op, "lookup")) {
        sendResponse(conn_fd, try opLookup(server, msg, session_id, msg_id), server.allocator);
    } else if (std.mem.eql(u8, op, "load-file")) {
        try opLoadFile(server, msg, session_id, msg_id, conn_fd);
    } else if (std.mem.eql(u8, op, "stdin")) {
        sendResponse(conn_fd, try opStdin(server, session_id, msg_id), server.allocator);
    } else {
        sendResponse(conn_fd, try makeErrorResponse(server.allocator, session_id orelse "", msg_id, "Unknown op"), server.allocator);
    }
}

// ============================================================================
// OPS
// ============================================================================

fn opClone(server: *Server, msg: bencode.BValue, parent_id: ?[]const u8, msg_id: []const u8) !bencode.BValue {
    _ = parent_id; // TODO: clone from parent session bindings
    _ = msg; // client-info available via msg.dictGet("client-info") for future use
    const new_id = try server.createSession();
    const session = server.getSession(new_id).?;
    return try bencode.makeDict(server.allocator, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "new-session", bencode.makeStr(new_id) },
        .{ "status", statusDone(server.allocator) },
        .{ "x-color-b", bencode.makeInt(@intCast(session.color.b)) },
        .{ "x-color-g", bencode.makeInt(@intCast(session.color.g)) },
        .{ "x-color-r", bencode.makeInt(@intCast(session.color.r)) },
    });
}

/// Build status ["done"] list — used by every response.
fn statusDone(allocator: std.mem.Allocator) bencode.BValue {
    return bencode.BValue{ .list = allocator.dupe(bencode.BValue, &.{bencode.makeStr("done")}) catch &.{} };
}

fn statusList(allocator: std.mem.Allocator, items: []const []const u8) bencode.BValue {
    const vals = allocator.alloc(bencode.BValue, items.len) catch return bencode.BValue{ .list = &.{} };
    for (items, 0..) |s, i| vals[i] = bencode.makeStr(s);
    return bencode.BValue{ .list = vals };
}

fn makeErrorResponse(allocator: std.mem.Allocator, sid: []const u8, msg_id: []const u8, err_msg: []const u8) !bencode.BValue {
    return try bencode.makeDict(allocator, &.{
        .{ "err", bencode.makeStr(err_msg) },
        .{ "id", bencode.makeStr(msg_id) },
        .{ "session", bencode.makeStr(sid) },
        .{ "status", statusList(allocator, &.{ "done", "error", "unknown-op" }) },
    });
}

fn opClose(server: *Server, session_id: ?[]const u8, msg_id: []const u8) !bencode.BValue {
    if (session_id) |sid| server.closeSession(sid);
    return try bencode.makeDict(server.allocator, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "session", bencode.makeStr(session_id orelse "") },
        .{ "status", statusList(server.allocator, &.{ "done", "session-closed" }) },
    });
}

fn opDescribe(server: *Server, msg_id: []const u8) !bencode.BValue {
    const a = server.allocator;
    const empty = try bencode.makeDict(a, &.{});
    const vs_jvm = plural.morphism(.nanoclj_zig_current, .jvm);
    return try bencode.makeDict(a, &.{
        .{ "aux", try bencode.makeDict(a, &.{
            .{ "behavior-vs-jvm", bencode.makeStr(vs_jvm.kind.label()) },
            .{ "bounded-eval", bencode.makeStr("enabled") },
            .{ "current-ns", bencode.makeStr("user") },
            .{ "time-tower", bencode.makeStr("time-ref(×5)→glimpse(×3)→trice(×5)→trit-tick") },
        }) },
        .{ "encoding", try bencode.makeDict(a, &.{
            .{ "default", bencode.makeStr("bencode") },
        }) },
        .{ "id", bencode.makeStr(msg_id) },
        .{ "ops", try bencode.makeDict(a, &.{
            .{ "clone", empty },
            .{ "close", empty },
            .{ "completions", empty },
            .{ "describe", empty },
            .{ "eval", empty },
            .{ "interrupt", empty },
            .{ "load-file", empty },
            .{ "lookup", empty },
            .{ "ls-sessions", empty },
            .{ "stdin", empty },
        }) },
        .{ "status", statusDone(a) },
        .{ "versions", try bencode.makeDict(a, &.{
            .{ "nanoclj-zig", try bencode.makeDict(a, &.{
                .{ "flick", bencode.makeInt(@intCast(time_units.FLICK)) },
                .{ "glimpse", bencode.makeInt(@intCast(time_units.GLIMPSE)) },
                .{ "trice", bencode.makeInt(@intCast(time_units.TRICE)) },
                .{ "trit-tick", bencode.makeInt(@intCast(time_units.TRIT_TICK)) },
                .{ "version-string", bencode.makeStr("0.1.0") },
            }) },
            .{ "nrepl", try bencode.makeDict(a, &.{
                .{ "major", bencode.makeInt(1) },
                .{ "minor", bencode.makeInt(3) },
                .{ "incremental", bencode.makeInt(0) },
                .{ "version-string", bencode.makeStr("1.3.0") },
            }) },
        }) },
    });
}

fn opLsSessions(server: *Server, msg_id: []const u8) !bencode.BValue {
    server.mutex.lock();
    defer server.mutex.unlock();
    var ids = compat.emptyList(bencode.BValue);
    var it = server.sessions.keyIterator();
    while (it.next()) |key| {
        try ids.append(server.allocator, bencode.makeStr(key.*));
    }
    return try bencode.makeDict(server.allocator, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "sessions", bencode.BValue{ .list = try ids.toOwnedSlice(server.allocator) } },
        .{ "status", statusDone(server.allocator) },
    });
}

fn opInterrupt(server: *Server, session_id: ?[]const u8, msg_id: []const u8) !bencode.BValue {
    if (session_id) |sid| {
        if (server.getSession(sid)) |session| {
            session.cancelled.store(true, .release);
        }
    }
    return try bencode.makeDict(server.allocator, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "session", bencode.makeStr(session_id orelse "") },
        .{ "status", statusList(server.allocator, &.{ "done", "session-idle" }) },
    });
}

/// Eval sends multiple nREPL messages per the protocol:
///   1. {out: "..."} — if there was stdout during eval
///   2. {value: "..."} — the printed result
///   3. {status: ["done"], x-*: ...} — completion with superstructure metadata
/// On error:
///   1. {err: "..."} — error text
///   2. {ex: "...", status: ["done", "eval-error"]}
fn opEval(server: *Server, msg: bencode.BValue, session_id: ?[]const u8, msg_id: []const u8, conn_fd: fd_t) !void {
    const a = server.allocator;
    const code = msg.dictGetStr("code") orelse {
        sendResponse(conn_fd, try makeErrorResponse(a, session_id orelse "", msg_id, "Missing code"), a);
        return;
    };

    // Resolve or create session
    const sid = session_id orelse try server.createSession();
    const session = server.getSession(sid) orelse {
        sendResponse(conn_fd, try makeErrorResponse(a, sid, msg_id, "Unknown session"), a);
        return;
    };

    // Reset cancel flag
    session.cancelled.store(false, .release);

    // Timestamp start (in trit-ticks for hyperreal precision)
    const start_ticks = getMonotonicTritTicks();

    // Read
    var reader = reader_mod.Reader.init(code, &session.gc);
    const form = reader.readForm() catch |err| {
        // Send err message, then done with eval-error status
        sendResponse(conn_fd, try bencode.makeDict(a, &.{
            .{ "err", bencode.makeStr(@errorName(err)) },
            .{ "id", bencode.makeStr(msg_id) },
            .{ "session", bencode.makeStr(sid) },
        }), a);
        sendResponse(conn_fd, try bencode.makeDict(a, &.{
            .{ "ex", bencode.makeStr(@errorName(err)) },
            .{ "id", bencode.makeStr(msg_id) },
            .{ "session", bencode.makeStr(sid) },
            .{ "status", statusList(a, &.{ "done", "eval-error" }) },
        }), a);
        return;
    };

    // Eval — bounded semantics (network surface → tighter limits)
    var nrepl_limits = transitivity.Limits{
        .max_depth = 256,
        .max_fuel = 1_000_000,
        .max_collection_size = 10_000,
        .max_string_len = 256 * 1024,
    };
    _ = &nrepl_limits;
    var res = Resources.init(nrepl_limits);
    const domain = transduction.evalBounded(form, &session.env, &session.gc, &res);
    const result = switch (domain) {
        .value => |v| v,
        .bottom => |reason| {
            const reason_str = switch (reason) {
                .fuel_exhausted => "fuel-exhausted",
                .depth_exceeded => "depth-exceeded",
                .read_depth_exceeded => "read-depth-exceeded",
                .divergent => "divergent",
            };
            sendResponse(conn_fd, try bencode.makeDict(a, &.{
                .{ "err", bencode.makeStr(reason_str) },
                .{ "id", bencode.makeStr(msg_id) },
                .{ "session", bencode.makeStr(sid) },
            }), a);
            sendResponse(conn_fd, try bencode.makeDict(a, &.{
                .{ "ex", bencode.makeStr(reason_str) },
                .{ "id", bencode.makeStr(msg_id) },
                .{ "session", bencode.makeStr(sid) },
                .{ "status", statusList(a, &.{ "done", "eval-error" }) },
                .{ "x-bounded", bencode.makeStr("true") },
            }), a);
            return;
        },
        .err => |sem_err| {
            const err_str = @tagName(sem_err.kind);
            sendResponse(conn_fd, try bencode.makeDict(a, &.{
                .{ "err", bencode.makeStr(err_str) },
                .{ "id", bencode.makeStr(msg_id) },
                .{ "session", bencode.makeStr(sid) },
            }), a);
            sendResponse(conn_fd, try bencode.makeDict(a, &.{
                .{ "ex", bencode.makeStr(err_str) },
                .{ "id", bencode.makeStr(msg_id) },
                .{ "session", bencode.makeStr(sid) },
                .{ "status", statusList(a, &.{ "done", "eval-error" }) },
            }), a);
            return;
        },
    };

    // Timing
    const end_ticks = getMonotonicTritTicks();
    const elapsed_ticks = end_ticks -| start_ticks;

    // Update session state
    session.eval_count += 1;
    session.accumulateTrit(result);
    session.pushHistory(result);

    // Zero-copy color stamp: attach session OKLAB as metadata on Obj results.
    // Non-Obj values (int, bool, nil, float) carry color via the response envelope.
    if (result.isObj()) {
        const obj = result.asObj();
        if (obj.meta == null) {
            // Allocate a color Obj and set as metadata — single allocation, no copy
            const color_obj = session.gc.allocObj(.color) catch null;
            if (color_obj) |co| {
                co.data.color = session.oklab;
                obj.meta = co;
            }
        }
    }

    // Print result
    const val_str = printer.prStr(result, &session.gc, true) catch "?";

    // Message 1: value
    sendResponse(conn_fd, try bencode.makeDict(a, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "ns", bencode.makeStr(session.ns) },
        .{ "session", bencode.makeStr(sid) },
        .{ "value", bencode.makeStr(val_str) },
    }), a);

    // Message 2: done + superstructure metadata
    sendResponse(conn_fd, try bencode.makeDict(a, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "session", bencode.makeStr(sid) },
        .{ "status", statusDone(a) },
        .{ "x-color-b", bencode.makeInt(@intCast(session.color.b)) },
        .{ "x-color-g", bencode.makeInt(@intCast(session.color.g)) },
        .{ "x-color-r", bencode.makeInt(@intCast(session.color.r)) },
        .{ "x-color-stamped", bencode.makeStr(if (result.isObj()) "true" else "false") },
        .{ "x-elapsed-trit-ticks", bencode.makeInt(@intCast(elapsed_ticks)) },
        .{ "x-eval-count", bencode.makeInt(@intCast(session.eval_count)) },
        .{ "x-trit-balance", bencode.makeInt(@intCast(session.trit_balance)) },
        .{ "x-trit-phase", bencode.makeInt(@intCast(transitivity.tritPhase(session.eval_count))) },
        .{ "x-fuel-remaining", bencode.makeInt(@intCast(res.fuel)) },
        .{ "x-bounded", bencode.makeStr("true") },
        .{ "x-tier", bencode.makeStr("blue") },
        .{ "x-tier-trit", bencode.makeInt(-1) },
    }), a);
}

// ============================================================================
// COMPLETIONS OP (nREPL 0.8+)
// ============================================================================

fn opCompletions(server: *Server, msg: bencode.BValue, session_id: ?[]const u8, msg_id: []const u8) !bencode.BValue {
    const a = server.allocator;
    const prefix = msg.dictGetStr("prefix") orelse "";
    const sid = session_id orelse "";

    // Gather matching builtins from the builtin table
    const core = @import("core.zig");
    var matches = compat.emptyList(bencode.BValue);

    // Iterate all builtin names
    var it = core.builtinIterator();
    while (it.next()) |name_ptr| {
        const name = name_ptr.*;
        if (prefix.len == 0 or (name.len >= prefix.len and std.mem.startsWith(u8, name, prefix))) {
            const entry = try bencode.makeDict(a, &.{
                .{ "candidate", bencode.makeStr(name) },
                .{ "type", bencode.makeStr("function") },
            });
            matches.append(a, entry) catch break;
        }
    }

    return try bencode.makeDict(a, &.{
        .{ "completions", bencode.BValue{ .list = matches.toOwnedSlice(a) catch &.{} } },
        .{ "id", bencode.makeStr(msg_id) },
        .{ "session", bencode.makeStr(sid) },
        .{ "status", statusDone(a) },
    });
}

// ============================================================================
// LOOKUP OP (nREPL 0.8+)
// ============================================================================

fn opLookup(server: *Server, msg: bencode.BValue, session_id: ?[]const u8, msg_id: []const u8) !bencode.BValue {
    const a = server.allocator;
    const sym = msg.dictGetStr("sym") orelse "";
    const sid = session_id orelse "";

    // Check if it's a known builtin
    const core = @import("core.zig");
    if (core.lookupBuiltin(sym) != null) {
        return try bencode.makeDict(a, &.{
            .{ "id", bencode.makeStr(msg_id) },
            .{ "info", try bencode.makeDict(a, &.{
                .{ "arglists-str", bencode.makeStr("(...)") },
                .{ "name", bencode.makeStr(sym) },
                .{ "ns", bencode.makeStr("nanoclj.core") },
            }) },
            .{ "session", bencode.makeStr(sid) },
            .{ "status", statusDone(a) },
        });
    }

    // Not found
    return try bencode.makeDict(a, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "session", bencode.makeStr(sid) },
        .{ "status", statusList(a, &.{ "done", "no-info" }) },
    });
}

// ============================================================================
// LOAD-FILE OP
// ============================================================================

fn opLoadFile(server: *Server, msg: bencode.BValue, session_id: ?[]const u8, msg_id: []const u8, conn_fd: fd_t) !void {
    const file_content = msg.dictGetStr("file") orelse {
        sendResponse(conn_fd, try makeErrorResponse(server.allocator, session_id orelse "", msg_id, "Missing file"), server.allocator);
        return;
    };
    // Treat load-file as eval of the file content
    // Construct a synthetic eval message
    const a = server.allocator;
    const entries = try a.alloc(bencode.BValue.DictEntry, 3);
    entries[0] = .{ .key = "code", .val = bencode.makeStr(file_content) };
    entries[1] = .{ .key = "id", .val = bencode.makeStr(msg_id) };
    entries[2] = .{ .key = "session", .val = bencode.makeStr(session_id orelse "") };
    const synthetic = bencode.BValue{ .dict = entries };
    try opEval(server, synthetic, session_id, msg_id, conn_fd);
}

// ============================================================================
// STDIN OP
// ============================================================================

fn opStdin(server: *Server, session_id: ?[]const u8, msg_id: []const u8) !bencode.BValue {
    // Minimal stdin support — acknowledge but don't block
    return try bencode.makeDict(server.allocator, &.{
        .{ "id", bencode.makeStr(msg_id) },
        .{ "session", bencode.makeStr(session_id orelse "") },
        .{ "status", statusDone(server.allocator) },
    });
}

/// Get monotonic time in trit-ticks (approximate — from clock_gettime)
fn getMonotonicTritTicks() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    const ns: u64 = @intCast(ts.sec * 1_000_000_000 + ts.nsec);
    // 1 trit-tick = 1/2,116,800,000 s ≈ 0.4724 ns
    // Approximate: trit_ticks ≈ ns * 2.1168
    return ns * 2 + ns / 5;
}

// ============================================================================
// BUILTIN: (nrepl-start port) — replaces the stub in substrate.zig
// ============================================================================

pub var global_server: ?*Server = null;

pub fn nreplStartFn(args: []value.Value, gc: *GC, env: *Env, _: *Resources) anyerror!value.Value {
    if (args.len > 1) return error.ArityError;

    // Determine port
    const port: u16 = if (args.len == 1 and args[0].isInt())
        @intCast(@max(@as(i48, 1024), @min(args[0].asInt(), 65535)))
    else
        time_units.nreplPortFromPath("nanoclj-zig"); // color-entropy default

    if (global_server != null) {
        // Already running — return port
        return value.Value.makeInt(@intCast(port));
    }

    const server = try gc.allocator.create(Server);
    server.* = Server.init(gc.allocator, env, gc, port);
    try server.start();
    global_server = server;

    // Report
    var buf: [128]u8 = undefined;
    // Get first session's color for display
    var color_r: u8 = 0;
    var color_g: u8 = 0;
    var color_b: u8 = 0;
    var vit = server.sessions.valueIterator();
    if (vit.next()) |first| {
        color_r = first.*.color.r;
        color_g = first.*.color.g;
        color_b = first.*.color.b;
    }
    const msg = std.fmt.bufPrint(&buf, "nREPL server started on port {d} on host 127.0.0.1 - nrepl://127.0.0.1:{d}\n", .{
        port, port,
    }) catch "nREPL started\n";
    compat.stdoutWrite(msg);

    return value.Value.makeInt(@intCast(port));
}

pub fn nreplStopFn(args: []value.Value, _: *GC, _: *Env, _: *Resources) anyerror!value.Value {
    if (args.len != 0) return error.ArityError;
    if (global_server) |server| {
        server.stop();
        global_server = null;
        return value.Value.makeBool(true);
    }
    return value.Value.makeNil();
}

pub fn nreplStatusFn(args: []value.Value, gc: *GC, _: *Env, _: *Resources) anyerror!value.Value {
    if (args.len != 0) return error.ArityError;
    if (global_server) |server| {
        const m = try gc.allocObj(.map);
        const kw = struct {
            fn intern(g: *GC, s: []const u8) !value.Value {
                return value.Value.makeKeyword(try g.internString(s));
            }
        }.intern;
        try m.data.map.keys.append(gc.allocator, try kw(gc, "port"));
        try m.data.map.vals.append(gc.allocator, value.Value.makeInt(@intCast(server.port)));
        try m.data.map.keys.append(gc.allocator, try kw(gc, "running"));
        try m.data.map.vals.append(gc.allocator, value.Value.makeBool(server.running.load(.acquire)));
        try m.data.map.keys.append(gc.allocator, try kw(gc, "sessions"));
        try m.data.map.vals.append(gc.allocator, value.Value.makeInt(@intCast(server.sessions.count())));
        return value.Value.makeObj(m);
    }
    return value.Value.makeNil();
}

// ============================================================================
// TESTS
// ============================================================================

test "session creation" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var session = Session.init(std.testing.allocator, &env, 42);
    defer session.deinit();

    try std.testing.expectEqual(@as(u8, 32), session.id_len);
    try std.testing.expectEqual(@as(u64, 0), session.eval_count);
    try std.testing.expectEqual(@as(i8, 0), session.trit_balance);
}

test "session trit accumulation" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var session = Session.init(std.testing.allocator, &env, 42);
    defer session.deinit();

    // +1, +1, +1 → 3 ≡ 0 mod 3
    session.accumulateTrit(value.Value.makeInt(1));
    session.accumulateTrit(value.Value.makeInt(1));
    session.accumulateTrit(value.Value.makeInt(1));
    try std.testing.expectEqual(@as(i8, 0), session.trit_balance);
}

test "session history rotation" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(std.testing.allocator, null);
    defer env.deinit();

    var session = Session.init(std.testing.allocator, &env, 42);
    defer session.deinit();

    session.pushHistory(value.Value.makeInt(1));
    session.pushHistory(value.Value.makeInt(2));
    session.pushHistory(value.Value.makeInt(3));

    try std.testing.expectEqual(@as(i48, 3), session.history[0].asInt());
    try std.testing.expectEqual(@as(i48, 2), session.history[1].asInt());
    try std.testing.expectEqual(@as(i48, 1), session.history[2].asInt());
}
