const std = @import("std");
const lib = @import("zig_template");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &stdout.interface;

    try w.print("zig-template v{s}\n", .{lib.version});
    try w.print("2 + 3 = {d}\n", .{lib.add(2, 3)});
    try w.flush();
}

test "library import" {
    try std.testing.expectEqual(@as(i32, 2), lib.add(1, 1));
}
