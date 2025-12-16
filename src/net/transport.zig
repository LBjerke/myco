// TCP transport for real deployments: handles handshake, gossip, deploy, and file streaming.
const std = @import("std");
const Identity = @import("identity.zig").Identity;
const Protocol = @import("protocol.zig").Handshake;
const Wire = @import("protocol.zig").Wire;
const Config = @import("../core/config.zig");
const Orchestrator = @import("../core/orchestrator.zig").Orchestrator;
const UX = @import("../util/ux.zig").UX; // <--- Import UX
const GossipEngine = @import("gossip.zig").GossipEngine;
const GossipSummary = @import("gossip.zig").ServiceSummary;

/// Transport server that accepts peer connections and proxies to orchestrator/UX.
pub const Server = struct {
    allocator: std.mem.Allocator,
    identity: *Identity,
    orchestrator: *Orchestrator,
    ux: *UX, // <--- New Dependency
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Update Init
    /// Create a server bound to identity, orchestrator, and UX logger.
    pub fn init(allocator: std.mem.Allocator, identity: *Identity, orchestrator: *Orchestrator, ux: *UX) Server {
        return Server{ .allocator = allocator, .identity = identity, .orchestrator = orchestrator, .ux = ux };
    }

    /// Spawn the accept loop on a background thread.
    pub fn start(self: *Server) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Process gossip payloads and request missing configs from the peer.
    fn handleGossip(self: *Server, stream: std.net.Stream, payload: []const u8) !void {
        // ... (Parse and Compare logic remains the same) ...
        const parsed = try std.json.parseFromSlice([]GossipSummary, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        
        var engine = GossipEngine.init(self.allocator);
        const needed = try engine.compare(parsed.value);
        defer {
            for (needed) |n| self.allocator.free(n);
            self.allocator.free(needed);
        }

        if (needed.len > 0) {
            self.ux.log("Gossip: Found {d} updates needed from peer.", .{needed.len});
            
            for (needed) |name| {
                self.ux.log("Gossip: Requesting sync for {s}...", .{name});
                try Wire.send(stream, self.allocator, .FetchService, name);
                
                // Wait for Config Response
                const packet = try Wire.receive(stream, self.allocator);
                defer self.allocator.free(packet.payload);
                
                if (packet.type == .ServiceConfig) {
                    const cfg_parsed = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, packet.payload, .{});
                    defer cfg_parsed.deinit();
                    
                    try Config.ConfigLoader.save(self.allocator, cfg_parsed.value);
                    self.ux.log("Gossip: Synced {s} v{d}", .{cfg_parsed.value.name, cfg_parsed.value.version});
                    
                    // Trigger Orchestrator
                    self.orchestrator.reconcile(cfg_parsed.value) catch {};
                }
            }
        }

        // FIX: Tell the client we are finished processing the gossip
        try Wire.send(stream, self.allocator, .GossipDone, &[_][]const u8{"BYE"});
    }
    /// Accept connections and dispatch protocol handlers until shutdown.
    fn acceptLoop(self: *Server) void {
                const port_env = std.posix.getenv("MYCO_PORT");
        const port = if (port_env) |p| std.fmt.parseInt(u16, p, 10) catch 7777 else 7777;

        const address = std.net.Address.parseIp4("0.0.0.0", port) catch return;
        var server = address.listen(.{ .reuse_address = true }) catch return;
        defer server.deinit();

        self.ux.log("Transport listening on 0.0.0.0:{d}", .{port});

        while (self.running.load(.seq_cst)) {
            const conn = server.accept() catch continue;
            defer conn.stream.close();

            // REPLACED std.debug.print with self.ux.log
            self.ux.log("Incoming connection from {f}", .{conn.address});

            Protocol.performServer(conn.stream, self.allocator) catch |err| {
                if (err != error.HealthCheckProbe) {
                    self.ux.log("Handshake rejected: {any}", .{err});
                }
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
                    // NEW: Handle Fetch Request
                    .FetchService => self.handleFetch(conn.stream, packet.payload) catch |e| self.ux.log("Fetch failed: {any}", .{e}),
                    .UploadStart => self.handleUpload(conn.stream, packet.payload) catch |e| self.ux.log("Upload failed: {any}", .{e}),
                    .Gossip => self.handleGossip(conn.stream, packet.payload) catch |e| self.ux.log("Gossip failed: {any}", .{e}),

                    else => {},
                }
            }
        }
    }

       // Define Payload Struct
    const UploadHeader = struct {
        filename: []const u8,
        size: u64,
    };

    /// Receive and persist an uploaded snapshot file.
    fn handleUpload(self: *Server, stream: std.net.Stream, payload: []const u8) !void {
        // 1. Parse Metadata
        const parsed = try std.json.parseFromSlice(UploadHeader, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const header = parsed.value;

        self.ux.log("Receiving snapshot: {s} ({d} bytes)", .{header.filename, header.size});

        // 2. Prepare Destination (Atomic Write)
        const backup_dir = "/var/lib/myco/backups";
        std.fs.makeDirAbsolute(backup_dir) catch {};
        
        const safe_name = std.fs.path.basename(header.filename);
        
        // FIX: Write to a .part file first to avoid clobbering the source 
        // if running on localhost, and to avoid corruption.
        const final_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{backup_dir, safe_name});
        defer self.allocator.free(final_path);

        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.part", .{backup_dir, safe_name});
        defer self.allocator.free(temp_path);

        {
            const file = try std.fs.createFileAbsolute(temp_path, .{});
            defer file.close();

            // 3. Stream Data
            try Wire.streamReceive(stream, file, header.size);
        } // Close file before renaming

        // 4. Rename to final path
        try std.fs.renameAbsolute(temp_path, final_path);

        self.ux.log("Snapshot received successfully.", .{});
        
        try Wire.send(stream, self.allocator, .ServiceList, &[_][]const u8{"OK"});
    }

    /// Serve a service config requested via gossip.
    fn handleFetch(self: *Server, stream: std.net.Stream, payload: []const u8) !void {
        // Wrap logic in a block to catch errors and send NACK
        fetch_logic: {
            const parsed_name = std.json.parseFromSlice([]const u8, self.allocator, payload, .{}) catch break :fetch_logic;
            defer parsed_name.deinit();
            const name = parsed_name.value;

            self.ux.log("Peer requested config for: {s}", .{name});

            const filename = std.fmt.allocPrint(self.allocator, "services/{s}.json", .{name}) catch break :fetch_logic;
            defer self.allocator.free(filename);

            const file = std.fs.cwd().openFile(filename, .{}) catch {
                self.ux.log("File not found: {s}", .{filename});
                // Send specific error message
                try Wire.send(stream, self.allocator, .Error, "Service config not found");
                return;
            };
            defer file.close();

            var sys_buf: [4096]u8 = undefined;
            var reader = file.reader(&sys_buf);
            const content = reader.file.readToEndAlloc(self.allocator, 1024 * 1024) catch break :fetch_logic;
            defer self.allocator.free(content);

            const parsed_cfg = std.json.parseFromSlice(Config.ServiceConfig, self.allocator, content, .{}) catch break :fetch_logic;
            defer parsed_cfg.deinit();

            // Success
            try Wire.send(stream, self.allocator, .ServiceConfig, parsed_cfg.value);
            return;
        }

        // Generic Error Fallback
        self.ux.log("Fetch processing failed", .{});
        try Wire.send(stream, self.allocator, .Error, "Internal Server Error during Fetch");
    }
    /// List all known service names.
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

    /// Accept a new service config and trigger reconciliation.
    fn handleDeploy(self: *Server, stream: std.net.Stream, payload: []const u8) !void {
        self.ux.log("Receiving deployment...", .{});

        const parsed = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const svc = parsed.value;

        const filename = try std.fmt.allocPrint(self.allocator, "services/{s}.json", .{svc.name});
        defer self.allocator.free(filename);

        {
            const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(svc, .{ .whitespace = .indent_4 })});
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
