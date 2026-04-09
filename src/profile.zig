const build_options = @import("build_options");

pub const embed_min = build_options.embed_min;
pub const embed_safe = build_options.embed_safe;
pub const enable_fuel = build_options.enable_fuel;
pub const enable_depth_limits = build_options.enable_depth_limits;
pub const enable_allocation_budget = build_options.enable_allocation_budget;
pub const enable_mcp = build_options.enable_mcp;
pub const enable_nrepl = build_options.enable_nrepl;
pub const enable_kanren = build_options.enable_kanren;
pub const enable_inet = build_options.enable_inet;
pub const enable_peval = build_options.enable_peval;

pub fn profileName() []const u8 {
    if (embed_min) return "embed-min";
    if (embed_safe) return "embed-safe";
    return "full";
}

