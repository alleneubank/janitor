//! janitor process supervisor.

const builtin = @import("builtin");
const std = @import("std");
const process_tree = @import("process_tree.zig");
// Build-time metadata: version single-sourced from build.zig.zon, git_sha
// resolved during `zig build`. See build.zig.
const build_info = @import("build_info");

const posix = std.posix;

/// Package version, single-sourced from build.zig.zon so the lib, executable,
/// and release archives never drift.
pub const version = build_info.version;

/// Short git commit the binary was built from, or "unknown" when built outside
/// a git checkout (e.g. from a release source tarball).
pub const git_sha = build_info.git_sha;

/// Build-target capability exposed for the executable's platform-accurate help.
pub const descendants_supported = process_tree.descendants_supported;

/// REQ-JANITOR-015: formats the version banner ("janitor <version> (<sha>)")
/// into `buf` and returns the written slice (no trailing newline). Buffer-based
/// rather than writer-based so the executable's stdout path and the unit test
/// share one formatting routine; 256 bytes is ample for a semver and short sha.
pub fn versionLine(buf: []u8) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "janitor {s} ({s})", .{ version, git_sha });
}

const default_grace_ms: u64 = 1500;
const default_poll_ms: u64 = 100;

pub const Config = struct {
    watch_path: ?[]const u8 = null,
    watch_pid: ?posix.pid_t = null,
    grace_ms: u64 = default_grace_ms,
    poll_ms: u64 = default_poll_ms,
    drain_scope: DrainScope = .snapshot,
    command: []const []const u8,
};

/// Snapshot draining is the safe default. The explicit escape hatch preserves
/// the historical behavior for programs that deliberately self-daemonize.
pub const DrainScope = enum {
    snapshot,
    pgroup_only,
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
    /// The direct child remains a zombie after this status is observed. Since
    /// it is also the process-group leader, that retains `child_pgid` until
    /// every numeric process-group operation has finished.
    observed: u8,
    reaped: u8,
};

// Zig 0.15 exposes Linux's waitid syscall but not the libc wrapper. Darwin
// provides the POSIX function; use its ABI types directly until std.posix
// grows that wrapper.
extern "c" fn waitid(idtype: c_uint, id: c_uint, info: *posix.siginfo_t, options: c_int) c_int;

const TeardownReason = enum {
    parent_exited,
    watched_pid_exited,
    path_missing,
    signal,
    child_exited,
};

const WatchEvent = union(enum) {
    parent_exited,
    watched_pid_exited,
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
    var watch_pid: ?posix.pid_t = null;
    var grace_ms = default_grace_ms;
    var poll_ms = default_poll_ms;
    var drain_scope: DrainScope = .snapshot;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            const command = args[i + 1 ..];
            if (command.len == 0) return error.MissingCommand;
            return .{
                .watch_path = watch_path,
                .watch_pid = watch_pid,
                .grace_ms = grace_ms,
                .poll_ms = poll_ms,
                .drain_scope = drain_scope,
                .command = command,
            };
        } else if (std.mem.eql(u8, arg, "--watch-path")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            watch_path = args[i];
        } else if (std.mem.eql(u8, arg, "--watch-pid")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            const pid = std.fmt.parseInt(posix.pid_t, args[i], 10) catch return error.InvalidNumber;
            if (pid <= 0) return error.InvalidNumber;
            watch_pid = pid;
        } else if (std.mem.eql(u8, arg, "--grace-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            grace_ms = std.fmt.parseUnsigned(u64, args[i], 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            poll_ms = std.fmt.parseUnsigned(u64, args[i], 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--pgroup-only")) {
            drain_scope = .pgroup_only;
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
    var terminal_foreground = claimTerminalForeground(posix.STDIN_FILENO, child_pgid);
    defer restoreTerminalForeground(&terminal_foreground);

    var child_state: ChildState = .running;
    var watcher = Watcher.init(
        original_parent,
        child_pid,
        config.watch_path,
        config.watch_pid,
    ) catch return error.WaitFailed;
    defer watcher.deinit();

    if (getParentPid() != original_parent) {
        return teardown(allocator, child_pid, child_pgid, config, &watcher, &child_state, .parent_exited);
    }

    while (true) {
        const event = watcher.wait(null) catch return error.WaitFailed;
        switch (event) {
            .parent_exited => return teardown(
                allocator,
                child_pid,
                child_pgid,
                config,
                &watcher,
                &child_state,
                .parent_exited,
            ),
            .watched_pid_exited => return teardown(
                allocator,
                child_pid,
                child_pgid,
                config,
                &watcher,
                &child_state,
                .watched_pid_exited,
            ),
            .path_missing => return teardown(
                allocator,
                child_pid,
                child_pgid,
                config,
                &watcher,
                &child_state,
                .path_missing,
            ),
            .signal => return teardown(allocator, child_pid, child_pgid, config, &watcher, &child_state, .signal),
            .child_exited => {
                if (!tryPollChild(child_pid, &child_state)) continue;
                // On Linux/Darwin the exited group leader is deliberately held
                // as a zombie to reserve its PGID.  `kill(-pgid, 0)` therefore
                // sees the reservation itself; only another live member makes
                // this a real teardown.
                if (originalGroupHasLiveMember(allocator, child_pid, child_pgid, child_state)) {
                    return teardown(allocator, child_pid, child_pgid, config, &watcher, &child_state, .child_exited);
                }

                return reapChild(child_pid, &child_state);
            },
            .timeout => unreachable,
        }
    }
}

fn teardown(
    allocator: std.mem.Allocator,
    child_pid: posix.pid_t,
    child_pgid: posix.pid_t,
    config: Config,
    watcher: *Watcher,
    child_state: *ChildState,
    reason: TeardownReason,
) u8 {
    // Teardown diagnostics are safety disclosures, so every reporter writes
    // through an unbuffered stderr interface. A deferred flush could fail
    // after a reporter had accepted bytes and make that disclosure disappear.
    var stderr = std.fs.File.stderr().writer(&.{});

    return teardownWithDiagnostics(
        allocator,
        child_pid,
        child_pgid,
        config,
        watcher,
        child_state,
        reason,
        &stderr.interface,
    );
}

fn teardownWithDiagnostics(
    allocator: std.mem.Allocator,
    child_pid: posix.pid_t,
    child_pgid: posix.pid_t,
    config: Config,
    watcher: *Watcher,
    child_state: *ChildState,
    reason: TeardownReason,
    diagnostics: *std.Io.Writer,
) u8 {
    _ = reason;

    var drain_set = DrainSet.init(allocator, config.drain_scope, child_pid, child_pgid) catch |err| {
        const plan = discoveryPlan(.capture_failed);
        reportDiscoveryPlan(diagnostics, plan, @errorName(err));
        return teardownGroupOnly(plan, child_pid, child_pgid, config, watcher, child_state, diagnostics);
    };
    defer drain_set.deinit(allocator);

    reportDiscoveryPlan(diagnostics, drain_set.plan, null);
    const sent_term = signalDrainSet(&drain_set, child_pgid, child_state, posix.SIG.TERM, diagnostics);

    const deadline_ns = monotonicNowNs() + msToNs(config.grace_ms);
    while (monotonicNowNs() < deadline_ns) {
        _ = tryPollChild(child_pid, child_state);
        latchReapedUnreservedGroup(&drain_set, child_state, diagnostics);
        if (!drainSetAlive(&drain_set, allocator, child_pgid, child_state, diagnostics)) break;

        const remaining_ms = remainingMs(deadline_ns);
        if (remaining_ms == 0) break;
        const event = watcher.wait(remaining_ms) catch .timeout;
        if (event == .timeout) break;
    }

    // Resweep before deciding whether escalation is needed. An initially
    // in-group target can call setsid() in response to the group TERM: after
    // the leader exits, the old group is gone but that captured identity is
    // still a valid individual target only the resweep can rediscover.
    if (drain_set.captured.items.len != 0) {
        drain_set.resweep(allocator) catch |err| {
            std.log.warn(
                "descendant resweep unavailable ({s}); forcing only verified captured targets",
                .{@errorName(err)},
            );
        };
    }
    // A process can disappear from the second process-table enumeration while
    // its retained Linux handle still proves it is the captured identity. If
    // the original group is already dead, such a live captured target must
    // have escaped it; publish that exact capability for individual draining.
    if (!originalGroupHasLiveMember(allocator, child_pid, child_pgid, child_state.*)) {
        drain_set.original_group_dead = true;
        drain_set.promoteLiveCapturedTargets(allocator) catch |err| {
            std.log.warn(
                "could not retain live captured descendants after resweep ({s})",
                .{@errorName(err)},
            );
        };
    }

    var sent_kill = false;
    if (drainSetAlive(&drain_set, allocator, child_pgid, child_state, diagnostics)) {
        sent_kill = signalDrainSet(&drain_set, child_pgid, child_state, posix.SIG.KILL, diagnostics);
    }

    while (child_state.* == .running) {
        _ = tryPollChild(child_pid, child_state);
        if (child_state.* != .running) break;
        _ = watcher.wait(null) catch break;
    }

    const sequence = teardownSequence(
        childPgidReservationHeld(),
        child_state.* == .reaped,
        sent_term,
        sent_kill,
    );
    return reapAfterTeardown(child_pid, child_state, sequence);
}

/// Teardown always retains the original child group. Discovery can only add
/// identity-verified individual targets; it can never make group cleanup
/// conditional on a snapshot succeeding.
const DiscoveryResult = enum {
    complete,
    incomplete,
    capture_failed,
};

const TeardownDiagnostic = enum {
    incomplete_discovery,
    capture_failed,
    identity_mismatch,
    target_unavailable,
};

/// The plan is the authority for original-group signaling. Discovery only adds
/// individually verified targets; it can never suppress the group fast path.
const DiscoveryPlan = struct {
    signal_original_group: bool = true,
    diagnostic: ?TeardownDiagnostic = null,
};

/// A numeric PGID becomes unsafe to signal once its original group has been
/// observed gone: the kernel may recycle it. The latch makes that observation
/// monotonic across TERM, grace-period probes, and KILL escalation.
const DrainSignalAction = struct {
    signal_original_group: bool,
    signal_escaped_targets: bool,
    original_group_dead: bool,
};

/// The pure completion seam records every numeric process-group signal before
/// the one real reap. Keeping it in production code makes the reservation
/// ordering independently testable across all teardown routes.
const TeardownAction = enum { signal_term, signal_kill, reap };

const TeardownSequence = struct {
    actions: [3]TeardownAction = undefined,
    len: usize,

    fn at(self: TeardownSequence, index: usize) TeardownAction {
        std.debug.assert(index < self.len);
        return self.actions[index];
    }
};

/// Once a backend has reaped the child leader, its former numeric PGID might
/// already name an unrelated process group. This gate must precede every
/// numeric PGID probe as well as every group signal.
fn numericGroupSignalsAllowed(reservation_held: bool, child_reaped: bool) bool {
    return reservation_held or !child_reaped;
}

const ForcedTeardownPlan = struct {
    resweep: bool,
    signal_original_group: bool,
    signal_escaped_targets: bool,
};

/// The bounded resweep is mandatory whenever the initial snapshot captured
/// targets, before liveness decides whether KILL is necessary. Keeping this
/// order pure makes the TERM-to-setsid race independently testable.
fn forcedTeardownPlan(
    snapshot_captured_targets: bool,
    original_group_alive: bool,
    original_group_dead: bool,
) ForcedTeardownPlan {
    const action = drainSignalAction(.{}, original_group_alive, original_group_dead);
    return .{
        .resweep = snapshot_captured_targets,
        .signal_original_group = action.signal_original_group,
        .signal_escaped_targets = action.signal_escaped_targets,
    };
}

fn teardownSequence(
    reservation_held: bool,
    child_reaped: bool,
    sent_term: bool,
    sent_kill: bool,
) TeardownSequence {
    var sequence: TeardownSequence = .{ .len = 0 };
    if (sent_term) {
        sequence.actions[sequence.len] = .signal_term;
        sequence.len += 1;
    }
    // Platforms without WNOWAIT consume the leader while observing its status.
    // After that reap, a numeric PGID can name an unrelated later group, so the
    // production plan must suppress every later group signal.
    if (!reservation_held and child_reaped) {
        sequence.actions[sequence.len] = .reap;
        sequence.len += 1;
        return sequence;
    }
    if (sent_kill) {
        sequence.actions[sequence.len] = .signal_kill;
        sequence.len += 1;
    }
    sequence.actions[sequence.len] = .reap;
    sequence.len += 1;
    return sequence;
}

fn childPgidReservationHeld() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos => true,
        else => false,
    };
}

/// Decides the exact production signal set from an immediate group-liveness
/// observation. Individual capabilities remain safe after the original group
/// exits, but the numeric PGID does not.
fn drainSignalAction(
    plan: DiscoveryPlan,
    original_group_alive: bool,
    original_group_dead: bool,
) DrainSignalAction {
    const dead = original_group_dead or !original_group_alive;
    return .{
        .signal_original_group = plan.signal_original_group and !dead,
        .signal_escaped_targets = true,
        .original_group_dead = dead,
    };
}

fn discoveryPlan(result: DiscoveryResult) DiscoveryPlan {
    return switch (result) {
        .complete => .{},
        .incomplete => .{ .diagnostic = .incomplete_discovery },
        .capture_failed => .{ .diagnostic = .capture_failed },
    };
}

/// Executes the original-group portion of a discovery plan. Keeping this
/// separate from process discovery makes the same plan executable in tests.
fn executeDiscoveryPlan(
    plan: DiscoveryPlan,
    child_pgid: posix.pid_t,
    signal: u8,
    signal_group: *const fn (posix.pid_t, u8) void,
) void {
    if (plan.signal_original_group) signal_group(child_pgid, signal);
}

/// Writes one diagnostic completely before returning its error to the caller.
/// This keeps injected buffered writers honest too: a flush failure takes the
/// same fallback path as an immediate write failure.
fn writeDiagnostic(comptime format: []const u8, writer: *std.Io.Writer, args: anytype) ?std.Io.Writer.Error {
    writer.print(format, args) catch return error.WriteFailed;
    writer.flush() catch return error.WriteFailed;
    return null;
}

fn reportDiscoveryPlan(writer: *std.Io.Writer, plan: DiscoveryPlan, detail: ?[]const u8) void {
    switch (plan.diagnostic orelse return) {
        .incomplete_discovery => if (writeDiagnostic(
            "janitor: descendant snapshot was incomplete; signaling only identities with proven ancestry\n",
            writer,
            .{},
        )) |err| reportDiagnosticWriteFailure(err),
        .capture_failed => if (writeDiagnostic(
            "janitor: descendant snapshot unavailable ({s}); draining only original process group\n",
            writer,
            .{detail orelse "unknown"},
        )) |err| reportDiagnosticWriteFailure(err),
        else => unreachable,
    }
}

const TargetDecision = union(enum) {
    live,
    done,
    diagnostic: TeardownDiagnostic,
};

/// Converts side-effect results into diagnostics at the supervision boundary.
/// A stale result specifically means the captured `(pid, start_time)` no
/// longer identifies the process, and must never degrade into a silent skip.
fn targetDecision(result: process_tree.TargetResult) TargetDecision {
    return switch (result) {
        .live => .live,
        .signaled, .gone => .done,
        .stale => .{ .diagnostic = .identity_mismatch },
        else => .{ .diagnostic = .target_unavailable },
    };
}

fn reportTargetDecision(writer: *std.Io.Writer, decision: TargetDecision, operation: []const u8) void {
    const diagnostic = switch (decision) {
        .diagnostic => |value| value,
        else => return,
    };
    switch (diagnostic) {
        .identity_mismatch => if (writeDiagnostic(
            "janitor: captured descendant identity mismatch during {s}; skipped individual target\n",
            writer,
            .{operation},
        )) |err| reportDiagnosticWriteFailure(err),
        .target_unavailable => if (writeDiagnostic(
            "janitor: could not verify captured descendant during {s}\n",
            writer,
            .{operation},
        )) |err| reportDiagnosticWriteFailure(err),
        else => unreachable,
    }
}

fn reportDiagnosticWriteFailure(err: std.Io.Writer.Error) void {
    std.log.warn("could not emit teardown diagnostic ({s})", .{@errorName(err)});
}

/// Owns the discovery snapshots behind every individual signal capability.
/// The original group remains separate because it is the sole wholesale group
/// target Janitor is allowed to signal.
const DrainSet = struct {
    initial: ?process_tree.Snapshot = null,
    reswept: ?process_tree.Snapshot = null,
    captured: std.ArrayList(process_tree.ProcessRecord) = .empty,
    escaped: std.ArrayList(*process_tree.CapturedTarget) = .empty,
    child_pgid: posix.pid_t,
    plan: DiscoveryPlan = .{},
    original_group_dead: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        scope: DrainScope,
        child_pid: posix.pid_t,
        child_pgid: posix.pid_t,
    ) !DrainSet {
        var result: DrainSet = .{ .child_pgid = child_pgid };
        errdefer result.deinit(allocator);
        if (scope == .pgroup_only) return result;
        if (!process_tree.descendants_supported) return error.UnsupportedPlatform;

        var snapshot = try process_tree.captureAll(allocator);
        errdefer snapshot.deinit(allocator);
        result.plan = discoveryPlan(if (snapshot.incomplete) .incomplete else .complete);
        const child = findTargetByPid(snapshot.targets, child_pid) orelse return error.ChildNotInSnapshot;
        try appendEscapedClosure(
            allocator,
            &result.captured,
            &result.escaped,
            snapshot.targets,
            child.record(),
            child_pgid,
        );
        result.initial = snapshot;
        return result;
    }

    fn deinit(self: *DrainSet, allocator: std.mem.Allocator) void {
        self.escaped.deinit(allocator);
        self.captured.deinit(allocator);
        if (self.reswept) |*snapshot| snapshot.deinit(allocator);
        if (self.initial) |*snapshot| snapshot.deinit(allocator);
        self.* = undefined;
    }

    /// One bounded refresh immediately before KILL narrows the TERM-to-KILL
    /// spawn race. It adds only targets anchored under still-matching records.
    fn resweep(self: *DrainSet, allocator: std.mem.Allocator) !void {
        if (self.initial == null or self.reswept != null) return;
        var snapshot = try process_tree.captureAll(allocator);
        errdefer snapshot.deinit(allocator);
        if (snapshot.incomplete) {
            std.log.warn("descendant resweep was incomplete; adding only proven identities", .{});
        }
        var current = std.ArrayList(process_tree.ProcessRecord).empty;
        defer current.deinit(allocator);
        for (snapshot.targets) |target| try current.append(allocator, target.record());
        var discovered = try process_tree.resweepDescendants(allocator, self.captured.items, current.items);
        defer discovered.deinit(allocator);
        if (discovered.incomplete) {
            std.log.warn("descendant resweep could not prove every ancestry link", .{});
        }
        try appendResweptTargets(
            allocator,
            &self.escaped,
            snapshot.targets,
            discovered.records,
            self.child_pgid,
        );
        self.reswept = snapshot;
    }

    /// After the original group dies, a live capability captured from that
    /// group can only name an escaped process. This covers a TERM handler that
    /// calls setsid() and is reparented before the resweep's numeric scan can
    /// read it, without authorizing any PID that was not captured initially.
    fn promoteLiveCapturedTargets(self: *DrainSet, allocator: std.mem.Allocator) !void {
        const initial = self.initial orelse return;
        for (initial.targets) |target| {
            if (!containsCapturedIdentity(self.captured.items, target.record().identity)) continue;
            if (target.liveness() != .live) continue;
            try appendUniqueTarget(allocator, &self.escaped, target);
        }
    }
};

fn containsCapturedIdentity(
    captured: []const process_tree.ProcessRecord,
    identity: process_tree.ProcessIdentity,
) bool {
    for (captured) |record| if (record.identity.eql(identity)) return true;
    return false;
}

/// Resweep targets remain owned by `snapshot` until the entire publication is
/// guaranteed infallible. This prevents an allocation failure from leaving
/// `escaped` with pointers into a snapshot its errdefer will destroy.
fn appendResweptTargets(
    allocator: std.mem.Allocator,
    escaped: *std.ArrayList(*process_tree.CapturedTarget),
    snapshot_targets: []const *process_tree.CapturedTarget,
    records: []const process_tree.ProcessRecord,
    child_pgid: posix.pid_t,
) !void {
    try escaped.ensureTotalCapacity(allocator, escaped.items.len + records.len);
    for (records) |record| {
        if (!record.isEscaped(child_pgid)) continue;
        const target = findTargetByIdentity(snapshot_targets, record.identity) orelse continue;
        appendUniqueTargetAssumeCapacity(escaped, target);
    }
}

fn appendEscapedClosure(
    allocator: std.mem.Allocator,
    captured: *std.ArrayList(process_tree.ProcessRecord),
    escaped: *std.ArrayList(*process_tree.CapturedTarget),
    targets: []const *process_tree.CapturedTarget,
    child: process_tree.ProcessRecord,
    child_pgid: posix.pid_t,
) !void {
    var records = std.ArrayList(process_tree.ProcessRecord).empty;
    defer records.deinit(allocator);
    for (targets) |target| try records.append(allocator, target.record());
    var closure = try process_tree.descendantClosure(allocator, records.items, child.identity);
    defer closure.deinit(allocator);
    if (closure.incomplete) {
        std.log.warn("descendant snapshot could not prove every ancestry link", .{});
    }
    for (closure.records) |record| {
        try appendUniqueRecord(allocator, captured, record);
        if (!record.isEscaped(child_pgid)) continue;
        const target = findTargetByIdentity(targets, record.identity) orelse continue;
        try appendUniqueTarget(allocator, escaped, target);
    }
}

fn appendUniqueRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(process_tree.ProcessRecord),
    candidate: process_tree.ProcessRecord,
) !void {
    for (records.items) |known| if (known.identity.eql(candidate.identity)) return;
    try records.append(allocator, candidate);
}

fn findTargetByPid(
    targets: []const *process_tree.CapturedTarget,
    pid: posix.pid_t,
) ?*process_tree.CapturedTarget {
    for (targets) |target| if (target.record().identity.pid == pid) return target;
    return null;
}

fn findTargetByIdentity(
    targets: []const *process_tree.CapturedTarget,
    identity: process_tree.ProcessIdentity,
) ?*process_tree.CapturedTarget {
    for (targets) |target| if (target.record().identity.eql(identity)) return target;
    return null;
}

fn appendUniqueTarget(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(*process_tree.CapturedTarget),
    target: *process_tree.CapturedTarget,
) !void {
    for (targets.items) |known| if (known.record().identity.eql(target.record().identity)) return;
    try targets.append(allocator, target);
}

fn appendUniqueTargetAssumeCapacity(
    targets: *std.ArrayList(*process_tree.CapturedTarget),
    target: *process_tree.CapturedTarget,
) void {
    for (targets.items) |known| if (known.record().identity.eql(target.record().identity)) return;
    targets.appendAssumeCapacity(target);
}

fn signalDrainSet(
    drain_set: *DrainSet,
    child_pgid: posix.pid_t,
    child_state: *const ChildState,
    signal: u8,
    diagnostics: *std.Io.Writer,
) bool {
    latchReapedUnreservedGroup(drain_set, child_state, diagnostics);
    const action = drainSignalAction(
        drain_set.plan,
        isProcessGroupAlive(child_pgid),
        drain_set.original_group_dead,
    );
    drain_set.original_group_dead = action.original_group_dead;
    if (action.signal_original_group) {
        // This remains the original group's fast path; escaped descendants are
        // never promoted into a group target.
        executeDiscoveryPlan(drain_set.plan, child_pgid, signal, signalProcessGroup);
    }
    if (action.signal_escaped_targets) {
        for (drain_set.escaped.items) |target| {
            reportTargetDecision(diagnostics, targetDecision(target.signal(signal)), "individual signal");
        }
    }
    return action.signal_original_group;
}

/// A retained zombie reserves its numeric PGID but is not a live group member.
/// The per-process capture is the discriminator. A capture can be incomplete
/// because an unrelated process raced discovery; that does not turn the held
/// leader itself into a live member. Any captured non-leader in this PGID still
/// keeps teardown active.
fn originalGroupHasLiveMember(
    allocator: std.mem.Allocator,
    child_pid: posix.pid_t,
    child_pgid: posix.pid_t,
    child_state: ChildState,
) bool {
    if (!isProcessGroupAlive(child_pgid)) return false;
    if (child_state == .running or !childPgidReservationHeld()) return true;

    var snapshot = process_tree.captureAll(allocator) catch return true;
    defer snapshot.deinit(allocator);
    for (snapshot.targets) |target| {
        const record = target.record();
        if (record.identity.pid != child_pid and record.pgid == child_pgid) return true;
    }
    return false;
}

fn latchReapedUnreservedGroup(
    drain_set: *DrainSet,
    child_state: *const ChildState,
    diagnostics: *std.Io.Writer,
) void {
    if (childPgidReservationHeld() or child_state.* != .reaped or drain_set.original_group_dead) return;
    drain_set.original_group_dead = true;
    if (writeDiagnostic(
        "janitor: child leader was reaped; skipping further process-group signals to avoid PGID reuse\n",
        diagnostics,
        .{},
    )) |err| reportDiagnosticWriteFailure(err);
}

fn drainSetAlive(
    drain_set: *DrainSet,
    allocator: std.mem.Allocator,
    child_pgid: posix.pid_t,
    child_state: *const ChildState,
    diagnostics: *std.Io.Writer,
) bool {
    const group_alive = originalGroupHasLiveMember(allocator, drain_set.child_pgid, child_pgid, child_state.*);
    drain_set.original_group_dead = drain_set.original_group_dead or !group_alive;
    if (group_alive and !drain_set.original_group_dead) return true;
    for (drain_set.escaped.items) |target| {
        switch (targetDecision(target.liveness())) {
            .live => return true,
            .done => {},
            .diagnostic => |diagnostic| reportTargetDecision(
                diagnostics,
                .{ .diagnostic = diagnostic },
                "liveness probe",
            ),
        }
    }
    return false;
}

fn teardownGroupOnly(
    plan: DiscoveryPlan,
    child_pid: posix.pid_t,
    child_pgid: posix.pid_t,
    config: Config,
    watcher: *Watcher,
    child_state: *ChildState,
    diagnostics: *std.Io.Writer,
) u8 {
    var sent_term = false;
    var sent_kill = false;
    // This gate intentionally comes before the first liveness probe. BSD
    // kqueue has already reaped a child-exit event, so even probe-only use of
    // the numeric PGID could observe a recycled unrelated group.
    if (numericGroupSignalsAllowed(childPgidReservationHeld(), child_state.* == .reaped) and
        isProcessGroupAlive(child_pgid))
    {
        executeDiscoveryPlan(plan, child_pgid, posix.SIG.TERM, signalProcessGroup);
        sent_term = true;

        const deadline_ns = monotonicNowNs() + msToNs(config.grace_ms);
        while (monotonicNowNs() < deadline_ns) {
            _ = tryPollChild(child_pid, child_state);
            if (!numericGroupSignalsAllowed(childPgidReservationHeld(), child_state.* == .reaped)) {
                if (writeDiagnostic(
                    "janitor: child leader was reaped; skipping further process-group signals to avoid PGID reuse\n",
                    diagnostics,
                    .{},
                )) |err| reportDiagnosticWriteFailure(err);
                break;
            }
            if (!isProcessGroupAlive(child_pgid)) break;

            const remaining_ms = remainingMs(deadline_ns);
            if (remaining_ms == 0) break;
            const event = watcher.wait(remaining_ms) catch .timeout;
            if (event == .timeout) break;
        }

        if (numericGroupSignalsAllowed(childPgidReservationHeld(), child_state.* == .reaped)) {
            if (isProcessGroupAlive(child_pgid)) {
                executeDiscoveryPlan(plan, child_pgid, posix.SIG.KILL, signalProcessGroup);
                sent_kill = true;
            }
        }
    }

    while (child_state.* == .running) {
        _ = tryPollChild(child_pid, child_state);
        if (child_state.* != .running) break;
        _ = watcher.wait(null) catch break;
    }

    const sequence = teardownSequence(
        childPgidReservationHeld(),
        child_state.* == .reaped,
        sent_term,
        sent_kill,
    );
    return reapAfterTeardown(child_pid, child_state, sequence);
}

fn tryPollChild(child_pid: posix.pid_t, child_state: *ChildState) bool {
    if (child_state.* != .running) return true;

    const status = observeChild(child_pid) orelse return false;
    child_state.* = if (childPgidReservationHeld()) .{ .observed = status } else .{ .reaped = status };
    return true;
}

/// Observes, but never consumes, the direct child's exit. Holding that zombie
/// is what makes signaling `-child_pgid` safe: a process group leader's PID
/// cannot be recycled before it is reaped.
fn observeChild(child_pid: posix.pid_t) ?u8 {
    return switch (builtin.os.tag) {
        .linux => observeChildLinux(child_pid),
        .macos, .ios, .tvos, .watchos, .visionos => observeChildDarwin(child_pid),
        // The remaining supported BSD watcher targets do not offer WNOWAIT
        // through their current platform ABI. They retain the dead-group latch
        // and group-only behavior documented by REQ-JANITOR-026, but cannot
        // claim this stronger PGID-reservation guarantee.
        else => observeChildWithoutReservation(child_pid),
    };
}

fn observeChildLinux(child_pid: posix.pid_t) ?u8 {
    const linux = std.os.linux;
    while (true) {
        var info = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.waitid(.PID, child_pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT);
        const errno_code = posix.errno(rc);
        switch (waitidErrnoAction(errno_code)) {
            .success => {},
            .retry => continue,
            .fatal => waitidUnexpectedErrno(errno_code),
        }
        if (info.signo == 0) return null;
        return childStatusFromSiginfo(info.code, info.fields.common.second.sigchld.status);
    }
}

fn observeChildDarwin(child_pid: posix.pid_t) ?u8 {
    while (true) {
        var info = std.mem.zeroes(posix.siginfo_t);
        const rc = waitid(1, @intCast(child_pid), &info, 0x00000004 | 0x00000001 | 0x00000020);
        const errno_code = posix.errno(rc);
        switch (waitidErrnoAction(errno_code)) {
            .success => {},
            .retry => continue,
            .fatal => waitidUnexpectedErrno(errno_code),
        }
        if (info.signo == 0) return null;
        return childStatusFromSiginfo(info.code, info.status);
    }
}

/// `NOHANG` with a zero siginfo is the sole running result.  The direct child
/// remains owned until Janitor reaps it, so ECHILD and option/ABI failures mean
/// our supervision invariant is broken rather than that the child is running.
fn waitidUnexpectedErrno(err: posix.E) noreturn {
    std.debug.panic("waitid direct-child observation failed unexpectedly: {s}", .{@tagName(err)});
}

const WaitidErrnoAction = enum { success, retry, fatal };

/// Kept pure so tests pin the narrow set of errors that may be treated as a
/// retry. In particular, ECHILD is never a disguised "still running" result.
fn waitidErrnoAction(err: posix.E) WaitidErrnoAction {
    return switch (err) {
        .SUCCESS => .success,
        .INTR => .retry,
        else => .fatal,
    };
}

fn observeChildWithoutReservation(child_pid: posix.pid_t) ?u8 {
    const result = posix.waitpid(child_pid, posix.W.NOHANG);
    if (result.pid == 0) return null;
    return encodeStatus(result.status);
}

const ChildExitCode = enum {
    exited,
    killed,
    dumped,
    trapped,
    stopped,
    continued,
    unexpected,
};

fn childExitCodeFromSiginfo(code: c_int) ChildExitCode {
    return switch (code) {
        1 => .exited, // CLD_EXITED
        2 => .killed, // CLD_KILLED
        3 => .dumped, // CLD_DUMPED
        4 => .trapped, // CLD_TRAPPED
        5 => .stopped, // CLD_STOPPED
        6 => .continued, // CLD_CONTINUED
        else => .unexpected,
    };
}

/// POSIX CLD_EXITED, CLD_KILLED, and CLD_DUMPED respectively. `waitid`
/// reports the same terminal outcome as `waitpid`, just without reaping it.
fn childStatusFromSiginfo(code: c_int, status: c_int) u8 {
    return switch (childExitCodeFromSiginfo(code)) {
        .exited => @intCast(status),
        .killed, .dumped => @intCast(@min(@as(c_int, 255), 128 + status)),
        .trapped, .stopped, .continued => std.debug.panic(
            "waitid reported non-terminal CLD code {d} with WEXITED",
            .{code},
        ),
        .unexpected => std.debug.panic("waitid reported unknown CLD code {d}", .{code}),
    };
}

/// Performs Janitor's one real reap after all process-group signaling and
/// probing. For WNOWAIT platforms the status was latched earlier; `waitpid`
/// here exists only to release the zombie and must agree with that latch.
fn reapChild(child_pid: posix.pid_t, child_state: *ChildState) u8 {
    return switch (child_state.*) {
        .reaped => |status| status,
        .observed => |status| blk: {
            _ = posix.waitpid(child_pid, 0);
            child_state.* = .{ .reaped = status };
            break :blk status;
        },
        .running => blk: {
            const result = posix.waitpid(child_pid, 0);
            const status = encodeStatus(result.status);
            child_state.* = .{ .reaped = status };
            break :blk status;
        },
    };
}

fn reapAfterTeardown(
    child_pid: posix.pid_t,
    child_state: *ChildState,
    sequence: TeardownSequence,
) u8 {
    // No numeric process-group probe or signal may follow this reap: while
    // the group leader is a zombie its PID reserves the PGID against reuse.
    std.debug.assert(sequence.len > 0);
    std.debug.assert(sequence.at(sequence.len - 1) == .reap);
    return reapChild(child_pid, child_state);
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

const TerminalForeground = struct {
    fd: posix.fd_t,
    original_pgid: posix.pid_t,
    active: bool = true,

    fn restore(self: *TerminalForeground) void {
        if (!self.active) return;
        self.active = false;
        _ = tcSetForeground(self.fd, self.original_pgid);
    }
};

fn restoreTerminalForeground(foreground: *?TerminalForeground) void {
    if (foreground.*) |*state| state.restore();
}

fn claimTerminalForeground(fd: posix.fd_t, child_pgid: posix.pid_t) ?TerminalForeground {
    if (!posix.isatty(fd)) return null;

    const original_pgid = tcGetForeground(fd) orelse return null;
    if (!tcSetForeground(fd, child_pgid)) return null;

    return .{
        .fd = fd,
        .original_pgid = original_pgid,
    };
}

fn tcGetForeground(fd: posix.fd_t) ?posix.pid_t {
    switch (builtin.os.tag) {
        .linux => {
            var pgrp: posix.pid_t = undefined;
            while (true) {
                const rc = std.os.linux.tcgetpgrp(fd, &pgrp);
                switch (posix.errno(rc)) {
                    .SUCCESS => return pgrp,
                    .INTR => continue,
                    else => return null,
                }
            }
        },
        else => {
            while (true) {
                const pgrp = tcgetpgrp(@intCast(fd));
                switch (posix.errno(pgrp)) {
                    .SUCCESS => return pgrp,
                    .INTR => continue,
                    else => return null,
                }
            }
        },
    }
}

fn tcSetForeground(fd: posix.fd_t, pgid: posix.pid_t) bool {
    // Reclaiming the terminal from a background process group (the restore path)
    // would deliver SIGTTOU and stop janitor, so block it strictly around the
    // call and restore the exact prior mask. Scoping it here keeps SIGTTOU from
    // leaking into janitor's wider supervision lifetime, including when the call
    // below fails and no handoff is claimed.
    var block = posix.sigemptyset();
    posix.sigaddset(&block, posix.SIG.TTOU);
    var previous: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &block, &previous);
    defer posix.sigprocmask(posix.SIG.SETMASK, &previous, null);

    switch (builtin.os.tag) {
        .linux => {
            var pgrp = pgid;
            while (true) {
                const rc = std.os.linux.tcsetpgrp(fd, &pgrp);
                switch (posix.errno(rc)) {
                    .SUCCESS => return true,
                    .INTR => continue,
                    else => return false,
                }
            }
        },
        else => {
            while (true) {
                const rc = tcsetpgrp(@intCast(fd), pgid);
                switch (posix.errno(rc)) {
                    .SUCCESS => return true,
                    .INTR => continue,
                    else => return false,
                }
            }
        },
    }
}

extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;
extern "c" fn tcsetpgrp(fd: c_int, pgrp: posix.pid_t) c_int;

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
        watched = 5,
    };

    fn init(
        parent_pid: posix.pid_t,
        child_pid: posix.pid_t,
        watch_path: ?[]const u8,
        watch_pid: ?posix.pid_t,
    ) !KqueueWatcher {
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
        if (watch_pid) |pid| {
            watcher.addProc(pid, .watched) catch |err| switch (err) {
                error.ProcessNotFound => watcher.pending.put(.watched_pid_exited),
                else => return err,
            };
        }
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
            .watched => .watched_pid_exited,
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

        const open_flags: posix.O = if (comptime builtin.os.tag == .macos)
            .{ .ACCMODE = .RDONLY, .EVTONLY = true, .CLOEXEC = true }
        else
            // EVTONLY is a Darwin-only extension. Other kqueue platforms use
            // the portable read-only descriptor for EVFILT_VNODE.
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
        const fd = try posix.open(path, open_flags, 0);
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
    watched_fd: ?posix.fd_t = null,
    signal_fd: ?posix.fd_t = null,
    inotify_fd: ?posix.fd_t = null,
    pending: PendingEvent = .{},

    const linux = std.os.linux;
    const EventId = enum(u64) {
        parent = 1,
        child = 2,
        signal = 3,
        path = 4,
        watched = 5,
    };

    fn init(
        parent_pid: posix.pid_t,
        child_pid: posix.pid_t,
        watch_path: ?[]const u8,
        watch_pid: ?posix.pid_t,
    ) !LinuxWatcher {
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

        watcher.watched_fd = if (watch_pid) |pid|
            linuxPidfdOpen(pid) catch |err| switch (err) {
                error.ProcessNotFound => blk: {
                    watcher.pending.put(.watched_pid_exited);
                    break :blk null;
                },
                else => return err,
            }
        else
            null;
        if (watcher.watched_fd) |fd| try watcher.addFd(fd, .watched);

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
        if (self.watched_fd) |fd| posix.close(fd);
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
            .watched => .watched_pid_exited,
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
    fn init(_: posix.pid_t, _: posix.pid_t, _: ?[]const u8, _: ?posix.pid_t) !UnsupportedWatcher {
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

test "parse accepts watch pid" {
    const args = &.{ "--watch-pid", "4321", "--", "sh", "-c", "true" };
    const parsed = try parseArgs(args);
    try std.testing.expectEqual(@as(posix.pid_t, 4321), parsed.watch_pid.?);
    try std.testing.expectEqualStrings("sh", parsed.command[0]);
}

test "parse defaults to snapshot draining and accepts pgroup-only" {
    const default_config = try parseArgs(&.{ "--", "true" });
    try std.testing.expectEqual(DrainScope.snapshot, default_config.drain_scope);

    const pgroup_only_config = try parseArgs(&.{ "--pgroup-only", "--", "true" });
    try std.testing.expectEqual(DrainScope.pgroup_only, pgroup_only_config.drain_scope);
}

test "parse rejects invalid watch pid" {
    try std.testing.expectError(error.InvalidNumber, parseArgs(&.{ "--watch-pid", "not-a-pid", "--", "true" }));
    try std.testing.expectError(error.InvalidNumber, parseArgs(&.{ "--watch-pid", "-1", "--", "true" }));
    try std.testing.expectError(error.InvalidNumber, parseArgs(&.{ "--watch-pid", "0", "--", "true" }));
}

test "parse rejects missing command" {
    try std.testing.expectError(error.MissingCommand, parseArgs(&.{}));
    try std.testing.expectError(error.MissingCommand, parseArgs(&.{"--"}));
}

test "versionLine renders version and git sha" {
    var buf: [256]u8 = undefined;
    const line = try versionLine(&buf);
    try std.testing.expect(std.mem.startsWith(u8, line, "janitor "));
    // The configured version and sha are both interpolated, wrapped in parens.
    try std.testing.expect(std.mem.indexOf(u8, line, version) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, git_sha) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '(') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, ')') != null);
}

test "discovery plan executes original-group cleanup and reports limitations" {
    const Recorder = struct {
        var calls: usize = 0;
        var pgid: posix.pid_t = 0;
        var signal: u8 = 0;

        fn signalGroup(child_pgid: posix.pid_t, value: u8) void {
            calls += 1;
            pgid = child_pgid;
            signal = value;
        }
    };

    const cases = [_]struct {
        result: DiscoveryResult,
        detail: ?[]const u8,
        condition: []const u8,
    }{
        .{ .result = .incomplete, .detail = null, .condition = "incomplete" },
        .{ .result = .capture_failed, .detail = "ProcessNotFound", .condition = "unavailable (ProcessNotFound)" },
    };

    for (cases) |case| {
        Recorder.calls = 0;
        const plan = discoveryPlan(case.result);
        executeDiscoveryPlan(plan, 4321, posix.SIG.TERM, Recorder.signalGroup);
        try std.testing.expect(plan.signal_original_group);
        try std.testing.expectEqual(@as(usize, 1), Recorder.calls);
        try std.testing.expectEqual(@as(posix.pid_t, 4321), Recorder.pgid);
        try std.testing.expectEqual(posix.SIG.TERM, Recorder.signal);

        var output: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        reportDiscoveryPlan(&writer, plan, case.detail);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), case.condition) != null);
    }
}

test "drain signal action latches a dead group while retaining escaped targets" {
    const plan = discoveryPlan(.complete);

    const dead_group = drainSignalAction(plan, false, false);
    try std.testing.expect(!dead_group.signal_original_group);
    try std.testing.expect(dead_group.signal_escaped_targets);
    try std.testing.expect(dead_group.original_group_dead);

    const later_round = drainSignalAction(plan, true, dead_group.original_group_dead);
    try std.testing.expect(!later_round.signal_original_group);
    try std.testing.expect(later_round.signal_escaped_targets);
    try std.testing.expect(later_round.original_group_dead);

    const live_group = drainSignalAction(plan, true, false);
    try std.testing.expect(live_group.signal_original_group);
    try std.testing.expect(live_group.signal_escaped_targets);
    try std.testing.expect(!live_group.original_group_dead);
}

test "reaped non-reservation leader suppresses the initial numeric group probe" {
    // FreeBSD/NetBSD child-exit observation consumes the group leader. The
    // fallback must not even test that numeric PGID before declining TERM.
    try std.testing.expect(!numericGroupSignalsAllowed(false, true));
    try std.testing.expect(numericGroupSignalsAllowed(false, false));
    try std.testing.expect(numericGroupSignalsAllowed(true, true));
}

test "forced teardown resweeps an in-group capture that escapes after TERM" {
    // The group died with its leader, but the snapshot had captured a member
    // that is still live after it called setsid() from its TERM handler. The
    // planner resweeps first and then retains only individual draining.
    const action = forcedTeardownPlan(true, false, true);
    try std.testing.expect(action.resweep);
    try std.testing.expect(!action.signal_original_group);
    try std.testing.expect(action.signal_escaped_targets);
}

test "teardown reaps after every numeric group signal" {
    const cases = [_]struct {
        name: []const u8,
        reservation_held: bool = true,
        child_reaped: bool = false,
        sent_term: bool,
        sent_kill: bool,
    }{
        .{ .name = "drain", .sent_term = true, .sent_kill = false },
        .{ .name = "escalate", .sent_term = true, .sent_kill = true },
        .{ .name = "discovery-failed", .sent_term = true, .sent_kill = true },
        .{ .name = "pgroup-only", .sent_term = true, .sent_kill = true },
        .{ .name = "child-self-exit", .sent_term = false, .sent_kill = false },
        .{
            .name = "bsd-reaped-during-grace",
            .reservation_held = false,
            .child_reaped = true,
            .sent_term = true,
            .sent_kill = false,
        },
        .{
            .name = "bsd-child-exited-before-teardown",
            .reservation_held = false,
            .child_reaped = true,
            .sent_term = false,
            .sent_kill = false,
        },
    };

    for (cases) |case| {
        const sequence = teardownSequence(case.reservation_held, case.child_reaped, case.sent_term, case.sent_kill);
        var reap_count: usize = 0;
        for (0..sequence.len) |index| {
            switch (sequence.at(index)) {
                .reap => {
                    reap_count += 1;
                    try std.testing.expectEqual(sequence.len - 1, index);
                },
                .signal_term, .signal_kill => try std.testing.expectEqual(@as(usize, 0), reap_count),
            }
        }
        try std.testing.expectEqual(@as(usize, 1), reap_count);
    }
}

test "waitid error and CLD seams classify only factual running and terminal states" {
    try std.testing.expectEqual(WaitidErrnoAction.success, waitidErrnoAction(.SUCCESS));
    try std.testing.expectEqual(WaitidErrnoAction.retry, waitidErrnoAction(.INTR));
    try std.testing.expectEqual(WaitidErrnoAction.fatal, waitidErrnoAction(.CHILD));
    try std.testing.expectEqual(WaitidErrnoAction.fatal, waitidErrnoAction(.INVAL));

    const cases = [_]struct { raw: c_int, expected: ChildExitCode }{
        .{ .raw = 1, .expected = .exited },
        .{ .raw = 2, .expected = .killed },
        .{ .raw = 3, .expected = .dumped },
        .{ .raw = 4, .expected = .trapped },
        .{ .raw = 5, .expected = .stopped },
        .{ .raw = 6, .expected = .continued },
        .{ .raw = 99, .expected = .unexpected },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, childExitCodeFromSiginfo(case.raw));
}

test "resweep publication allocation failure leaves drain set valid" {
    if (!process_tree.descendants_supported) return error.SkipZigTest;

    var snapshot = try process_tree.captureAll(std.testing.allocator);
    if (snapshot.targets.len == 0) {
        snapshot.deinit(std.testing.allocator);
        return error.SkipZigTest;
    }
    const target = snapshot.targets[0];
    const records = [_]process_tree.ProcessRecord{target.record()};
    var drain_set: DrainSet = .{
        .initial = snapshot,
        .child_pgid = 0,
        .original_group_dead = true,
    };
    defer drain_set.deinit(std.testing.allocator);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        appendResweptTargets(
            failing_allocator.allocator(),
            &drain_set.escaped,
            drain_set.initial.?.targets,
            &records,
            drain_set.child_pgid,
        ),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), drain_set.escaped.items.len);

    // With no published snapshot-owned pointers, the same decision seam that
    // drives signaling still excludes the recycled numeric group and preserves
    // the individually-addressable escalation path.
    const action = drainSignalAction(drain_set.plan, false, drain_set.original_group_dead);
    try std.testing.expect(!action.signal_original_group);
    try std.testing.expect(action.signal_escaped_targets);
}

test "stale descendant identity from completed discovery is diagnosed" {
    const plan = discoveryPlan(.complete);
    const decision = targetDecision(.stale);
    const expected: TargetDecision = .{ .diagnostic = .identity_mismatch };
    try std.testing.expectEqual(expected, decision);

    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    reportTargetDecision(&writer, decision, "individual signal");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "identity mismatch") != null);
    try std.testing.expect(plan.signal_original_group);
}

test "diagnostic writer failures are surfaced immediately" {
    var writer: std.Io.Writer = .failing;
    const failure = writeDiagnostic("janitor: test diagnostic\n", &writer, .{});
    try std.testing.expectEqual(error.WriteFailed, failure.?);
}
