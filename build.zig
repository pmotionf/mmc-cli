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
    const network_dep = b.dependency("network", .{
        .target = target,
        .optimize = optimize,
    });
    const chrono = b.dependency("chrono", .{
        .target = target,
        .optimize = optimize,
    });
    const mmc_config = b.dependency("mmc_config", .{
        .target = target,
        .optimize = optimize,
        .mdfunc = mdfunc_lib_path,
        .mdfunc_mock = mdfunc_mock_build,
    });
    const soem = b.dependency("soem", .{
        .target = target,
        .optimize = optimize,
    });

    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("network", network_dep.module("network"));
    mod.addImport("mcl", mcl.module("mcl"));
    mod.addImport("chrono", chrono.module("chrono"));
    mod.addImport("mmc_config", mmc_config.module("mmc-config"));
    mod.addImport("build.zig.zon", build_zig_zon);
    if (target.result.os.tag == .windows) {
        const zigwin32 = b.lazyDependency("zigwin32", .{});
        if (zigwin32) |zwin32| {
            mod.addImport("win32", zwin32.module("win32"));
        }
    }
    mod.linkLibrary(soem.artifact("soem"));
    mod.addIncludePath(soem.path("include"));

    const exe = b.addExecutable(.{ .name = "mmc-cli", .root_module = mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const mcl_mock = b.dependency("mcl", .{
        .target = target,
        .optimize = optimize,
        .mdfunc = mdfunc_lib_path,
        .mdfunc_mock = true,
    });

    const mmc_config_mock = b.dependency("mmc_config", .{
        .target = target,
        .optimize = optimize,
        .mdfunc = mdfunc_lib_path,
        .mdfunc_mock = true,
    });

    const check_exe = b.addExecutable(.{
        .name = "mmc-cli",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_exe.root_module.addImport("network", network_dep.module("network"));
    check_exe.root_module.addImport("mcl", mcl_mock.module("mcl"));
    check_exe.root_module.addImport("chrono", chrono.module("chrono"));
    if (target.result.os.tag == .windows) {
        const zigwin32 = b.lazyDependency("zigwin32", .{});
        if (zigwin32) |zwin32| {
            check_exe.root_module.addImport("win32", zwin32.module("win32"));
        }
    }
    check_exe.root_module.addImport(
        "mmc_config",
        mmc_config_mock.module("mmc-config"),
    );
    check_exe.root_module.addImport("build.zig.zon", build_zig_zon);
    const check = b.step("check", "Check if `mmc-cli` compiles");
    check.dependOn(&check_exe.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("network", network_dep.module("network"));
    unit_tests.root_module.addImport("mcl", mcl_mock.module("mcl"));
    unit_tests.root_module.addImport("chrono", chrono.module("chrono"));
    if (target.result.os.tag == .windows) {
        const zigwin32 = b.lazyDependency("zigwin32", .{});
        if (zigwin32) |zwin32| {
            unit_tests.root_module.addImport("win32", zwin32.module("win32"));
        }
    }
    unit_tests.root_module.addImport(
        "mmc_config",
        mmc_config_mock.module("mmc-config"),
    );
    unit_tests.root_module.linkLibrary(soem.artifact("soem"));
    unit_tests.root_module.addIncludePath(soem.path("include"));
    unit_tests.root_module.addImport("build.zig.zon", build_zig_zon);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
