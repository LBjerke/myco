const std = @import("std");
const Identity = @import("identity.zig").Identity;
const Protocol = @import("protocol.zig").Handshake; // <--- Import
const UX = @import("ux.zig").UX;

pub const Server = struct {
    allocator: std.mem.Allocator,
    identity: *Identity,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, identity: *Identity) Server {
        return Server{
            .allocator = allocator,
            .identity = identity,
        };
    }

    pub fn start(self: *Server) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn acceptLoop(self: *Server) void {
    var ux = UX.init(self.allocator);
    defer ux.deinit();
        // FIX 1: Use parseIp4 (as seen in your working reference)
        const address = std.net.Address.parseIp4("0.0.0.0", 7777) catch |err| {
            ux.fail("[!] Transport Error: Bad IP: {}\n", .{err});
            return;
        };
        
        // FIX 2: Call listen() directly on the address.
        // This replaces 'std.net.StreamServer.init'.
        // We pass reuse_address options here.
        var server = address.listen(.{ .reuse_address = true }) catch |err| {
            ux.fail("Transport Error: Failed to listen on 7777: {}", .{err});
            return;
        };
        defer server.deinit();

        ux.success("Transport listening on 0.0.0.0:7777", .{});

        while (self.running.load(.seq_cst)) {
            // FIX 3: Accept returns a Connection object
            const conn = server.accept() catch |err| {
                ux.fail("Accept Error: {}", .{err});
                continue;
            };
            defer conn.stream.close();
              // For the skeleton, we do it blocking to verify it works.
             ux.step("Handshaking with {f}...\n", .{conn.address}) catch |err| {
                  ux.fail("unreachable: {}\n", .{err});
         };
            
            Protocol.performServer(conn.stream, self.allocator) catch |err| {
                  ux.fail("Handshake Failed: {}\n", .{err});
            };
        }
    }
};
