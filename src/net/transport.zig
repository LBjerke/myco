// TCP transport for real deployments: handshake, gossip, deploy, and artifact streaming.
const std = @import("std");
const myco = @import("myco");
const Identity = myco.net.handshake.Identity;
const Protocol = @import("protocol.zig");
const Wire = Protocol.Wire;
const Handshake = Protocol.Handshake;
pub const HandshakeOptions = Protocol.HandshakeOptions;
const SecurityMode = Protocol.SecurityMode;
const MessageType = Protocol.MessageType;
const Packet = Protocol.Packet;
const CryptoWire = @import("crypto_wire.zig");
const Config = myco.core.config;
const Orchestrator = myco.core.orchestrator.Orchestrator;
const UX = myco.util.ux.UX;
const Node = myco.Node;
const Service = myco.schema.service.Service;
const GossipEngine = myco.net.gossip.GossipEngine;
const GossipSummary = myco.net.gossip.ServiceSummary;

pub fn handshakeOptionsFromEnv() HandshakeOptions {
    const force_plain = std.posix.getenv("MYCO_TRANSPORT_PLAINTEXT") != null;
    const allow_plain = force_plain or (std.posix.getenv("MYCO_TRANSPORT_ALLOW_PLAINTEXT") != null);
    return .{
        .allow_plaintext = allow_plain,
        .force_plaintext = force_plain,
    };
}

const Session = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    mode: SecurityMode,
    key: CryptoWire.Key,
    mac_failures: *std.atomic.Value(u64),

    fn send(self: *const Session, msg_type: MessageType, data: anytype) !void {
        switch (self.mode) {
            .aes_gcm => try Wire.sendEncrypted(self.stream, self.allocator, self.key, msg_type, data),
            .plaintext => try Wire.send(self.stream, self.allocator, msg_type, data),
        }
    }

    fn receive(self: *const Session) !Packet {
        if (self.mode == .aes_gcm) {
            return Wire.receiveEncrypted(self.stream, self.allocator, self.key) catch |err| {
                if (err == error.AuthenticationFailed) {
                    _ = self.mac_failures.fetchAdd(1, .seq_cst);
                }
                return err;
            };
        }
        return Wire.receive(self.stream, self.allocator);
    }
};

/// Transport server that accepts peer connections and proxies to orchestrator/UX.
pub const Server = struct {
    allocator: std.mem.Allocator,
    identity: *Identity,
    node: *Node,
    orchestrator: *Orchestrator,
    ux: *UX, // <--- New Dependency
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mac_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Update Init
    /// Create a server bound to identity, orchestrator, and UX logger.
    pub fn init(allocator: std.mem.Allocator, identity: *Identity, node: *Node, orchestrator: *Orchestrator, ux: *UX) Server {
        return Server{ .allocator = allocator, .identity = identity, .node = node, .orchestrator = orchestrator, .ux = ux };
    }

    /// Spawn the accept loop on a background thread.
    pub fn start(self: *Server) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn handshakeOptions(self: *Server) HandshakeOptions {
        _ = self;
        return handshakeOptionsFromEnv();
    }

    /// Process gossip payloads and request missing configs from the peer.
    fn handleGossip(self: *Server, session: *Session, payload: []const u8) !void {
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
                try session.send(.FetchService, name);

                // Wait for Config Response
                const packet = try session.receive();
                defer self.allocator.free(packet.payload);

                if (packet.type == .ServiceConfig) {
                    const cfg_parsed = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, packet.payload, .{});
                    defer cfg_parsed.deinit();

                    try Config.ConfigLoader.save(self.allocator, cfg_parsed.value);
                    self.ux.log("Gossip: Synced {s} v{d}", .{ cfg_parsed.value.name, cfg_parsed.value.version });

                    // Apply to node state so metrics reflect replicated services.
                    var svc = Service{
                        .id = if (cfg_parsed.value.id != 0) cfg_parsed.value.id else cfg_parsed.value.version,
                        .name = undefined,
                        .flake_uri = undefined,
                        .exec_name = [_]u8{0} ** 32,
                    };
                    svc.setName(cfg_parsed.value.name);
                    const flake = if (cfg_parsed.value.flake_uri.len > 0) cfg_parsed.value.flake_uri else cfg_parsed.value.package;
                    svc.setFlake(flake);
                    const exec_src = cfg_parsed.value.exec_name;
                    const exec_len = @min(exec_src.len, svc.exec_name.len);
                    @memcpy(svc.exec_name[0..exec_len], exec_src[0..exec_len]);

                    _ = self.node.injectService(svc) catch {};

                    // Trigger Orchestrator
                    self.orchestrator.reconcile(cfg_parsed.value) catch {};
                }
            }
        }

        // FIX: Tell the client we are finished processing the gossip
        try session.send(.GossipDone, &[_][]const u8{"BYE"});
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

            const handshake = Handshake.performServer(conn.stream, self.allocator, self.identity, self.handshakeOptions()) catch |err| {
                if (err != error.HealthCheckProbe) {
                    self.ux.log("Handshake rejected: {any}", .{err});
                }
                continue;
            };

            var session = Session{
                .stream = conn.stream,
                .allocator = self.allocator,
                .mode = handshake.mode,
                .key = handshake.shared_key,
                .mac_failures = &self.mac_failures,
            };

            while (true) {
                const packet = session.receive() catch |err| {
                    if (err == error.AuthenticationFailed) {
                        self.ux.log("MAC check failed; dropping packet", .{});
                        continue;
                    }
                    if (err != error.EndOfStream) self.ux.log("Connection Error: {any}", .{err});
                    break;
                };
                defer self.allocator.free(packet.payload);

                switch (packet.type) {
                    .ListServices => self.handleList(&session) catch |e| self.ux.log("List failed: {any}", .{e}),
                    .DeployService => self.handleDeploy(&session, packet.payload) catch |e| self.ux.log("Deploy failed: {any}", .{e}),
                    // NEW: Handle Fetch Request
                    .FetchService => self.handleFetch(&session, packet.payload) catch |e| self.ux.log("Fetch failed: {any}", .{e}),
                    .UploadStart => self.handleUpload(&session, packet.payload) catch |e| self.ux.log("Upload failed: {any}", .{e}),
                    .Gossip => self.handleGossip(&session, packet.payload) catch |e| self.ux.log("Gossip failed: {any}", .{e}),

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
    fn handleUpload(self: *Server, session: *Session, payload: []const u8) !void {
        // 1. Parse Metadata
        const parsed = try std.json.parseFromSlice(UploadHeader, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const header = parsed.value;

        self.ux.log("Receiving snapshot: {s} ({d} bytes)", .{ header.filename, header.size });

        // 2. Prepare Destination (Atomic Write)
        const backup_dir = "/var/lib/myco/backups";
        std.fs.makeDirAbsolute(backup_dir) catch {};

        const safe_name = std.fs.path.basename(header.filename);

        // FIX: Write to a .part file first to avoid clobbering the source
        // if running on localhost, and to avoid corruption.
        const final_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ backup_dir, safe_name });
        defer self.allocator.free(final_path);

        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.part", .{ backup_dir, safe_name });
        defer self.allocator.free(temp_path);

        {
            const file = try std.fs.createFileAbsolute(temp_path, .{});
            defer file.close();

            // 3. Stream Data
            try Wire.streamReceive(session.stream, file, header.size);
        } // Close file before renaming

        // 4. Rename to final path
        try std.fs.renameAbsolute(temp_path, final_path);

        self.ux.log("Snapshot received successfully.", .{});

        try session.send(.ServiceList, &[_][]const u8{"OK"});
    }

    /// Serve a service config requested via gossip.
    fn handleFetch(self: *Server, session: *Session, payload: []const u8) !void {
        // Wrap logic in a block to catch errors and send NACK
        fetch_logic: {
            const parsed_name = std.json.parseFromSlice([]const u8, self.allocator, payload, .{}) catch break :fetch_logic;
            defer parsed_name.deinit();
            const name = parsed_name.value;

            self.ux.log("Peer requested config for: {s}", .{name});

            const config_path = Config.serviceConfigPath(self.allocator, name) catch break :fetch_logic;
            defer self.allocator.free(config_path);

            const file = std.fs.openFileAbsolute(config_path, .{}) catch {
                self.ux.log("File not found: {s}", .{config_path});
                // Send specific error message
                try session.send(.Error, "Service config not found");
                return;
            };
            defer file.close();

            var sys_buf: [4096]u8 = undefined;
            var reader = file.reader(&sys_buf);
            const content = reader.file.readToEndAlloc(self.allocator, 1024 * 1024) catch break :fetch_logic;
            defer self.allocator.free(content);

            const parsed_cfg = std.json.parseFromSlice(Config.ServiceConfig, self.allocator, content, .{ .ignore_unknown_fields = true }) catch break :fetch_logic;
            defer parsed_cfg.deinit();

            // Success
            try session.send(.ServiceConfig, parsed_cfg.value);
            return;
        }

        // Generic Error Fallback
        self.ux.log("Fetch processing failed", .{});
        try session.send(.Error, "Internal Server Error during Fetch");
    }
    /// List all known service names.
    fn handleList(self: *Server, session: *Session) !void {
        var loader = Config.ConfigLoader.init(self.allocator);
        defer loader.deinit();
        const configs = loader.loadAll("services") catch &[_]Config.ServiceConfig{};

        var names = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer names.deinit(self.allocator);

        for (configs) |c| {
            try names.append(self.allocator, c.name);
        }

        try session.send(.ServiceList, names.items);
    }

    /// Accept a new service config and trigger reconciliation.
    fn handleDeploy(self: *Server, session: *Session, payload: []const u8) !void {
        self.ux.log("Receiving deployment...", .{});

        const parsed = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const svc = parsed.value;

        Config.ConfigLoader.save(self.allocator, svc) catch |err| {
            self.ux.log("Config save failed: {any}", .{err});
            return err;
        };

        self.ux.log("Handing off to Orchestrator...", .{});

        self.orchestrator.reconcile(svc) catch |err| {
            self.ux.log("Orchestration failed: {any}", .{err});
            return err;
        };

        self.ux.log("Deployed {s} successfully!", .{svc.name});

        try session.send(.ServiceList, &[_][]const u8{"OK"});
    }
};

/// Simple TCP client wrapper using the same handshake/key plumbing as the server.
pub const Client = struct {
    allocator: std.mem.Allocator,
    identity: *Identity,
    stream: std.net.Stream,
    session: Session,
    mac_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn connectHost(allocator: std.mem.Allocator, identity: *Identity, host: []const u8, port: u16) !Client {
        const addr = try std.net.Address.parseIp4(host, port);
        return connectAddress(allocator, identity, addr, handshakeOptionsFromEnv());
    }

    pub fn connectAddress(allocator: std.mem.Allocator, identity: *Identity, address: std.net.Address, opts: HandshakeOptions) !Client {
        var stream = try std.net.tcpConnectToAddress(address);
        errdefer stream.close();

        const hs = try Handshake.performClient(stream, allocator, identity, opts);

        var client = Client{
            .allocator = allocator,
            .identity = identity,
            .stream = stream,
            .session = Session{
                .stream = stream,
                .allocator = allocator,
                .mode = hs.mode,
                .key = hs.shared_key,
                .mac_failures = undefined,
            },
        };
        client.session.mac_failures = &client.mac_failures;
        return client;
    }

    pub fn send(self: *Client, msg_type: MessageType, data: anytype) !void {
        try self.session.send(msg_type, data);
    }

    pub fn receive(self: *Client) !Packet {
        return self.session.receive();
    }

    pub fn close(self: *Client) void {
        self.stream.close();
    }
};
