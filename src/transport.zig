const std = @import("std");
const Identity = @import("identity.zig").Identity;
const Protocol = @import("protocol.zig").Handshake;
const Wire = @import("protocol.zig").Wire;
const Config = @import("config.zig");
const Nix = @import("nix.zig");
const Systemd = @import("systemd.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    identity: *Identity,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, identity: *Identity) Server {
        return Server{ .allocator = allocator, .identity = identity };
    }

    pub fn start(self: *Server) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn acceptLoop(self: *Server) void {
        const address = std.net.Address.parseIp4("0.0.0.0", 7777) catch return;
        var server = address.listen(.{ .reuse_address = true }) catch return;
        defer server.deinit();

        std.debug.print("[+] Transport listening on 0.0.0.0:7777\n", .{});

        while (self.running.load(.seq_cst)) {
            const conn = server.accept() catch continue;
            defer conn.stream.close();

            std.debug.print("[*] Incoming connection...\n", .{});

            // 1. Handshake
            Protocol.performServer(conn.stream, self.allocator) catch |err| {
                std.debug.print("[x] Handshake rejected: {}\n", .{err});
                continue;
            };

            // 2. Command Loop
            while (true) {
                const packet = Wire.receive(conn.stream, self.allocator) catch |err| {
                    if (err != error.EndOfStream) std.debug.print("[!] Conn Error: {}\n", .{err});
                    break;
                };
                defer self.allocator.free(packet.payload);

                switch (packet.type) {
                    .ListServices => self.handleList(conn.stream) catch |e| std.debug.print("[!] List failed: {}\n", .{e}),
                    .DeployService => self.handleDeploy(conn.stream, packet.payload) catch |e| std.debug.print("[!] Deploy failed: {}\n", .{e}),
                    else => {}, // Ignore ServiceList messages sent to server
                }
            }
        }
    }

    // Helper: Handle ListServices command
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

    // Helper: Handle DeployService command
    fn handleDeploy(self: *Server, stream: std.net.Stream, payload: []const u8) !void {
        std.debug.print("[*] Receiving deployment...\n", .{});

        // 1. Parse JSON
        const parsed = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const svc = parsed.value;

        // 2. Persist to Disk
        const filename = try std.fmt.allocPrint(self.allocator, "services/{s}.json", .{svc.name});
        defer self.allocator.free(filename);

        {
            // FIX: Use std.fmt with std.json.fmt to serialize to a string first.
            // This bypasses the 'stringify' Writer interface issues.
            const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(svc, .{ .whitespace = .indent_4 })});
            defer self.allocator.free(json_str);

            const file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();

            // Use raw POSIX write to ensure data hits disk
            _ = try std.posix.write(file.handle, json_str);
        }

        // 3. Apply Configuration
        std.debug.print("[*] Building {s}...\n", .{svc.name});
        var new_nix = Nix.Nix.init(self.allocator);
        const store_path = try new_nix.build(svc.package);
        defer self.allocator.free(store_path);

        std.debug.print("[*] Starting {s}...\n", .{svc.name});
        try Systemd.apply(self.allocator, svc, store_path);

        std.debug.print("[+] Deployed {s} successfully!\n", .{svc.name});

        // Ack
        try Wire.send(stream, self.allocator, .ServiceList, &[_][]const u8{"OK"});
    }
};
