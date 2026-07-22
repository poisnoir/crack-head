const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mujoco_include = b.path("vendor/mujoco/include");
    const mujoco_lib = b.path("vendor/mujoco/lib");

    const spine_zig_dep = b.dependency("spine_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const spine_zig_mod = spine_zig_dep.module("spine");

    const exe = b.addExecutable(.{
        .name = "crack-head",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spine_zig", .module = spine_zig_mod },
            },
        }),
    });

    exe.root_module.addIncludePath(mujoco_include);
    exe.root_module.addLibraryPath(mujoco_lib);
    exe.root_module.addRPath(mujoco_lib);
    exe.root_module.linkSystemLibrary("mujoco", .{});
    exe.root_module.linkSystemLibrary("glfw", .{});
    exe.root_module.link_libc = true;

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
