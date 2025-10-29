const std = @import("std");
const builtin = @import("builtin");
const quickzilver = @import("quickzilver");

////////////////////////////////// constants //////////////////////////////////

const mirror_registry_url = std.Uri.parse("https://ziglang.org/download/community-mirrors.txt") catch unreachable;
const mirror_list_fallback =
    \\https://pkg.machengine.org/zig
    \\https://zigmirror.hryx.net/zig
    \\https://zig.linus.dev/zig
    \\https://zig.squirl.dev
    \\https://zig.florent.dev
    \\https://zig.mirror.mschae23.de/zig
    \\https://zigmirror.meox.dev
;
const TestConfig = enum { All, Fast };
const test_config: TestConfig = TestConfig.All;

////////////////////////////////// entrypoint /////////////////////////////////

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fp = try std.fs.openFileAbsolute("/Users/johndevries/repos/quickzilver/testing_config.zon", .{});
    const stat = try fp.stat();
    var config_bytes = try alloc.alloc(u8, stat.size + 1);
    defer alloc.free(config_bytes);
    _ = try fp.read(config_bytes);
    config_bytes[stat.size] = 0;
    const config_str = config_bytes[0..stat.size :0];
    const conf = try parse(alloc, config_str);

    var list = list_mirrors(alloc);
    defer list.free();

    var randint: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&randint));
    const randfloat: f64 = @as(f64, @floatFromInt(randint)) / @as(f64, @floatFromInt(2 << 63));
    const mirror_choice = pick_mirror(randfloat, list.items);

    std.debug.print("BEGIN mirror options\n{s}END mirror options\n", .{list.items});
    std.debug.print("Downloading file {s} from {s}\n", .{ conf.filename, mirror_choice });
}

test main {
    if (test_config == .Fast) {
        return error.SkipZigTest;
    }
    try main();
}

////////////////////////////////// debugging //////////////////////////////////

const debugPrinting: enum { Enabled, Disabled } = blk: {
    if (builtin.is_test) {
        break :blk .Enabled;
    }
    break :blk .Disabled;
};

/// Get `loc` by calling the `@src()` builtin.
fn dbg(comptime loc: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    comptime {
        std.debug.assert(fmt[fmt.len - 1] == '\n'); // fmt template must end with newline
    }
    if (debugPrinting != .Enabled) {
        return;
    }

    const prefixed_fmt = comptime pf: {
        const f = loc.file;

        const col = loc.column;
        var col_strbuf: [10]u8 = undefined;
        const col_str = std.fmt.bufPrint(&col_strbuf, "{d}", .{col}) catch unreachable;
        const ln = loc.line;
        var ln_strbf: [10]u8 = undefined;
        const ln_str = std.fmt.bufPrint(&ln_strbf, "{d}", .{ln}) catch unreachable;

        const mod = loc.module;
        const func = loc.fn_name;

        var fmt_buf: [
            f.len + col_str.len + ln_str.len + mod.len + func.len + 21 + fmt.len
        ]u8 = undefined;
        _ = std.fmt.bufPrint(&fmt_buf, "--\nsrc/{s}:{s}:{s} || {s}::{s}\n\t{s}\n--\n", .{ f, ln_str, col_str, mod, func, fmt }) catch unreachable;
        const final = fmt_buf;
        break :pf final;
    };
    std.debug.print(&prefixed_fmt, args);
}

////////////////////////////////// config /////////////////////////////////////

const Config = struct {
    /// One of the file names listed on https://ziglang.org/download/index.json.
    filename: []const u8,
};

fn parse(alloc: std.mem.Allocator, source: [:0]const u8) !Config {
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
    var dba = std.heap.DebugAllocator(.{}){};
    const alloc = dba.allocator();

    const raw =
        \\.{
        \\    .filename = "zig-aarch64-macos-0.16.0-dev.747+493ad58ff.tar.xz",
        \\}
    ;
    const conf = try parse(alloc, raw);
    const filename = "zig-aarch64-macos-0.16.0-dev.747+493ad58ff.tar.xz";
    try std.testing.expectEqualDeep(conf, Config{ .filename = filename });
}

////////////////////////////////// mirror discovery ///////////////////////////

fn _list_mirrors(alloc: std.mem.Allocator) ![]const u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();
    try client.initDefaultProxies(alloc);

    var req = try client.request(std.http.Method.GET, mirror_registry_url, .{});
    defer req.deinit();
    try req.sendBodiless();
    var res = try req.receiveHead(&.{});

    if (std.unicode.utf8ValidateSlice(res.head.bytes)) {
        dbg(@src(), "list_mirrors response header: {s}\n", .{res.head.bytes});
    }

    var buf_tr: [2 << 6]u8 = undefined;
    var buf_dc: [std.compress.flate.max_window_len]u8 = undefined;
    var buf_rd: [2 << 6]u8 = undefined;
    var dc: std.http.Decompress = undefined;
    var rd = res.readerDecompressing(&buf_tr, &dc, &buf_dc);
    var text = std.ArrayList(u8){};
    while (rd.readSliceShort(&buf_rd)) |readlen| {
        try text.appendSlice(alloc, buf_rd[0..readlen]);
        if (readlen < buf_rd.len) {
            break;
        }
    } else |e| return e;

    dbg(@src(), "got mirror list: {s}\n", .{text.items});
    return try text.toOwnedSlice(alloc);
}

const fallback = fb: {
    if (builtin.is_test) {
        break :fb "SENTINEL";
    } else {
        break :fb mirror_list_fallback;
    }
};

const MirrorResult = struct {
    pub const ResultLocation = union(enum) { Static, Heap: std.mem.Allocator };

    location: ResultLocation,
    items: []const u8,

    fn free(self: *MirrorResult) void {
        switch (self.location) {
            ResultLocation.Static => return,
            ResultLocation.Heap => |alloc| alloc.free(self.items),
        }
    }
};
fn list_mirrors(alloc: std.mem.Allocator) MirrorResult {
    const heap_allocated_list = _list_mirrors(alloc) catch |err| {
        dbg(@src(), "could not get mirror from net: {t}\n", .{err});
        return .{ .location = MirrorResult.ResultLocation.Static, .items = fallback };
    };
    return .{ .items = heap_allocated_list, .location = MirrorResult.ResultLocation{ .Heap = alloc } };
}

test "download list of mirrors" {
    if (test_config == .Fast) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    var text = list_mirrors(alloc);
    defer text.free();
    var lines = std.mem.splitSequence(u8, text.items, "\n");
    while (lines.next()) |line| {
        if (line.len != 0) {
            try std.testing.expectEqualStrings("https://", line[0..8]);
        }
    }
}

test "fallback behavior to avoid ziglang.org point of failure" {
    var buf: [0]u8 = undefined;
    var a = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = a.allocator();
    var items = list_mirrors(alloc);
    defer items.free();
    try std.testing.expectEqualStrings(fallback, items.items);
}

fn pick_mirror(rand: f64, list: []const u8) []const u8 {
    var line_cnt: u32 = 0;
    for (list) |byte| {
        if (byte == '\n') {
            line_cnt += 1;
        }
    }
    const rng_f: f64 = @floatFromInt(line_cnt);
    const target_idx_f = rand * rng_f;
    const idx: u32 = @intFromFloat(std.math.floor(target_idx_f));
    var i: u32 = 0;
    var lines = std.mem.splitSequence(u8, list, "\n");
    while (lines.next()) |line| {
        if (i == idx) {
            dbg(@src(), "rand {e} causes us to pick line {d} which is {s}\n", .{ rand, idx, line });
            return line;
        }
        i += 1;
    }
    unreachable;
}

test pick_mirror {
    {
        const res = pick_mirror(0.0, "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n");
        try std.testing.expectEqualStrings("0", res);
    }

    {
        const res = pick_mirror(0.2, "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n");
        try std.testing.expectEqualStrings("2", res);
    }
}
