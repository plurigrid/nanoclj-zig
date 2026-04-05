//! spi_builtins.zig: Clojure-facing builtins for the SPI registry.
//!
//! (spi/providers)       → list all registered providers with Chomsky levels
//! (spi/census)          → {3 N, 2 N, 1 N, 0 N} count per Chomsky level
//! (spi/match engine s)  → {:matched bool :consumed N :trit T}
//! (spi/escalate s rule) → {:result ... :level N :provider "name"}
//! (spi/manifest)        → comparative table vs Janet/Shen/Racket/Guile/Clojure
//! (spi/dominates? them) → true iff we have >= engines at every Chomsky level

const std = @import("std");
const spi = @import("spi.zig");
const Value = @import("value.zig").Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;

var global_registry: ?spi.Registry = null;

fn ensureRegistry() *spi.Registry {
    if (global_registry == null) {
        global_registry = spi.defaultRegistry();
    }
    return &global_registry.?;
}

/// (spi/census) → vector [regexp-count peg-count csg-count re-count]
pub fn builtinCensus(gc: *GC) Value {
    const reg = ensureRegistry();
    const census = reg.census();
    // Return as vector of 4 ints
    var items: [4]Value = undefined;
    for (census, 0..) |c, i| {
        items[i] = Value.makeInt(@intCast(c));
    }
    return gc.makeVector(&items);
}

/// (spi/total) → int
pub fn builtinTotal(_: *GC) Value {
    const reg = ensureRegistry();
    return Value.makeInt(@intCast(reg.total()));
}

/// (spi/providers) → list of maps {:name "..." :chomsky N}
pub fn builtinProviders(gc: *GC) Value {
    const reg = ensureRegistry();
    var results: [32]Value = undefined;
    var count: usize = 0;

    for (0..4) |level| {
        for (reg.levels[level][0..reg.counts[level]]) |maybe_prov| {
            if (maybe_prov) |prov| {
                // Build a simple keyword-value pair representation
                const name_val = gc.internString(prov.name);
                const level_val = Value.makeInt(@intCast(level));
                // Store as [name level] vector for simplicity
                const pair = [_]Value{ name_val, level_val };
                results[count] = gc.makeVector(&pair);
                count += 1;
            }
        }
    }

    return gc.makeList(results[0..count]);
}

/// (spi/escalate input rule) → {:result ... :level N :provider "name"}
pub fn builtinEscalate(gc: *GC, input: []const u8, rule: []const u8) Value {
    const reg = ensureRegistry();
    const result = reg.escalate(input, rule);

    const matched_val = Value.makeBool(result.result.matched);
    const consumed_val = Value.makeInt(@intCast(result.result.consumed));
    const trit_val = Value.makeInt(result.result.trit);
    const level_val = Value.makeInt(@intCast(result.level));
    const provider_val = gc.internString(result.provider_name);

    // Return as vector [matched consumed trit level provider-name]
    const items = [_]Value{ matched_val, consumed_val, trit_val, level_val, provider_val };
    return gc.makeVector(&items);
}

/// (spi/manifest) → the compile-time comparative manifest as a readable structure
pub fn builtinManifest(gc: *GC) Value {
    // Return names and engine counts for comparison
    const entries = [_]struct { name: []const u8, re: u8, peg: u8, logic: u8, size: u16 }{
        .{ .name = "nanoclj-zig", .re = 3, .peg = 3, .logic = 2, .size = 3 },
        .{ .name = "Janet", .re = 0, .peg = 1, .logic = 0, .size = 1 },
        .{ .name = "Shen", .re = 0, .peg = 0, .logic = 1, .size = 5 },
        .{ .name = "Racket", .re = 1, .peg = 1, .logic = 2, .size = 200 },
        .{ .name = "Guile", .re = 1, .peg = 1, .logic = 1, .size = 30 },
        .{ .name = "Clojure", .re = 1, .peg = 1, .logic = 1, .size = 400 },
    };

    var results: [6]Value = undefined;
    for (entries, 0..) |e, i| {
        const items = [_]Value{
            gc.internString(e.name),
            Value.makeInt(e.re),
            Value.makeInt(e.peg),
            Value.makeInt(e.logic),
            Value.makeInt(e.size),
        };
        results[i] = gc.makeVector(&items);
    }
    return gc.makeList(&results);
}

/// (spi/dominates? "Janet") → true iff nanoclj-zig >= at every axis
pub fn builtinDominates(gc: *GC, name: []const u8) Value {
    _ = gc;
    const dominated = if (std.mem.eql(u8, name, "Janet"))
        spi.Manifest.us.regexp_engines >= spi.Manifest.janet.regexp_engines and
            spi.Manifest.us.peg_engines >= spi.Manifest.janet.peg_engines and
            spi.Manifest.us.logic_engines >= spi.Manifest.janet.logic_engines
    else if (std.mem.eql(u8, name, "Shen"))
        spi.Manifest.us.regexp_engines >= spi.Manifest.shen.regexp_engines and
            spi.Manifest.us.peg_engines >= spi.Manifest.shen.peg_engines and
            spi.Manifest.us.logic_engines >= spi.Manifest.shen.logic_engines
    else if (std.mem.eql(u8, name, "Racket"))
        spi.Manifest.us.regexp_engines >= spi.Manifest.racket.regexp_engines and
            spi.Manifest.us.peg_engines >= spi.Manifest.racket.peg_engines and
            spi.Manifest.us.logic_engines >= spi.Manifest.racket.logic_engines
    else if (std.mem.eql(u8, name, "Guile"))
        spi.Manifest.us.regexp_engines >= spi.Manifest.guile.regexp_engines and
            spi.Manifest.us.peg_engines >= spi.Manifest.guile.peg_engines and
            spi.Manifest.us.logic_engines >= spi.Manifest.guile.logic_engines
    else if (std.mem.eql(u8, name, "Clojure"))
        spi.Manifest.us.regexp_engines >= spi.Manifest.clojure.regexp_engines and
            spi.Manifest.us.peg_engines >= spi.Manifest.clojure.peg_engines and
            spi.Manifest.us.logic_engines >= spi.Manifest.clojure.logic_engines
    else
        false;

    return Value.makeBool(dominated);
}
