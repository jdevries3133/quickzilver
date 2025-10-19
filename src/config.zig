const std = @import("std");

const Version = enum {
    FifteenOne,
    FourteenOne
};

const Config = struct {
    version: Version
};

pub fn read(alloc: std.mem.Allocator, source: []u8) i32 {
    std.zon.parse.fromSlice(Config, alloc, source);
}
