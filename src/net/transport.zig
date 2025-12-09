const std = @import("std");
const Identity = @import("identity.zig").Identity;
const Protocol = @import("protocol.zig").Handshake;
const Wire = @import("protocol.zig").Wire;
const Config = @import("../core/config.zig");
const Orchestrator = @import("../core/orchestrator.zig").Orchestrator;
const UX = @import("../util/ux.zig").UX; // <--- Import UX

pub const Server = struct {
    allocator: std.mem.Allocator,
    identity: *Identity,
    orchestrator: *Orchestrator,
    ux: *UX, // <--- New Dependency
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Update Init
    pub fn init(allocator: std.mem.Allocator, identity: *Identity, orchestrator: *Orchestrator, ux: *UX) Server {
        return Server{ 
            .allocator = allocator, 
            .identity = identity,
            .orchestrator = orchestrator,
            .ux = ux
        };
    }

    pub fn start(self: *Server) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn acceptLoop(self: *Server) void {
        const address = std.net.Address.parseIp4("0.0.0.0", 7777) catch return;
        var server = address.listen(.{ .reuse_address = true }) catch return;
        defer server.deinit();

        self.ux.log("Transport listening on 0.0.0.0:7777", .{});

        while (self.running.load(.seq_cst)) {
            const conn = server.accept() catch continue;
            defer conn.stream.close();

            // REPLACED std.debug.print with self.ux.log
            self.ux.log("Incoming connection from {any}", .{conn.address});
            
            Protocol.performServer(conn.stream, self.allocator) catch |err| {
                self.ux.log("Handshake rejected: {any}", .{err});
                continue;
            };

            while (true) {
                const packet = Wire.receive(conn.stream, self.allocator) catch |err| {
                    if (err != error.EndOfStream) self.ux.log("Connection Error: {any}", .{err});
                    break;
                };
                defer self.allocator.free(packet.payload);

                switch (packet.type) {
                    .ListServices => self.handleList(conn.stream) catch |e| self.ux.log("List failed: {any}", .{e}),
                    .DeployService => self.handleDeploy(conn.stream, packet.payload) catch |e| self.ux.log("Deploy failed: {any}", .{e}),
                    else => {},
                }
            }
        }
    }

    fn handleList(self: *Server, stream: std.net.Stream) !void {
        var loader = Config.ConfigLoader.init(self.allocator);
        defer loader.deinit();
        const configs = loader.loadAll("services") catch &[_]Config.ServiceConfig{};
        
        var names = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer names.deinit(self.allocator);

        for (configs) |c| {
            try names.append(self.allocator, c.name);
        }

        try Wire.send(stream, self.allocator, .ServiceList, names.items);
    }

    fn handleDeploy(self: *Server, stream: std.net.Stream, payload: []const u8) !void {
        self.ux.log("Receiving deployment...", .{});

        const parsed = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const svc = parsed.value;

        const filename = try std.fmt.allocPrint(self.allocator, "services/{s}.json", .{svc.name});
        defer self.allocator.free(filename);
        
        {
            const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{
                std.json.fmt(svc, .{ .whitespace = .indent_4 })
            });
            defer self.allocator.free(json_str);

            const file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();
            _ = try std.posix.write(file.handle, json_str);
        }

        self.ux.log("Handing off to Orchestrator...", .{});
        
        self.orchestrator.reconcile(svc) catch |err| {
            self.ux.log("Orchestration failed: {any}", .{err});
            return err;
        };
        
        self.ux.log("Deployed {s} successfully!", .{svc.name});
        
        try Wire.send(stream, self.allocator, .ServiceList, &[_][]const u8{"OK"});
    }
};
