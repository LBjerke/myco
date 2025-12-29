const std = @import("std");
const myco = @import("myco");
const Identity = myco.net.handshake.Identity;
const Protocol = @import("protocol.zig");
const Wire = Protocol.Wire;
const Handshake = Protocol.Handshake;
pub const HandshakeOptions = Protocol.HandshakeOptions;
const SecurityMode = Protocol.SecurityMode;
const MessageType = Protocol.MessageType;

// Import Packet from fixed struct
const Packet = @import("../packet.zig").Packet;
const Headers = @import("../packet.zig").Headers;
const CryptoWire = @import("crypto_wire.zig");
const Config = myco.core.config;
const Orchestrator = myco.core.orchestrator.Orchestrator;
const UX = myco.util.ux.UX;
const json_noalloc = myco.util.json_noalloc;
const Node = myco.Node;
const Service = myco.schema.service.Service;
const GossipEngine = myco.net.gossip.GossipEngine;
const GossipSummary = myco.net.gossip.ServiceSummary;
const noalloc_guard = myco.util.noalloc_guard;

const limits = @import("../core/limits.zig");
const ObjectPool = @import("../util/pool.zig").ObjectPool;

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
    mode: SecurityMode,
    key: CryptoWire.Key,
    mac_failures: *std.atomic.Value(u64),

    fn send(self: *const Session, msg_type: MessageType, data: anytype) !void {
        noalloc_guard.check();
        var packet = Packet{};
        packet.msg_type = @intFromEnum(msg_type);

        var writer = std.io.Writer.fixed(packet.payload[0..]);
        var serializer = std.json.Stringify{
            .writer = &writer,
            .options = .{},
        };

        try serializer.write(data);

        packet.payload_len = @intCast(std.io.Writer.buffered(&writer).len);

        if (self.mode == .plaintext) {
            try Wire.send(self.stream, &packet);
        } else {
            return error.EncryptionNotImplementedForZeroAlloc;
        }
    }

    fn receive(self: *const Session) !Packet {
        noalloc_guard.check();
        var packet = Packet{};
        if (self.mode == .plaintext) {
            try Wire.receive(self.stream, &packet);
        } else {
            return error.EncryptionNotImplementedForZeroAlloc;
        }
        return packet;
    }
};

pub const Server = struct {
    identity: *Identity,
    node: *Node,
    orchestrator: *Orchestrator,
    ux: *UX,
    state_dir: []const u8,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mac_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packet_pool: ObjectPool(Packet, limits.MAX_CONNECTIONS * 2),
    config_io: Config.ConfigIO,

    pub fn init(state_dir: []const u8, identity: *Identity, node: *Node, orchestrator: *Orchestrator, ux: *UX) Server {
        return Server{
            .identity = identity,
            .node = node,
            .orchestrator = orchestrator,
            .ux = ux,
            .state_dir = state_dir,
            .packet_pool = .{},
            .config_io = .{},
        };
    }

    pub fn start(self: *Server) !void {
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn handshakeOptions(self: *Server) HandshakeOptions {
        _ = self;
        return handshakeOptionsFromEnv();
    }

    fn handleGossip(self: *Server, session: *Session, payload: []const u8) !void {
        noalloc_guard.check();
        var engine = GossipEngine.init();
        const remote = engine.parseSummary(payload) catch {
            self.ux.log("Gossip: Invalid summary payload", .{});
            try session.send(.GossipDone, &[_][]const u8{"BYE"});
            return;
        };
        const needed = engine.compare(self.node, remote);

        if (needed.len > 0) {
            self.ux.log("Gossip: Found {d} updates needed from peer.", .{needed.len});

            for (needed) |name| {
                self.ux.log("Gossip: Requesting sync for {s}...", .{name});
                try session.send(.FetchService, name);

                const packet = try session.receive();
                if (packet.msg_type == @intFromEnum(MessageType.ServiceConfig)) {
                    const real_payload = packet.payload[0..packet.payload_len];

                    var scratch = Config.ConfigScratch{};
                    const cfg = Config.parseServiceConfigJson(real_payload, &scratch) catch {
                        self.ux.log("Gossip: Invalid service config", .{});
                        continue;
                    };

                    Config.saveNoAlloc(self.state_dir, cfg, &self.config_io) catch |err| {
                        self.ux.log("Config save failed: {any}", .{err});
                    };
                    self.ux.log("Gossip: Synced {s} v{d}", .{ cfg.name, cfg.version });

                    var svc = Service{
                        .id = if (cfg.id != 0) cfg.id else cfg.version,
                        .name = undefined,
                        .flake_uri = undefined,
                        .exec_name = [_]u8{0} ** 32,
                    };
                    svc.setName(cfg.name);
                    const flake = if (cfg.flake_uri.len > 0) cfg.flake_uri else cfg.package;
                    svc.setFlake(flake);
                    const exec_src = cfg.exec_name;
                    const exec_len = @min(exec_src.len, svc.exec_name.len);
                    @memcpy(svc.exec_name[0..exec_len], exec_src[0..exec_len]);

                    _ = self.node.injectService(svc) catch {};
                    self.orchestrator.reconcile(cfg) catch {};
                }
            }
        }
        try session.send(.GossipDone, &[_][]const u8{"BYE"});
    }

    fn acceptLoop(self: *Server) void {
        noalloc_guard.check();
        const port_env = std.posix.getenv("MYCO_PORT");
        const port = if (port_env) |p| std.fmt.parseInt(u16, p, 10) catch 7777 else 7777;

        const address = std.net.Address.parseIp4("0.0.0.0", port) catch return;
        var server = address.listen(.{ .reuse_address = true }) catch return;
        defer server.deinit();

        self.ux.log("Transport listening on 0.0.0.0:{d}", .{port});

        while (self.running.load(.seq_cst)) {
            const conn = server.accept() catch continue;
            defer conn.stream.close();

            self.ux.log("Incoming connection from {f}", .{conn.address});

            const handshake = Handshake.performServer(conn.stream, self.identity, self.handshakeOptions()) catch |err| {
                if (err != error.HealthCheckProbe) {
                    self.ux.log("Handshake rejected: {any}", .{err});
                }
                continue;
            };

            const packet_ptr = self.packet_pool.acquire() orelse {
                self.ux.log("Dropped connection: Pool Empty", .{});
                continue;
            };
            defer self.packet_pool.release(packet_ptr);

            var session = Session{
                .stream = conn.stream,
                .mode = handshake.mode,
                .key = handshake.shared_key,
                .mac_failures = &self.mac_failures,
            };

            while (true) {
                if (session.mode == .plaintext) {
                    Wire.receive(conn.stream, packet_ptr) catch |err| {
                        if (err != error.EndOfStream) self.ux.log("Conn error: {}", .{err});
                        break;
                    };
                } else {
                    break;
                }

                const payload = packet_ptr.payload[0..packet_ptr.payload_len];

                switch (@as(MessageType, @enumFromInt(packet_ptr.msg_type))) {
                    .ListServices => self.handleList(&session) catch |e| self.ux.log("List failed: {any}", .{e}),
                    .DeployService => self.handleDeploy(&session, payload) catch |e| self.ux.log("Deploy failed: {any}", .{e}),
                    .FetchService => self.handleFetch(&session, payload) catch |e| self.ux.log("Fetch failed: {any}", .{e}),
                    .UploadStart => self.handleUpload(&session, payload) catch |e| self.ux.log("Upload failed: {any}", .{e}),
                    .Gossip => self.handleGossip(&session, payload) catch |e| self.ux.log("Gossip failed: {any}", .{e}),
                    else => {},
                }
            }
        }
    }

    const UploadHeader = struct {
        filename: []const u8,
        size: u64,
    };

    fn handleUpload(self: *Server, session: *Session, payload: []const u8) !void {
        noalloc_guard.check();
        var idx: usize = 0;
        var name_buf: [limits.PATH_MAX]u8 = undefined;
        var header = UploadHeader{ .filename = "", .size = 0 };

        json_noalloc.expectChar(payload, &idx, '{') catch return error.InvalidUploadHeader;
        while (true) {
            json_noalloc.skipWhitespace(payload, &idx);
            if (idx >= payload.len) return error.InvalidUploadHeader;
            if (payload[idx] == '}') {
                idx += 1;
                break;
            }

            var key_buf: [16]u8 = undefined;
            const key = try json_noalloc.parseString(payload, &idx, key_buf[0..]);
            try json_noalloc.expectChar(payload, &idx, ':');

            if (std.mem.eql(u8, key, "filename")) {
                header.filename = try json_noalloc.parseString(payload, &idx, name_buf[0..]);
            } else if (std.mem.eql(u8, key, "size")) {
                header.size = try json_noalloc.parseU64(payload, &idx);
            } else {
                try json_noalloc.skipValue(payload, &idx);
            }

            json_noalloc.skipWhitespace(payload, &idx);
            if (idx >= payload.len) return error.InvalidUploadHeader;
            if (payload[idx] == ',') {
                idx += 1;
                continue;
            }
            if (payload[idx] == '}') {
                idx += 1;
                break;
            }
            return error.InvalidUploadHeader;
        }

        if (header.filename.len == 0) return error.InvalidUploadHeader;

        self.ux.log("Receiving snapshot: {s} ({d} bytes)", .{ header.filename, header.size });

        const backup_dir = "/var/lib/myco/backups";
        std.fs.makeDirAbsolute(backup_dir) catch {};
        const safe_name = std.fs.path.basename(header.filename);

        var final_buf: [limits.PATH_MAX]u8 = undefined;
        const final_path = try std.fmt.bufPrint(&final_buf, "{s}/{s}", .{ backup_dir, safe_name });

        var temp_buf: [limits.PATH_MAX]u8 = undefined;
        const temp_path = try std.fmt.bufPrint(&temp_buf, "{s}/{s}.part", .{ backup_dir, safe_name });

        {
            const file = try std.fs.createFileAbsolute(temp_path, .{});
            defer file.close();
            try Wire.streamReceive(session.stream, file, header.size);
        }

        try std.fs.renameAbsolute(temp_path, final_path);
        self.ux.log("Snapshot received successfully.", .{});
        try session.send(.ServiceList, &[_][]const u8{"OK"});
    }

    fn handleFetch(self: *Server, session: *Session, payload: []const u8) !void {
        noalloc_guard.check();
        var idx: usize = 0;
        var name_buf: [limits.MAX_SERVICE_NAME]u8 = undefined;
        const name = json_noalloc.parseString(payload, &idx, name_buf[0..]) catch {
            self.ux.log("Fetch processing failed", .{});
            try session.send(.Error, "Invalid service request");
            return;
        };
        json_noalloc.skipWhitespace(payload, &idx);
        if (idx != payload.len) {
            self.ux.log("Fetch processing failed", .{});
            try session.send(.Error, "Invalid service request");
            return;
        }

        self.ux.log("Peer requested config for: {s}", .{name});

        const svc = self.node.getServiceByName(name) orelse {
            self.ux.log("Service not found: {s}", .{name});
            try session.send(.Error, "Service config not found");
            return;
        };

        const cfg = Config.fromService(svc, self.node.getVersion(svc.id));
        try session.send(.ServiceConfig, cfg);
    }

    fn handleList(self: *Server, session: *Session) !void {
        noalloc_guard.check();
        var engine = GossipEngine.init();
        const summary = engine.generateSummary(self.node);
        try session.send(.ServiceList, summary);
    }

    fn handleDeploy(self: *Server, session: *Session, payload: []const u8) !void {
        noalloc_guard.check();
        self.ux.log("Receiving deployment...", .{});

        var scratch = Config.ConfigScratch{};
        const svc = Config.parseServiceConfigJson(payload, &scratch) catch |err| {
            self.ux.log("Deploy parse failed: {any}", .{err});
            return err;
        };

        Config.saveNoAlloc(self.state_dir, svc, &self.config_io) catch |err| {
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

pub const Client = struct {
    identity: *Identity,
    stream: std.net.Stream,
    session: Session,
    mac_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn connectHost(identity: *Identity, host: []const u8, port: u16) !Client {
        const addr = try std.net.Address.parseIp4(host, port);
        return connectAddress(identity, addr, handshakeOptionsFromEnv());
    }

    pub fn connectAddress(identity: *Identity, address: std.net.Address, opts: HandshakeOptions) !Client {
        noalloc_guard.check();
        var stream = try std.net.tcpConnectToAddress(address);
        errdefer stream.close();

        const hs = try Handshake.performClient(stream, identity, opts);

        var client = Client{
            .identity = identity,
            .stream = stream,
            .session = Session{
                .stream = stream,
                .mode = hs.mode,
                .key = hs.shared_key,
                .mac_failures = undefined,
            },
        };
        client.session.mac_failures = &client.mac_failures;
        return client;
    }

    pub fn send(self: *Client, msg_type: MessageType, data: anytype) !void {
        noalloc_guard.check();
        try self.session.send(msg_type, data);
    }

    pub fn receive(self: *Client) !Packet {
        noalloc_guard.check();
        return self.session.receive();
    }

    pub fn close(self: *Client) void {
        self.stream.close();
    }
};
