const std = @import("std");

// Single source of truth for the package version; the build_info options module
// re-exports it so the lib, executable, and release archives never drift.
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build metadata surfaced by `janitor --version` / `janitor version`. The
    // git sha lets a deployed binary be matched back to its source commit.
    const sha_override = b.option(
        []const u8,
        "git_sha",
        "Embed this commit sha in the version banner. Release CI passes it so the " ++
            "sha never depends on git being present inside the nix build shell.",
    );
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", zon.version);
    build_info.addOption([]const u8, "git_sha", resolveGitSha(b, sha_override));

    // Library module (exposed to package consumers)
    const mod = b.addModule("janitor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    // root.zig reads version/git_sha from here; the import travels with the
    // module to every consumer (exe, unit tests, package dependents).
    mod.addImport("build_info", build_info.createModule());

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

// Resolves the short git commit to embed in the version banner. An explicit
// -Dgit_sha override wins (release CI passes the runner-computed sha so the
// value never depends on git inside the nix shell). Otherwise it shells out to
// git, degrading to "unknown" outside a git checkout (e.g. a release source
// tarball) so the build never fails just because git is unavailable.
fn resolveGitSha(b: *std.Build, override: ?[]const u8) []const u8 {
    if (override) |sha| {
        const trimmed = std.mem.trim(u8, sha, " \t\r\n");
        if (trimmed.len > 0) return b.dupe(trimmed);
    }
    var code: u8 = undefined;
    const raw = b.runAllowFail(
        &.{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--short", "HEAD" },
        &code,
        .Ignore,
    ) catch return "unknown";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "unknown";
    return b.dupe(trimmed);
}
