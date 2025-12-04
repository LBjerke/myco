const builtin = @import("builtin");
const log = std.log.scoped(.server);
const std = @import("std");
const myco = @import("Myco");
const lmdb = @import("lmdb");
const zimq = @import("zimq");
const nix = @import("nix.zig").Nix;
const http = std.http;
const mem = std.mem;
const net = std.net;
const native_endian = builtin.cpu.arch.endian();
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

// TODO: create router for the server
// Woot I figured out how to read the body from a request
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit(); // Ensure all memory is freed at the end of `main`.

    // Get the allocator interface from the gpa.
    const allocator = gpa.allocator();
    // Prints to stderr, ignoring potential errors.
    //this is the zimq part

    const address = try std.net.Address.parseIp4("127.0.0.1", 8088);
    var server = try address.listen(.{});
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        var reader_buf: [1024]u8 = undefined;
        var writer_buf: [1024]u8 = undefined;

        var reader = conn.stream.reader(&reader_buf).file_reader;
        var writer = conn.stream.writer(&writer_buf).file_writer;

        var server_http = std.http.Server.init(&reader.interface, &writer.interface);

        var req = try server_http.receiveHead();
        if (mem.eql(u8, req.head.target, "/hello")) {
                     // Example: Read request body

            const body = try (try req.readerExpectContinue(&.{})).allocRemaining(allocator, .unlimited);
            defer allocator.free(body);
            std.debug.print("Request body: {s}\n", .{body});
            var new_nix = nix.init(allocator);
            new_nix.proprietary_software = true;
            try new_nix.nixosRebuild();
            try req.respond(body, .{});
        } else {
            try req.respond("hello!", .{});
        }
    }
}
test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
