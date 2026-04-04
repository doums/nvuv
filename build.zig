const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "name", @tagName(zon.name));
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "nvuv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                // .{ .name = "nvuv", .module = mod },
            },
            .link_libc = true, // required for nvml
        }),
    });

    exe.root_module.addOptions("buildmeta", options);
    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.linkSystemLibrary("nvidia-ml", .{});

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("clap", clap.module("clap"));

    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("toml", toml.module("toml"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
