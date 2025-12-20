// TCP transport for real deployments: handshake, gossip, deploy, and artifact streaming.
const std = @import("std");
const Identity = @import("handshake.zig").Identity;
const Protocol = @import("protocol.zig");
const Wire = Protocol.Wire;
const Handshake = Protocol.Handshake;
pub const HandshakeOptions = Protocol.HandshakeOptions;
const SecurityMode = Protocol.SecurityMode;
const MessageType = Protocol.MessageType;
const Packet = Protocol.Packet;
const CryptoWire = @import("crypto_wire.zig");
const Service = @import("../schema/service.zig").Service;
const Node = @import("../node.zig").Node;
const Wyhash = std.hash.Wyhash;
const Config = @import("../core/config.zig");
const Orchestrator = @import("../core/orchestrator.zig").Orchestrator;
const UX = @import("../util/ux.zig").UX;
const GossipEngine = @import("gossip.zig").GossipEngine;
const GossipSummary = @import("gossip.zig").ServiceSummary;

pub fn handshakeOptionsFromEnv() HandshakeOptions {
    const force_plain = std.posix.getenv("MYCO_TRANSPORT_PLAINTEXT") != null;
    const allow_plain = force_plain or (std.posix.getenv("MYCO_TRANSPORT_ALLOW_PLAINTEXT") != null);
    const psk = std.posix.getenv("MYCO_TRANSPORT_PSK");
    return .{
        .allow_plaintext = allow_plain,
        .force_plaintext = force_plain,
        .psk = psk,
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

                    // Hydrate CRDT state so metrics reflect replicated services.
                    var svc = Service{
                        .id = if (cfg_parsed.value.id != 0) cfg_parsed.value.id else Wyhash.hash(0, cfg_parsed.value.name),
                        .name = undefined,
                        .flake_uri = undefined,
                        .exec_name = undefined,
                    };
                    svc.setName(cfg_parsed.value.name);
                    svc.setFlake(cfg_parsed.value.package);
                    if (cfg_parsed.value.cmd) |cmd| {
                        @memset(&svc.exec_name, 0);
                        const copy_len = @min(cmd.len, svc.exec_name.len);
                        @memcpy(svc.exec_name[0..copy_len], cmd[0..copy_len]);
                    } else {
                        @memset(&svc.exec_name, 0);
                    }
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
        var path_buf: [256]u8 = undefined;
        const final_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ backup_dir, safe_name });

        var temp_buf: [256]u8 = undefined;
        const temp_path = try std.fmt.bufPrint(&temp_buf, "{s}/{s}.part", .{ backup_dir, safe_name });

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

            var name_buf: [128]u8 = undefined;
            const filename = std.fmt.bufPrint(&name_buf, "services/{s}.json", .{name}) catch break :fetch_logic;

            const file = std.fs.cwd().openFile(filename, .{}) catch {
                self.ux.log("File not found: {s}", .{filename});
                // Send specific error message
                try session.send(.Error, "Service config not found");
                return;
            };
            defer file.close();

            var sys_buf: [4096]u8 = undefined;
            var reader = file.reader(&sys_buf);
            var content_buf: [1024 * 4]u8 = undefined;
            const read_len = reader.file.read(&content_buf) catch break :fetch_logic;
            const content = content_buf[0..read_len];

            const parsed_cfg = std.json.parseFromSlice(Config.ServiceConfig, self.allocator, content, .{}) catch break :fetch_logic;
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

        var names_buf: [Config.ConfigLoader.max_services][]const u8 = undefined;
        var names_len: usize = 0;

        for (configs) |c| {
            if (names_len == names_buf.len) break;
            names_buf[names_len] = c.name;
            names_len += 1;
        }

        try session.send(.ServiceList, names_buf[0..names_len]);
    }

    /// Accept a new service config and trigger reconciliation.
    fn handleDeploy(self: *Server, session: *Session, payload: []const u8) !void {
        self.ux.log("Receiving deployment...", .{});

        const parsed = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const svc = parsed.value;

        var path_buf: [128]u8 = undefined;
        const filename = try std.fmt.bufPrint(&path_buf, "services/{s}.json", .{svc.name});

        {
            var json_buf: [4096]u8 = undefined;
            const json_str = try std.fmt.bufPrint(&json_buf, "{f}", .{std.json.fmt(svc, .{ .whitespace = .indent_4 })});
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
