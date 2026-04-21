const std = @import("std");

const Profile = enum {
    full,
    embed_min,
    embed_safe,
};

fn addBuildOptions(b: *std.Build, _: std.Build.ResolvedTarget, _: std.builtin.OptimizeMode, profile: Profile) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "embed_min", profile == .embed_min);
    options.addOption(bool, "embed_safe", profile == .embed_safe);
    options.addOption(bool, "enable_fuel", profile != .embed_min);
    options.addOption(bool, "enable_depth_limits", profile == .embed_safe);
    options.addOption(bool, "enable_allocation_budget", profile == .embed_safe);
    options.addOption(bool, "enable_mcp", profile == .full);
    options.addOption(bool, "enable_nrepl", profile == .full);
    options.addOption(bool, "enable_kanren", profile == .full);
    options.addOption(bool, "enable_inet", profile == .full);
    options.addOption(bool, "enable_peval", profile == .full);
    return options.createModule();
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const syrup_path = b.option([]const u8, "syrup-path", "Path to zig-syrup/src/syrup.zig") orelse "../zig-syrup/src/syrup.zig";
    const syrup_mod = b.addModule("syrup", .{
        .root_source_file = .{ .cwd_relative = syrup_path },
        .target = target,
        .optimize = optimize,
    });

    const full_build_options = addBuildOptions(b, target, optimize, .full);

    // nanoclj REPL
    const exe = b.addExecutable(.{
        .name = "nanoclj",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syrup", .module = syrup_mod },
                .{ .name = "build_options", .module = full_build_options },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run nanoclj REPL");
    run_step.dependOn(&run_cmd.step);

    // MCP server
    const mcp = b.addExecutable(.{
        .name = "nanoclj-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp_tool.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = full_build_options },
                .{ .name = "syrup", .module = syrup_mod },
            },
        }),
    });
    b.installArtifact(mcp);

    const mcp_run = b.addRunArtifact(mcp);
    mcp_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| mcp_run.addArgs(args);
    const mcp_step = b.step("mcp", "Run nanoclj MCP server");
    mcp_step.dependOn(&mcp_run.step);

    // gorj MCP server (self-hosted: tool handlers defined in nanoclj Clojure)
    const gorj_mcp = b.addExecutable(.{
        .name = "gorj-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gorj_mcp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = full_build_options },
                .{ .name = "syrup", .module = syrup_mod },
            },
        }),
    });
    b.installArtifact(gorj_mcp);

    const gorj_mcp_run = b.addRunArtifact(gorj_mcp);
    gorj_mcp_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| gorj_mcp_run.addArgs(args);
    const gorj_mcp_step = b.step("gorj", "Run gorj MCP server (self-hosted)");
    gorj_mcp_step.dependOn(&gorj_mcp_run.step);

    // Color strip demo
    const strip = b.addExecutable(.{
        .name = "nanoclj-strip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/strip_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(strip);

    const strip_run = b.addRunArtifact(strip);
    strip_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| strip_run.addArgs(args);
    const strip_step = b.step("strip", "Run color strip demo");
    strip_step.dependOn(&strip_run.step);

    // World
    const demo = b.addExecutable(.{
        .name = "nanoclj-world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/world.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = full_build_options },
                .{ .name = "syrup", .module = syrup_mod },
            },
        }),
    });
    b.installArtifact(demo);

    const demo_run = b.addRunArtifact(demo);
    demo_run.step.dependOn(b.getInstallStep());
    const demo_step = b.step("world", "Run world showcase");
    demo_step.dependOn(&demo_run.step);

    // SectorClojure freestanding x86 boot image
    const sector_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const sector_exe = b.addExecutable(.{
        .name = "sector.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sector_boot.zig"),
            .target = sector_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .unwind_tables = .none,
            .red_zone = false,
        }),
    });
    sector_exe.setLinkerScript(b.path("src/linker.ld"));
    b.installArtifact(sector_exe);

    const sector_bin = sector_exe.addObjCopy(.{ .format = .bin });
    const sector_install = b.addInstallBinFile(sector_bin.getOutput(), "sector.bin");
    const sector_step = b.step("sector", "Build SectorClojure freestanding boot image");
    sector_step.dependOn(&sector_install.step);

    // WASM target: nanoclj as a WebAssembly module
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const wasm_build_options = addBuildOptions(b, wasm_target, .ReleaseSmall, .embed_safe);
    const wasm_syrup_mod = b.addModule("syrup_wasm", .{
        .root_source_file = .{ .cwd_relative = syrup_path },
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_exe = b.addExecutable(.{
        .name = "nanoclj",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .imports = &.{
                .{ .name = "build_options", .module = wasm_build_options },
                .{ .name = "syrup", .module = wasm_syrup_mod },
            },
        }),
    });
    // Export eval entry point for JS host; no _start entry point
    wasm_exe.root_module.export_symbol_names = &.{ "nanoclj_init", "nanoclj_eval", "nanoclj_result_len", "nanoclj_alloc", "nanoclj_free" };
    wasm_exe.entry = .disabled;
    b.installArtifact(wasm_exe);
    const wasm_install = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step("wasm", "Build nanoclj WebAssembly module");
    wasm_step.dependOn(&wasm_install.step);

    // Embedded profiles: same REPL entry point today, but with explicit build flags
    // so the runtime can progressively shed features in source-level gates.
    const embed_min_options = addBuildOptions(b, target, .ReleaseSmall, .embed_min);
    const embed_min_exe = b.addExecutable(.{
        .name = "nanoclj-embed-min",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
            .imports = &.{
                .{ .name = "syrup", .module = syrup_mod },
                .{ .name = "build_options", .module = embed_min_options },
            },
        }),
    });
    b.installArtifact(embed_min_exe);
    const embed_min_run = b.addRunArtifact(embed_min_exe);
    embed_min_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| embed_min_run.addArgs(args);
    const embed_min_step = b.step("embed-min", "Build/run the minimal embedded profile");
    embed_min_step.dependOn(&embed_min_run.step);

    const embed_safe_options = addBuildOptions(b, target, .ReleaseSmall, .embed_safe);
    const embed_safe_exe = b.addExecutable(.{
        .name = "nanoclj-embed-safe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
            .imports = &.{
                .{ .name = "syrup", .module = syrup_mod },
                .{ .name = "build_options", .module = embed_safe_options },
            },
        }),
    });
    b.installArtifact(embed_safe_exe);
    const embed_safe_run = b.addRunArtifact(embed_safe_exe);
    embed_safe_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| embed_safe_run.addArgs(args);
    const embed_safe_step = b.step("embed-safe", "Build/run the bounded embedded profile");
    embed_safe_step.dependOn(&embed_safe_run.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syrup", .module = syrup_mod },
                .{ .name = "build_options", .module = full_build_options },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // flow.zig standalone tests (world-constructor kernel, registry W1..W5b)
    const flow_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flow.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_flow_tests = b.addRunArtifact(flow_tests);
    const flow_test_step = b.step("flow-test", "Run flow.zig kernel + registry tests");
    flow_test_step.dependOn(&run_flow_tests.step);
    test_step.dependOn(&run_flow_tests.step);

    // flow_value.zig bidirectional teleportation tests (Clojure ↔ Zig bridge)
    const flow_value_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flow_value.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syrup", .module = syrup_mod },
                .{ .name = "build_options", .module = full_build_options },
            },
        }),
    });
    const run_flow_value_tests = b.addRunArtifact(flow_value_tests);
    const flow_value_test_step = b.step("flow-value-test", "Run flow_value.zig Clojure↔Zig bridge tests");
    flow_value_test_step.dependOn(&run_flow_value_tests.step);

    // .topos/bench harness — BMF-JSON microbenchmarks.
    // Streams per-bench JSON to stdout; pipe to `bencher run --adapter json`
    // for continuous-benchmarking CI (sharkdp/hyperfine-style regression gate).
    const bench_step = b.step("bench", "Run .topos/bench microbenchmarks (BMF JSON)");
    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const nanoclj_lib = b.addModule("nanoclj", .{
        .root_source_file = b.path("src/bench_lib.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "syrup", .module = syrup_mod },
            .{ .name = "build_options", .module = full_build_options },
        },
    });

    const bench_names = [_][]const u8{
        "cold_start",
        "nanbox_fib",
        "reader_arena",
        "flow_throughput",
        "fuel_slope",
        "tak_gabriel",
        "map_reduce",
        "assoc_growth",
        "ackermann",
        "binary_trees",
        "loop_tight",
    };
    inline for (bench_names) |name| {
        const bench_exe = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt(".topos/bench/{s}.zig", .{name})),
                .target = target,
                .optimize = bench_optimize,
                .imports = &.{
                    .{ .name = "syrup", .module = syrup_mod },
                    .{ .name = "build_options", .module = full_build_options },
                    .{ .name = "nanoclj", .module = nanoclj_lib },
                },
            }),
        });
        const bench_run = b.addRunArtifact(bench_exe);
        bench_step.dependOn(&bench_run.step);
    }
}
