# `quickzilver`

A tiny tool for interacting with zig community mirrors, written in Zig.

Implements the [pseudocode prescriptions from the Zig Software Foundation
site](https://ziglang.org/download/community-mirrors/).

# Config

Pass `quickzilver` config to STDIN as a [Zig Object Notation
(ZON)](https://ziglang.org/documentation/master/std/#std.zon) string. See
[`config.zig`](./src/config.zig).
