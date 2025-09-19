const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    // Enable/disable backends selectively through options.
    const mcl = if (target.result.os.tag == .windows) b.option(
        bool,
        "mcl",
        "Enable the `MCL` backend (default true).",
    ) orelse true else false;
    options.addOption(bool, "mcl", mcl);
    const return_demo2 = b.option(
        bool,
        "return_demo2",
        "Enable the `return_demo2` backend (default false).",
    ) orelse false;
    options.addOption(bool, "return_demo2", return_demo2);
    const mmc_client = b.option(
        bool,
        "mmc_client",
        "Enable the `mmc_client` backend (default true).",
    ) orelse true;
    options.addOption(bool, "mmc_client", mmc_client);
    const mes07 = if (target.result.os.tag == .linux) b.option(
        bool,
        "mes07",
        "Enable the `mes07` backend (default true).",
    ) orelse true else false;
    options.addOption(bool, "mes07", mes07);

    const mdfunc_lib_path = if (target.result.os.tag == .windows) (b.option(
        []const u8,
        "mdfunc",
        "Specify the path to the MELSEC static library artifact.",
    ) orelse if (target.result.cpu.arch == .x86_64)
        "vendor/mdfunc/lib/x64/MdFunc32.lib"
    else
        "vendor/mdfunc/lib/mdfunc32.lib") else "";
    const mdfunc_mock_build = if (target.result.os.tag == .windows) (b.option(
        bool,
        "mdfunc_mock",
        "Enable building a mock version of the MELSEC data link library.",
    ) orelse (target.result.os.tag != .windows)) else false;

    const network_dep = b.dependency("network", .{
        .target = target,
        .optimize = optimize,
    });
    const chrono = b.dependency("chrono", .{
        .target = target,
        .optimize = optimize,
    });
    const mmc_api = b.dependency("mmc_api", .{
        .target = target,
        .optimize = optimize,
    });

    const zignet = b.dependency("zignet", .{
        .target = target,
        .optimize = optimize,
    });

    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "build.zig.zon", .module = build_zig_zon },
        .{ .name = "mmc-api", .module = mmc_api.module("mmc-api") },
        .{ .name = "network", .module = network_dep.module("network") },
        .{ .name = "chrono", .module = chrono.module("chrono") },
        .{ .name = "zignet", .module = zignet.module("zignet") },
    };
    const setup_options: SetupOptions = .{
        .target = target,
        .optimize = optimize,
        .options = options,
        .imports = imports,
    };

    const exe = b.addExecutable(.{
        .name = "mmc-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    try setupModule(b, exe.root_module, setup_options);
    if (target.result.os.tag == .windows and mcl) {
        const mcl_dep = b.lazyDependency("mcl", .{
            .target = target,
            .optimize = optimize,
            .mdfunc = mdfunc_lib_path,
            .mdfunc_mock = mdfunc_mock_build,
        });
        if (mcl_dep) |dep| {
            exe.root_module.addImport("mcl", dep.module("mcl"));
        }
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = "mmc-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    try setupModule(b, check_exe.root_module, setup_options);
    if (target.result.os.tag == .windows and mcl) {
        const mcl_mock = b.lazyDependency("mcl", .{
            .target = target,
            .optimize = optimize,
            .mdfunc = mdfunc_lib_path,
            .mdfunc_mock = true,
        });
        if (mcl_mock) |dep| {
            check_exe.root_module.addImport("mcl", dep.module("mcl"));
        }
    }
    const check = b.step("check", "Check if `mmc-cli` compiles");
    check.dependOn(&check_exe.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    try setupModule(b, unit_tests.root_module, setup_options);
    if (target.result.os.tag == .windows and mcl) {
        const mcl_mock = b.lazyDependency("mcl", .{
            .target = target,
            .optimize = optimize,
            .mdfunc = mdfunc_lib_path,
            .mdfunc_mock = true,
        });
        if (mcl_mock) |dep| {
            unit_tests.root_module.addImport("mcl", dep.module("mcl"));
        }
    }
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

const SetupOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import = &.{},
    options: ?*std.Build.Step.Options = null,
};

fn setupModule(
    b: *std.Build,
    mod: *std.Build.Module,
    options: SetupOptions,
) !void {
    if (options.options) |opt| {
        mod.addOptions("config", opt);
    }
    for (options.imports) |import| {
        mod.addImport(import.name, import.module);
    }
    switch (options.target.result.os.tag) {
        .windows => {},
        .linux => {
            const soem = b.lazyDependency("soem", .{
                .target = options.target,
                .optimize = options.optimize,
            });
            if (soem) |dep| {
                mod.linkLibrary(dep.artifact("soem"));
                mod.addIncludePath(dep.path("include"));
            }
        },
        else => {
            return error.UnsupportedOs;
        },
    }
}
