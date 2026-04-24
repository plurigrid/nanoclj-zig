//! WASM stub for tree_vfs — filesystem not available on freestanding.
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

fn unsupported(_: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    return error.EvalFailed;
}

pub const treeReadFn = unsupported;
pub const treeTitleFn = unsupported;
pub const treeTranscludedFn = unsupported;
pub const treeTranscludersFn = unsupported;
pub const treeIdsFn = unsupported;
pub const treeIsolatedFn = unsupported;
pub const treeChainFn = unsupported;
pub const treeTaxonFn = unsupported;
pub const treeAuthorFn = unsupported;
pub const treeMetaFn = unsupported;
pub const treeImportsFn = unsupported;
pub const treeByTaxonFn = unsupported;

pub fn deinitForest() void {}
