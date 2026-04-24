//! Rung 10 of agent-o-nanoclj — telemetry aggregator.
//!
//! The outer monitor over the inner feedback loop. Every Verdict score,
//! every ActionResult's numeric `data`, every RunInfo.latency_ns / step_count
//! is a candidate signal. This rung collects named float samples with
//! monotonic timestamps and returns rolling aggregates (count/sum/mean/
//! min/max) over arbitrary time windows.
//!
//! Port target: agent-o-rama's time-series telemetry surface
//! ("feedback scores automatically become additional telemetry metrics…
//!  Each evaluator rule produces time-series data for every score it
//!  generates, enabling continuous monitoring of quality metrics
//!  alongside operational metrics.").
//!
//! Deliberately in-memory. Rung 6 (persistence) would swap the backing
//! store for an on-disk append log without changing the API.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

const aor_eval = @import("aor_eval.zig");
const aor_action = @import("aor_action.zig");

pub const Sample = struct {
    ts_ns: u64,
    value: f32,
    /// Optional comma-separated tag; caller-owned slice.
    tags: []const u8 = "",
};

/// A single named time-series (e.g. "eval.overall-score",
/// "latency.ms", "action.tokens-used").
pub const Series = struct {
    name: []const u8,
    samples: std.ArrayListUnmanaged(Sample) = .empty,
};

pub const Aggregate = struct {
    count: usize,
    sum: f32,
    min: f32,
    max: f32,
    pub fn mean(self: Aggregate) f32 {
        if (self.count == 0) return 0.0;
        return self.sum / @as(f32, @floatFromInt(self.count));
    }
};

pub const TelemetrySink = struct {
    allocator: std.mem.Allocator,
    series: std.StringHashMapUnmanaged(Series) = .empty,

    pub fn init(allocator: std.mem.Allocator) TelemetrySink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TelemetrySink) void {
        var it = self.series.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            // Free sink-owned tag strings (empty strings from fresh inserts
            // are harmless — dupe returns a zero-length slice we still free).
            for (kv.value_ptr.samples.items) |s| {
                if (s.tags.len > 0) self.allocator.free(s.tags);
            }
            kv.value_ptr.samples.deinit(self.allocator);
        }
        self.series.deinit(self.allocator);
    }

    /// Record a sample under `series_name`. Creates the series if missing.
    /// The sink owns a duplicated copy of `series_name` and (if non-empty)
    /// `tags` so callers can pass transient (stack-allocated) strings safely.
    pub fn record(self: *TelemetrySink, series_name: []const u8, v: f32, tags: []const u8) !void {
        const owned_tags = if (tags.len == 0) "" else try self.allocator.dupe(u8, tags);
        errdefer if (tags.len > 0) self.allocator.free(owned_tags);

        if (self.series.getEntry(series_name)) |entry| {
            try entry.value_ptr.samples.append(self.allocator, .{
                .ts_ns = monoNs(),
                .value = v,
                .tags = owned_tags,
            });
            return;
        }
        const owned = try self.allocator.dupe(u8, series_name);
        errdefer self.allocator.free(owned);
        try self.series.putNoClobber(self.allocator, owned, .{ .name = owned });
        const entry = self.series.getEntry(owned).?;
        try entry.value_ptr.samples.append(self.allocator, .{
            .ts_ns = monoNs(),
            .value = v,
            .tags = owned_tags,
        });
    }

    pub fn getSeries(self: *const TelemetrySink, name: []const u8) ?*const Series {
        if (self.series.getPtr(name)) |p| return p;
        return null;
    }

    /// Aggregate samples in [start_ns, end_ns) for the given series.
    /// Returns count=0 sentinel if the series doesn't exist.
    pub fn aggregate(self: *const TelemetrySink, series_name: []const u8, start_ns: u64, end_ns: u64) Aggregate {
        const s = self.getSeries(series_name) orelse return emptyAggregate();
        var agg = emptyAggregate();
        for (s.samples.items) |sample| {
            if (sample.ts_ns < start_ns or sample.ts_ns >= end_ns) continue;
            if (agg.count == 0) {
                agg.min = sample.value;
                agg.max = sample.value;
            } else {
                if (sample.value < agg.min) agg.min = sample.value;
                if (sample.value > agg.max) agg.max = sample.value;
            }
            agg.sum += sample.value;
            agg.count += 1;
        }
        return agg;
    }

    /// Aggregate across the series' full history.
    pub fn aggregateAll(self: *const TelemetrySink, series_name: []const u8) Aggregate {
        return self.aggregate(series_name, 0, std.math.maxInt(u64));
    }

    /// Convenience: ingest a slice of Verdicts, one sample per verdict, all
    /// under "eval.<evaluator_name>".
    pub fn ingestVerdicts(self: *TelemetrySink, verdicts: []const aor_eval.Verdict) !void {
        var namebuf: [256]u8 = undefined;
        for (verdicts) |v| {
            const key = try std.fmt.bufPrint(&namebuf, "eval.{s}", .{v.evaluator_name});
            try self.record(key, v.score, "");
        }
    }

    /// Convenience: ingest one RunInfo as latency + step-count samples.
    pub fn ingestRunInfo(self: *TelemetrySink, info: aor_action.RunInfo) !void {
        try self.record("latency.ns", @as(f32, @floatFromInt(info.latency_ns)), "");
        try self.record("step-count", @as(f32, @floatFromInt(info.step_count)), "");
    }

    /// Rung 6 — append one line per Sample across all series:
    ///   series_name|ts_ns|value|tags
    /// Grammar matches TraceStore/ActionLog (escape '\|\n\\').
    pub fn writeJsonl(
        self: *const TelemetrySink,
        out: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        scratch_alloc: std.mem.Allocator,
    ) !void {
        var tmp: [64]u8 = undefined;
        var it = self.series.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const series = kv.value_ptr.*;
            for (series.samples.items) |s| {
                const name_esc = try escapeField(scratch_alloc, name);
                defer scratch_alloc.free(name_esc);
                const tags_esc = try escapeField(scratch_alloc, s.tags);
                defer scratch_alloc.free(tags_esc);

                try out.appendSlice(alloc, name_esc);
                try out.append(alloc, '|');
                try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{s.ts_ns}));
                try out.append(alloc, '|');
                try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{s.value}));
                try out.append(alloc, '|');
                try out.appendSlice(alloc, tags_esc);
                try out.append(alloc, '\n');
            }
        }
    }

    pub fn loadJsonl(self: *TelemetrySink, data: []const u8) !void {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var parts: [4][]const u8 = undefined;
            var idx: usize = 0;
            var cursor: usize = 0;
            var field_start: usize = 0;
            while (cursor < line.len and idx < 4) : (cursor += 1) {
                if (line[cursor] == '\\' and cursor + 1 < line.len) {
                    cursor += 1;
                    continue;
                }
                if (line[cursor] == '|') {
                    parts[idx] = line[field_start..cursor];
                    idx += 1;
                    field_start = cursor + 1;
                }
            }
            if (idx != 3) return error.ParseError;
            parts[3] = line[field_start..];

            const name_owned = try unescapeField(self.allocator, parts[0]);
            defer self.allocator.free(name_owned);
            const ts_ns = try std.fmt.parseInt(u64, parts[1], 10);
            const v = try std.fmt.parseFloat(f32, parts[2]);
            const tags_parsed = try unescapeField(self.allocator, parts[3]);
            defer self.allocator.free(tags_parsed);

            // record() dupes name + tags internally; both temp copies freed.
            try self.record(name_owned, v, tags_parsed);
            // Manually stamp the timestamp onto the just-appended sample
            // so ts_ns survives the reload (record() writes current mono).
            const entry = self.series.getEntry(name_owned).?;
            const last_idx = entry.value_ptr.samples.items.len - 1;
            entry.value_ptr.samples.items[last_idx].ts_ns = ts_ns;
        }
    }
};

fn escapeField(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '|' => try out.appendSlice(allocator, "\\|"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn unescapeField(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                '\\' => try out.append(allocator, '\\'),
                'n' => try out.append(allocator, '\n'),
                '|' => try out.append(allocator, '|'),
                else => try out.append(allocator, s[i + 1]),
            }
            i += 2;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn emptyAggregate() Aggregate {
    return .{ .count = 0, .sum = 0.0, .min = 0.0, .max = 0.0 };
}

fn monoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "TelemetrySink.record + aggregateAll over a single series" {
    var sink = TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    try sink.record("eval.s", 1.0, "");
    try sink.record("eval.s", 3.0, "");
    try sink.record("eval.s", 5.0, "");
    const a = sink.aggregateAll("eval.s");
    try std.testing.expectEqual(@as(usize, 3), a.count);
    try std.testing.expectEqual(@as(f32, 9.0), a.sum);
    try std.testing.expectEqual(@as(f32, 3.0), a.mean());
    try std.testing.expectEqual(@as(f32, 1.0), a.min);
    try std.testing.expectEqual(@as(f32, 5.0), a.max);
}

test "TelemetrySink.aggregate returns empty sentinel for missing series" {
    var sink = TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    const a = sink.aggregateAll("not-there");
    try std.testing.expectEqual(@as(usize, 0), a.count);
    try std.testing.expectEqual(@as(f32, 0.0), a.mean());
}

test "ingestVerdicts creates eval.<name> series entries" {
    var sink = TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    const verdicts = [_]aor_eval.Verdict{
        .{ .evaluator_name = "score", .score = 0.7 },
        .{ .evaluator_name = "score", .score = 0.9 },
        .{ .evaluator_name = "preference", .score = -1.0 },
    };
    try sink.ingestVerdicts(&verdicts);
    const score_agg = sink.aggregateAll("eval.score");
    try std.testing.expectEqual(@as(usize, 2), score_agg.count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), score_agg.mean(), 0.0001);
    const pref_agg = sink.aggregateAll("eval.preference");
    try std.testing.expectEqual(@as(usize, 1), pref_agg.count);
    try std.testing.expectEqual(@as(f32, -1.0), pref_agg.mean());
}

test "ingestRunInfo creates latency.ns and step-count series" {
    var sink = TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    const info = aor_action.RunInfo{
        .invoke_id = 1,
        .input = Value.makeInt(0),
        .output = Value.makeInt(0),
        .latency_ns = 1_000_000,
        .step_count = 5,
    };
    try sink.ingestRunInfo(info);
    const lat = sink.aggregateAll("latency.ns");
    const steps = sink.aggregateAll("step-count");
    try std.testing.expectEqual(@as(usize, 1), lat.count);
    try std.testing.expectEqual(@as(f32, 1_000_000.0), lat.mean());
    try std.testing.expectEqual(@as(usize, 1), steps.count);
    try std.testing.expectEqual(@as(f32, 5.0), steps.mean());
}

test "window filtering in aggregate" {
    var sink = TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    try sink.record("m", 1.0, "");
    try sink.record("m", 2.0, "");
    // Aggregate over a future window — zero matches.
    const a_future = sink.aggregate("m", std.math.maxInt(u64) - 10, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 0), a_future.count);
    // Aggregate over the full past — all match.
    const a_all = sink.aggregate("m", 0, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 2), a_all.count);
    try std.testing.expectEqual(@as(f32, 3.0), a_all.sum);
}

test "TelemetrySink writeJsonl → loadJsonl roundtrip preserves values + timestamps" {
    var sink = TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    try sink.record("latency.ns", 1_000_000.0, "");
    try sink.record("latency.ns", 2_500_000.0, "");
    try sink.record("eval.score", 0.8, "");

    // Snapshot timestamps before write for exact comparison after load.
    const lat_series = sink.getSeries("latency.ns").?;
    const ts0 = lat_series.samples.items[0].ts_ns;
    const ts1 = lat_series.samples.items[1].ts_ns;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try sink.writeJsonl(&buf, std.testing.allocator, std.testing.allocator);

    var sink2 = TelemetrySink.init(std.testing.allocator);
    defer sink2.deinit();
    try sink2.loadJsonl(buf.items);

    const lat_agg = sink2.aggregateAll("latency.ns");
    const score_agg = sink2.aggregateAll("eval.score");
    try std.testing.expectEqual(@as(usize, 2), lat_agg.count);
    try std.testing.expectEqual(@as(usize, 1), score_agg.count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), score_agg.mean(), 0.0001);

    // Timestamps preserved exactly (loadJsonl overwrites the record()'s
    // monoNs() with the loaded ts_ns).
    const lat2 = sink2.getSeries("latency.ns").?;
    try std.testing.expectEqual(ts0, lat2.samples.items[0].ts_ns);
    try std.testing.expectEqual(ts1, lat2.samples.items[1].ts_ns);
}

test "multiple series are kept independent" {
    var sink = TelemetrySink.init(std.testing.allocator);
    defer sink.deinit();
    try sink.record("a", 10.0, "");
    try sink.record("b", 100.0, "");
    try sink.record("a", 20.0, "");
    const agg_a = sink.aggregateAll("a");
    const agg_b = sink.aggregateAll("b");
    try std.testing.expectEqual(@as(usize, 2), agg_a.count);
    try std.testing.expectEqual(@as(f32, 15.0), agg_a.mean());
    try std.testing.expectEqual(@as(usize, 1), agg_b.count);
    try std.testing.expectEqual(@as(f32, 100.0), agg_b.mean());
}
