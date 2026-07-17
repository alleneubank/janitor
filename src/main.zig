const std = @import("std");
const cc_hook = @import("cc_hook.zig");
const janitor = @import("janitor");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "cc-hook")) {
        cc_hook.main(allocator, if (args.len >= 3) args[2] else null);
        return;
    }

    // Version request short-circuits before arg parsing so it never collides
    // with the `-- CMD` form. A program literally named "version" still runs via
    // `janitor -- version`.
    if (args.len >= 2 and isVersionRequest(args[1])) {
        printVersion();
        return;
    }

    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        printUsage(null);
        return;
    }

    const config = janitor.parseArgs(args[1..]) catch |err| {
        printUsage(err);
        std.process.exit(2);
    };

    const code = janitor.run(config, allocator) catch |err| {
        std.debug.print("janitor: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn isVersionRequest(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "version") or
        std.mem.eql(u8, arg, "--version") or
        std.mem.eql(u8, arg, "-V");
}

fn printVersion() void {
    var buf: [256]u8 = undefined;
    const line = janitor.versionLine(&buf) catch return;
    // Version is requested output, not a diagnostic, so it goes to stdout.
    writeStdout(line);
    writeStdout("\n");
}

fn writeStdout(bytes: []const u8) void {
    // Best-effort write: a closed stdout (e.g. `janitor --version | head`)
    // raises EPIPE, which is not worth a nonzero exit. Surfaced at debug level
    // rather than swallowed silently.
    std.fs.File.stdout().writeAll(bytes) catch |err| {
        std.log.debug("stdout write failed: {s}", .{@errorName(err)});
    };
}

fn printUsage(err: ?janitor.ParseError) void {
    if (err) |parse_err| {
        if (parse_err != error.MissingCommand) {
            std.debug.print("janitor: {s}\n\n", .{@errorName(parse_err)});
        }
    }

    const teardown_description = if (comptime janitor.descendants_supported)
        \\Runs CMD in a new process group. If janitor's parent changes, a watched
        \\path disappears, a watched PID exits, or janitor receives TERM/INT/HUP,
        \\it snapshots live descendants, then drains the child process group and any
        \\identity-verified escaped descendants with SIGTERM, a grace window, then SIGKILL.
        \\Use --pgroup-only to retain historical child-process-group-only teardown.
    else
        \\Runs CMD in a new process group. If janitor's parent changes, a watched
        \\path disappears, a watched PID exits, or janitor receives TERM/INT/HUP,
        \\it drains only the child process group with SIGTERM, a grace window, then SIGKILL.
        \\Descendant snapshot draining is available on Linux and macOS only.
    ;
    std.debug.print(
        \\usage: janitor [--watch-path PATH] [--watch-pid PID] [--grace-ms MS]
        \\               [--poll-ms MS] [--pgroup-only] -- CMD [ARGS...]
        \\   or: janitor version | --version | -V
        \\
        \\{s}
        \\
    , .{teardown_description});
}

test "library import" {
    const args = &.{ "--", "true" };
    const config = try janitor.parseArgs(args);
    try std.testing.expectEqualStrings("true", config.command[0]);
}
