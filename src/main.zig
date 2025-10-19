const std = @import("std");
const quickzilver = @import("quickzilver");
const config = @import("config.zig");

pub fn main() !void {
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const fp = try std.fs.openFileAbsolute("/Users/johndevries/repos/quickzilver/config.zon", .{});
    const stat = try fp.stat();
    const config_bytes = try allocator.alloc(u8, stat.size);
    defer allocator.free(config_bytes);
    _ = try fp.read(config_bytes);
    std.debug.print("{s}", .{config_bytes});
}

