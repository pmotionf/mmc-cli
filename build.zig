const std = @import("std");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    switch (target.result.os.tag) {
        .windows, .linux => {},
        else => return error.UnsupportedOs,
    }
    const translate_c = b.dependency("translate_c", .{
        .target = b.graph.host,
        .optimize = optimize,
    });

    const soem = b.dependency("soem", .{
        .target = target,
        .optimize = optimize,
        .EC_TIMEOUTRET = 1000,
        // Maximum slaves match maximum cclink stations
        .EC_MAXSLAVE = 257,
    });

    const trans_soem: Translator = .init(translate_c, .{
        .c_source_file = b.addWriteFiles().add("c.h",
            \\#include <soem/soem.h>
        ),
        .target = target,
        .optimize = optimize,
    });

    trans_soem.linkLibrary(soem.artifact("soem"));
    // Workaround for the wrong alignment caused by #pragma pack.
    // TODO: Remove this one once the zig 0.17.0 is used. This problem might be
    // fixed with https://codeberg.org/ziglang/translate-c/commit/174a76a5b20c0fde03032d9c1cc9d4a78a6318af
    trans_soem.mod.addCSourceFile(.{
        .file = b.path("src/command/mcl/protocol/ethercat/soem_shim.c"),
    });

    // Building this library requires the wpcap bundled by SOEM
    if (target.result.os.tag == .windows) {
        trans_soem.mod.addLibraryPath(soem.namedLazyPath("wpcap_lib_dir"));
    }

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
    const mdfunc = b.dependency("mdfunc", .{
        .target = target,
        .optimize = optimize,
        .mdfunc = mdfunc_lib_path,
        .mock = mdfunc_mock_build,
    });

    const chrono = b.dependency("chrono", .{});
    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    const mmc_api = b.dependency("mmc_api", .{
        .target = target,
        .optimize = optimize,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "build.zig.zon", .module = build_zig_zon },
        .{ .name = "chrono", .module = chrono.module("chrono") },
        .{ .name = "mmc-api", .module = mmc_api.module("mmc-api") },
        .{ .name = "soem", .module = trans_soem.mod },
    };

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
        .error_tracing = true,
    });

    mod.addImport("mdfunc", mdfunc.module("mdfunc"));

    const exe = b.addExecutable(.{
        .name = "mmc-cli",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const mdfunc_mock = b.dependency("mdfunc", .{
        .target = target,
        .optimize = optimize,
        .mdfunc = mdfunc_lib_path,
        .mock = true,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
        .error_tracing = true,
    });

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.root_module.addImport("mdfunc", mdfunc_mock.module("mdfunc"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
