const std = @import("std");
const quickzilver = @import("quickzilver");
const config = @import("config.zig");

pub fn main() !void {
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const fp = try std.fs.openFileAbsolute("/Users/johndevries/repos/quickzilver/config.zon", .{});
    const stat = try fp.stat();
    var config_bytes = try allocator.alloc(u8, stat.size + 1);
    defer allocator.free(config_bytes);
    _ = try fp.read(config_bytes);
    config_bytes[stat.size] = 0;
    const config_str = config_bytes[0..stat.size :0];
    const conf = try config.parse(allocator, config_str);
    std.debug.print("{d}.{d}.{d}\n", .{conf.version_major, conf.version_minor, conf.version_patch});
}

