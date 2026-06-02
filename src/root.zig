//! janitor process supervisor.

const builtin = @import("builtin");
const std = @import("std");

const posix = std.posix;

pub const version = "0.1.0";

const default_grace_ms: u64 = 1500;
const default_poll_ms: u64 = 100;

pub const Config = struct {
    watch_path: ?[]const u8 = null,
    grace_ms: u64 = default_grace_ms,
    poll_ms: u64 = default_poll_ms,
    command: []const []const u8,
};

pub const ParseError = error{
    MissingCommand,
    MissingOptionValue,
    InvalidNumber,
    UnknownOption,
};

pub const RunError = error{
    UnsupportedPlatform,
    SpawnFailed,
    WaitFailed,
};

const ChildState = union(enum) {
    running,
    exited: u32,
};

const TeardownReason = enum {
    parent_exited,
    path_missing,
    signal,
    child_exited,
};

const WatchEvent = union(enum) {
    parent_exited,
    child_exited,
    path_missing,
    signal: u8,
    timeout,
};

const Watcher = switch (builtin.os.tag) {
    .linux => LinuxWatcher,
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .openbsd, .netbsd, .dragonfly => KqueueWatcher,
    else => UnsupportedWatcher,
};

pub fn parseArgs(args: []const []const u8) ParseError!Config {
    var watch_path: ?[]const u8 = null;
    var grace_ms = default_grace_ms;
    var poll_ms = default_poll_ms;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            const command = args[i + 1 ..];
            if (command.len == 0) return error.MissingCommand;
            return .{
                .watch_path = watch_path,
                .grace_ms = grace_ms,
                .poll_ms = poll_ms,
                .command = command,
            };
        } else if (std.mem.eql(u8, arg, "--watch-path")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            watch_path = args[i];
        } else if (std.mem.eql(u8, arg, "--grace-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            grace_ms = std.fmt.parseUnsigned(u64, args[i], 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            poll_ms = std.fmt.parseUnsigned(u64, args[i], 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.MissingCommand;
        } else {
            return error.UnknownOption;
        }
    }

    return error.MissingCommand;
}

pub fn run(config: Config, allocator: std.mem.Allocator) RunError!u8 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.UnsupportedPlatform;

    const original_parent = getParentPid();

    var child = std.process.Child.init(config.command, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.pgid = 0;
    child.spawn() catch return error.SpawnFailed;
    child.waitForSpawn() catch return error.SpawnFailed;

    const child_pid = child.id;
    const child_pgid = child_pid;

    var child_state: ChildState = .running;
    var watcher = Watcher.init(original_parent, child_pid, config.watch_path) catch return error.WaitFailed;
    defer watcher.deinit();

    if (getParentPid() != original_parent) {
        return teardown(child_pid, child_pgid, config, &watcher, &child_state, .parent_exited);
    }

    while (true) {
        const event = watcher.wait(null) catch return error.WaitFailed;
        switch (event) {
            .parent_exited => return teardown(child_pid, child_pgid, config, &watcher, &child_state, .parent_exited),
            .path_missing => return teardown(child_pid, child_pgid, config, &watcher, &child_state, .path_missing),
            .signal => return teardown(child_pid, child_pgid, config, &watcher, &child_state, .signal),
            .child_exited => {
                if (!tryPollChild(child_pid, &child_state)) continue;
                if (isProcessGroupAlive(child_pgid)) {
                    return teardown(child_pid, child_pgid, config, &watcher, &child_state, .child_exited);
                }

                return encodeStatus(child_state.exited);
            },
            .timeout => unreachable,
        }
    }
}

fn teardown(
    child_pid: posix.pid_t,
    child_pgid: posix.pid_t,
    config: Config,
    watcher: *Watcher,
    child_state: *ChildState,
    reason: TeardownReason,
) u8 {
    _ = reason;

    if (isProcessGroupAlive(child_pgid)) {
        signalProcessGroup(child_pgid, posix.SIG.TERM);

        const deadline_ns = monotonicNowNs() + msToNs(config.grace_ms);
        while (monotonicNowNs() < deadline_ns) {
            _ = tryPollChild(child_pid, child_state);
            if (!isProcessGroupAlive(child_pgid)) break;

            const remaining_ms = remainingMs(deadline_ns);
            if (remaining_ms == 0) break;
            const event = watcher.wait(remaining_ms) catch .timeout;
            if (event == .timeout) break;
        }

        if (isProcessGroupAlive(child_pgid)) {
            signalProcessGroup(child_pgid, posix.SIG.KILL);
        }
    }

    while (child_state.* == .running) {
        _ = tryPollChild(child_pid, child_state);
        if (child_state.* != .running) break;
        _ = watcher.wait(null) catch break;
    }

    return switch (child_state.*) {
        .running => 128 + posix.SIG.KILL,
        .exited => |status| encodeStatus(status),
    };
}

fn tryPollChild(child_pid: posix.pid_t, child_state: *ChildState) bool {
    if (child_state.* != .running) return true;

    const result = posix.waitpid(child_pid, posix.W.NOHANG);
    if (result.pid == 0) return false;
    child_state.* = .{ .exited = result.status };
    return true;
}

pub fn encodeStatus(status: u32) u8 {
    if (posix.W.IFEXITED(status)) return posix.W.EXITSTATUS(status);
    if (posix.W.IFSIGNALED(status)) {
        const signal = posix.W.TERMSIG(status);
        return @intCast(@min(@as(u32, 255), 128 + signal));
    }
    return 128;
}

fn signalProcessGroup(pgid: posix.pid_t, signal: u8) void {
    posix.kill(-pgid, signal) catch |err| switch (err) {
        error.ProcessNotFound => {},
        error.PermissionDenied => {},
        else => {},
    };
}

pub fn isProcessGroupAlive(pgid: posix.pid_t) bool {
    posix.kill(-pgid, 0) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return true,
    };
    return true;
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return true,
        };
        return true;
    }

    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn getParentPid() posix.pid_t {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        return @intCast(std.os.linux.getppid());
    }

    return std.c.getppid();
}

fn monotonicNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn msToNs(ms: u64) u64 {
    return ms * std.time.ns_per_ms;
}

fn remainingMs(deadline_ns: u64) u64 {
    const now = monotonicNowNs();
    if (now >= deadline_ns) return 0;
    return std.math.divCeil(u64, deadline_ns - now, std.time.ns_per_ms) catch 0;
}

fn watchedSignalSet() posix.sigset_t {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.TERM);
    posix.sigaddset(&mask, posix.SIG.INT);
    posix.sigaddset(&mask, posix.SIG.HUP);
    return mask;
}

fn blockWatchedSignals() void {
    var mask = watchedSignalSet();
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);
}

const PendingEvent = struct {
    event: ?WatchEvent = null,

    fn take(self: *PendingEvent) ?WatchEvent {
        const event = self.event;
        self.event = null;
        return event;
    }

    fn put(self: *PendingEvent, event: WatchEvent) void {
        if (self.event == null) self.event = event;
    }
};

const KqueueWatcher = struct {
    kq: i32,
    path_fd: ?posix.fd_t = null,
    pending: PendingEvent = .{},

    const EventId = enum(usize) {
        parent = 1,
        child = 2,
        signal = 3,
        path = 4,
    };

    fn init(parent_pid: posix.pid_t, child_pid: posix.pid_t, watch_path: ?[]const u8) !KqueueWatcher {
        blockWatchedSignals();

        var watcher: KqueueWatcher = .{ .kq = try posix.kqueue() };
        errdefer watcher.deinit();

        watcher.addProc(parent_pid, .parent) catch |err| switch (err) {
            error.ProcessNotFound => watcher.pending.put(.parent_exited),
            else => return err,
        };
        watcher.addProc(child_pid, .child) catch |err| switch (err) {
            error.ProcessNotFound => watcher.pending.put(.child_exited),
            else => return err,
        };
        try watcher.addSignal(posix.SIG.TERM);
        try watcher.addSignal(posix.SIG.INT);
        try watcher.addSignal(posix.SIG.HUP);

        if (watch_path) |path| {
            watcher.addPath(path) catch |err| switch (err) {
                error.FileNotFound => watcher.pending.put(.path_missing),
                else => return err,
            };
        }

        return watcher;
    }

    fn deinit(self: *KqueueWatcher) void {
        if (self.path_fd) |fd| posix.close(fd);
        posix.close(self.kq);
        self.* = undefined;
    }

    fn wait(self: *KqueueWatcher, timeout_ms: ?u64) !WatchEvent {
        if (self.pending.take()) |event| return event;

        var timeout_ts: posix.timespec = undefined;
        const timeout_ptr = if (timeout_ms) |ms| blk: {
            timeout_ts = .{
                .sec = @intCast(ms / std.time.ms_per_s),
                .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
            };
            break :blk &timeout_ts;
        } else null;

        var events: [1]posix.Kevent = undefined;
        const count = try posix.kevent(self.kq, &.{}, events[0..], timeout_ptr);
        if (count == 0) return .timeout;

        const event = events[0];
        return switch (@as(EventId, @enumFromInt(event.udata))) {
            .parent => .parent_exited,
            .child => .child_exited,
            .signal => .{ .signal = @intCast(event.ident) },
            .path => .path_missing,
        };
    }

    fn addProc(self: *KqueueWatcher, pid: posix.pid_t, event_id: EventId) !void {
        try self.addKevent(
            @intCast(pid),
            std.c.EVFILT.PROC,
            std.c.NOTE.EXIT,
            @intFromEnum(event_id),
            std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
        );
    }

    fn addSignal(self: *KqueueWatcher, signal: u8) !void {
        try self.addKevent(
            signal,
            std.c.EVFILT.SIGNAL,
            0,
            @intFromEnum(EventId.signal),
            std.c.EV.ADD | std.c.EV.ENABLE,
        );
    }

    fn addPath(self: *KqueueWatcher, path: []const u8) !void {
        if (!pathExists(path)) return error.FileNotFound;

        const fd = try posix.open(path, .{ .ACCMODE = .RDONLY, .EVTONLY = true, .CLOEXEC = true }, 0);
        errdefer posix.close(fd);

        try self.addKevent(
            @intCast(fd),
            std.c.EVFILT.VNODE,
            std.c.NOTE.DELETE | std.c.NOTE.RENAME | std.c.NOTE.REVOKE,
            @intFromEnum(EventId.path),
            std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        );
        self.path_fd = fd;
    }

    fn addKevent(self: *KqueueWatcher, ident: usize, filter: i16, fflags: u32, udata: usize, flags: u16) !void {
        const change: posix.Kevent = .{
            .ident = ident,
            .filter = filter,
            .flags = flags,
            .fflags = fflags,
            .data = 0,
            .udata = udata,
        };
        _ = try posix.kevent(self.kq, &.{change}, &.{}, null);
    }
};

const LinuxWatcher = struct {
    epfd: i32,
    parent_fd: ?posix.fd_t = null,
    child_fd: ?posix.fd_t = null,
    signal_fd: ?posix.fd_t = null,
    inotify_fd: ?posix.fd_t = null,
    pending: PendingEvent = .{},

    const linux = std.os.linux;
    const EventId = enum(u64) {
        parent = 1,
        child = 2,
        signal = 3,
        path = 4,
    };

    fn init(parent_pid: posix.pid_t, child_pid: posix.pid_t, watch_path: ?[]const u8) !LinuxWatcher {
        blockWatchedSignals();

        var watcher: LinuxWatcher = .{ .epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC) };
        errdefer watcher.deinit();

        watcher.parent_fd = linuxPidfdOpen(parent_pid) catch |err| switch (err) {
            error.ProcessNotFound => blk: {
                watcher.pending.put(.parent_exited);
                break :blk null;
            },
            else => return err,
        };
        if (watcher.parent_fd) |fd| try watcher.addFd(fd, .parent);

        watcher.child_fd = linuxPidfdOpen(child_pid) catch |err| switch (err) {
            error.ProcessNotFound => blk: {
                watcher.pending.put(.child_exited);
                break :blk null;
            },
            else => return err,
        };
        if (watcher.child_fd) |fd| try watcher.addFd(fd, .child);

        var mask = watchedSignalSet();
        watcher.signal_fd = try posix.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        try watcher.addFd(watcher.signal_fd.?, .signal);

        if (watch_path) |path| {
            watcher.addPath(path) catch |err| switch (err) {
                error.FileNotFound => watcher.pending.put(.path_missing),
                else => return err,
            };
        }

        return watcher;
    }

    fn deinit(self: *LinuxWatcher) void {
        if (self.inotify_fd) |fd| posix.close(fd);
        if (self.signal_fd) |fd| posix.close(fd);
        if (self.child_fd) |fd| posix.close(fd);
        if (self.parent_fd) |fd| posix.close(fd);
        posix.close(self.epfd);
        self.* = undefined;
    }

    fn wait(self: *LinuxWatcher, timeout_ms: ?u64) !WatchEvent {
        if (self.pending.take()) |event| return event;

        const timeout = if (timeout_ms) |ms|
            @as(i32, @intCast(@min(ms, @as(u64, @intCast(std.math.maxInt(i32))))))
        else
            -1;

        var events: [1]linux.epoll_event = undefined;
        const count = posix.epoll_wait(self.epfd, events[0..], timeout);
        if (count == 0) return .timeout;

        const event_id: EventId = @enumFromInt(events[0].data.u64);
        return switch (event_id) {
            .parent => .parent_exited,
            .child => .child_exited,
            .signal => blk: {
                self.drainSignalFd();
                break :blk .{ .signal = 0 };
            },
            .path => blk: {
                self.drainInotifyFd();
                break :blk .path_missing;
            },
        };
    }

    fn addFd(self: *LinuxWatcher, fd: posix.fd_t, event_id: EventId) !void {
        var event: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .u64 = @intFromEnum(event_id) },
        };
        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn addPath(self: *LinuxWatcher, path: []const u8) !void {
        if (!pathExists(path)) return error.FileNotFound;

        const fd = try posix.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        errdefer posix.close(fd);

        _ = try posix.inotify_add_watch(fd, path, linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.IGNORED);
        try self.addFd(fd, .path);
        self.inotify_fd = fd;
    }

    fn drainSignalFd(self: *LinuxWatcher) void {
        var buffer: [@sizeOf(linux.signalfd_siginfo) * 4]u8 = undefined;
        while (true) {
            const read_len = posix.read(self.signal_fd.?, buffer[0..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
            if (read_len == 0 or read_len < buffer.len) return;
        }
    }

    fn drainInotifyFd(self: *LinuxWatcher) void {
        var buffer: [@sizeOf(linux.inotify_event) + 256]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const read_len = posix.read(self.inotify_fd.?, buffer[0..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
            if (read_len == 0 or read_len < buffer.len) return;
        }
    }

    fn linuxPidfdOpen(pid: posix.pid_t) !posix.fd_t {
        const rc = linux.pidfd_open(pid, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .SRCH => return error.ProcessNotFound,
            .INVAL => unreachable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
};

const UnsupportedWatcher = struct {
    fn init(_: posix.pid_t, _: posix.pid_t, _: ?[]const u8) !UnsupportedWatcher {
        return error.UnsupportedPlatform;
    }

    fn deinit(self: *UnsupportedWatcher) void {
        self.* = undefined;
    }

    fn wait(_: *UnsupportedWatcher, _: ?u64) !WatchEvent {
        return error.UnsupportedPlatform;
    }
};

test "parse accepts command after separator" {
    const args = &.{ "--watch-path", "/tmp/work", "--grace-ms", "250", "--poll-ms", "10", "--", "sh", "-c", "true" };
    const parsed = try parseArgs(args);
    try std.testing.expectEqualStrings("/tmp/work", parsed.watch_path.?);
    try std.testing.expectEqual(@as(u64, 250), parsed.grace_ms);
    try std.testing.expectEqual(@as(u64, 10), parsed.poll_ms);
    try std.testing.expectEqualStrings("sh", parsed.command[0]);
}

test "parse rejects missing command" {
    try std.testing.expectError(error.MissingCommand, parseArgs(&.{}));
    try std.testing.expectError(error.MissingCommand, parseArgs(&.{"--"}));
}
