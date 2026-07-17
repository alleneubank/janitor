const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const TimeoutError = error{Timeout};
const fixture_timeout_ms: u64 = 3000;

// std.posix.tcsetpgrp/tcgetpgrp reference std.c.tc*pgrp, which is not declared
// for macOS in Zig 0.15.2, so the test harness calls the libc symbols directly.
// These are standard POSIX terminal calls present in macOS libSystem and glibc.
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;

// TIOCSCTTY: make the freshly setsid()'d child claim the pty slave as its
// controlling terminal, mirroring how a terminal emulator launches a shell.
const tiocsctty: c_int = switch (builtin.os.tag) {
    .linux => 0x540E,
    else => 0x20007461, // darwin/BSD _IO('t', 97)
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 3 and std.mem.eql(u8, args[1], "--detached-fixture")) {
        return runDetachedFixture(args[2]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "--term-escape-fixture")) {
        return runTermEscapeFixture(args[2]);
    }

    if (args.len != 2) {
        std.debug.print("usage: e2e <janitor-exe>\n", .{});
        std.process.exit(2);
    }

    const janitor_exe = args[1];
    const e2e_exe = try std.fs.cwd().realpathAlloc(allocator, args[0]);
    defer allocator.free(e2e_exe);

    try testVersionCommand(allocator, janitor_exe);
    try testTrivialExitSkipsGraceWindow(allocator, janitor_exe);
    try testNormalExit(allocator, janitor_exe);
    try testWatchPathKillsProcessGroup(allocator, janitor_exe);
    try testWatchPidKillsProcessGroup(allocator, janitor_exe);
    try testSignalKillsProcessGroup(allocator, janitor_exe);
    try testParentDeathKillsProcessGroup(allocator, janitor_exe);
    try testInteractiveForegroundHandoff(allocator, janitor_exe);
    try testWatchPathDetachedDescendant(allocator, janitor_exe, e2e_exe, false);
    try testWatchPathDetachedDescendant(allocator, janitor_exe, e2e_exe, true);
    try testWatchPathTermEscapeDescendant(allocator, janitor_exe, e2e_exe);
}

// This fixture intentionally lives in the e2e executable rather than Janitor:
// production behavior must not acquire a test-only command. Its direct helper
// remains in Janitor's child group while the forked descendant becomes a fresh
// session/process-group leader, so it remains PPID-linked but escapes group
// signaling. The descendant ignores TERM to make a missing individual KILL
// deterministic.
fn runDetachedFixture(control_path: []const u8) !void {
    const detached_pid = try posix.fork();
    if (detached_pid == 0) {
        if (std.c.setsid() < 0) posix.exit(90);

        var ignore_term = std.mem.zeroes(posix.Sigaction);
        ignore_term.handler = .{ .handler = ignoreSignal };
        ignore_term.mask = posix.sigemptyset();
        posix.sigaction(posix.SIG.TERM, &ignore_term, null);

        // The socket is the fixture's identity capability. Establish it before
        // becoming long lived: a listener/setup failure exits this escaped
        // child on a deadline instead of leaving a detached sentinel behind.
        const control_fd = connectFixtureControl(control_path, fixture_timeout_ms) catch |err| {
            std.debug.print("detached fixture control connection failed: {s}\n", .{@errorName(err)});
            posix.exit(91);
        };
        defer posix.close(control_fd);

        var pid_buf: [64]u8 = undefined;
        const pid_contents = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.c.getpid()}) catch posix.exit(91);
        sendControlMessage(control_fd, pid_contents, fixture_timeout_ms) catch |err| {
            std.debug.print("detached fixture readiness send failed: {s}\n", .{@errorName(err)});
            posix.exit(92);
        };

        // Janitor's pre-fix implementation cannot reach this setsid() child,
        // so it remains here until the harness observes that failure and asks
        // this exact connected peer to clean up. EOF is also a cleanup request
        // so every harness failure path releases the fixture.
        waitForFixtureCleanup(control_fd) catch |err| {
            std.debug.print("detached fixture control wait failed: {s}\n", .{@errorName(err)});
            posix.exit(93);
        };
        return;
    }

    // Keep the parent side of the PPID chain alive until Janitor starts
    // teardown; otherwise this would cover the explicitly excluded already-
    // reparented case instead of the live-descendant contract.
    while (true) std.Thread.sleep(std.time.ns_per_s);
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

// This reproduces the narrow snapshot-to-signal race: the forked member is
// captured while it belongs to Janitor's original group, then the group's TERM
// invokes its handler and it creates a new session. The group leader dies, so
// only the bounded resweep can find the still-matching member for KILL.
fn runTermEscapeFixture(control_path: []const u8) !void {
    const member_pid = try posix.fork();
    if (member_pid == 0) {
        const control_fd = connectFixtureControl(control_path, fixture_timeout_ms) catch |err| {
            std.debug.print("term-escape fixture control connection failed: {s}\n", .{@errorName(err)});
            posix.exit(94);
        };
        defer posix.close(control_fd);

        var escape_term = std.mem.zeroes(posix.Sigaction);
        escape_term.handler = .{ .handler = escapeGroupOnTerm };
        escape_term.mask = posix.sigemptyset();
        posix.sigaction(posix.SIG.TERM, &escape_term, null);

        var pid_buf: [64]u8 = undefined;
        const pid_contents = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.c.getpid()}) catch posix.exit(95);
        sendControlMessage(control_fd, pid_contents, fixture_timeout_ms) catch |err| {
            std.debug.print("term-escape fixture readiness send failed: {s}\n", .{@errorName(err)});
            posix.exit(96);
        };

        waitForTermEscapeCleanup(control_fd) catch |err| {
            std.debug.print("term-escape fixture control wait failed: {s}\n", .{@errorName(err)});
            posix.exit(97);
        };
        return;
    }

    // This direct child remains group leader and deliberately has the default
    // SIGTERM disposition. Its exit makes old-group liveness false exactly
    // when the escaped member needs the resweep.
    while (true) std.Thread.sleep(std.time.ns_per_s);
}

var term_escape_requested = std.atomic.Value(bool).init(false);

fn escapeGroupOnTerm(_: c_int) callconv(.c) void {
    // The handler only publishes the request. `setsid` executes in normal
    // control flow below, so an interrupted poll cannot accidentally end the
    // fixture before it proves the post-TERM escape race.
    term_escape_requested.store(true, .release);
}

// REQ-JANITOR-017 through REQ-JANITOR-020: default teardown drains a live
// detached descendant, while the explicit `--pgroup-only` policy leaves that
// same identity-connected sentinel outside Janitor's drain set.
fn testWatchPathDetachedDescendant(
    allocator: std.mem.Allocator,
    janitor_exe: []const u8,
    e2e_exe: []const u8,
    pgroup_only: bool,
) !void {
    return testWatchPathControlledDescendant(
        allocator,
        janitor_exe,
        e2e_exe,
        "--detached-fixture",
        pgroup_only,
        "detached-descendant",
    );
}

// REQ-JANITOR-022: a descendant that was in the original group at snapshot
// time can escape *because of* the initial TERM. Default teardown resweeps its
// captured identity, rediscovers the new individual target, and drains it.
fn testWatchPathTermEscapeDescendant(
    allocator: std.mem.Allocator,
    janitor_exe: []const u8,
    e2e_exe: []const u8,
) !void {
    return testWatchPathControlledDescendant(
        allocator,
        janitor_exe,
        e2e_exe,
        "--term-escape-fixture",
        false,
        "term-escape-descendant",
    );
}

fn testWatchPathControlledDescendant(
    allocator: std.mem.Allocator,
    janitor_exe: []const u8,
    e2e_exe: []const u8,
    fixture_arg: []const u8,
    pgroup_only: bool,
    test_name: []const u8,
) !void {
    var sandbox = try Sandbox.init(
        allocator,
        if (pgroup_only) "detached-pgroup-only" else test_name,
    );
    defer sandbox.deinit();

    const watch_path = try sandbox.path("watch");
    const control_path = try sandbox.path("detached.control");
    try std.fs.cwd().writeFile(.{ .sub_path = watch_path, .data = "" });

    // Bind before spawning Janitor: the child cannot enter its long-lived
    // detached state until it owns a connected endpoint, and a setup failure
    // makes it self-exit on its bounded connection deadline.
    var control_listener = try FixtureControlListener.init(control_path);
    defer control_listener.deinit();

    var arguments = std.ArrayList([]const u8).empty;
    defer arguments.deinit(allocator);
    try arguments.appendSlice(allocator, &.{
        janitor_exe,
        "--watch-path",
        watch_path,
        "--grace-ms",
        "150",
        "--poll-ms",
        "20",
    });
    if (pgroup_only) try arguments.append(allocator, "--pgroup-only");
    try arguments.appendSlice(allocator, &.{ "--", e2e_exe, fixture_arg, control_path });

    var janitor = std.process.Child.init(arguments.items, allocator);
    janitor.stdin_behavior = .Ignore;
    janitor.stdout_behavior = .Ignore;
    janitor.stderr_behavior = .Inherit;
    try janitor.spawn();

    var janitor_reaped = false;
    defer {
        if (!janitor_reaped) {
            // Let Janitor run its normal signal teardown before forcefully
            // reaping it, so a pre-readiness failure does not strand its
            // child. Each reap is bounded: a broken implementation must not
            // turn an e2e assertion into a permanently hung suite.
            janitor_reaped = reapFixtureJanitor(&janitor);
        }
    }

    var control = try control_listener.acceptWithin(fixture_timeout_ms);
    defer control.close();
    var control_cleanup_required = true;
    defer if (control_cleanup_required) control.requestCleanupAndWait();
    const diagnostic_pid = try control.receiveDiagnosticPid(fixture_timeout_ms);
    std.debug.print("detached fixture connected (diagnostic pid {d})\n", .{diagnostic_pid});

    try std.fs.cwd().deleteFile(watch_path);
    const janitor_term = try waitForChildTerm(&janitor, 3000, test_name);
    janitor_reaped = true;
    try expectExited(
        janitor_term,
        128 + posix.SIG.TERM,
        "controlled descendant teardown preserves direct child status",
    );

    if (pgroup_only) {
        try std.testing.expectError(error.Timeout, control.waitForExit(250));
        control.requestCleanupAndWait();
        control_cleanup_required = false;
    } else {
        control.waitForExit(fixture_timeout_ms) catch |err| {
            std.debug.print("connected {s} survived default Janitor teardown\n", .{test_name});
            return err;
        };
        control_cleanup_required = false;
    }
}

// REQ-JANITOR-015: `janitor --version`, `-V`, and the `version` subcommand each
// print the package version plus build-time git sha to stdout and exit 0, so a
// deployed binary can be matched back to its source. Exercises the compiled
// binary (not the library) per the project's e2e convention.
fn testVersionCommand(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    const forms = [_][]const u8{ "--version", "-V", "version" };
    for (forms) |form| {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ janitor_exe, form },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try expectExited(result.term, 0, "version request exits 0");

        // Assert the banner shape ("janitor <version> (<sha>)") without pinning
        // the exact version/sha, which change per release and per build.
        if (!std.mem.startsWith(u8, result.stdout, "janitor ")) {
            std.debug.print("version form {s}: missing banner prefix: {s}\n", .{ form, result.stdout });
            return error.VersionBannerMissing;
        }
        if (std.mem.indexOfScalar(u8, result.stdout, '(') == null or
            std.mem.indexOfScalar(u8, result.stdout, ')') == null)
        {
            std.debug.print("version form {s}: missing sha parens: {s}\n", .{ form, result.stdout });
            return error.VersionShaMissing;
        }
    }
}

// REQ-JANITOR-013: with a controlling terminal, janitor must hand terminal
// foreground ownership to the child process group (so the child receives
// keyboard input and Ctrl-C directly), then restore the previous foreground
// group on teardown. Reproduces an interactive launch by running janitor under
// a pty whose foreground group we observe through the master via tcgetpgrp.
fn testInteractiveForegroundHandoff(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    var sandbox = try Sandbox.init(allocator, "fg-handoff");
    defer sandbox.deinit();

    const watch_path = try sandbox.path("watch");
    const child_pid_path = try sandbox.path("child.pid");

    // janitor's direct child leads the new process group, so its own $$ is the
    // process-group id we expect to see take over the terminal foreground.
    const runner_script = try Sandbox.writeScriptFmt(
        \\echo $$ > "{s}"
        \\sleep 30
        \\
    , sandbox, "runner.sh", .{child_pid_path});

    try std.fs.cwd().writeFile(.{ .sub_path = watch_path, .data = "" });

    // Allocate a pty; the parent keeps the master purely to observe the slave's
    // foreground process group. tcgetpgrp/tcsetpgrp from the parent would fail
    // (the pty is not the parent's controlling terminal), so only the in-session
    // janitor can change foreground ownership — exactly what we are testing.
    const o_rdwr: c_int = 0o2;
    const master = posix_openpt(o_rdwr);
    if (master < 0) return error.OpenPtFailed;
    defer posix.close(master);
    if (grantpt(master) != 0) return error.GrantPtFailed;
    if (unlockpt(master) != 0) return error.UnlockPtFailed;

    var slave_buf: [128]u8 = undefined;
    const slave_name = blk: {
        const raw = ptsname(master) orelse return error.PtsNameFailed;
        const span = std.mem.span(raw);
        if (span.len + 1 > slave_buf.len) return error.PtsNameTooLong;
        @memcpy(slave_buf[0..span.len], span);
        slave_buf[span.len] = 0;
        break :blk slave_buf[0..span.len :0];
    };

    // `sh -c` (no exec) keeps sh as the session leader and janitor as its child,
    // matching the real layout where janitor inherits the shell's terminal. The
    // trailing `sleep` keeps the session leader alive after janitor exits so the
    // restored foreground group stays observable: were the leader to exit
    // immediately, the kernel would tear down the session and reset the pty
    // foreground before the parent could read it — exactly how a real shell
    // outlives the wrapped command and reclaims its terminal.
    const janitor_cmd = try std.fmt.allocPrint(
        allocator,
        "'{s}' --watch-path '{s}' --grace-ms 200 --poll-ms 20 -- sh '{s}'; sleep 5",
        .{ janitor_exe, watch_path, runner_script },
    );
    defer allocator.free(janitor_cmd);
    const janitor_cmd_z = try allocator.dupeZ(u8, janitor_cmd);
    defer allocator.free(janitor_cmd_z);

    const argv = [_:null]?[*:0]const u8{ "sh", "-c", janitor_cmd_z, null };
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin:/usr/local/bin", null };

    const leader_pid = try posix.fork();
    if (leader_pid == 0) {
        // Session leader that owns the pty, like a terminal emulator's shell.
        _ = posix.setsid() catch posix.exit(80);
        const slave = posix.openZ(slave_name, .{ .ACCMODE = .RDWR }, 0) catch posix.exit(81);
        _ = std.c.ioctl(slave, tiocsctty, @as(c_int, 0));
        posix.dup2(slave, 0) catch posix.exit(82);
        posix.dup2(slave, 1) catch posix.exit(83);
        posix.dup2(slave, 2) catch posix.exit(84);
        if (slave > 2) posix.close(slave);
        posix.close(master);
        const exec_err = posix.execvpeZ("sh", &argv, &envp);
        std.debug.print("e2e session leader exec failed: {s}\n", .{@errorName(exec_err)});
        posix.exit(85);
    }

    // Reap the session leader and nuke any survivors regardless of pass/fail —
    // janitor's own test must not leak the processes it is meant to clean up.
    defer {
        killGroup(leader_pid);
        _ = posix.waitpid(leader_pid, 0);
    }

    const child_pgid = try waitForPidFile(child_pid_path, 5000);
    defer killGroup(child_pgid);

    // Foreground ownership must move to the child's process group.
    waitForForeground(master, child_pgid, 4000) catch |err| {
        std.debug.print(
            "interactive handoff: child pgid {d} never became tty foreground (saw {d})\n",
            .{ child_pgid, tcgetpgrp(master) },
        );
        return err;
    };

    // Teardown via watch-path removal must still drain the child group...
    try std.fs.cwd().deleteFile(watch_path);
    try waitForProcessGone(child_pgid, 3000);

    // ...and the previous foreground process group must be restored before exit.
    waitForForeground(master, leader_pid, 3000) catch |err| {
        std.debug.print(
            "interactive restore: leader pgid {d} never reclaimed tty foreground (saw {d})\n",
            .{ leader_pid, tcgetpgrp(master) },
        );
        return err;
    };
}

fn waitForForeground(master: c_int, expected: posix.pid_t, timeout_ms: u64) !void {
    const deadline_ns = deadlineAfterMs(timeout_ms);
    while (monotonicNowNs() < deadline_ns) {
        if (tcgetpgrp(master) == expected) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn killGroup(pgid: posix.pid_t) void {
    // Best-effort teardown of a leftover group; an already-drained group
    // (ESRCH) is the expected, benign case.
    posix.kill(-pgid, posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {},
    };
}

fn testNormalExit(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    var child = std.process.Child.init(&.{ janitor_exe, "--", "sh", "-c", "exit 7" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    try expectExited(term, 7, "normal child exit status is propagated");
}

// A held WNOWAIT zombie reserves the original PGID on Linux/Darwin, but it is
// not a live group member. This compiled-binary regression test keeps a wide
// grace window so mistakenly treating that reservation as liveness is obvious.
fn testTrivialExitSkipsGraceWindow(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    var child = std.process.Child.init(&.{ janitor_exe, "--grace-ms", "1500", "--", "true" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    const started_ns = monotonicNowNs();
    try child.spawn();
    const stderr_file = child.stderr orelse return error.MissingStderrPipe;
    const stderr = try stderr_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(stderr);
    const term = try child.wait();
    const elapsed_ns = monotonicNowNs() - started_ns;

    try expectExited(term, 0, "trivial child exit status is propagated");
    try std.testing.expect(elapsed_ns < 750 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), stderr.len);
}

fn testWatchPathKillsProcessGroup(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    var sandbox = try Sandbox.init(allocator, "watch-path");
    defer sandbox.deinit();

    const watch_path = try sandbox.path("watch");
    const child_pid_path = try sandbox.path("child.pid");
    const stubborn_script = try sandbox.writeScript("stubborn.sh",
        \\trap "" TERM
        \\while :; do sleep 1; done
        \\
    );
    const runner_script = try Sandbox.writeScriptFmt(
        \\sh "{s}" &
        \\echo $! > "{s}"
        \\wait
        \\
    , sandbox, "runner.sh", .{ stubborn_script, child_pid_path });

    try std.fs.cwd().writeFile(.{ .sub_path = watch_path, .data = "" });

    var child = std.process.Child.init(&.{
        janitor_exe,
        "--watch-path",
        watch_path,
        "--grace-ms",
        "150",
        "--poll-ms",
        "20",
        "--",
        "sh",
        runner_script,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const stubborn_pid = try waitForPidFile(child_pid_path, 2000);
    try std.fs.cwd().deleteFile(watch_path);

    const term = try child.wait();
    try expectExitedAny(term, "watch-path teardown exits instead of hanging");
    try waitForProcessGone(stubborn_pid, 3000);
}

fn testWatchPidKillsProcessGroup(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    var sandbox = try Sandbox.init(allocator, "watch-pid");
    defer sandbox.deinit();

    const child_pid_path = try sandbox.path("child.pid");
    const stubborn_script = try sandbox.writeScript("stubborn.sh",
        \\trap "" TERM
        \\while :; do sleep 1; done
        \\
    );
    const runner_script = try Sandbox.writeScriptFmt(
        \\sh "{s}" &
        \\echo $! > "{s}"
        \\wait
        \\
    , sandbox, "runner.sh", .{ stubborn_script, child_pid_path });

    var doomed = std.process.Child.init(&.{ "sleep", "30" }, allocator);
    doomed.stdin_behavior = .Ignore;
    doomed.stdout_behavior = .Ignore;
    doomed.stderr_behavior = .Inherit;
    try doomed.spawn();

    var doomed_reaped = false;
    defer {
        if (!doomed_reaped) {
            posix.kill(doomed.id, posix.SIG.KILL) catch {};
            _ = doomed.wait() catch {};
        }
    }

    const doomed_pid_arg = try std.fmt.allocPrint(allocator, "{d}", .{doomed.id});
    defer allocator.free(doomed_pid_arg);

    var child = std.process.Child.init(&.{
        janitor_exe,
        "--watch-pid",
        doomed_pid_arg,
        "--grace-ms",
        "150",
        "--poll-ms",
        "20",
        "--",
        "sh",
        runner_script,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const stubborn_pid = try waitForPidFile(child_pid_path, 2000);
    try posix.kill(doomed.id, posix.SIG.TERM);

    try expectExitedAny(try child.wait(), "watch-pid teardown exits instead of hanging");
    _ = try doomed.wait();
    doomed_reaped = true;
    try waitForProcessGone(stubborn_pid, 3000);
}

fn testParentDeathKillsProcessGroup(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    var sandbox = try Sandbox.init(allocator, "parent-death");
    defer sandbox.deinit();

    const child_pid_path = try sandbox.path("child.pid");
    const janitor_pid_path = try sandbox.path("janitor.pid");
    const stubborn_script = try sandbox.writeScript("stubborn.sh",
        \\trap "" TERM
        \\while :; do sleep 1; done
        \\
    );
    const runner_script = try Sandbox.writeScriptFmt(
        \\sh "{s}" &
        \\echo $! > "{s}"
        \\wait
        \\
    , sandbox, "runner.sh", .{ stubborn_script, child_pid_path });
    const parent_script = try Sandbox.writeScriptFmt(
        \\"{s}" --grace-ms 150 --poll-ms 20 -- sh "{s}" &
        \\echo $! > "{s}"
        \\sleep 1
        \\exit 0
        \\
    , sandbox, "parent.sh", .{ janitor_exe, runner_script, janitor_pid_path });

    var parent = std.process.Child.init(&.{ "sh", parent_script }, allocator);
    parent.stdin_behavior = .Ignore;
    parent.stdout_behavior = .Ignore;
    parent.stderr_behavior = .Inherit;
    try expectExited(try parent.spawnAndWait(), 0, "launcher parent exits normally");

    const janitor_pid = try waitForPidFile(janitor_pid_path, 2000);
    const stubborn_pid = try waitForPidFile(child_pid_path, 2000);
    try waitForProcessGone(janitor_pid, 3000);
    try waitForProcessGone(stubborn_pid, 3000);
}

fn testSignalKillsProcessGroup(allocator: std.mem.Allocator, janitor_exe: []const u8) !void {
    var sandbox = try Sandbox.init(allocator, "signal");
    defer sandbox.deinit();

    const child_pid_path = try sandbox.path("child.pid");
    const stubborn_script = try sandbox.writeScript("stubborn.sh",
        \\trap "" TERM
        \\while :; do sleep 1; done
        \\
    );
    const runner_script = try Sandbox.writeScriptFmt(
        \\sh "{s}" &
        \\echo $! > "{s}"
        \\wait
        \\
    , sandbox, "runner.sh", .{ stubborn_script, child_pid_path });

    var child = std.process.Child.init(&.{
        janitor_exe,
        "--grace-ms",
        "150",
        "--poll-ms",
        "20",
        "--",
        "sh",
        runner_script,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const stubborn_pid = try waitForPidFile(child_pid_path, 2000);
    try posix.kill(child.id, posix.SIG.TERM);
    try expectExitedAny(try child.wait(), "signal teardown exits instead of hanging");
    try waitForProcessGone(stubborn_pid, 3000);
}

const Sandbox = struct {
    allocator: std.mem.Allocator,
    root: []const u8,

    fn init(allocator: std.mem.Allocator, name: []const u8) !Sandbox {
        const root = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/janitor-e2e-{s}-{d}",
            .{ name, std.time.nanoTimestamp() },
        );
        try std.fs.cwd().makePath(root);
        return .{ .allocator = allocator, .root = root };
    }

    fn deinit(self: *Sandbox) void {
        std.fs.cwd().deleteTree(self.root) catch |err| {
            std.debug.print("warning: failed to delete e2e sandbox {s}: {s}\n", .{ self.root, @errorName(err) });
        };
        self.allocator.free(self.root);
        self.* = undefined;
    }

    fn path(self: Sandbox, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
    }

    fn writeScript(self: Sandbox, name: []const u8, contents: []const u8) ![]const u8 {
        const script_path = try self.path(name);
        try std.fs.cwd().writeFile(.{ .sub_path = script_path, .data = contents });
        return script_path;
    }

    fn writeScriptFmt(
        comptime fmt: []const u8,
        self: Sandbox,
        name: []const u8,
        args: anytype,
    ) ![]const u8 {
        const contents = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(contents);
        return self.writeScript(name, contents);
    }
};

// A connected Unix-domain socket is the detached fixture's identity token. The
// diagnostic PID aids failure output only; it never authorizes a signal or a
// liveness decision, so PID reuse cannot redirect this test's cleanup.
const FixtureControl = struct {
    fd: posix.fd_t,

    fn close(self: *FixtureControl) void {
        posix.close(self.fd);
    }

    fn receiveDiagnosticPid(self: *FixtureControl, timeout_ms: u64) !posix.pid_t {
        const deadline_ns = deadlineAfterMs(timeout_ms);
        var pid_buf: [64]u8 = undefined;
        var pid_len: usize = 0;

        while (pid_len < pid_buf.len) {
            const events = try waitForControlEvent(self.fd, deadline_ns, posix.POLL.IN);
            if (events & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return error.ControlConnectionFailed;
            if (events & (posix.POLL.IN | posix.POLL.HUP) == 0) continue;

            const received = posix.recv(self.fd, pid_buf[pid_len..], 0) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionResetByPeer => return error.FixtureControlClosedBeforeReady,
                else => return err,
            };
            if (received == 0) return error.FixtureControlClosedBeforeReady;
            pid_len += received;

            for (pid_buf[0..pid_len], 0..) |byte, newline| {
                if (byte == '\n') {
                    return std.fmt.parseInt(posix.pid_t, pid_buf[0..newline], 10);
                }
            }
        }

        return error.FixtureDiagnosticTooLong;
    }

    fn waitForExit(self: *FixtureControl, timeout_ms: u64) !void {
        const deadline_ns = deadlineAfterMs(timeout_ms);
        while (true) {
            const events = try waitForControlEvent(self.fd, deadline_ns, posix.POLL.IN);
            if (events & posix.POLL.NVAL != 0) return error.ControlConnectionFailed;
            if (events & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;

            var byte: [1]u8 = undefined;
            const received = posix.recv(self.fd, &byte, 0) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionResetByPeer => return,
                else => return err,
            };
            if (received == 0) return;
            std.debug.print("unexpected detached fixture control data: {x}\n", .{byte[0]});
            return error.UnexpectedFixtureControlData;
        }
    }

    // Defer paths cannot propagate errors, so report every failure explicitly.
    // Closing this exact peer remains safe even if its diagnostic PID has long
    // since been recycled by an unrelated process.
    fn requestCleanupAndWait(self: *FixtureControl) void {
        sendControlMessage(self.fd, "C", fixture_timeout_ms) catch |err| {
            std.debug.print("detached fixture cleanup request failed: {s}\n", .{@errorName(err)});
        };
        posix.shutdown(self.fd, .send) catch |err| switch (err) {
            error.SocketNotConnected => {},
            else => std.debug.print("detached fixture cleanup shutdown failed: {s}\n", .{@errorName(err)}),
        };
        self.waitForExit(fixture_timeout_ms) catch |err| {
            std.debug.print("detached fixture cleanup acknowledgment failed: {s}\n", .{@errorName(err)});
        };
    }
};

const FixtureControlListener = struct {
    server: std.net.Server,
    path: []const u8,

    fn init(path: []const u8) !FixtureControlListener {
        const address = try std.net.Address.initUnix(path);
        return .{
            .server = try address.listen(.{ .kernel_backlog = 1, .force_nonblocking = true }),
            .path = path,
        };
    }

    fn deinit(self: *FixtureControlListener) void {
        self.server.deinit();
        std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.debug.print(
                "failed to remove fixture control socket {s}: {s}\n",
                .{ self.path, @errorName(err) },
            ),
        };
        self.* = undefined;
    }

    fn acceptWithin(self: *FixtureControlListener, timeout_ms: u64) !FixtureControl {
        const deadline_ns = deadlineAfterMs(timeout_ms);
        while (true) {
            const events = try waitForControlEvent(self.server.stream.handle, deadline_ns, posix.POLL.IN);
            if (events & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return error.ControlListenerFailed;
            if (events & posix.POLL.IN == 0) continue;

            const fd = posix.accept(
                self.server.stream.handle,
                null,
                null,
                posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            ) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => continue,
                else => return err,
            };
            return .{ .fd = fd };
        }
    }
};

fn connectFixtureControl(path: []const u8, timeout_ms: u64) !posix.fd_t {
    const fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        0,
    );
    errdefer posix.close(fd);

    const address = try std.net.Address.initUnix(path);
    posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            const deadline_ns = deadlineAfterMs(timeout_ms);
            while (true) {
                const events = try waitForControlEvent(fd, deadline_ns, posix.POLL.OUT);
                if (events & (posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP) == 0) continue;
                posix.getsockoptError(fd) catch |connect_err| switch (connect_err) {
                    error.ConnectionPending => continue,
                    else => return connect_err,
                };
                return fd;
            }
        },
        else => return err,
    };
    return fd;
}

fn sendControlMessage(fd: posix.fd_t, message: []const u8, timeout_ms: u64) !void {
    const deadline_ns = deadlineAfterMs(timeout_ms);
    var sent: usize = 0;
    while (sent < message.len) {
        const events = try waitForControlEvent(fd, deadline_ns, posix.POLL.OUT);
        if (events & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return error.ControlConnectionFailed;
        if (events & posix.POLL.OUT == 0) continue;

        const wrote = posix.send(fd, message[sent..], posix.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (wrote == 0) return error.ControlConnectionClosed;
        sent += wrote;
    }
}

fn waitForFixtureCleanup(fd: posix.fd_t) !void {
    var poll_fds = [1]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        _ = try posix.poll(&poll_fds, -1);
        const events = poll_fds[0].revents;
        poll_fds[0].revents = 0;
        if (events & posix.POLL.NVAL != 0) return error.ControlConnectionFailed;
        if (events & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;

        var byte: [1]u8 = undefined;
        const received = posix.recv(fd, &byte, 0) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.ConnectionResetByPeer => return,
            else => return err,
        };
        if (received == 0 or byte[0] == 'C') return;
        return error.UnexpectedFixtureControlData;
    }
}

fn waitForTermEscapeCleanup(fd: posix.fd_t) !void {
    var escaped = false;
    var poll_fds = [1]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        if (!escaped and term_escape_requested.load(.acquire)) {
            _ = try posix.setsid();
            escaped = true;
        }
        _ = try posix.poll(&poll_fds, 50);
        const events = poll_fds[0].revents;
        poll_fds[0].revents = 0;
        if (events & posix.POLL.NVAL != 0) return error.ControlConnectionFailed;
        if (events & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;

        var byte: [1]u8 = undefined;
        const received = posix.recv(fd, &byte, 0) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.ConnectionResetByPeer => return,
            else => return err,
        };
        if (received == 0 or byte[0] == 'C') return;
        return error.UnexpectedFixtureControlData;
    }
}

fn waitForControlEvent(fd: posix.fd_t, deadline_ns: u64, events: i16) !i16 {
    const now_ns = monotonicNowNs();
    if (now_ns >= deadline_ns) return error.Timeout;
    const remaining_ns = deadline_ns - now_ns;
    const timeout_ms: i32 = @intCast(@min(
        (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
        @as(u64, 50),
    ));

    var poll_fds = [1]posix.pollfd{.{
        .fd = fd,
        .events = events,
        .revents = 0,
    }};
    _ = try posix.poll(&poll_fds, timeout_ms);
    return poll_fds[0].revents;
}

fn waitForPidFile(path: []const u8, timeout_ms: u64) !posix.pid_t {
    const deadline_ns = deadlineAfterMs(timeout_ms);
    var buf: [64]u8 = undefined;

    while (monotonicNowNs() < deadline_ns) {
        if (std.fs.cwd().readFile(path, &buf)) |contents| {
            const trimmed = std.mem.trim(u8, contents, " \n\r\t");
            if (trimmed.len > 0) {
                return std.fmt.parseInt(posix.pid_t, trimmed, 10);
            }
        } else |_| {}

        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    return error.Timeout;
}

fn waitForProcessGone(pid: posix.pid_t, timeout_ms: u64) !void {
    const deadline_ns = deadlineAfterMs(timeout_ms);
    while (monotonicNowNs() < deadline_ns) {
        if (!processExists(pid)) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    return error.ProcessWaitTimedOut;
}

fn processExists(pid: posix.pid_t) bool {
    posix.kill(pid, 0) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return true,
    };
    return true;
}

// `std.process.Child.wait` is deliberately blocking. The fixture instead
// polls waitpid with W.NOHANG so a regression in Janitor's teardown cannot
// stall the entire e2e suite. This raw reap consumes the child status, so the
// caller must mark its Child as reaped and never call Child.wait afterwards.
fn waitForChildTerm(
    child: *std.process.Child,
    timeout_ms: u64,
    context: []const u8,
) !std.process.Child.Term {
    const deadline_ns = deadlineAfterMs(timeout_ms);
    while (monotonicNowNs() < deadline_ns) {
        const result = posix.waitpid(child.id, posix.W.NOHANG);
        if (result.pid != 0) return childTermFromWaitStatus(result.status);
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    std.debug.print("{s}: child pid {d} did not exit within {d}ms\n", .{ context, child.id, timeout_ms });
    return error.ChildWaitTimedOut;
}

fn childTermFromWaitStatus(status: u32) std.process.Child.Term {
    return if (posix.W.IFEXITED(status))
        .{ .Exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .Signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .Stopped = posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

// Failure cleanup follows the same escalation contract as the fixture under
// test: request orderly teardown, wait a bounded interval, then force it down
// and wait once more. ProcessNotFound is benign; every other failure remains
// visible because it can leave fixture processes behind.
fn reapFixtureJanitor(janitor: *std.process.Child) bool {
    signalFixtureProcess(janitor.id, posix.SIG.TERM, "SIGTERM");
    _ = waitForChildTerm(janitor, 3000, "fixture cleanup after SIGTERM") catch {
        signalFixtureProcess(janitor.id, posix.SIG.KILL, "SIGKILL");
        _ = waitForChildTerm(janitor, 3000, "fixture cleanup after SIGKILL") catch return false;
    };
    return true;
}

fn signalFixtureProcess(pid: posix.pid_t, signal: u8, signal_name: []const u8) void {
    posix.kill(pid, signal) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {
            std.debug.print(
                "failed to send {s} to fixture child pid {d}: {s}\n",
                .{ signal_name, pid, @errorName(err) },
            );
        },
    };
}

fn expectExited(term: std.process.Child.Term, expected: u8, context: []const u8) !void {
    switch (term) {
        .Exited => |code| {
            if (code == expected) return;
            std.debug.print("{s}: expected exit {d}, got {d}\n", .{ context, expected, code });
            return error.UnexpectedExitCode;
        },
        else => {
            std.debug.print("{s}: unexpected term {any}\n", .{ context, term });
            return error.UnexpectedTermination;
        },
    }
}

fn expectExitedAny(term: std.process.Child.Term, context: []const u8) !void {
    switch (term) {
        .Exited => return,
        else => {
            std.debug.print("{s}: unexpected term {any}\n", .{ context, term });
            return error.UnexpectedTermination;
        },
    }
}

// All fixture deadlines share this POSIX monotonic clock, not wall time. A
// saturated deadline keeps waits bounded even if a future caller supplies a
// timeout that cannot be represented in nanoseconds.
fn deadlineAfterMs(timeout_ms: u64) u64 {
    const timeout_ns = std.math.mul(u64, timeout_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    return std.math.add(u64, monotonicNowNs(), timeout_ns) catch std.math.maxInt(u64);
}

fn monotonicNowNs() u64 {
    const timespec = posix.clock_gettime(.MONOTONIC) catch |err| {
        std.debug.panic("CLOCK_MONOTONIC unavailable: {s}", .{@errorName(err)});
    };
    const seconds_ns = std.math.mul(u64, @intCast(timespec.sec), std.time.ns_per_s) catch unreachable;
    return std.math.add(u64, seconds_ns, @intCast(timespec.nsec)) catch unreachable;
}
