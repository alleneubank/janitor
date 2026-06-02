const std = @import("std");

const posix = std.posix;

const TimeoutError = error{Timeout};

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
