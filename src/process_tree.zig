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
    const root_index = uniqueIndexForPid(table, root.pid, &incomplete) orelse {
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

            // A duplicate PID cannot prove a unique ancestry link.  Mark the
            // snapshot incomplete even when the duplicate is otherwise idle.
            if (uniqueIndexForPid(table, candidate.identity.pid, &incomplete) == null) continue;
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
    // A captured closure is root-first.  Starting from that exact root makes a
    // surviving child insufficient when the root PID itself was recycled.
    if (captured.len == 0) {
        return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = false };
    }
    const root = captured[0];
    const root_index = uniqueIndexForPid(resweep_table, root.identity.pid, &incomplete) orelse {
        return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = true };
    };
    const current_root = resweep_table[root_index];
    if (!current_root.identity.eql(root.identity)) {
        return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = true };
    }
    try selected.append(allocator, current_root);

    var cursor: usize = 0;
    while (cursor < selected.items.len) : (cursor += 1) {
        const parent = selected.items[cursor];
        for (resweep_table) |candidate| {
            if (candidate.ppid != parent.identity.pid) continue;
            if (uniqueIndexForPid(resweep_table, candidate.identity.pid, &incomplete) == null) continue;
            try appendUnique(allocator, &selected, candidate);
        }
    }

    return .{ .records = try selected.toOwnedSlice(allocator), .incomplete = incomplete };
}

fn uniqueIndexForPid(table: []const ProcessRecord, pid: posix.pid_t, incomplete: *bool) ?usize {
    var found: ?usize = null;
    for (table, 0..) |item, index| {
        if (item.identity.pid != pid) continue;
        if (found != null) {
            incomplete.* = true;
            return null;
        }
        found = index;
    }
    return found;
}

fn tableHasAmbiguityOrMissingParent(table: []const ProcessRecord) bool {
    var incomplete = false;
    for (table) |item| {
        if (item.ppid > 0 and uniqueIndexForPid(table, item.ppid, &incomplete) == null) {
            incomplete = true;
        }
        // Check this PID as well, including rows unrelated to the requested
        // root. A partial/ambiguous global table must not be called complete.
        _ = uniqueIndexForPid(table, item.identity.pid, &incomplete);
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
pub const CapturedTarget = struct {
    record: ProcessRecord,
    handle: Handle,

    const Handle = union(enum) {
        linux_proc_fd: posix.fd_t,
        darwin_revalidate,
        inert,
    };

    pub fn deinit(self: *CapturedTarget) void {
        switch (self.handle) {
            .linux_proc_fd => |fd| posix.close(fd),
            .darwin_revalidate, .inert => {},
        }
        self.* = undefined;
    }

    /// Signal 0 liveness is identity-safe on Linux. Darwin re-reads identity
    /// immediately before its liveness claim; a reuse after that re-read is the
    /// documented, unavoidable validation-to-kill TOCTOU.
    pub fn isLive(self: *const CapturedTarget) bool {
        return switch (self.handle) {
            .linux_proc_fd => |fd| linuxSendSignal(fd, 0),
            .darwin_revalidate => identityStillPresent(self.record.identity),
            .inert => false,
        };
    }

    /// Sends an individual signal only through this captured authorization.
    pub fn signal(self: *const CapturedTarget, signal_number: u8) bool {
        return switch (self.handle) {
            .linux_proc_fd => |fd| linuxSendSignal(fd, signal_number),
            .darwin_revalidate => if (identityStillPresent(self.record.identity)) blk: {
                posix.kill(self.record.identity.pid, signal_number) catch break :blk false;
                break :blk true;
            } else false,
            .inert => false,
        };
    }
};

pub const Snapshot = struct {
    targets: []CapturedTarget,
    incomplete: bool,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.targets) |*target| target.deinit();
        allocator.free(self.targets);
        self.* = undefined;
    }
};

pub const CaptureError = error{ UnsupportedPlatform, SnapshotSetupFailed };

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

pub fn identityStillPresent(identity: ProcessIdentity) bool {
    const current = captureIdentity(identity.pid) orelse return false;
    return current.eql(identity);
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
    var targets = std.ArrayList(CapturedTarget).empty;
    errdefer {
        for (targets.items) |*target| target.deinit();
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
        const target = captureLinuxTarget(proc, entry.name) orelse {
            incomplete = true;
            continue;
        };
        try targets.append(allocator, target);
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

fn captureLinuxTarget(proc: std.fs.Dir, name: []const u8) ?CapturedTarget {
    if (comptime builtin.os.tag != .linux) return null;
    var process = proc.openDir(name, .{}) catch return null;
    errdefer process.close();
    const item = readLinuxStat(process) orelse return null;
    return .{ .record = item, .handle = .{ .linux_proc_fd = process.fd } };
}

fn readLinuxStat(process: std.fs.Dir) ?ProcessRecord {
    if (comptime builtin.os.tag != .linux) return null;
    var stat = process.openFile("stat", .{}) catch return null;
    defer stat.close();
    var buffer: [4096]u8 = undefined;
    const bytes = stat.readAll(&buffer) catch return null;
    return parseLinuxStat(buffer[0..bytes]);
}

fn linuxSendSignal(fd: posix.fd_t, signal: u8) bool {
    if (comptime builtin.os.tag != .linux) return false;
    const result = std.os.linux.pidfd_send_signal(fd, @intCast(signal), null, 0);
    return posix.errno(result) == .SUCCESS;
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
    const byte_count = proc_listallpids(null, 0);
    if (byte_count <= 0) return error.SnapshotSetupFailed;
    const count: usize = @intCast(@divTrunc(byte_count, @sizeOf(c_int)));
    const pids = try allocator.alloc(c_int, count);
    defer allocator.free(pids);
    const actual_bytes = proc_listallpids(@ptrCast(pids.ptr), byte_count);
    if (actual_bytes < 0) return error.SnapshotSetupFailed;

    var targets = std.ArrayList(CapturedTarget).empty;
    errdefer targets.deinit(allocator);
    var incomplete = actual_bytes != byte_count;
    const actual_count: usize = @intCast(@divTrunc(actual_bytes, @sizeOf(c_int)));
    for (pids[0..@min(count, actual_count)]) |pid| {
        if (pid <= 0) continue;
        const item = captureDarwinRecord(pid) orelse {
            incomplete = true;
            continue;
        };
        try targets.append(allocator, .{ .record = item, .handle = .darwin_revalidate });
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

test "resweep deduplicates deterministically and rejects stale anchors" {
    const captured = [_]ProcessRecord{ testRecord(40, 1, 0, 40), testRecord(41, 2, 40, 40) };
    const resweep = [_]ProcessRecord{
        testRecord(40, 1, 0, 40),
        testRecord(41, 2, 40, 40),
        testRecord(42, 3, 41, 77),
        testRecord(42, 3, 41, 77),
    };
    var result = try resweepDescendants(std.testing.allocator, &captured, &resweep);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.records.len);
    try std.testing.expectEqual(@as(posix.pid_t, 40), result.records[0].identity.pid);
    try std.testing.expectEqual(@as(posix.pid_t, 41), result.records[1].identity.pid);
    try std.testing.expect(result.incomplete);

    const recycled = [_]ProcessRecord{ testRecord(40, 9, 0, 40), testRecord(41, 2, 40, 40), testRecord(42, 3, 41, 77) };
    var stale = try resweepDescendants(std.testing.allocator, &captured, &recycled);
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), stale.records.len);
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
    try std.testing.expect(identityStillPresent(identity));
    var snapshot = try captureAll(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    var found = false;
    for (snapshot.targets) |target| {
        if (target.record.identity.eql(identity)) found = true;
    }
    try std.testing.expect(found);
}
