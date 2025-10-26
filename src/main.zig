const std = @import("std");
const builtin = @import("builtin");
const quickzilver = @import("quickzilver");

////////////////////////////////// entrypoint /////////////////////////////////

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fp = try std.fs.openFileAbsolute("/Users/johndevries/repos/quickzilver/config.zon", .{});
    const stat = try fp.stat();
    var config_bytes = try allocator.alloc(u8, stat.size + 1);
    defer allocator.free(config_bytes);
    _ = try fp.read(config_bytes);
    config_bytes[stat.size] = 0;
    const config_str = config_bytes[0..stat.size :0];
    const conf = try parse(allocator, config_str);

    _ = try list_mirrors(allocator);

    std.debug.print("{d}.{d}.{d}\n", .{ conf.version_major, conf.version_minor, conf.version_patch });
}

////////////////////////////////// debugging //////////////////////////////////

const debugPrinting: enum {
    Enabled,
    Disabled
}= .Enabled;

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
        var col_strbuf:  [10]u8 = undefined;
        const col_str = std.fmt.bufPrint(&col_strbuf, "{d}", .{ col }) catch unreachable;
        const ln = loc.line;
        var ln_strbf:  [10]u8 = undefined;
        const ln_str = std.fmt.bufPrint(&ln_strbf, "{d}", .{ ln }) catch unreachable;

        const mod = loc.module;
        const func = loc.fn_name;

        var fmt_buf: [f.len
            + col_str.len
            + ln_str.len 
            + mod.len 
            + func.len 
            // \n\t
            // count of non-template characters in the fmt string below
            + 21
            + fmt.len]u8 = undefined;
        _ = std.fmt.bufPrint(&fmt_buf, "--\nsrc/{s}:{s}:{s} || {s}::{s}\n\t{s}\n--\n", .{
            f,
            col_str,
            ln_str,
            mod,
            func,
            fmt
        }) catch unreachable;
        const final = fmt_buf;
        break :pf final;
    };
    std.debug.print(&prefixed_fmt, args);
}

////////////////////////////////// config /////////////////////////////////////

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
    var dba = std.heap.DebugAllocator(.{}){};
    const alloc = dba.allocator();

    const raw =
        \\.{
        \\    .version_major = 0,
        \\    .version_minor = 15,
        \\    .version_patch = 2,
        \\}
    ;
    const conf = try parse(alloc, raw);
    try std.testing.expectEqual(conf, Config{ .version_major = 0, .version_minor = 15, .version_patch = 2 });
}

////////////////////////////////// http proto /////////////////////////////////

const HexResult = struct {
    value: u64,
    // The position of the last hext byte in `hex`.
    end_idx: u64,
};
fn parse_hex_while_it_lasts(hex: []const u8) !HexResult {
    var out: HexResult = .{ .value = 0, .end_idx = 0 };
    var chars_read: u10 = 0;
    for (hex) |char| {
        const hexval = switch (char) {
            '0'...'9' => char - 48,
            'a'...'f' => char - 87,
            'A'...'F' => char - 55,
            else => {
                return out;
            },
        };

        out.end_idx += 1;
        out.value = out.value <<| 4;
        out.value = out.value | hexval;
        if (out.value == std.math.maxInt(@TypeOf(out.value))) {
            return out;
        }
        chars_read += 1;
        // SAFETY: This can be screwed with by feeding in zeroes forever. We
        // won't read more than 1,000 characters; that gives lots of room for
        // trailing zeroes and a u64.
        if (chars_read > 1000) {
            return error.Malformed;
        }
    }
    return out;
}

test parse_hex_while_it_lasts {
    try std.testing.expectEqual(15, (try parse_hex_while_it_lasts("f")).value);
    try std.testing.expectEqual(255, (try parse_hex_while_it_lasts("ff")).value);
    try std.testing.expectEqual(170, (try parse_hex_while_it_lasts("aa")).value);
    try std.testing.expectEqual(170, (try parse_hex_while_it_lasts("AA")).value);
    try std.testing.expectEqual(1, (try parse_hex_while_it_lasts("01")).value);

    // Stops at the first non-hex byte.
    try std.testing.expectEqual(1, (try parse_hex_while_it_lasts("01z")).value);
    try std.testing.expectEqual(2, (try parse_hex_while_it_lasts("01z")).end_idx);
    try std.testing.expectEqual(11259375, (try parse_hex_while_it_lasts("abcdefg")).value);
    try std.testing.expectEqual(6, (try parse_hex_while_it_lasts("abcdefg")).end_idx);
    try std.testing.expectEqual(0, (try parse_hex_while_it_lasts("zig")).value);

    // Saturates to u64 max.
    try std.testing.expectEqual(std.math.maxInt(u64), (try parse_hex_while_it_lasts("fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")).value);

    // Rejects abuse by zeroes.
    var buf: [1001]u8 = undefined;
    for (&buf) |*c| {
        c.* = '0';
    }
    try std.testing.expectError(error.Malformed, parse_hex_while_it_lasts(&buf));
}

const ChunkParserOpts = struct {
    /// The total limit of the chunk. This applies to the data in the chunk,
    /// not counting the bytes which encode the chunk size or ignored
    /// extension bytes.
    chunk_limit: u32 = 2 << 18,
    /// How many chunked encoding extension bytes we'll discard.
    chunk_extension_limit: u16 = 2 << 12,
    /// The hex parser can be abused by feeding zeroes forever without this
    /// limit.
    hex_size_char_limit: u16 = 2 << 9,
};

const Chunk = struct {
    /// SAFETY: this is a view into the body passed into
    /// `parse_chunked_response`.
    payload: []const u8,
    // SAFETY: this points to the first byte of the next chunk; pointing one
    // byte past the end of the range that is read during chunk parsing.
    // It's possible that this is beyond the end of the stream read buffer.
    next_chunk_idx: u64,
};

/// Return the sub-slice of `body` with the chunk data excluding the trailing
/// `\r\n`. Remember, the trailing `\r\n` is not in the returned slice, but we
/// do validate it's there. Ensure that these bytes are discarded when
/// navigating to the start of the next chunk before calling this function
/// again to parse the next chunk.
///
/// Chunked encoding extensions are ignored.
///
/// `ChunkParserOpts` establishes limits on the chunk as a whole, and its
/// internal pieces.
///
/// `error.NeedMoreBytes` is returned when the chunk size is larger than
/// `body`. This implies that we've received the incomplete head of a stream.
/// The caller should take more bytes from the stream, and call this function
/// again so that we can see up until the end of the current chunk.
///
/// `error.Malformed` indicates that the chunk is malformed because a limit
/// defined by `ChunkParserOpts` has been exceeded. Or, the chunk is internally
/// inconsistent. For example, there is not a `\r\n` directly after the end of
/// the chunk payload.
fn parse_chunked_response(body: []const u8, opts: ChunkParserOpts) !Chunk {
    var total_chunk_length: u64 = 0;
    const hex_result = try parse_hex_while_it_lasts(body);
    total_chunk_length += hex_result.end_idx;

    if (hex_result.value > opts.chunk_limit) {
        return error.Malformed;
    }

    const after_hex = body[hex_result.end_idx..];

    // Read until we find `\r\n`, or until the end.
    var ptr: u64 = 0;
    var cr_found = false;
    for (after_hex) |byte| {
        if (byte == '\r') {
            cr_found = true;
        } else if (byte == '\n' and cr_found) {
            break;
        } else {
            cr_found = false;
        }
        ptr += 1;
    }

    if (ptr > opts.chunk_extension_limit) {
        return error.Malformed;
    }

    // In this case, we previously read until the end of the body without
    // finding the `\r\n`. We need more bytes, because we did not get into the
    // payload.
    if (!cr_found) {
        return error.NeedMoreBytes;
    }

    // Advance past `\n`, and do a bounds check.
    const data_start = ptr + 1;
    if (data_start > after_hex.len) {
        return error.NeedMoreBytes;
    }

    const payload_head = after_hex[data_start..];

    // See if the payload_head slice goes all the way until the end of the
    // payload. Otherwise, we need to keep reading.
    if (payload_head.len < hex_result.value + 2) {
        return error.NeedMoreBytes;
    }
    const crlf: []const u8 = "\r\n";
    if (std.mem.eql(u8, crlf, payload_head[hex_result.end_idx .. hex_result.end_idx + 1])) {
        return error.Malformed;
    }

    total_chunk_length += data_start + hex_result.value + 2;

    return .{ .payload = payload_head[0..hex_result.value], .next_chunk_idx = total_chunk_length };
}

const test_opts: ChunkParserOpts = .{ .chunk_extension_limit = 16, .chunk_limit = 128 };
test "parse basic chunks" {
    {
        const body: []const u8 = "02\r\nhi\r\n";
        const result = try parse_chunked_response(body, test_opts);
        try std.testing.expectEqualStrings(result.payload, "hi");
        try std.testing.expectEqual(8, result.next_chunk_idx);
    }

    {
        const body: []const u8 = "03\r\nhey\r\n";
        const result = try parse_chunked_response(body, test_opts);
        try std.testing.expectEqualStrings(result.payload, "hey");
    }
    {
        const body: []const u8 = "5 some extension OK\r\n12345\r\n";
        const result = try parse_chunked_response(body, .{ .chunk_extension_limit = 50, .chunk_limit = 50 });
        try std.testing.expectEqualStrings(result.payload, "12345");
    }
}

test "parse incomplete chunks" {
    {
        // no \r\n at the end
        const body: []const u8 = "02\r\nhey";
        try std.testing.expectError(error.NeedMoreBytes, parse_chunked_response(body, test_opts));
    }

    {
        const body: []const u8 = "50\r\nneeds more sauce\r\n";
        try std.testing.expectError(error.NeedMoreBytes, parse_chunked_response(body, test_opts));
    }
    {
        // did not find the ending newline yet
        const body: []const u8 = "5\r\n";
        try std.testing.expectError(error.NeedMoreBytes, parse_chunked_response(body, test_opts));
    }
}

test "parse bad chunk extensions" {
    const body: []const u8 = "3 here is my life story as an http chunk extension. What do you think?!\r\nhey\r\n";
    try std.testing.expectError(error.Malformed, parse_chunked_response(body, test_opts));
}

test "parse chunk too big" {
    const body: []const u8 = "30000000\r\ndisrespect for chonk supreme\r\n";
    try std.testing.expectError(error.Malformed, parse_chunked_response(body, test_opts));
}

test "parse last chunk" {
    const body: []const u8 = "0\r\n\r\n";
    const result = try parse_chunked_response(body, test_opts);
    try std.testing.expectEqual(0, result.payload.len);
}

test "parse two chunks returns only the first chunk" {
    const body: []const u8 = "2\r\nhi\r\n3\r\nhey\r\n";
    const result = try parse_chunked_response(body, test_opts);
    try std.testing.expectEqualStrings("hi", result.payload);
    try std.testing.expectEqual(7, result.next_chunk_idx);
}

////////////////////////////////// http i/o ///////////////////////////////////

fn list_mirrors(alloc: std.mem.Allocator) !void { // !std.ArrayList([]const u8) {
    const mirror_registry_url = try std.Uri.parse("https://ziglang.org/download/community-mirrors.txt");
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();
    try client.initDefaultProxies(alloc);

    var req = try client.request(std.http.Method.GET, mirror_registry_url, .{});
    defer req.deinit();
    try req.sendBodiless();
    var res = try req.receiveHead(&[_]u8{});
    const transfer_buf = try alloc.alloc(u8, 2 << 12);
    defer alloc.free(transfer_buf);
    _ = res.reader(transfer_buf);

    // const response_buf_rd = std.io.fixedBufferStream(gzipped_response).reader();
    // const decompress_buf = try alloc.alloc(u8, std.compress.flate.max_window_len);
    // var dc = std.compress.flate.Decompress.init(response_buf_rd, std.compress.flate.Container.gzip, decompress_buf);
    // const text_buf = try alloc.alloc(u8, 2 << 12);
    // try dc.reader.readSliceAll(text_buf);
    // if (!std.unicode.utf8ValidateSlice(text_buf)) {
    //     return error.InvalidUtf8Response;
    // }

    // std.debug.print("{s}", .{gzipped_response});

    // var names = std.ArrayList([]const u8);
}

// test "download list of mirrors" {
//     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();
//
//     try list_mirrors(allocator);
//     // var found = false;
//     // for (mirrors.items) |item| {
//     //     found = found || std.mem.eql(item, "https://zigmirror.meox.dev");
//     // }
// }

test "random assertion that 2 << 12 is 8 KiB" {
    try std.testing.expectEqual(8192, 2 << 12);
}
