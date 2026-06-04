const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const TimeoutError = error{Timeout};

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

    if (args.len != 2) {
        std.debug.print("usage: e2e <janitor-exe>\n", .{});
        std.process.exit(2);
    }

    const janitor_exe = args[1];
    try testNormalExit(allocator, janitor_exe);
    try testWatchPathKillsProcessGroup(allocator, janitor_exe);
    try testSignalKillsProcessGroup(allocator, janitor_exe);
    try testParentDeathKillsProcessGroup(allocator, janitor_exe);
    try testInteractiveForegroundHandoff(allocator, janitor_exe);
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
    const deadline_ns = monotonicNowNs() + timeout_ms * std.time.ns_per_ms;
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

fn waitForPidFile(path: []const u8, timeout_ms: u64) !posix.pid_t {
    const deadline_ns = monotonicNowNs() + timeout_ms * std.time.ns_per_ms;
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
    const deadline_ns = monotonicNowNs() + timeout_ms * std.time.ns_per_ms;
    while (monotonicNowNs() < deadline_ns) {
        if (!processExists(pid)) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    return error.Timeout;
}

fn processExists(pid: posix.pid_t) bool {
    posix.kill(pid, 0) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return true,
    };
    return true;
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

fn monotonicNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}
