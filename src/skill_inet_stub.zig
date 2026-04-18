//! WASM stub for skill_inet — filesystem/clock not available on freestanding.
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

fn unsupported(_: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    return error.EvalFailed;
}

pub const skillRegisterFn = unsupported;
pub const skillActivateFn = unsupported;
pub const skillListFn = unsupported;
pub const skillLoadFn = unsupported;
pub const skillParseFileFn = unsupported;
pub const skillNetStatsFn = unsupported;
pub const skillWatchFn = unsupported;
pub const skillWatchAllFn = unsupported;
pub const skillTranscludeFn = unsupported;
pub const skillCacheStatsFn = unsupported;
pub const skillInvalidateFn = unsupported;
