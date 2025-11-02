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

const zsf_release_public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";
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

    const tarball = try download_tarball(alloc, mirror_choice, conf.filename);
    std.debug.print("Got tarball ({d} bytes)\n", .{tarball.len});
}

test main {
    if (test_config == .Fast) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    try skip_if_offline(@src(), alloc);
    try main();
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
        dbg(@src(), "response header: {s}\n", .{res.head.bytes});
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
    try skip_if_offline(@src(), alloc);
    var text = list_mirrors(alloc);
    defer text.free();
    var lines = std.mem.tokenizeScalar(u8, text.items, '\n');
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

////////////////////////////////// mirror choice //////////////////////////////

/// Returns a random mirror URL.
fn pick_mirror(rand: f64, list: []const u8) []const u8 {
    std.debug.assert(rand >= 0 and rand <= 1);
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
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
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

////////////////////////////////// tarball download ///////////////////////////

/// Returns an unsafe tarball whose signature and checksum have not been
/// verified!
///
/// Caller owns the returned memory.
fn download_tarball(alloc: std.mem.Allocator, mirror_choice: []const u8, tarball_name: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();
    try client.initDefaultProxies(alloc);

    const query_params = "?source=quickzilver";
    const buflen: usize =
        mirror_choice.len
            // `/`
        + 1 + tarball_name.len + query_params.len;
    const buf = try alloc.alloc(u8, buflen);
    defer alloc.free(buf);
    const fmt_slice = try std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ mirror_choice, tarball_name, query_params });
    const uri = try std.Uri.parse(fmt_slice);

    var req = try client.request(std.http.Method.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();
    var res = try req.receiveHead(&.{});
    if (std.unicode.utf8ValidateSlice(res.head.bytes)) {
        dbg(@src(), "response header: {s}\n", .{res.head.bytes});
    }

    var tb = std.ArrayList(u8){};
    defer tb.deinit(alloc);
    var rd_buf: [2 << 6]u8 = undefined;
    var tf_buf: [2 << 6]u8 = undefined;
    var rd = res.reader(&tf_buf);
    while (rd.readSliceShort(&rd_buf)) |end| {
        try tb.appendSlice(alloc, rd_buf[0..end]);
        if (end < buf.len) {
            break;
        }
    } else |e| return e;

    return tb.toOwnedSlice(alloc);
}

test download_tarball {
    if (test_config == .Fast) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    try skip_if_offline(@src(), alloc);
    const tb = try download_tarball(alloc, "https://zigmirror.hryx.net/zig", "zig-aarch64-macos-0.16.0-dev.747+493ad58ff.tar.xz");
    defer alloc.free(tb);
    try std.testing.expectEqual(51414532, tb.len);
}

////////////////////////////////// validation /////////////////////////////////

/// When a keypair is generated using minisign, `pk` will be in their [public
/// key format](https://jedisct1.github.io/minisign/#public-key-format).
/// However, ziglang.org just lists the plain base64-encoded public key. Also,
/// we're hard-coding their current key here in our tool. The tool will break
/// if this key changes or ever needs to be input in a different way and that's
/// OK for now. Anyway, all this is to say that `pk` is the raw base64 encoded
/// public key as listed on [zig's official download
/// page](https://ziglang.org/download/).
///
/// `sig`, on the other hand, is the full signature file according to the
/// [minisign spec](https://jedisct1.github.io/minisign/#signature-format).
/// We'll validate the signature for the payload as well as the trusted comment.
///
/// `filename` is the same filename passed as a top-level input to quickzilver.
/// By convention, the `sig` trusted comment has two key-value pairs by
/// default: (1) timestamp, and (2) name of the file being validated. The file
/// name is useful to us as an extra source of validation. The user inputs the
/// filename they'd like to download as a top-level input to quickzilver. In
/// the validation step, we can check not only that the signature is valid with
/// zsf's public key, but also that the filename in the signature file trusted
/// comment is the same as the filename that the user intends to download.
fn validate(
    alloc: std.mem.Allocator,
    pk: []const u8,
    sig: []const u8,
    // filename
    _: []const u8,
    // payload
    _: []const u8,
) !void {
    const pk_bin = try decode(alloc, pk);
    defer alloc.free(pk_bin);

    try std.base64.standard.Decoder.decode(pk_bin, pk);
    // The first 2 bytes indicate the algorithm, they should be "Ed."
    std.debug.assert(std.mem.eql(u8, pk_bin[0..2], "Ed"));
    // The next 8 are the key serial number, which we don't care about.
    // Bytes 10 => 42 are the 32-byte public key.
    const pk_ = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pk_bin[10..42].*);
    dbg(@src(), "pk bytes {x}\n", .{pk_.bytes});

    // Extract each of the 4 lines from the signature file.
    var lines = std.mem.tokenizeScalar(u8, sig, '\n');
    // discard untrusted comment
    _ = lines.next() orelse return error.MalformedSignature;
    const signature = lines.next() orelse return error.MalformedSignature;
    const sig_bytes = try decode(alloc, signature);
    defer alloc.free(sig_bytes);
    const trusted_comment_line = lines.next() orelse return error.MalformedSignature;
    // The global signature is a sign of the signature and trusted comment
    // concatenated together.
    const global_sig = lines.next() orelse return error.MalformedSignature;

    // Extract trusted comment body from the line, which has a prefix.
    const trusted_comment_prefix = "trusted comment: ";
    std.debug.assert(std.mem.eql(u8, trusted_comment_line[0..trusted_comment_prefix.len], trusted_comment_prefix));
    const trusted_comment_body = trusted_comment_line[trusted_comment_prefix.len..];
    dbg(@src(), "trusted comment body: {s}\n", .{trusted_comment_body});

    // The first 10 bytes are the signature algorithm (2 bytes) and public key
    // serial number (8 bytes), but only the 64-bit signature itself goes into
    // the global context.
    const sig_offset = 10;
    const sig_len = 64;

    // Construct the global context, against which the global_signature was
    // made to prepare to verify it.
    var global = try alloc.alloc(u8, sig_len + trusted_comment_body.len);
    defer alloc.free(global);

    @memcpy(global[0..sig_len], sig_bytes[sig_offset .. sig_offset + sig_len]);
    @memcpy(global[sig_len..], trusted_comment_body);
    dbg(@src(), "global ctx: {x}\n", .{global});

    // Verify the global signature signs the global context using the public
    // key.
    const global_sig_bytes = try decode(alloc, global_sig);
    defer alloc.free(global_sig_bytes);
    std.debug.assert(global_sig_bytes.len == 64);
    const sig_ = std.crypto.sign.Ed25519.Signature.fromBytes(global_sig_bytes[0..64].*);
    try sig_.verify(global, pk_);
}

test "validate a valid signature" {
    const payload = "test\n";
    const pubkey = "RWSL91HT7deJlk5K4d68epTe8XJ8ZCitYye7UNe1KilCnBACefdJoctp";
    const sig = @embedFile("./test.minisig");
    try validate(std.testing.allocator, pubkey, sig, "test", payload);
}

////////////////////////////////// test utils /////////////////////////////////

fn skip_if_offline(comptime loc: std.builtin.SourceLocation, alloc: std.mem.Allocator) !void {
    const list = std.net.getAddressList(alloc, "google.com", 443) catch |e| {
        if (e == error.UnknownHostName) {
            dbg(loc, "Skipping test: {s}\n", .{loc.fn_name});
            // Not connected to the internet.
            return error.SkipZigTest;
        } else {
            return e;
        }
    };
    defer list.deinit();
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
            f.len + col_str.len + ln_str.len + mod.len + func.len + 14 + fmt.len
        ]u8 = undefined;
        _ = std.fmt.bufPrint(&fmt_buf, "src/{s}:{s}:{s} || {s}::{s}\t{s}\n", .{ f, ln_str, col_str, mod, func, fmt }) catch unreachable;
        const final = fmt_buf;
        break :pf final;
    };
    std.debug.print(&prefixed_fmt, args);
}
////////////////////////////////// b64 ////////////////////////////////////////

/// Caller owns returned memory.
fn decode(alloc: std.mem.Allocator, str: []const u8) ![]u8 {
    const bufsize = try std.base64.standard.Decoder.calcSizeForSlice(str);
    const buf = try alloc.alloc(u8, bufsize);
    try std.base64.standard.Decoder.decode(buf, str);
    return buf;
}
