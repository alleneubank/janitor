//! zig-template library.
//!
//! Replace this with your library's documentation.

const std = @import("std");

/// Library version.
pub const version = "0.0.0";

/// Example library function. Replace with your own.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "add" {
    try std.testing.expectEqual(@as(i32, 5), add(2, 3));
}

test "add negative" {
    try std.testing.expectEqual(@as(i32, 0), add(-1, 1));
}
