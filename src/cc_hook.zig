const builtin = @import("builtin");
const std = @import("std");

const posix = std.posix;

const default_grace_ms: u64 = 1500;
const max_hook_input_bytes: usize = 1024 * 1024;
const max_pid_walk_hops: usize = 8;

pub const default_skip_patterns = [_][]const u8{
    "ls",
    "cat",
    "pwd",
    "echo",
    "which",
    "cd",
    "git status",
    "git log",
    "git diff",
    "git show",
};

const empty_patterns = [_][]const u8{};

pub const WrapMode = enum {
    all,
    background_only,
};

pub const Decision = enum {
    wrap,
    passthrough,
};

pub const PreToolUse = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8,
    tool_name: []const u8,
    command: []const u8,
    run_in_background: bool,

    pub fn deinit(self: *const PreToolUse) void {
        self.allocator.free(self.session_id);
        self.allocator.free(self.tool_name);
        self.allocator.free(self.command);
    }
};

const PatternSet = struct {
    values: []const []const u8,
    owned: bool = false,

    fn deinit(self: PatternSet, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.values) |pattern| allocator.free(pattern);
        allocator.free(self.values);
    }
};

pub const HookConfig = struct {
    enabled: bool = true,
    grace_ms: u64 = default_grace_ms,
    wrap_mode: WrapMode = .all,
    shell: []const u8 = "bash",
    shell_owned: bool = false,
    skip_patterns: PatternSet = .{ .values = default_skip_patterns[0..] },
    deny_patterns: PatternSet = .{ .values = empty_patterns[0..] },

    pub fn deinit(self: HookConfig, allocator: std.mem.Allocator) void {
        if (self.shell_owned) allocator.free(self.shell);
        self.skip_patterns.deinit(allocator);
        self.deny_patterns.deinit(allocator);
    }
};

pub const EnvLookup = struct {
    ctx: *const anyopaque,
    get: *const fn (*const anyopaque, []const u8) ?[]const u8,

    fn value(self: EnvLookup, name: []const u8) ?[]const u8 {
        return self.get(self.ctx, name);
    }
};

pub const WrappedCommandParams = struct {
    janitor: []const u8,
    lock: ?[]const u8 = null,
    pid: ?posix.pid_t = null,
    grace_ms: u64 = default_grace_ms,
    shell: []const u8 = "bash",
    command: []const u8,
    run_in_background: bool = false,
};

const ProcInfo = struct {
    ppid: posix.pid_t,
    comm: []const u8,
};

pub fn main(allocator: std.mem.Allocator, subcommand: ?[]const u8) void {
    if (builtin.os.tag == .windows) return;

    const cmd = subcommand orelse return;
    if (std.mem.eql(u8, cmd, "pretooluse")) {
        runPreToolUse(allocator) catch {};
    } else if (std.mem.eql(u8, cmd, "session-end")) {
        runSessionEnd(allocator) catch {};
    }
}

pub fn parsePreToolUse(allocator: std.mem.Allocator, json_bytes: []const u8) !PreToolUse {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{
            .allocator = allocator,
            .session_id = try allocator.dupe(u8, ""),
            .tool_name = try allocator.dupe(u8, ""),
            .command = try allocator.dupe(u8, ""),
            .run_in_background = false,
        },
    };

    const session_id = stringField(root, "session_id") orelse "";
    const tool_name = stringField(root, "tool_name") orelse "";
    var command: []const u8 = "";
    var run_in_background = false;

    if (root.get("tool_input")) |tool_input| switch (tool_input) {
        .object => |tool_object| {
            command = stringField(tool_object, "command") orelse "";
            run_in_background = boolField(tool_object, "run_in_background") orelse false;
        },
        else => {},
    };

    return .{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, session_id),
        .tool_name = try allocator.dupe(u8, tool_name),
        .command = try allocator.dupe(u8, command),
        .run_in_background = run_in_background,
    };
}

pub fn parseConfig(allocator: std.mem.Allocator, lookup: EnvLookup) !HookConfig {
    var config: HookConfig = .{};
    errdefer config.deinit(allocator);

    if (lookup.value("JANITOR_CC_ENABLED")) |enabled| {
        config.enabled = !isFalseValue(enabled);
    }
    if (lookup.value("JANITOR_CC_GRACE_MS")) |grace_ms| {
        config.grace_ms = std.fmt.parseUnsigned(u64, std.mem.trim(u8, grace_ms, " \t\r\n"), 10) catch default_grace_ms;
    }
    if (lookup.value("JANITOR_CC_WRAP_MODE")) |wrap_mode| {
        const trimmed = std.mem.trim(u8, wrap_mode, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "background-only")) {
            config.wrap_mode = .background_only;
        } else {
            config.wrap_mode = .all;
        }
    }
    if (lookup.value("JANITOR_CC_SHELL")) |shell| {
        const trimmed = std.mem.trim(u8, shell, " \t\r\n");
        if (trimmed.len != 0) {
            config.shell = try allocator.dupe(u8, trimmed);
            config.shell_owned = true;
        }
    }
    if (lookup.value("JANITOR_CC_SKIP_PATTERNS")) |patterns| {
        config.skip_patterns = try parsePatternSet(allocator, patterns);
    }
    if (lookup.value("JANITOR_CC_DENY_PATTERNS")) |patterns| {
        config.deny_patterns = try parsePatternSet(allocator, patterns);
    }

    return config;
}

pub fn decide(input: PreToolUse, config: HookConfig) Decision {
    if (!std.mem.eql(u8, input.tool_name, "Bash")) return .passthrough;
    if (!config.enabled) return .passthrough;
    if (isAlreadyWrapped(input.command)) return .passthrough;
    if (matchesSkip(input.command, config.skip_patterns.values)) return .passthrough;
    if (matchesSkip(input.command, config.deny_patterns.values)) return .passthrough;
    if (config.wrap_mode == .background_only and !input.run_in_background) return .passthrough;
    return .wrap;
}

pub fn matchesSkip(command: []const u8, patterns: []const []const u8) bool {
    const normalized = stripLeadingEnvAssignments(command);
    for (patterns) |pattern| {
        const trimmed_pattern = std.mem.trim(u8, pattern, " \t\r\n");
        if (trimmed_pattern.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed_pattern, ' ') == null) {
            const token = firstToken(normalized);
            if (std.mem.eql(u8, token, trimmed_pattern)) return true;
        } else if (startsWithPhrase(normalized, trimmed_pattern)) {
            return true;
        }
    }
    return false;
}

pub fn singleQuoteEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeByte('\'');
    for (s) |byte| {
        if (byte == '\'') {
            try out.writer.writeAll("'\\''");
        } else {
            try out.writer.writeByte(byte);
        }
    }
    try out.writer.writeByte('\'');

    return try out.toOwnedSlice();
}

pub fn buildWrappedCommand(allocator: std.mem.Allocator, params: WrappedCommandParams) ![]u8 {
    _ = params.run_in_background;

    const escaped_janitor = try singleQuoteEscape(allocator, params.janitor);
    defer allocator.free(escaped_janitor);

    const escaped_lock = if (params.lock) |lock| try singleQuoteEscape(allocator, lock) else null;
    defer if (escaped_lock) |lock| allocator.free(lock);

    const escaped_shell = try singleQuoteEscape(allocator, params.shell);
    defer allocator.free(escaped_shell);

    const escaped_command = try singleQuoteEscape(allocator, params.command);
    defer allocator.free(escaped_command);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll(escaped_janitor);
    if (escaped_lock) |lock| try out.writer.print(" --watch-path {s}", .{lock});
    if (params.pid) |pid| try out.writer.print(" --watch-pid {}", .{pid});
    try out.writer.print(" --grace-ms {} -- {s} -c {s}", .{ params.grace_ms, escaped_shell, escaped_command });

    return try out.toOwnedSlice();
}

pub fn lockPathFor(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const base = env_map.get("XDG_RUNTIME_DIR") orelse env_map.get("TMPDIR") orelse "/tmp";
    return lockPathForBase(allocator, base, session_id);
}

pub fn lockPathForBase(allocator: std.mem.Allocator, base: []const u8, session_id: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.lock", .{session_id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ base, "janitor-cc", filename });
}

pub fn isShellComm(comm: []const u8) bool {
    const normalized = commName(comm);
    return std.mem.eql(u8, normalized, "sh") or
        std.mem.eql(u8, normalized, "bash") or
        std.mem.eql(u8, normalized, "zsh") or
        std.mem.eql(u8, normalized, "dash");
}

fn commName(comm: []const u8) []const u8 {
    var name = std.mem.trim(u8, comm, " \t\r\n");
    name = std.fs.path.basename(name);
    if (name.len > 0 and name[0] == '-') name = name[1..];
    return name;
}

pub fn resolveClaudePidWalk(
    start_pid: posix.pid_t,
    ctx: *const anyopaque,
    lookup: *const fn (*const anyopaque, posix.pid_t) ?ProcInfo,
) ?posix.pid_t {
    var pid = start_pid;
    var hops: usize = 0;
    while (pid > 0 and hops < max_pid_walk_hops) : (hops += 1) {
        const info = lookup(ctx, pid) orelse return null;
        if (std.mem.eql(u8, commName(info.comm), "claude")) return pid;
        if (!isShellComm(info.comm)) return null;
        pid = info.ppid;
    }
    return null;
}

fn runPreToolUse(allocator: std.mem.Allocator) !void {
    const stdin = std.fs.File.stdin();
    const json_bytes = try stdin.readToEndAlloc(allocator, max_hook_input_bytes);
    defer allocator.free(json_bytes);

    const input = parsePreToolUse(allocator, json_bytes) catch return;
    defer input.deinit();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    const config = try parseConfig(allocator, .{ .ctx = &env_map, .get = envMapLookup });
    defer config.deinit(allocator);

    if (decide(input, config) == .passthrough) return;

    const lock = ensureLock(allocator, input.session_id);
    defer if (lock) |path| allocator.free(path);

    const claude_pid = resolveClaudePid(allocator);
    if (lock == null and claude_pid == null) return;

    const janitor_path = try selfJanitorPath(allocator);
    defer allocator.free(janitor_path);

    const wrapped = try buildWrappedCommand(allocator, .{
        .janitor = janitor_path,
        .lock = lock,
        .pid = claude_pid,
        .grace_ms = config.grace_ms,
        .shell = config.shell,
        .command = input.command,
    });
    defer allocator.free(wrapped);

    try emitPreToolUseUpdate(wrapped);
}

fn runSessionEnd(allocator: std.mem.Allocator) !void {
    const stdin = std.fs.File.stdin();
    const json_bytes = try stdin.readToEndAlloc(allocator, max_hook_input_bytes);
    defer allocator.free(json_bytes);

    const session_id = parseSessionId(allocator, json_bytes) catch return;
    defer allocator.free(session_id);
    if (session_id.len == 0) return;

    const lock = lockPathFor(allocator, session_id) catch return;
    defer allocator.free(lock);
    deleteFile(lock);
}

fn parseSessionId(allocator: std.mem.Allocator, json_bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return allocator.dupe(u8, ""),
    };
    return allocator.dupe(u8, stringField(root, "session_id") orelse "");
}

fn ensureLock(allocator: std.mem.Allocator, session_id: []const u8) ?[]u8 {
    if (session_id.len == 0) return null;

    const lock = lockPathFor(allocator, session_id) catch return null;
    errdefer allocator.free(lock);

    const parent = std.fs.path.dirname(lock) orelse return null;
    std.fs.cwd().makePath(parent) catch return null;

    const file = if (std.fs.path.isAbsolute(lock))
        std.fs.createFileAbsolute(lock, .{ .truncate = false }) catch return null
    else
        std.fs.cwd().createFile(lock, .{ .truncate = false }) catch return null;
    file.close();

    return lock;
}

fn deleteFile(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };
    } else {
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };
    }
}

fn resolveClaudePid(allocator: std.mem.Allocator) ?posix.pid_t {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const ctx_allocator = arena.allocator();
    return resolveClaudePidWalk(getParentPid(), &ctx_allocator, psLookup);
}

fn psLookup(ctx: *const anyopaque, pid: posix.pid_t) ?ProcInfo {
    const allocator_ptr: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
    const allocator = allocator_ptr.*;

    const pid_text = std.fmt.allocPrint(allocator, "{}", .{pid}) catch return null;
    defer allocator.free(pid_text);

    const ppid = runPsInt(allocator, &.{ "ps", "-o", "ppid=", "-p", pid_text }) orelse return null;
    const comm = runPsText(allocator, &.{ "ps", "-o", "comm=", "-p", pid_text }) orelse return null;

    return .{ .ppid = ppid, .comm = comm };
}

fn runPsInt(allocator: std.mem.Allocator, argv: []const []const u8) ?posix.pid_t {
    const text = runPsText(allocator, argv) orelse return null;
    defer allocator.free(text);
    return std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

fn runPsText(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 4096,
    }) catch return null;
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    return result.stdout;
}

fn selfJanitorPath(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.selfExePathAlloc(allocator) catch allocator.dupe(u8, "janitor");
}

fn emitPreToolUseUpdate(command: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try std.json.Stringify.value(.{
        .hookSpecificOutput = .{
            .hookEventName = "PreToolUse",
            .permissionDecision = "allow",
            .updatedInput = .{
                .command = command,
            },
        },
    }, .{}, &stdout.interface);
    try stdout.interface.flush();
}

fn getParentPid() posix.pid_t {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        return @intCast(std.os.linux.getppid());
    }
    return std.c.getppid();
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn parsePatternSet(allocator: std.mem.Allocator, csv: []const u8) !PatternSet {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |pattern| allocator.free(pattern);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw_pattern| {
        const pattern = std.mem.trim(u8, raw_pattern, " \t\r\n");
        if (pattern.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, pattern));
    }

    return .{ .values = try list.toOwnedSlice(allocator), .owned = true };
}

fn isFalseValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.eql(u8, trimmed, "0") or std.ascii.eqlIgnoreCase(trimmed, "false");
}

fn envMapLookup(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
    const env_map: *const std.process.EnvMap = @ptrCast(@alignCast(ctx));
    return env_map.get(name);
}

fn isAlreadyWrapped(command: []const u8) bool {
    const token = firstToken(stripLeadingEnvAssignments(command));
    return std.mem.eql(u8, token, "janitor") or std.mem.endsWith(u8, token, "/janitor");
}

fn stripLeadingEnvAssignments(command: []const u8) []const u8 {
    var rest = std.mem.trimLeft(u8, command, " \t\r\n");
    while (true) {
        const token_len = tokenLength(rest);
        if (token_len == 0) return rest;
        const token = rest[0..token_len];
        if (!isEnvAssignmentToken(token)) return rest;
        rest = std.mem.trimLeft(u8, rest[token_len..], " \t\r\n");
    }
}

fn firstToken(command: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, command, " \t\r\n");
    return trimmed[0..tokenLength(trimmed)];
}

fn tokenLength(command: []const u8) usize {
    var i: usize = 0;
    while (i < command.len and !std.ascii.isWhitespace(command[i])) : (i += 1) {}
    return i;
}

fn isEnvAssignmentToken(token: []const u8) bool {
    if (token.len == 0) return false;
    const equals = std.mem.indexOfScalar(u8, token, '=') orelse return false;
    if (equals == 0) return false;
    if (!(std.ascii.isAlphabetic(token[0]) or token[0] == '_')) return false;
    for (token[1..equals]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn startsWithPhrase(command: []const u8, phrase: []const u8) bool {
    if (!std.mem.startsWith(u8, command, phrase)) return false;
    if (command.len == phrase.len) return true;
    return std.ascii.isWhitespace(command[phrase.len]);
}

test "parsePreToolUse extracts bash fields" {
    const allocator = std.testing.allocator;
    const input =
        \\{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test","run_in_background":true}}
    ;
    const parsed = try parsePreToolUse(allocator, input);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("s1", parsed.session_id);
    try std.testing.expectEqualStrings("Bash", parsed.tool_name);
    try std.testing.expectEqualStrings("npm test", parsed.command);
    try std.testing.expect(parsed.run_in_background);
}

test "parsePreToolUse defaults missing optional fields" {
    const allocator = std.testing.allocator;
    const parsed = try parsePreToolUse(allocator, "{}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("", parsed.session_id);
    try std.testing.expectEqualStrings("", parsed.tool_name);
    try std.testing.expectEqualStrings("", parsed.command);
    try std.testing.expect(!parsed.run_in_background);
}

test "decide passthrough rules" {
    const allocator = std.testing.allocator;
    const base = try parsePreToolUse(allocator,
        \\{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"make dev"}}
    );
    defer base.deinit();

    try std.testing.expectEqual(Decision.wrap, decide(base, .{}));

    const disabled: HookConfig = .{ .enabled = false };
    try std.testing.expectEqual(Decision.passthrough, decide(base, disabled));

    const background_only: HookConfig = .{ .wrap_mode = .background_only };
    try std.testing.expectEqual(Decision.passthrough, decide(base, background_only));
}

test "decide skips non-bash and already wrapped commands" {
    const allocator = std.testing.allocator;
    const other = try parsePreToolUse(allocator,
        \\{"session_id":"s1","tool_name":"Read","tool_input":{"command":"make dev"}}
    );
    defer other.deinit();
    try std.testing.expectEqual(Decision.passthrough, decide(other, .{}));

    const wrapped = try parsePreToolUse(allocator,
        \\{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"FOO=bar /usr/local/bin/janitor -- true"}}
    );
    defer wrapped.deinit();
    try std.testing.expectEqual(Decision.passthrough, decide(wrapped, .{}));
}

test "matchesSkip handles first tokens and multi-word prefixes" {
    try std.testing.expect(matchesSkip("  cat README.md", default_skip_patterns[0..]));
    try std.testing.expect(matchesSkip("FOO=bar git status --short", default_skip_patterns[0..]));
    try std.testing.expect(matchesSkip("git diff -- src", default_skip_patterns[0..]));
    try std.testing.expect(!matchesSkip("catalog README.md", default_skip_patterns[0..]));
    try std.testing.expect(!matchesSkip("git statusfoo", default_skip_patterns[0..]));
    try std.testing.expect(!matchesSkip("git push", default_skip_patterns[0..]));
}

test "singleQuoteEscape preserves shell metacharacters" {
    const allocator = std.testing.allocator;
    const escaped = try singleQuoteEscape(allocator, "echo 'hi' && date | cat; echo $(whoami)");
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("'echo '\\''hi'\\'' && date | cat; echo $(whoami)'", escaped);
}

test "buildWrappedCommand omits optional triggers and preserves wrapper shape" {
    const allocator = std.testing.allocator;
    const plain = try buildWrappedCommand(allocator, .{
        .janitor = "janitor",
        .lock = "/tmp/s.lock",
        .pid = 123,
        .grace_ms = 1500,
        .shell = "bash",
        .command = "npm test",
    });
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("'janitor' --watch-path '/tmp/s.lock' --watch-pid 123 --grace-ms 1500 -- 'bash' -c 'npm test'", plain);

    const no_lock = try buildWrappedCommand(allocator, .{
        .janitor = "janitor",
        .pid = 123,
        .command = "npm test",
    });
    defer allocator.free(no_lock);
    try std.testing.expectEqualStrings("'janitor' --watch-pid 123 --grace-ms 1500 -- 'bash' -c 'npm test'", no_lock);

    const no_pid = try buildWrappedCommand(allocator, .{
        .janitor = "janitor",
        .lock = "/tmp/s.lock",
        .command = "npm test",
    });
    defer allocator.free(no_pid);
    try std.testing.expectEqualStrings("'janitor' --watch-path '/tmp/s.lock' --grace-ms 1500 -- 'bash' -c 'npm test'", no_pid);
}

test "buildWrappedCommand escapes complex original command" {
    const allocator = std.testing.allocator;
    const wrapped = try buildWrappedCommand(allocator, .{
        .janitor = "janitor",
        .lock = "/tmp/s.lock",
        .pid = 123,
        .command = "echo 'hi' && printf foo | cat",
    });
    defer allocator.free(wrapped);

    try std.testing.expectEqualStrings("'janitor' --watch-path '/tmp/s.lock' --watch-pid 123 --grace-ms 1500 -- 'bash' -c 'echo '\\''hi'\\'' && printf foo | cat'", wrapped);
}

test "buildWrappedCommand quotes paths with spaces" {
    const allocator = std.testing.allocator;
    const wrapped = try buildWrappedCommand(allocator, .{
        .janitor = "/opt/my janitor/janitor",
        .lock = "/tmp/runtime dir/s.lock",
        .pid = 123,
        .shell = "/bin/my bash",
        .command = "npm test",
    });
    defer allocator.free(wrapped);

    try std.testing.expectEqualStrings("'/opt/my janitor/janitor' --watch-path '/tmp/runtime dir/s.lock' --watch-pid 123 --grace-ms 1500 -- '/bin/my bash' -c 'npm test'", wrapped);
}

test "buildWrappedCommand ignores Claude background flag" {
    const allocator = std.testing.allocator;
    const foreground = try buildWrappedCommand(allocator, .{
        .janitor = "janitor",
        .lock = "/tmp/s.lock",
        .pid = 123,
        .command = "npm test",
        .run_in_background = false,
    });
    defer allocator.free(foreground);

    const background = try buildWrappedCommand(allocator, .{
        .janitor = "janitor",
        .lock = "/tmp/s.lock",
        .pid = 123,
        .command = "npm test",
        .run_in_background = true,
    });
    defer allocator.free(background);

    try std.testing.expectEqualStrings(foreground, background);
}

test "lockPathForBase builds runtime lock shape" {
    const allocator = std.testing.allocator;
    const lock = try lockPathForBase(allocator, "/tmp/runtime", "session-1");
    defer allocator.free(lock);

    try std.testing.expectEqualStrings("/tmp/runtime/janitor-cc/session-1.lock", lock);
}

test "isShellComm handles login shell markers" {
    try std.testing.expect(isShellComm("sh"));
    try std.testing.expect(isShellComm("-bash"));
    try std.testing.expect(isShellComm("zsh\n"));
    try std.testing.expect(isShellComm("/opt/homebrew/bin/zsh"));
    try std.testing.expect(isShellComm("/bin/bash"));
    try std.testing.expect(isShellComm("-/opt/homebrew/bin/zsh"));
    try std.testing.expect(!isShellComm("claude"));
    try std.testing.expect(!isShellComm("/usr/bin/login"));
}

test "resolveClaudePidWalk skips shells to claude" {
    const ancestry = struct {
        fn lookup(_: *const anyopaque, pid: posix.pid_t) ?ProcInfo {
            return switch (pid) {
                10 => .{ .ppid = 9, .comm = "zsh" },
                9 => .{ .ppid = 8, .comm = "-bash" },
                8 => .{ .ppid = 1, .comm = "claude" },
                else => null,
            };
        }
    };

    try std.testing.expectEqual(@as(?posix.pid_t, 8), resolveClaudePidWalk(10, undefined, ancestry.lookup));
}

test "resolveClaudePidWalk handles full comm paths from ps" {
    const ancestry = struct {
        fn lookup(_: *const anyopaque, pid: posix.pid_t) ?ProcInfo {
            return switch (pid) {
                10 => .{ .ppid = 9, .comm = "/opt/homebrew/bin/zsh" },
                9 => .{ .ppid = 8, .comm = "/bin/bash" },
                8 => .{ .ppid = 1, .comm = "/Users/x/.local/bin/claude" },
                else => null,
            };
        }
    };

    try std.testing.expectEqual(@as(?posix.pid_t, 8), resolveClaudePidWalk(10, undefined, ancestry.lookup));
}

test "parseConfig reads env values" {
    const allocator = std.testing.allocator;
    const env = struct {
        fn lookup(_: *const anyopaque, name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "JANITOR_CC_ENABLED")) return "false";
            if (std.mem.eql(u8, name, "JANITOR_CC_GRACE_MS")) return "42";
            if (std.mem.eql(u8, name, "JANITOR_CC_WRAP_MODE")) return "background-only";
            if (std.mem.eql(u8, name, "JANITOR_CC_SHELL")) return "zsh";
            if (std.mem.eql(u8, name, "JANITOR_CC_SKIP_PATTERNS")) return "git branch,whoami";
            if (std.mem.eql(u8, name, "JANITOR_CC_DENY_PATTERNS")) return "vim";
            return null;
        }
    };

    const config = try parseConfig(allocator, .{ .ctx = undefined, .get = env.lookup });
    defer config.deinit(allocator);

    try std.testing.expect(!config.enabled);
    try std.testing.expectEqual(@as(u64, 42), config.grace_ms);
    try std.testing.expectEqual(WrapMode.background_only, config.wrap_mode);
    try std.testing.expectEqualStrings("zsh", config.shell);
    try std.testing.expect(matchesSkip("git branch --show-current", config.skip_patterns.values));
    try std.testing.expect(matchesSkip("vim file", config.deny_patterns.values));
}
