//! Clojure Agents for nanoclj-zig.
//!
//! Single-threaded semantics first: `send`/`send-off` enqueue an action
//! `(f state & args)` into the agent's mailbox; `(await a)` drains.
//! Actions run synchronously during drain, in FIFO order. Each successful
//! action CAS-replaces `state`. An error (thrown or validator-rejected)
//! stops the agent, records the error, and stashes remaining actions
//! until `(restart-agent)`.
//!
//! Integration points (see also jepsen.zig, thread_peval.zig, channel.zig):
//!   - Mailbox is a plain queue here; channel.ChannelData is the upgrade path
//!     when we move to thread_peval.SharedContext workers.
//!   - Every applied action emits `jepsen/record!` so the agent's action log
//!     is a linearizable history — exactly agent-o-rama's
//!     `interaction_sequences` schema (see
//!     asi/skills/agent-o-rama/SKILL.md §DuckDB Integration).
//!   - Validators reuse the atom `runAtomValidator` contract.

const std = @import("std");
const compat = @import("compat.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const Action = struct {
    /// The function to apply: (f state & args) → new-state.
    func: Value,
    /// Extra args after state.
    args: std.ArrayListUnmanaged(Value) = compat.emptyList(Value),
    /// send vs send-off (reserved: currently identical in single-thread mode).
    off: bool = false,
};

pub const AgentData = struct {
    state: Value = Value.makeNil(),
    /// Pending actions, FIFO.
    mailbox: std.ArrayListUnmanaged(Action) = compat.emptyList(Action),
    /// Optional predicate: (validator new-state) must be truthy.
    validator: Value = Value.makeNil(),
    /// Set when an action raises; agent is stopped until restart.
    error_state: Value = Value.makeNil(),
    /// Optional (handler agent exc) callback, like clojure's set-error-handler!
    error_handler: Value = Value.makeNil(),
    /// :continue keeps running after error; :fail stops (default).
    continue_on_error: bool = false,
    /// Linearizable state history — one entry per successful transition
    /// (initial state is index 0). Enables agent-o-rama DuckDB ingestion
    /// and Barton-reflexive self-witness: (history a) lets the agent see itself.
    history: std.ArrayListUnmanaged(Value) = compat.emptyList(Value),

    pub fn isStopped(self: *const AgentData) bool {
        return !self.error_state.isNil() and !self.continue_on_error;
    }

    pub fn enqueue(
        self: *AgentData,
        allocator: std.mem.Allocator,
        action: Action,
    ) !void {
        try self.mailbox.append(allocator, action);
    }

    /// Pop the next action; caller owns the Action.args list.
    pub fn dequeue(self: *AgentData) ?Action {
        if (self.mailbox.items.len == 0) return null;
        return self.mailbox.orderedRemove(0);
    }

    pub fn clearMailbox(self: *AgentData, allocator: std.mem.Allocator) void {
        for (self.mailbox.items) |*a| a.args.deinit(allocator);
        self.mailbox.clearAndFree(allocator);
    }

    pub fn deinit(self: *AgentData, allocator: std.mem.Allocator) void {
        self.clearMailbox(allocator);
        self.history.deinit(allocator);
    }
};
