//! spi_builtins.zig: Clojure-facing builtins for the SPI registry.
//!
//! (spi/providers)       → list all registered providers with Chomsky levels
//! (spi/census)          → {3 N, 2 N, 1 N, 0 N} count per Chomsky level
//! (spi/match engine s)  → {:matched bool :consumed N :trit T}
//! (spi/escalate s rule) → {:result ... :level N :provider "name"}
//! (spi/manifest)        → actual engine census from the live registry
//! (spi/dominates? them) → always false (no verified external data)

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

/// (spi/manifest) → actual engine census from the live registry
/// Returns a single vector: ["nanoclj-zig" regexp-count peg-count csg-count logic-count total]
/// All counts are dynamic — queried from the registry, not hardcoded.
pub fn builtinManifest(gc: *GC) Value {
    const reg = ensureRegistry();
    const census = reg.census();
    const items = [_]Value{
        gc.internString("nanoclj-zig"),
        Value.makeInt(@intCast(census[3])), // regexp (Chomsky 3)
        Value.makeInt(@intCast(census[2])), // PEG/CFG (Chomsky 2)
        Value.makeInt(@intCast(census[1])), // CSG (Chomsky 1)
        Value.makeInt(@intCast(census[0])), // logic/RE (Chomsky 0)
        Value.makeInt(@intCast(reg.total())),
    };
    return gc.makeVector(&items);
}

/// (spi/dominates? "Janet") → always false.
/// Cross-language dominance claims require verified external data we don't have.
pub fn builtinDominates(gc: *GC, name: []const u8) Value {
    _ = gc;
    _ = name;
    return Value.makeBool(false);
}
