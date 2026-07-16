//! Identity-safe process discovery and individually-addressable descendants.
//!
//! A PID is only an enumeration lead.  `ProcessIdentity` combines it with a
//! platform start token, and `CapturedTarget` keeps the platform capability
//! required to act on that exact process.  In particular, no public operation
//! in this module accepts a bare PID as an individual signal target.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

pub const descendants_supported = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

/// A start token is opaque to callers. Linux stores clock ticks; Darwin packs
/// `(start_tvsec, start_tvusec)`, so equality is the only supported operation.
pub const ProcessIdentity = struct {
    pid: posix.pid_t,
    start_token: u128,

    pub fn eql(left: ProcessIdentity, right: ProcessIdentity) bool {
        return left.pid == right.pid and left.start_token == right.start_token;
    }
};

/// Immutable process-table evidence captured while reading a process record.
pub const ProcessRecord = struct {
    identity: ProcessIdentity,
    ppid: posix.pid_t,
    pgid: posix.pid_t,

    pub fn isEscaped(self: ProcessRecord, original_pgid: posix.pid_t) bool {
        return self.pgid != original_pgid;
    }
};

pub const Discovery = struct {
    records: []ProcessRecord,
    incomplete: bool,

    pub fn deinit(self: *Discovery, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        self.* = undefined;
    }
};

/// Selects only the PPID-linked closure rooted at an exact identity. A missing
/// parent or duplicate PID makes the answer incomplete and excludes the branch;
/// it never turns a numeric PID into ownership evidence.
pub fn descendantClosure(
    allocator: std.mem.Allocator,
    table: []const ProcessRecord,
    root: ProcessIdentity,
) !Discovery {
    var selected = std.ArrayList(ProcessRecord).empty;
    errdefer selected.deinit(allocator);

    var incomplete = tableHasAmbiguityOrMissingParent(table);
    const root_index = uniqueExactIndexForPid(table, root.pid, &incomplete) orelse {
        return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = true };
    };
    if (!table[root_index].identity.eql(root)) {
        return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = true };
    }
    try selected.append(allocator, table[root_index]);

    var cursor: usize = 0;
    while (cursor < selected.items.len) : (cursor += 1) {
        const parent = selected.items[cursor];
        for (table) |candidate| {
            if (candidate.ppid != parent.identity.pid) continue;

            // Conflicting duplicate rows cannot prove a unique ancestry link.
            // Exact duplicates are collapsed by uniqueExactIndexForPid.
            if (uniqueExactIndexForPid(table, candidate.identity.pid, &incomplete) == null) continue;
            if (containsIdentity(selected.items, candidate.identity)) continue;

            // The table is immutable for the pure model, so a PPID link to an
            // already-selected exact parent is the complete available proof.
            try selected.append(allocator, candidate);
        }
    }

    return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = incomplete };
}

/// Performs one bounded resweep. New rows can join only beneath an exact
/// identity that was already captured and is still present in the resweep.
pub fn resweepDescendants(
    allocator: std.mem.Allocator,
    captured: []const ProcessRecord,
    resweep_table: []const ProcessRecord,
) !Discovery {
    var selected = std.ArrayList(ProcessRecord).empty;
    errdefer selected.deinit(allocator);

    var incomplete = tableHasAmbiguityOrMissingParent(resweep_table);
    // Every still-present captured identity is a possible safe anchor. A
    // stale root must not prevent a separately captured, still-live child
    // from anchoring its own new descendants; conversely, a recycled captured
    // PID is never allowed to bridge into the replacement's subtree.
    if (captured.len == 0) {
        return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = false };
    }

    for (captured) |anchor| {
        const captured_index = uniqueExactIndexForPid(captured, anchor.identity.pid, &incomplete) orelse continue;
        const expected = captured[captured_index];
        const index = uniqueExactIndexForPid(resweep_table, expected.identity.pid, &incomplete) orelse continue;
        const current = resweep_table[index];
        if (!current.identity.eql(expected.identity)) {
            incomplete = true;
            continue;
        }
        try appendUnique(allocator, &selected, current);
    }

    var cursor: usize = 0;
    while (cursor < selected.items.len) : (cursor += 1) {
        const parent = selected.items[cursor];
        for (resweep_table) |candidate| {
            if (candidate.ppid != parent.identity.pid) continue;
            if (uniqueExactIndexForPid(resweep_table, candidate.identity.pid, &incomplete) == null) continue;
            if (capturedRecordForPid(captured, candidate.identity.pid, &incomplete)) |captured_record| {
                if (!candidate.identity.eql(captured_record.identity)) {
                    incomplete = true;
                    continue;
                }
            }
            try appendUnique(allocator, &selected, candidate);
        }
    }

    return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = incomplete };
}

fn capturedRecordForPid(
    captured: []const ProcessRecord,
    pid: posix.pid_t,
    incomplete: *bool,
) ?ProcessRecord {
    const index = uniqueExactIndexForPid(captured, pid, incomplete) orelse return null;
    return captured[index];
}

/// Returns one row for a PID when every duplicate is byte-for-byte equivalent.
/// Exact duplicate proc rows are harmless enumeration repetition; conflicting
/// rows are ambiguous and can never supply an ancestry bridge.
fn uniqueExactIndexForPid(table: []const ProcessRecord, pid: posix.pid_t, incomplete: *bool) ?usize {
    var found: ?usize = null;
    for (table, 0..) |item, index| {
        if (item.identity.pid != pid) continue;
        if (found) |first| {
            if (!recordEql(table[first], item)) {
                incomplete.* = true;
                return null;
            }
            continue;
        }
        found = index;
    }
    return found;
}

fn recordEql(left: ProcessRecord, right: ProcessRecord) bool {
    return left.identity.eql(right.identity) and left.ppid == right.ppid and left.pgid == right.pgid;
}

fn tableHasAmbiguityOrMissingParent(table: []const ProcessRecord) bool {
    var incomplete = false;
    for (table) |item| {
        if (item.ppid > 0 and uniqueExactIndexForPid(table, item.ppid, &incomplete) == null) {
            incomplete = true;
        }
        // Check this PID as well, including rows unrelated to the requested
        // root. A partial/ambiguous global table must not be called complete.
        _ = uniqueExactIndexForPid(table, item.identity.pid, &incomplete);
    }
    return incomplete;
}

fn containsIdentity(records: []const ProcessRecord, identity: ProcessIdentity) bool {
    for (records) |item| if (item.identity.eql(identity)) return true;
    return false;
}

fn appendUnique(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(ProcessRecord),
    item: ProcessRecord,
) !void {
    if (!containsIdentity(records.items, item.identity)) try records.append(allocator, item);
}

/// A retained, platform-specific authorization to act on `record.identity`.
/// This is deliberately private-state: callers can construct neither a Linux
/// signal capability nor an identity-only Darwin target from a PID alone.
/// Result from a liveness probe or individual signal request. Callers must
/// keep failures distinct: only `.gone` and `.stale` mean that a target no
/// longer belongs in a drain set.
pub const TargetResult = union(enum) {
    live,
    signaled,
    gone,
    stale,
    permission_denied,
    invalid_handle,
    invalid_request,
    unsupported,
    unexpected_errno: posix.E,
};

/// An opaque, snapshot-owned authorization to act on one captured identity.
/// Its representation is deliberately unavailable to callers: a PID or
/// `ProcessIdentity` can inspect a target but can never manufacture, retarget,
/// copy, or select its platform signaling handle.
pub const CapturedTarget = opaque {
    pub fn record(self: *const CapturedTarget) ProcessRecord {
        return targetImplConst(self).record;
    }

    /// A signal-zero probe. Darwin revalidates identity before probing; a
    /// reuse after that re-read is the documented validation-to-kill TOCTOU.
    pub fn liveness(self: *const CapturedTarget) TargetResult {
        const target = targetImplConst(self);
        return switch (target.handle) {
            .linux_proc_dir => |fd| linuxSignalResult(fd, 0),
            .darwin_revalidate => darwinSignalResult(target.record.identity, 0, .live),
        };
    }

    /// Sends an individual signal only through this captured authorization.
    pub fn signal(self: *const CapturedTarget, signal_number: u8) TargetResult {
        const target = targetImplConst(self);
        return switch (target.handle) {
            .linux_proc_dir => |fd| linuxSignalResult(fd, signal_number),
            .darwin_revalidate => darwinSignalResult(target.record.identity, signal_number, .signaled),
        };
    }
};

const TargetImpl = struct {
    record: ProcessRecord,
    handle: Handle,

    const Handle = union(enum) {
        // Linux accepts a stable `/proc/<pid>` directory FD in
        // pidfd_send_signal. Retaining that FD keeps the signal capability
        // identical to the handle through which this record was observed.
        linux_proc_dir: posix.fd_t,
        darwin_revalidate,
    };
};

fn targetImplConst(target: *const CapturedTarget) *const TargetImpl {
    return @ptrCast(@alignCast(target));
}

fn targetImpl(target: *CapturedTarget) *TargetImpl {
    return @ptrCast(@alignCast(target));
}

fn allocateTarget(
    allocator: std.mem.Allocator,
    record: ProcessRecord,
    handle: TargetImpl.Handle,
) std.mem.Allocator.Error!*CapturedTarget {
    const target = try allocator.create(TargetImpl);
    target.* = .{ .record = record, .handle = handle };
    return @ptrCast(target);
}

fn deinitTarget(allocator: std.mem.Allocator, target: *CapturedTarget) void {
    const implementation = targetImpl(target);
    switch (implementation.handle) {
        .linux_proc_dir => |fd| posix.close(fd),
        .darwin_revalidate => {},
    }
    allocator.destroy(implementation);
}

pub const Snapshot = struct {
    targets: []*CapturedTarget,
    incomplete: bool,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.targets) |target| deinitTarget(allocator, target);
        allocator.free(self.targets);
        self.* = undefined;
    }
};

const LinuxAcquireError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    UnsupportedProcHandle,
    SnapshotSetupFailed,
};

pub const CaptureError = error{ UnsupportedPlatform, SnapshotSetupFailed } || LinuxAcquireError;

/// Captures every readable process record. Expected disappearance or unreadable
/// entries only marks the snapshot incomplete; allocation/setup errors escape.
pub fn captureAll(allocator: std.mem.Allocator) (CaptureError || std.mem.Allocator.Error)!Snapshot {
    return switch (builtin.os.tag) {
        .linux => captureLinux(allocator),
        .macos => captureDarwin(allocator),
        else => error.UnsupportedPlatform,
    };
}

pub fn captureIdentity(pid: posix.pid_t) ?ProcessIdentity {
    return switch (builtin.os.tag) {
        .linux => captureLinuxOne(pid) orelse return null,
        .macos => captureDarwinOne(pid) orelse return null,
        else => null,
    };
}

/// `/proc` entry metadata captured before opening the directory. The inode is
/// compared with `fstat`-equivalent metadata from the retained FD so a numeric
/// directory name cannot silently hand off to a replacement process.
const LinuxProcEntryIdentity = struct {
    inode: u64,

    fn eql(left: LinuxProcEntryIdentity, right: LinuxProcEntryIdentity) bool {
        return left.inode == right.inode;
    }
};

const LinuxEnumerationLead = struct {
    pid: posix.pid_t,
    entry_identity: LinuxProcEntryIdentity,
};

const LinuxTargetAcquisition = union(enum) {
    target: *CapturedTarget,
    incomplete,
};

const LinuxProcHandleReader = struct {
    directory: std.fs.Dir,

    fn readEntryIdentity(self: *const LinuxProcHandleReader) LinuxAcquireError!?LinuxProcEntryIdentity {
        return linuxProcEntryIdentityFromFd(self.directory.fd);
    }

    fn readRecord(self: *const LinuxProcHandleReader) LinuxAcquireError!?ProcessRecord {
        return readLinuxStat(self.directory);
    }
};

/// Reads and validates the target through one acquired proc-directory handle.
/// This is generic only so the test harness can substitute a faithful stable
/// handle; production passes `LinuxProcHandleReader` backed by a real FD.
fn readLinuxHandleRecord(
    lead: LinuxEnumerationLead,
    reader: anytype,
) LinuxAcquireError!?ProcessRecord {
    const handle_identity = try reader.readEntryIdentity() orelse return null;
    if (!lead.entry_identity.eql(handle_identity)) return null;

    const record = try reader.readRecord() orelse return null;
    if (record.identity.pid != lead.pid) return null;
    return record;
}

/// Parses Linux `/proc/<pid>/stat`, treating `comm` as opaque. The terminal
/// `) <state> ` boundary is searched from the right because `comm` may include
/// whitespace and closing parentheses.
pub fn parseLinuxStat(input: []const u8) ?ProcessRecord {
    const open = std.mem.indexOf(u8, input, " (") orelse return null;
    const close = std.mem.lastIndexOf(u8, input, ") ") orelse return null;
    if (close <= open or close + 4 > input.len or input[close + 3] != ' ') return null;

    const pid = std.fmt.parseInt(posix.pid_t, input[0..open], 10) catch return null;
    var fields = std.mem.tokenizeScalar(u8, input[close + 4 ..], ' ');
    const ppid_text = fields.next() orelse return null;
    const pgid_text = fields.next() orelse return null;
    const ppid = std.fmt.parseInt(posix.pid_t, ppid_text, 10) catch return null;
    const pgid = std.fmt.parseInt(posix.pid_t, pgid_text, 10) catch return null;

    var start_time: ?u64 = null;
    // Fields after state begin at stat field 4. Start time is field 22, hence
    // index 18 in this suffix; ppid and pgid consumed indexes 0 and 1.
    var index: usize = 2;
    while (fields.next()) |field| : (index += 1) {
        if (index == 18) {
            start_time = std.fmt.parseInt(u64, field, 10) catch return null;
            break;
        }
    }
    return .{ .identity = .{ .pid = pid, .start_token = start_time orelse return null }, .ppid = ppid, .pgid = pgid };
}

fn captureLinux(allocator: std.mem.Allocator) (CaptureError || std.mem.Allocator.Error)!Snapshot {
    if (comptime builtin.os.tag != .linux) unreachable;
    var targets = std.ArrayList(*CapturedTarget).empty;
    errdefer {
        for (targets.items) |target| deinitTarget(allocator, target);
        targets.deinit(allocator);
    }
    var incomplete = false;

    var proc = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return error.SnapshotSetupFailed;
    defer proc.close();
    var iterator = proc.iterate();
    while (true) {
        const maybe_entry = iterator.next() catch {
            incomplete = true;
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        if (pid <= 0) continue;
        switch (try captureLinuxTarget(allocator, proc, entry.name, pid)) {
            .incomplete => incomplete = true,
            .target => |target| {
                errdefer deinitTarget(allocator, target);
                try targets.append(allocator, target);
            },
        }
    }
    return .{ .targets = try targets.toOwnedSlice(allocator), .incomplete = incomplete };
}

fn captureLinuxOne(pid: posix.pid_t) ?ProcessIdentity {
    if (comptime builtin.os.tag != .linux) return null;
    var name: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "/proc/{d}", .{pid}) catch return null;
    var dir = std.fs.openDirAbsolute(path, .{}) catch return null;
    defer dir.close();
    const item = readLinuxStat(dir) orelse return null;
    if (item.identity.pid != pid) return null;
    return item.identity;
}

fn captureLinuxTarget(
    allocator: std.mem.Allocator,
    proc: std.fs.Dir,
    name: []const u8,
    pid: posix.pid_t,
) (LinuxAcquireError || std.mem.Allocator.Error)!LinuxTargetAcquisition {
    if (comptime builtin.os.tag != .linux) return .incomplete;

    // The numeric directory entry is just a lead. Record its identity before
    // open, then require the retained FD to denote that same proc entry.
    const entry_identity = try linuxProcEntryIdentityAt(proc.fd, name) orelse return .incomplete;
    var process = proc.openDir(name, .{}) catch |err| {
        _ = try linuxAcquisitionDispositionFromError(err);
        return .incomplete;
    };
    var transferred = false;
    defer if (!transferred) process.close();

    var reader: LinuxProcHandleReader = .{ .directory = process };
    const record = try readLinuxHandleRecord(.{
        .pid = pid,
        .entry_identity = entry_identity,
    }, &reader) orelse return .incomplete;

    const target = try allocateTarget(allocator, record, .{ .linux_proc_dir = process.fd });
    transferred = true;
    return .{ .target = target };
}

fn linuxProcEntryIdentityAt(
    proc_fd: posix.fd_t,
    name: []const u8,
) LinuxAcquireError!?LinuxProcEntryIdentity {
    const name_z = posix.toPosixPath(name) catch return error.SnapshotSetupFailed;
    return linuxProcEntryIdentityFromStatx(proc_fd, &name_z, std.os.linux.AT.NO_AUTOMOUNT);
}

fn linuxProcEntryIdentityFromFd(fd: posix.fd_t) LinuxAcquireError!?LinuxProcEntryIdentity {
    return linuxProcEntryIdentityFromStatx(fd, "", std.os.linux.AT.EMPTY_PATH);
}

fn linuxProcEntryIdentityFromStatx(
    dir_fd: posix.fd_t,
    path: [*:0]const u8,
    flags: u32,
) LinuxAcquireError!?LinuxProcEntryIdentity {
    var metadata = std.mem.zeroes(std.os.linux.Statx);
    const result = std.os.linux.statx(
        dir_fd,
        path,
        flags,
        std.os.linux.STATX_TYPE | std.os.linux.STATX_INO,
        &metadata,
    );
    switch (posix.errno(result)) {
        .SUCCESS => {},
        else => {
            _ = try linuxAcquisitionDispositionFromErrno(posix.errno(result));
            return null;
        },
    }
    if ((metadata.mask & std.os.linux.STATX_INO) == 0) return error.UnsupportedProcHandle;
    if ((metadata.mask & std.os.linux.STATX_TYPE) == 0) return error.UnsupportedProcHandle;
    if ((metadata.mode & std.os.linux.S.IFMT) != std.os.linux.S.IFDIR) return null;
    return .{ .inode = metadata.ino };
}

fn readLinuxStat(process: std.fs.Dir) LinuxAcquireError!?ProcessRecord {
    var stat = process.openFile("stat", .{}) catch |err| {
        _ = try linuxAcquisitionDispositionFromError(err);
        return null;
    };
    defer stat.close();
    var buffer: [4096]u8 = undefined;
    const bytes = stat.readAll(&buffer) catch |err| {
        _ = try linuxAcquisitionDispositionFromError(err);
        return null;
    };
    return parseLinuxStat(buffer[0..bytes]);
}

const LinuxAcquisitionDisposition = enum { incomplete };

/// Expected process disappearance, PID recycling, and permission races leave
/// a disclosed partial snapshot. Descriptor exhaustion, memory pressure,
/// unsupported proc semantics, and unknown operating failures must stop
/// capture instead of being misreported as a successful partial snapshot.
fn linuxAcquisitionDispositionFromErrno(
    errno_code: posix.E,
) LinuxAcquireError!LinuxAcquisitionDisposition {
    return switch (errno_code) {
        .NOENT, .SRCH, .ACCES, .PERM, .NOTDIR => .incomplete,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .NODEV => error.UnsupportedProcHandle,
        else => error.SnapshotSetupFailed,
    };
}

fn linuxAcquisitionDispositionFromError(
    err: anyerror,
) LinuxAcquireError!LinuxAcquisitionDisposition {
    return switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.NotDir => .incomplete,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.NoDevice => error.UnsupportedProcHandle,
        else => error.SnapshotSetupFailed,
    };
}

fn linuxSignalResult(fd: posix.fd_t, signal: u8) TargetResult {
    if (comptime builtin.os.tag != .linux) return .unsupported;
    return signalResultFromErrno(posix.errno(std.os.linux.pidfd_send_signal(fd, @intCast(signal), null, 0)), signal);
}

fn signalResultFromErrno(errno_code: posix.E, signal: u8) TargetResult {
    return switch (errno_code) {
        .SUCCESS => if (signal == 0) .live else .signaled,
        .SRCH => .gone,
        .PERM, .ACCES => .permission_denied,
        .BADF => .invalid_handle,
        .INVAL => .invalid_request,
        .NOSYS => .unsupported,
        else => .{ .unexpected_errno = errno_code },
    };
}

const ProcBsdInfo = extern struct {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    reserved: u32,
    comm: [16]u8,
    name: [32]u8,
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    tdev: u32,
    tpgid: u32,
    nice: i32,
    start_tvsec: u64,
    start_tvusec: u64,
};

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffer_size: c_int) c_int;
extern "c" fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: *anyopaque,
    buffer_size: c_int,
) c_int;

const proc_pidtbsdinfo = 3;

fn captureDarwin(allocator: std.mem.Allocator) (CaptureError || std.mem.Allocator.Error)!Snapshot {
    if (comptime builtin.os.tag != .macos) unreachable;
    // libproc returns a PID *count*, while accepting a byte capacity. Leave
    // bounded slack and retry on a full buffer so a growing table is marked
    // incomplete rather than silently truncated.
    const initial_count = proc_listallpids(null, 0);
    if (initial_count <= 0) return error.SnapshotSetupFailed;
    var capacity = std.math.add(usize, @intCast(initial_count), 64) catch return error.SnapshotSetupFailed;
    var pids: []c_int = undefined;
    var actual_count: usize = 0;
    var incomplete = false;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        pids = try allocator.alloc(c_int, capacity);
        const byte_capacity = std.math.mul(usize, capacity, @sizeOf(c_int)) catch {
            allocator.free(pids);
            return error.SnapshotSetupFailed;
        };
        const result = proc_listallpids(@ptrCast(pids.ptr), std.math.cast(c_int, byte_capacity) orelse {
            allocator.free(pids);
            return error.SnapshotSetupFailed;
        });
        if (result < 0) {
            allocator.free(pids);
            return error.SnapshotSetupFailed;
        }
        actual_count = @intCast(result);
        if (actual_count < capacity) break;
        allocator.free(pids);
        if (attempt == 2) {
            incomplete = true;
            // We still process every element returned by the final bounded
            // enumeration, but disclose that a concurrent growth may exist.
            pids = try allocator.alloc(c_int, capacity);
            const final_result = proc_listallpids(@ptrCast(pids.ptr), std.math.cast(c_int, byte_capacity) orelse {
                allocator.free(pids);
                return error.SnapshotSetupFailed;
            });
            if (final_result < 0) {
                allocator.free(pids);
                return error.SnapshotSetupFailed;
            }
            actual_count = @intCast(final_result);
            break;
        }
        capacity = std.math.add(usize, actual_count, 64) catch return error.SnapshotSetupFailed;
    }
    defer allocator.free(pids);

    var targets = std.ArrayList(*CapturedTarget).empty;
    errdefer {
        for (targets.items) |target| deinitTarget(allocator, target);
        targets.deinit(allocator);
    }
    for (pids[0..@min(capacity, actual_count)]) |pid| {
        if (pid <= 0) continue;
        const item = captureDarwinRecord(pid) orelse {
            incomplete = true;
            continue;
        };
        const target = try allocateTarget(allocator, item, .darwin_revalidate);
        errdefer deinitTarget(allocator, target);
        try targets.append(allocator, target);
    }
    return .{ .targets = try targets.toOwnedSlice(allocator), .incomplete = incomplete };
}

fn captureDarwinOne(pid: posix.pid_t) ?ProcessIdentity {
    if (comptime builtin.os.tag != .macos) return null;
    return (captureDarwinRecord(pid) orelse return null).identity;
}

fn captureDarwinRecord(pid: posix.pid_t) ?ProcessRecord {
    if (comptime builtin.os.tag != .macos) return null;
    var info: ProcBsdInfo = undefined;
    const returned = proc_pidinfo(pid, proc_pidtbsdinfo, 0, @ptrCast(&info), @sizeOf(ProcBsdInfo));
    if (returned != @sizeOf(ProcBsdInfo) or info.pid != @as(u32, @intCast(pid))) return null;
    return .{
        .identity = .{ .pid = pid, .start_token = (@as(u128, info.start_tvsec) << 64) | info.start_tvusec },
        .ppid = @intCast(info.ppid),
        .pgid = @intCast(info.pgid),
    };
}

fn darwinSignalResult(identity: ProcessIdentity, signal: u8, success: TargetResult) TargetResult {
    const current = captureDarwinOne(identity.pid) orelse return darwinAbsentIdentityResult(identity.pid);
    if (!current.eql(identity)) return .stale;
    const errno_code = posix.errno(posix.system.kill(identity.pid, signal));
    return switch (signalResultFromErrno(errno_code, signal)) {
        .live, .signaled => success,
        else => |result| result,
    };
}

fn darwinAbsentIdentityResult(pid: posix.pid_t) TargetResult {
    // proc_pidinfo reports several expected OS failures as a short read. A
    // signal-zero probe recovers the important distinction without granting
    // signal authorization to a bare PID: this only diagnoses why identity
    // revalidation could not complete.
    return switch (signalResultFromErrno(posix.errno(posix.system.kill(pid, 0)), 0)) {
        .live => .{ .unexpected_errno = .IO },
        else => |result| result,
    };
}

fn testRecord(pid: posix.pid_t, start: u128, ppid: posix.pid_t, pgid: posix.pid_t) ProcessRecord {
    return .{ .identity = .{ .pid = pid, .start_token = start }, .ppid = ppid, .pgid = pgid };
}

test "closure selects a happy tree and classifies escaped descendants" {
    const table = [_]ProcessRecord{
        testRecord(10, 1, 0, 10), testRecord(11, 2, 10, 10), testRecord(12, 3, 11, 99),
    };
    var found = try descendantClosure(std.testing.allocator, &table, table[0].identity);
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), found.records.len);
    try std.testing.expect(found.records[2].isEscaped(10));
    try std.testing.expect(!found.incomplete);
}

test "closure excludes unrelated rows and marks missing ancestry incomplete" {
    const unrelated = [_]ProcessRecord{ testRecord(20, 1, 0, 20), testRecord(21, 2, 20, 20), testRecord(99, 3, 0, 99) };
    var selected = try descendantClosure(std.testing.allocator, &unrelated, unrelated[0].identity);
    defer selected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), selected.records.len);
    try std.testing.expect(!selected.incomplete);

    const missing = [_]ProcessRecord{ testRecord(20, 1, 0, 20), testRecord(21, 2, 20, 20), testRecord(22, 3, 99, 20) };
    var partial = try descendantClosure(std.testing.allocator, &missing, missing[0].identity);
    defer partial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), partial.records.len);
    try std.testing.expect(partial.incomplete);
}

test "closure rejects duplicate pid and wrong root identity" {
    const duplicate = [_]ProcessRecord{
        testRecord(30, 1, 0, 30), testRecord(31, 2, 30, 30), testRecord(31, 3, 30, 30),
    };
    var duplicate_result = try descendantClosure(std.testing.allocator, &duplicate, duplicate[0].identity);
    defer duplicate_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), duplicate_result.records.len);
    try std.testing.expect(duplicate_result.incomplete);

    var mismatch = try descendantClosure(std.testing.allocator, &duplicate, .{ .pid = 30, .start_token = 99 });
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), mismatch.records.len);
    try std.testing.expect(mismatch.incomplete);
}

test "resweep deduplicates exact rows and rejects recycled intermediates" {
    const captured = [_]ProcessRecord{ testRecord(40, 1, 0, 40), testRecord(41, 2, 40, 40) };
    const resweep = [_]ProcessRecord{
        testRecord(40, 1, 0, 40),
        testRecord(41, 2, 40, 40),
        testRecord(42, 3, 41, 77),
        testRecord(42, 3, 41, 77),
    };
    var result = try resweepDescendants(std.testing.allocator, &captured, &resweep);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.records.len);
    try std.testing.expectEqual(@as(posix.pid_t, 40), result.records[0].identity.pid);
    try std.testing.expectEqual(@as(posix.pid_t, 41), result.records[1].identity.pid);
    try std.testing.expectEqual(@as(posix.pid_t, 42), result.records[2].identity.pid);
    try std.testing.expect(!result.incomplete);

    const recycled_intermediate = [_]ProcessRecord{
        testRecord(40, 1, 0, 40),
        testRecord(41, 9, 40, 40),
        testRecord(42, 3, 41, 77),
    };
    var stale = try resweepDescendants(std.testing.allocator, &captured, &recycled_intermediate);
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), stale.records.len);
    try std.testing.expectEqual(@as(posix.pid_t, 40), stale.records[0].identity.pid);
    try std.testing.expect(stale.incomplete);
}

test "resweep permits a surviving non-root anchor and rejects conflicting rows" {
    const captured = [_]ProcessRecord{ testRecord(50, 1, 0, 50), testRecord(51, 2, 50, 50) };
    const surviving_child = [_]ProcessRecord{
        testRecord(50, 9, 0, 50),
        testRecord(51, 2, 50, 50),
        testRecord(52, 3, 51, 77),
    };
    var expanded = try resweepDescendants(std.testing.allocator, &captured, &surviving_child);
    defer expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), expanded.records.len);
    try std.testing.expectEqual(@as(posix.pid_t, 51), expanded.records[0].identity.pid);
    try std.testing.expectEqual(@as(posix.pid_t, 52), expanded.records[1].identity.pid);
    try std.testing.expect(expanded.incomplete);

    const conflicting = [_]ProcessRecord{
        testRecord(50, 1, 0, 50),
        testRecord(51, 2, 50, 50),
        testRecord(51, 7, 50, 50),
        testRecord(52, 3, 51, 77),
    };
    var ambiguous = try resweepDescendants(std.testing.allocator, &captured, &conflicting);
    defer ambiguous.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ambiguous.records.len);
    try std.testing.expectEqual(@as(posix.pid_t, 50), ambiguous.records[0].identity.pid);
    try std.testing.expect(ambiguous.incomplete);
}

test "linux handle reader rejects a recycled proc entry and accepts an exact handle" {
    const FakeStableHandle = struct {
        const Self = @This();

        entry_identity: LinuxProcEntryIdentity,
        record: ProcessRecord,

        fn readEntryIdentity(self: *const Self) LinuxAcquireError!?LinuxProcEntryIdentity {
            return self.entry_identity;
        }

        fn readRecord(self: *const Self) LinuxAcquireError!?ProcessRecord {
            return self.record;
        }
    };

    const old_descendant = testRecord(61, 2, 60, 60);
    const original_entry: LinuxProcEntryIdentity = .{ .inode = 6101 };
    const replacement_entry: LinuxProcEntryIdentity = .{ .inode = 6102 };
    var replacement_handle: FakeStableHandle = .{
        .entry_identity = replacement_entry,
        .record = testRecord(61, 9, 999, 777),
    };
    const rejected = try readLinuxHandleRecord(.{
        .pid = old_descendant.identity.pid,
        .entry_identity = original_entry,
    }, &replacement_handle);
    try std.testing.expect(rejected == null);

    // A rejected handle read provides no row to the same closure builder that
    // determines the drain set, so the replacement cannot be selected under
    // the old descendant's PPID link.
    const root = testRecord(60, 1, 0, 60);
    var drain_rows = std.ArrayList(ProcessRecord).empty;
    defer drain_rows.deinit(std.testing.allocator);
    try drain_rows.append(std.testing.allocator, root);
    if (rejected) |record| try drain_rows.append(std.testing.allocator, record);
    var closure = try descendantClosure(std.testing.allocator, drain_rows.items, root.identity);
    defer closure.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), closure.records.len);

    var exact_handle: FakeStableHandle = .{
        .entry_identity = original_entry,
        .record = old_descendant,
    };
    const accepted = try readLinuxHandleRecord(.{
        .pid = old_descendant.identity.pid,
        .entry_identity = original_entry,
    }, &exact_handle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(recordEql(old_descendant, accepted));
}

test "linux acquisition maps races separately from fatal handle failures" {
    try std.testing.expectEqual(
        LinuxAcquisitionDisposition.incomplete,
        try linuxAcquisitionDispositionFromErrno(.SRCH),
    );
    try std.testing.expectEqual(
        LinuxAcquisitionDisposition.incomplete,
        try linuxAcquisitionDispositionFromErrno(.ACCES),
    );
    try std.testing.expectError(
        error.ProcessFdQuotaExceeded,
        linuxAcquisitionDispositionFromErrno(.MFILE),
    );
    try std.testing.expectError(
        error.SystemFdQuotaExceeded,
        linuxAcquisitionDispositionFromErrno(.NFILE),
    );
    try std.testing.expectError(
        error.SystemResources,
        linuxAcquisitionDispositionFromErrno(.NOMEM),
    );
    try std.testing.expectError(
        error.UnsupportedProcHandle,
        linuxAcquisitionDispositionFromErrno(.NODEV),
    );
    try std.testing.expectError(
        error.SnapshotSetupFailed,
        linuxAcquisitionDispositionFromErrno(.IO),
    );
}

test "captured targets are opaque capabilities" {
    comptime std.debug.assert(@typeInfo(CapturedTarget) == .@"opaque");
}

test "snapshot owns and releases opaque target allocations" {
    const target = try allocateTarget(
        std.testing.allocator,
        testRecord(70, 1, 0, 70),
        .darwin_revalidate,
    );
    const targets = try std.testing.allocator.alloc(*CapturedTarget, 1);
    targets[0] = target;
    var snapshot: Snapshot = .{ .targets = targets, .incomplete = false };
    snapshot.deinit(std.testing.allocator);
}

test "signal results preserve disappearance and operational failures" {
    try std.testing.expect(switch (signalResultFromErrno(.SRCH, 0)) {
        .gone => true,
        else => false,
    });
    try std.testing.expect(switch (signalResultFromErrno(.PERM, 15)) {
        .permission_denied => true,
        else => false,
    });
    try std.testing.expect(switch (signalResultFromErrno(.BADF, 15)) {
        .invalid_handle => true,
        else => false,
    });
    try std.testing.expect(switch (signalResultFromErrno(.NOSYS, 15)) {
        .unsupported => true,
        else => false,
    });
}

test "linux stat parser survives hostile comm" {
    const stat = "77 (a hostile ) name with spaces) S 55 66 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345 0";
    const parsed = parseLinuxStat(stat) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(posix.pid_t, 77), parsed.identity.pid);
    try std.testing.expectEqual(@as(posix.pid_t, 55), parsed.ppid);
    try std.testing.expectEqual(@as(posix.pid_t, 66), parsed.pgid);
    try std.testing.expectEqual(@as(u128, 12345), parsed.identity.start_token);
}

test "native current-process identity captures and revalidates on macos" {
    if (builtin.os.tag != .macos) return;
    const identity = captureIdentity(std.c.getpid()) orelse return error.TestUnexpectedResult;
    const current = captureIdentity(identity.pid) orelse return error.TestUnexpectedResult;
    try std.testing.expect(current.eql(identity));
    var snapshot = try captureAll(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    var found = false;
    for (snapshot.targets) |target| {
        if (target.record().identity.eql(identity)) found = true;
    }
    try std.testing.expect(found);

    // A fresh count is allowed to race, but a snapshot smaller by the former
    // count/byte double division (roughly 1/16 coverage) must fail loudly.
    const fresh_count = proc_listallpids(null, 0);
    try std.testing.expect(fresh_count > 0);
    try std.testing.expect(snapshot.targets.len * 4 >= @as(usize, @intCast(fresh_count)));
}
