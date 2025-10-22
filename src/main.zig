const std = @import("std");
const quickzilver = @import("quickzilver");

const Config = struct {
    version_major: u8,
    version_minor: u8,
    version_patch: u8,
};

pub fn parse(alloc: std.mem.Allocator, source: [:0]const u8) !Config {
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSlice(Config, alloc, source, &diag, .{}) catch |err| {
        var buf: [1024]u8 = undefined;
        const w = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();
        diag.format(w) catch unreachable;
        return err;
    };
}

test "parse zon config file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw =
        \\.{
        \\    .version_major = 0,
        \\    .version_minor = 15,
        \\    .version_patch = 2,
        \\}
    ;
    const conf = try parse(allocator, raw);
    try std.testing.expectEqual(conf, Config{
        .version_major = 0,
        .version_minor = 15,
        .version_patch = 2
    });
}

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
    const conf = try parse(allocator, config_str);
    std.debug.print("{d}.{d}.{d}\n", .{conf.version_major, conf.version_minor, conf.version_patch});
}

