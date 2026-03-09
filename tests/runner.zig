//! Test runner that imports simulation tests.
//! Run with: zig test tests/runner.zig

const std = @import("std");
const sim = @import("simulation");

pub fn main() !void {
    std.debug.print("Running simulation tests...\n", .{});
}
