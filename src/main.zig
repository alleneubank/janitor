const std = @import("std");
const janitor = @import("janitor");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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

fn printUsage(err: ?janitor.ParseError) void {
    if (err) |parse_err| {
        if (parse_err != error.MissingCommand) {
            std.debug.print("janitor: {s}\n\n", .{@errorName(parse_err)});
        }
    }

    std.debug.print(
        \\usage: janitor [--watch-path PATH] [--watch-pid PID] [--grace-ms MS] [--poll-ms MS] -- CMD [ARGS...]
        \\
        \\Runs CMD in a new process group. If janitor's parent changes, a watched
        \\path disappears, a watched PID exits, or janitor receives TERM/INT/HUP,
        \\it drains the child process group with SIGTERM, a grace window, then SIGKILL.
        \\
    , .{});
}

test "library import" {
    const args = &.{ "--", "true" };
    const config = try janitor.parseArgs(args);
    try std.testing.expectEqualStrings("true", config.command[0]);
}
