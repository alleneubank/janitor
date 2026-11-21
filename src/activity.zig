//! Best-effort activity feed for an executor's owned workload.

const std = @import("std");
const builtin = @import("builtin");
const tree = @import("process_tree.zig");
const posix = std.posix;

// Zig 0.15's Linux F namespace omits F_DUPFD_CLOEXEC (linux/fcntl.h).
const dupfd_cloexec = if (builtin.os.tag == .linux) 1030 else posix.F.DUPFD_CLOEXEC;

pub const default_interval_ms: u64 = 5000;
pub const min_interval_ms: u64 = 25;
pub const max_interval_ms: u64 = 5000;

pub const Config = struct {
    socket_path: []const u8,
    interval_ms: u64 = default_interval_ms,

    pub fn valid(self: Config) bool {
        return self.socket_path.len > 0 and
            std.mem.indexOfScalar(u8, self.socket_path, 0) == null and
            self.interval_ms >= min_interval_ms and self.interval_ms <= max_interval_ms;
    }
};

const Frame = struct {
    version: u8 = 1,
    seq: u64,
    elapsedMs: u64,
    coverage: enum { complete, uncertain } = .uncertain,
    cpuAdvanced: bool = false,
    state: enum { unknown, blocked, unresolved_wait, runnable } = .unknown,
};

pub const Feed = struct {
    // A slow observation must not monopolize the watch loop. An interval
    // shorter than this ceiling also gets its own proportional work budget.
    const max_sample_ns = 100 * std.time.ns_per_ms;

    allocator: std.mem.Allocator,
    fd: ?posix.fd_t,
    epoch: std.time.Instant,
    interval_ns: u64,
    next_ns: u64,
    sequence: u64 = 0,
    root: ?tree.ProcessIdentity = null,
    previous: ?[]tree.ProcessObservation = null,

    pub fn connect(config: Config, allocator: std.mem.Allocator) !Feed {
        const address = try std.net.Address.initUnix(config.socket_path);
        const socket = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        const fd = if (socket <= posix.STDERR_FILENO) blk: {
            defer posix.close(socket);
            const duplicate = try posix.fcntl(socket, dupfd_cloexec, posix.STDERR_FILENO + 1);
            break :blk @as(posix.fd_t, @intCast(duplicate));
        } else socket;
        errdefer posix.close(fd);
        try posix.connect(fd, &address.any, address.getOsSockLen());
        return .{
            .allocator = allocator,
            .fd = fd,
            .epoch = try std.time.Instant.now(),
            .interval_ns = config.interval_ms * std.time.ns_per_ms,
            .next_ns = config.interval_ms * std.time.ns_per_ms,
        };
    }

    pub fn arm(self: *Feed, executor: posix.pid_t) void {
        self.root = tree.captureIdentity(executor);
    }

    pub fn close(self: *Feed) void {
        if (self.fd) |fd| posix.close(fd);
        self.fd = null;
        self.setBaseline(null);
    }

    fn setBaseline(self: *Feed, observations: ?[]tree.ProcessObservation) void {
        if (self.previous) |old| self.allocator.free(old);
        self.previous = observations;
    }

    pub fn waitMs(self: *Feed) ?u64 {
        if (self.fd == null) return null;
        const now = std.time.Instant.now() catch {
            self.close();
            return null;
        };
        const remaining = self.next_ns -| now.since(self.epoch);
        return std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch unreachable;
    }

    pub fn sample(self: *Feed) void {
        const fd = self.fd orelse return;
        const start = std.time.Instant.now() catch {
            self.close();
            return;
        };
        const elapsed = start.since(self.epoch);
        if (elapsed < self.next_ns) return;

        const late = elapsed - self.next_ns;
        const ticks = late / self.interval_ns + 1;
        self.next_ns += ticks * self.interval_ns;
        self.sequence += ticks;

        var frame: Frame = .{ .seq = self.sequence, .elapsedMs = elapsed / std.time.ns_per_ms };
        const budget = @min(self.interval_ns / 2, max_sample_ns);
        if (self.root) |root| self.observe(&frame, root, start, budget);
        const end = std.time.Instant.now() catch {
            self.close();
            return;
        };
        frame.elapsedMs = end.since(self.epoch) / std.time.ns_per_ms;
        if (late >= self.interval_ns / 2 or end.since(start) >= budget) frame.coverage = .uncertain;

        var bytes: [256]u8 = undefined;
        var output: std.Io.Writer = .fixed(&bytes);
        std.json.Stringify.value(frame, .{}, &output) catch unreachable;
        output.writeByte('\n') catch unreachable;
        const record = output.buffered();
        const sent = posix.send(fd, record, posix.MSG.NOSIGNAL) catch |err| switch (err) {
            // The next sequence exposes the dropped record. Never wait for
            // the reader while supervising a process group.
            error.WouldBlock => return,
            else => {
                self.close();
                return;
            },
        };
        // A partial line must never be joined to a subsequent record.
        if (sent != record.len) self.close();
    }

    fn observe(self: *Feed, frame: *Frame, root: tree.ProcessIdentity, start: std.time.Instant, limit_ns: u64) void {
        const current = tree.observeWorkload(self.allocator, root, start, limit_ns) catch {
            self.setBaseline(null);
            return;
        };
        defer self.setBaseline(current);
        const state = workloadState(current);
        if (state) |observed| {
            frame.state = switch (observed) {
                .blocked => .blocked,
                .unresolved_wait => .unresolved_wait,
                .runnable => .runnable,
            };
        }
        if (self.previous) |previous| {
            const activity = compareObservations(previous, current);
            if (activity.complete and state != null and workloadState(previous) != null) frame.coverage = .complete;
            frame.cpuAdvanced = activity.advanced;
        }
    }
};

fn workloadState(sample: []const tree.ProcessObservation) ?tree.WaitState {
    var state: ?tree.WaitState = null;
    for (sample) |observation| {
        if (observation.state) |observed| {
            const current = state orelse .blocked;
            const priority = @max(@intFromEnum(current), @intFromEnum(observed));
            state = @enumFromInt(priority);
        }
    }
    return state;
}

const Comparison = struct { complete: bool = true, advanced: bool = false };

fn compareObservations(previous: []const tree.ProcessObservation, current: []const tree.ProcessObservation) Comparison {
    var result: Comparison = .{};
    for (previous) |before| {
        for (current) |after| {
            if (before.identity.eql(after.identity)) {
                // Reaped CPU can corroborate progress, but it is aggregate
                // and cannot prove which of several missing branches exited.
                inline for (std.meta.fields(tree.CpuTime)) |field| {
                    const old = @field(before.cpu, field.name);
                    const new = @field(after.cpu, field.name);
                    if (new > old) result.advanced = true;
                    if (new < old) result.complete = false;
                }
                break;
            }
        } else {
            result.complete = false;
        }
    }
    // A newly observed process has no CPU baseline for this interval.
    if (current.len != previous.len) result.complete = false;
    return result;
}

test "a replaced PID cannot bridge a CPU interval" {
    const previous = [_]tree.ProcessObservation{.{
        .identity = .{ .pid = 20, .start_token = 100 },
        .cpu = .{ .user = 10 },
        .state = .blocked,
    }};
    var current = previous;
    current[0].identity.start_token = 200;
    current[0].cpu.user = 11;
    const result = compareObservations(&previous, &current);
    try std.testing.expectEqual(@as(Comparison, .{ .complete = false, .advanced = false }), result);
}

test "reaped child CPU constitutes progress without a live worker" {
    const previous = [_]tree.ProcessObservation{.{
        .identity = .{ .pid = 20, .start_token = 100 },
        .cpu = .{ .child_user = 10 },
        .state = .blocked,
    }};
    var current = previous;
    current[0].cpu.child_user = 11;
    const result = compareObservations(&previous, &current);
    try std.testing.expectEqual(@as(Comparison, .{ .complete = true, .advanced = true }), result);
}
