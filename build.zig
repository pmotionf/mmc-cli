const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mdfunc_lib_path = b.option(
        []const u8,
        "mdfunc",
        "Specify the path to the MELSEC static library artifact.",
    ) orelse if (target.result.cpu.arch == .x86_64)
        "vendor/mdfunc/lib/x64/MdFunc32.lib"
    else
        "vendor/mdfunc/lib/mdfunc32.lib";
    const mdfunc_mock_build = b.option(
        bool,
        "mdfunc_mock",
        "Enable building a mock version of the MELSEC data link library.",
    ) orelse (target.result.os.tag != .windows);

    const mcl = b.dependency("mcl", .{
        .target = target,
        .optimize = optimize,
        .mdfunc = mdfunc_lib_path,
        .mdfunc_mock = mdfunc_mock_build,
    });
    const network_dep = b.dependency("network", .{});
    const chrono = b.dependency("chrono", .{});

    const zig_args = b.dependency("zig-args", .{});

    const exe = b.addExecutable(.{
        .name = "mmc-cli",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("network", network_dep.module("network"));
    exe.root_module.addImport("mcl", mcl.module("mcl"));
    exe.root_module.addImport("chrono", chrono.module("chrono"));

    b.installArtifact(exe);

    const configurator = b.addExecutable(.{
        .name = "configurator",
        .root_source_file = b.path("src/configurator.zig"),
        .target = target,
        .optimize = optimize,
    });
    configurator.root_module.addImport(
        "network",
        network_dep.module("network"),
    );
    configurator.root_module.addImport("mcl", mcl.module("mcl"));
    configurator.root_module.addImport("args", zig_args.module("args"));
    b.installArtifact(configurator);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
