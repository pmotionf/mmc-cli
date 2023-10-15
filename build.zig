const std = @import("std");

pub const McsCliBuildOptions = struct {
    mcs_library_path: []const u8,
    mcs_header_path: []const u8,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.getOsTag() != .windows) {
        return error.WindowsRequired;
    }

    const mcs_library_path = b.option(
        []const u8,
        "mcs_library_path",
        "Specify the path to the directory containing the static MCS library.",
    );
    const mcs_header_path = b.option(
        []const u8,
        "mcs_header_path",
        "Specify the path to the directory containing the MCS library header.",
    );
    const mcs_cli_build_options: McsCliBuildOptions = .{
        .mcs_library_path = mcs_library_path orelse "lib/MCS/lib",
        .mcs_header_path = mcs_header_path orelse "lib/MCS/include",
    };

    const network_dep = b.dependency("network", .{});

    const exe = b.addExecutable(.{
        .name = "mcs-cli",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("network", network_dep.module("network"));
    exe.addIncludePath(.{ .path = mcs_cli_build_options.mcs_header_path });
    exe.addLibraryPath(.{ .path = mcs_cli_build_options.mcs_library_path });
    exe.linkSystemLibrary2("MCS", .{ .preferred_link_mode = .Static });

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
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
