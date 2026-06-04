const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (exposed to package consumers)
    const mod = b.addModule("janitor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "janitor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "janitor", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the application");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const cc_hook_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/cc_hook.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(cc_hook_tests).step);

    const e2e_exe = b.addExecutable(.{
        .name = "janitor-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/e2e.zig"),
            .target = target,
            .optimize = optimize,
            // The e2e harness drives a pty via libc terminal calls (posix_openpt,
            // tcgetpgrp, ...) to observe terminal foreground ownership.
            .link_libc = true,
        }),
    });
    const run_e2e = b.addRunArtifact(e2e_exe);
    run_e2e.addFileArg(exe.getEmittedBin());
    run_e2e.step.dependOn(&exe.step);
    test_step.dependOn(&run_e2e.step);

    // Documentation
    const docs_step = b.step("docs", "Generate documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // Format check
    const fmt_step = b.step("fmt", "Check source formatting");
    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig" } });
    fmt_step.dependOn(&fmt.step);
}
