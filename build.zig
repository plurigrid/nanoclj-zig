const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const syrup_path = b.option([]const u8, "syrup-path", "Path to zig-syrup/src/syrup.zig") orelse "../zig-syrup/src/syrup.zig";
    const syrup_mod = b.addModule("syrup", .{
        .root_source_file = .{ .cwd_relative = syrup_path },
        .target = target,
        .optimize = optimize,
    });

    // nanoclj REPL
    const exe = b.addExecutable(.{
        .name = "nanoclj",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syrup", .module = syrup_mod },
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

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "syrup", .module = syrup_mod },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
