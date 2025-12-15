const std = @import("std");
const UX = @import("util/ux.zig").UX; // Still needed for init
const App = @import("app.zig").App;
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Init UX first (needed for App init)
    var ux = UX.init(allocator);
    defer ux.deinit();

    // Init App (Global State)
    var app = try App.init(allocator, &ux);
    defer app.deinit();

    // Run CLI
    cli.run(allocator, &app) catch |err| {
        ux.fail("Critical Error: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}

test {
    // Force inclusion of these modules in the test build
    _ = @import("core/shims.zig");
    _ = @import("core/config.zig");
    _ = @import("net/identity.zig");
    _ = @import("net/protocol.zig");
    // _ = @import("net/transport.zig"); // Might fail if it tries to bind port 7777 during test
}
