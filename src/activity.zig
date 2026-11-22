//! Best-effort activity feed for an executor's owned workload.

const std = @import("std");
const builtin = @import("builtin");
const tree = @import("process_tree.zig");
const posix = std.posix;

// Zig 0.15's Linux F namespace omits F_DUPFD_CLOEXEC (linux/fcntl.h).
const dupfd_cloexec = if (builtin.os.tag == .linux) 1030 else posix.F.DUPFD_CLOEXEC;
const socket_send_buffer_bytes: c_int = 4096;

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
    fd: ?posix.fd_t,
    epoch: std.time.Instant,
    interval_ns: u64,
    worker: ?*Worker = null,

    pub fn connect(config: Config) !Feed {
        const address = try std.net.Address.initUnix(config.socket_path);
        const socket = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        const fd = if (socket <= posix.STDERR_FILENO) blk: {
            defer posix.close(socket);
            const duplicate = try posix.fcntl(socket, dupfd_cloexec, posix.STDERR_FILENO + 1);
            break :blk @as(posix.fd_t, @intCast(duplicate));
        } else socket;
        errdefer posix.close(fd);
        // Keep queued observations close to the reader's current window.
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&socket_send_buffer_bytes));
        try posix.connect(fd, &address.any, address.getOsSockLen());
        return .{
            .fd = fd,
            .epoch = try std.time.Instant.now(),
            .interval_ns = config.interval_ms * std.time.ns_per_ms,
        };
    }

    pub fn arm(self: *Feed, executor: posix.pid_t) void {
        self.worker = Worker.start(self.*, executor) catch {
            self.close();
            return;
        };
    }

    pub fn close(self: *Feed) void {
        const fd = self.fd orelse return;
        self.fd = null;
        if (self.worker) |worker| {
            // A proc read can still be in the kernel. Terminate the socket
            // immediately and let the worker retire using its own resources.
            shutdownSocket(fd);
            worker.stop();
            worker.release();
            self.worker = null;
        }
        posix.close(fd);
    }
};

fn shutdownSocket(fd: posix.fd_t) void {
    posix.shutdown(fd, .both) catch |err| switch (err) {
        error.SocketNotConnected => {},
        else => std.log.debug("activity socket shutdown failed: {s}", .{@errorName(err)}),
    };
}

// One worker per Janitor process also bounds detached work when the library
// is used repeatedly and a prior proc read is still stuck in the kernel.
var sampler_running = std.atomic.Value(bool).init(false);

const Worker = struct {
    const allocator = std.heap.smp_allocator;

    references: std.atomic.Value(u8) = .init(2),
    mutex: std.Thread.Mutex = .{},
    wake: std.Thread.Condition = .{},
    stopping: bool = false,
    sampler: Sampler,

    fn start(feed: Feed, executor: posix.pid_t) !*Worker {
        if (sampler_running.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.ActivityUnavailable;
        errdefer sampler_running.store(false, .release);

        const observer = try allocator.create(Worker);
        errdefer allocator.destroy(observer);
        const duplicate = try posix.fcntl(feed.fd.?, dupfd_cloexec, posix.STDERR_FILENO + 1);
        const fd: posix.fd_t = @intCast(duplicate);
        errdefer posix.close(fd);
        observer.* = .{ .sampler = .{
            .fd = fd,
            .epoch = feed.epoch,
            .interval_ns = feed.interval_ns,
            .next_ns = feed.interval_ns,
            .root = tree.captureIdentity(executor),
        } };
        const sampler = try std.Thread.spawn(.{}, run, .{observer});
        sampler.detach();
        return observer;
    }

    fn run(self: *Worker) void {
        defer self.release();
        defer sampler_running.store(false, .release);
        defer self.sampler.close();
        while (self.sampler.fd != null and self.waitUntilDue()) self.sampler.sample();
    }

    fn waitUntilDue(self: *Worker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.stopping) {
            const now = std.time.Instant.now() catch return false;
            const remaining = self.sampler.next_ns -| now.since(self.sampler.epoch);
            if (remaining == 0) return true;
            self.wake.timedWait(&self.mutex, remaining) catch continue;
        }
        return false;
    }

    fn stop(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
        self.wake.signal();
    }

    fn release(self: *Worker) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) allocator.destroy(self);
    }
};

const Sampler = struct {
    const allocator = std.heap.smp_allocator;
    const max_sample_ns = 100 * std.time.ns_per_ms;

    fd: ?posix.fd_t,
    epoch: std.time.Instant,
    interval_ns: u64,
    next_ns: u64,
    root: ?tree.ProcessIdentity,
    sequence: u64 = 0,
    previous: ?[]tree.ProcessObservation = null,

    fn close(self: *Sampler) void {
        if (self.fd) |fd| {
            shutdownSocket(fd);
            posix.close(fd);
        }
        self.fd = null;
        self.setBaseline(null);
    }

    fn setBaseline(self: *Sampler, observations: ?[]tree.ProcessObservation) void {
        if (self.previous) |old| allocator.free(old);
        self.previous = observations;
    }

    fn sample(self: *Sampler) void {
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

    fn observe(self: *Sampler, frame: *Frame, root: tree.ProcessIdentity, start: std.time.Instant, limit_ns: u64) void {
        const current = tree.observeWorkload(allocator, root, start, limit_ns) catch {
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
