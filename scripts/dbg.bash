#!/bin/bash

set -ux

zig build
lldb -o run zig-out/bin/quickzilver
