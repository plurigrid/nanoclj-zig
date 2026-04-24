//! WASM stub for brainfloj — serial/file I/O not available on freestanding.
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

fn unsupported(_: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    return error.EvalFailed; // Not available on WASM
}

pub const brainflojParseFn = unsupported;
pub const brainflojReadFn = unsupported;
pub const brainflojSerialFn = unsupported;
