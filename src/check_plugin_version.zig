const std = @import("std");

const build_version_file = "build.zig.zon";

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .{};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const expected_version = args.next() orelse fatal(
        "usage: check-plugin-version <build.zig.zon-version> <plugin-json-path>\n",
        .{},
    );
    const plugin_manifest_path = args.next() orelse fatal(
        "usage: check-plugin-version <build.zig.zon-version> <plugin-json-path>\n",
        .{},
    );
    if (args.next() != null) {
        fatal("usage: check-plugin-version <build.zig.zon-version> <plugin-json-path>\n", .{});
    }

    const manifest_bytes = std.fs.cwd().readFileAlloc(
        allocator,
        plugin_manifest_path,
        1024 * 1024,
    ) catch |err| fatal(
        "failed to read {s}: {s}\n",
        .{ plugin_manifest_path, @errorName(err) },
    );
    defer allocator.free(manifest_bytes);

    const parsed_manifest = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        manifest_bytes,
        .{},
    ) catch |err| fatal(
        "failed to parse {s}: {s}\n",
        .{ plugin_manifest_path, @errorName(err) },
    );
    defer parsed_manifest.deinit();

    const plugin_version = readPluginVersion(
        parsed_manifest.value,
        plugin_manifest_path,
        expected_version,
    );

    if (!std.mem.eql(u8, expected_version, plugin_version)) {
        fatal(
            "{s} version {s} does not match {s} version {s}\n",
            .{ plugin_manifest_path, plugin_version, build_version_file, expected_version },
        );
    }
}

fn readPluginVersion(
    manifest: std.json.Value,
    plugin_manifest_path: []const u8,
    expected_version: []const u8,
) []const u8 {
    const object = switch (manifest) {
        .object => |value| value,
        else => fatal(
            "{s} must be a JSON object with string field \"version\"; {s} version is {s}\n",
            .{ plugin_manifest_path, build_version_file, expected_version },
        ),
    };

    const version_value = object.get("version") orelse fatal(
        "{s} is missing string field \"version\"; {s} version is {s}\n",
        .{ plugin_manifest_path, build_version_file, expected_version },
    );

    return switch (version_value) {
        .string => |value| value,
        else => fatal(
            "{s} field \"version\" must be a string; {s} version is {s}\n",
            .{ plugin_manifest_path, build_version_file, expected_version },
        ),
    };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
