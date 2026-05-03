const std = @import("std");
const lib = @import("zig_template");

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    const file = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .initStreaming(file, io, &buf);
    const w = &writer.interface;

    try w.print("zig-template v{s}\n", .{lib.version});
    try w.print("2 + 3 = {d}\n", .{lib.add(2, 3)});
    try w.flush();
}

test "library import" {
    try std.testing.expectEqual(@as(i32, 2), lib.add(1, 1));
}
