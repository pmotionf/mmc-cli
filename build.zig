const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    // Enable/disable backends selectively through options.
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
    const tracy_options, const tracy_enable = blk: {
        const tracy_options = b.addOptions();
        tracy_options.step.name = "tracy options";

        const enable = b.option(
            bool,
            "enable-tracy",
            "Whether tracy should be enabled.",
        ) orelse false;
        const enable_allocation = b.option(
            bool,
            "enable-tracy-allocation",
            "Enable using TracyAllocator to monitor allocations.",
        ) orelse enable;
        const enable_callstack = b.option(
            bool,
            "enable-tracy-callstack",
            "Enable callstack graphs.",
        ) orelse enable;
        if (!enable) std.debug.assert(!enable_allocation and !enable_callstack);

        tracy_options.addOption(bool, "enable", enable);
        tracy_options.addOption(
            bool,
            "enable_allocation",
            enable and enable_allocation,
        );
        tracy_options.addOption(
            bool,
            "enable_callstack",
            enable and enable_callstack,
        );

        break :blk .{ tracy_options.createModule(), enable };
    };
    const tracy_module = createTracyModule(
        b,
        .{
            .target = target,
            .optimize = optimize,
            .enable = tracy_enable,
            .tracy_options = tracy_options,
        },
    );

    const json5 = b.dependency("json5", .{
        .target = target,
        .optimize = optimize,
    });
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

    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "build.zig.zon", .module = build_zig_zon },
        .{ .name = "json5", .module = json5.module("json5") },
        .{ .name = "mmc-api", .module = mmc_api.module("mmc-api") },
        .{ .name = "network", .module = network_dep.module("network") },
        .{ .name = "chrono", .module = chrono.module("chrono") },
        .{ .name = "tracy", .module = tracy_module },
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

fn createTracyModule(
    b: *std.Build,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        enable: bool,
        tracy_options: *std.Build.Module,
    },
) *std.Build.Module {
    const tracy_module = b.createModule(.{
        .root_source_file = b.path("src/tracy.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "options", .module = options.tracy_options },
        },
        .link_libc = options.enable,
        .link_libcpp = options.enable,
        .sanitize_c = .off,
    });
    if (!options.enable) return tracy_module;

    const tracy_dependency = b.lazyDependency("tracy", .{
        .target = options.target,
        .optimize = options.optimize,
    }) orelse return tracy_module;

    tracy_module.addCMacro("TRACY_ENABLE", "1");
    tracy_module.addIncludePath(tracy_dependency.path(""));
    tracy_module.addCSourceFile(.{
        .file = tracy_dependency.path("public/TracyClient.cpp"),
    });

    if (options.target.result.os.tag == .windows) {
        tracy_module.linkSystemLibrary("dbghelp", .{});
        tracy_module.linkSystemLibrary("ws2_32", .{});
    }

    return tracy_module;
}
