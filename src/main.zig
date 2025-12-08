const std = @import("std");
const UX = @import("util/ux.zig").UX;
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ux = UX.init(allocator);
    defer ux.deinit();

    // Pass control to CLI
    cli.run(allocator, &ux) catch |err| {
        // Pretty print top-level errors
        ux.fail("Critical Error: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}
