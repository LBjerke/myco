// CLI entry point for Myco: handles init, daemon lifecycle, deployment, and metrics.
const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const Limits = myco.limits;
const Scaffolder = myco.cli.init.Scaffolder;
const Packet = myco.Packet;
const ApiServer = myco.api.server.ApiServer;
const PeerManager = myco.p2p.peers.PeerManager;
const OutboundPacket = myco.OutboundPacket;
const Service = myco.schema.service.Service;
const PacketCrypto = myco.crypto.packet_crypto;
const TransportServer = myco.net.transport.Server;
const TransportClient = myco.net.transport.Client;
const HandshakeOptions = myco.net.transport.HandshakeOptions;
const MessageType = myco.net.protocol.MessageType;
const GossipEngine = myco.net.gossip.GossipEngine;
const ServiceSummary = myco.net.gossip.ServiceSummary;
const Config = myco.core.config;
const ServiceConfig = Config.ServiceConfig;
const UX = myco.util.ux.UX;
const Orchestrator = myco.core.orchestrator.Orchestrator;

const SystemdCompiler = myco.engine.systemd;
const NixBuilder = myco.engine.nix.NixBuilder;

// Context to hold dependencies for the executor callback.
const DaemonContext = struct {
    allocator: std.mem.Allocator,
    nix_builder: NixBuilder,
};

/// Executor invoked on service deploys: builds via Nix and (re)starts a systemd unit.
fn realExecutor(ctx_ptr: *anyopaque, service: Service) anyerror!void {
    const ctx: *DaemonContext = @ptrCast(@alignCast(ctx_ptr));
    const allocator = ctx.allocator;

    std.debug.print("⚙️ [Executor] Deploying Service: {s} (ID: {d})\n", .{ service.getName(), service.id });

    // 1. Prepare Paths
    const bin_dir = try std.fmt.allocPrint(allocator, "/var/lib/myco/bin/{d}", .{service.id});
    defer allocator.free(bin_dir);

    // Recursive makePath to ensure parent dirs exist
    std.fs.cwd().makePath(bin_dir) catch {};

    // 2. Nix Build
    const out_link = try std.fmt.allocPrint(allocator, "{s}/result", .{bin_dir});
    defer allocator.free(out_link);

    // Build the flake (using the NixBuilder wrapper)
    // false = real execution (not dry run)
    _ = try ctx.nix_builder.build(service.getFlake(), out_link, false);

    // 3. Systemd Unit Generation
    var unit_buf: [2048]u8 = undefined;
    const unit_content = try SystemdCompiler.compile(service, &unit_buf);

    // Use /run/systemd/system for ephemeral units on NixOS
    const unit_path = try std.fmt.allocPrint(allocator, "/run/systemd/system/myco-{d}.service", .{service.id});
    defer allocator.free(unit_path);

    // Write Unit File
    {
        const file = try std.fs.cwd().createFile(unit_path, .{});
        defer file.close();
        try file.writeAll(unit_content);
    }

    // 4. Reload and Start
    const cmd = [_][]const u8{ "systemctl", "daemon-reload" };
    var child = std.process.Child.init(&cmd, allocator);
    _ = try child.spawnAndWait();

    const service_name = try std.fmt.allocPrint(allocator, "myco-{d}", .{service.id});
    defer allocator.free(service_name);

    const start_cmd = [_][]const u8{ "systemctl", "restart", service_name };
    var start_child = std.process.Child.init(&start_cmd, allocator);
    _ = try start_child.spawnAndWait();

    std.debug.print("✅ [Executor] Service {s} is LIVE.\n", .{service.getName()});
}

var global_memory: [Limits.GLOBAL_MEMORY_SIZE]u8 = undefined;
/// CLI dispatcher for Myco commands.
pub fn main() !void {

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.deinit();
    //const allocator = gpa.allocator();
    var fba = std.heap.FixedBufferAllocator.init(&global_memory);
    const allocator = fba.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }
    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        const cwd = std.fs.cwd();
        const scaffolder = Scaffolder.init(cwd);
        try scaffolder.generate();
        std.debug.print("✅ Initialized Myco project.\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "daemon")) {
        try runDaemon(allocator);
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        try queryDaemon("GET /metrics HTTP/1.0\r\n\r\n");
        return;
    }
    if (std.mem.eql(u8, command, "pubkey")) {
        // Ensure identity exists and print public key hex for cluster wiring.
        var ident = try myco.net.identity.Identity.init(allocator);
        defer {
            // Nothing to deinit in Identity today.
        }
        const hex = try ident.getPublicKeyHex();
        defer allocator.free(hex);
        try std.fs.File.stdout().writeAll(hex);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, command, "peer")) {
        if (args.len < 5 or !std.mem.eql(u8, args[2], "add")) {
            std.debug.print("Usage: myco peer add <PUBKEY_HEX> <IP:PORT>\n", .{});
            return;
        }
        const key = args[3];
        const ip = args[4];
        const state_dir = std.posix.getenv("MYCO_STATE_DIR") orelse "/var/lib/myco";
        const peers_path = try std.fs.path.join(allocator, &[_][]const u8{ state_dir, "peers.list" });
        defer allocator.free(peers_path);
        var pm = PeerManager.init(allocator, peers_path);
        defer pm.deinit();
        pm.add(key, ip) catch |err| {
            std.debug.print("Failed to add peer: {}\n", .{err});
            return;
        };
        std.debug.print("✅ Peer added to peers.list\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "deploy")) {
        try myco.cli.deploy.run(allocator);
        return;
    }

    printUsage();
}

/// Print CLI usage to stderr.
fn printUsage() void {
    std.debug.print(
        \\Usage: myco [command]
        \\
        \\Commands:
        \\  init      Generate flake.nix
        \\  daemon    Start the node
        \\  deploy    Deploy current directory
        \\  status    Query metrics
        \\  peer add  Add neighbor
        \\
    , .{});
}

fn handshakeOptionsFromEnv() HandshakeOptions {
    const force_plain = std.posix.getenv("MYCO_TRANSPORT_PLAINTEXT") != null;
    const allow_plain = force_plain or (std.posix.getenv("MYCO_TRANSPORT_ALLOW_PLAINTEXT") != null);
    return .{
        .allow_plaintext = allow_plain,
        .force_plaintext = force_plain,
    };
}

fn serveFetchFromDisk(allocator: std.mem.Allocator, session: *TransportClient, payload: []const u8) !void {
    const parsed_name = std.json.parseFromSlice([]const u8, allocator, payload, .{}) catch {
        try session.send(.Error, "Invalid service request");
        return;
    };
    defer parsed_name.deinit();
    const name = parsed_name.value;

    const config_path = Config.serviceConfigPath(allocator, name) catch {
        try session.send(.Error, "Service config not found");
        return;
    };
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        try session.send(.Error, "Service config not found");
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed_cfg = std.json.parseFromSlice(ServiceConfig, allocator, content, .{ .ignore_unknown_fields = true }) catch {
        try session.send(.Error, "Invalid service config");
        return;
    };
    defer parsed_cfg.deinit();

    try session.send(.ServiceConfig, parsed_cfg.value);
}

fn syncWithPeer(allocator: std.mem.Allocator, node: *Node, orchestrator: *Orchestrator, identity: *myco.net.handshake.Identity, peer: myco.p2p.peers.Peer) void {
    const opts = handshakeOptionsFromEnv();
    std.debug.print("[sync] dialing peer {any}\n", .{peer.ip});
    var client = TransportClient.connectAddress(allocator, identity, peer.ip, opts) catch return;
    defer client.close();

    var engine = GossipEngine.init(allocator);
    const summary = engine.generateSummary() catch return;
    defer allocator.free(summary);

    client.send(.Gossip, summary) catch return;

    while (true) {
        const pkt = client.receive() catch break;
        const payload_len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);
        const payload = pkt.payload[0..payload_len];

        switch (@as(MessageType, @enumFromInt(pkt.msg_type))) {
            .FetchService => serveFetchFromDisk(allocator, &client, payload) catch {},
            .GossipDone => break,
            else => {},
        }
    }

    // Pull missing services from the peer (reverse direction).
    client.send(.ListServices, "") catch return;
    const list_pkt = client.receive() catch return;
    const list_payload_len: usize = @min(@as(usize, list_pkt.payload_len), list_pkt.payload.len);
    const list_payload = list_pkt.payload[0..list_payload_len];
    if (@as(MessageType, @enumFromInt(list_pkt.msg_type)) == .ServiceList) {
        const remote = std.json.parseFromSlice([]ServiceSummary, allocator, list_payload, .{ .ignore_unknown_fields = true }) catch return;
        defer remote.deinit();

        var engine_pull = GossipEngine.init(allocator);
        const needed = engine_pull.compare(remote.value) catch return;
        defer {
            for (needed) |n| allocator.free(n);
            allocator.free(needed);
        }

        for (needed) |name| {
            client.send(.FetchService, name) catch continue;
            const cfg_pkt = client.receive() catch continue;
            const cfg_payload_len: usize = @min(@as(usize, cfg_pkt.payload_len), cfg_pkt.payload.len);
            const cfg_payload = cfg_pkt.payload[0..cfg_payload_len];
            if (@as(MessageType, @enumFromInt(cfg_pkt.msg_type)) != .ServiceConfig) continue;

            const cfg = std.json.parseFromSlice(Config.ServiceConfig, allocator, cfg_payload, .{ .ignore_unknown_fields = true }) catch continue;
            defer cfg.deinit();

            Config.ConfigLoader.save(allocator, cfg.value) catch {};

            var svc = Service{
                .id = if (cfg.value.id != 0) cfg.value.id else cfg.value.version,
                .name = undefined,
                .flake_uri = undefined,
                .exec_name = [_]u8{0} ** 32,
            };
            svc.setName(cfg.value.name);
            const flake = if (cfg.value.flake_uri.len > 0) cfg.value.flake_uri else cfg.value.package;
            svc.setFlake(flake);
            const exec_src = cfg.value.exec_name;
            const exec_len = @min(exec_src.len, svc.exec_name.len);
            @memcpy(svc.exec_name[0..exec_len], exec_src[0..exec_len]);

            _ = node.injectService(svc) catch {};
            orchestrator.reconcile(cfg.value) catch {};
        }
    }
}

/// Start the UDP+Unix-socket daemon loop handling gossip and API requests.
/// Start the UDP+Unix-socket daemon loop handling gossip and API requests.
fn runDaemon(allocator: std.mem.Allocator) !void {
    const default_port: u16 = 7777;
    const port_env = std.posix.getenv("MYCO_PORT");
    const UDP_PORT = if (port_env) |p|
        std.fmt.parseUnsigned(u16, p, 10) catch default_port
    else
        default_port;
    const skip_udp = std.posix.getenv("MYCO_SKIP_UDP") != null;
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const UDS_PATH = if (uds_env) |v| v else "/tmp/myco.sock";
    const packet_force_plain = std.posix.getenv("MYCO_PACKET_PLAINTEXT") != null;
    const packet_allow_plain = packet_force_plain or (std.posix.getenv("MYCO_PACKET_ALLOW_PLAINTEXT") != null);

    // Atomic counter for metrics
    var packet_mac_failures = std.atomic.Value(u64).init(0);

    const state_dir = std.posix.getenv("MYCO_STATE_DIR") orelse "/var/lib/myco";
    const peers_path = try std.fs.path.join(allocator, &[_][]const u8{ state_dir, "peers.list" });
    defer allocator.free(peers_path);

    var peer_manager = PeerManager.init(allocator, peers_path);
    defer peer_manager.deinit();
    peer_manager.load() catch {};

    // WAL Buffer (Part of the Slab concept, typically passed in or alloc'd once)
    const wal_buf = try allocator.alloc(u8, 64 * 1024);
    @memset(wal_buf, 0);

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const node_id_env = std.posix.getenv("MYCO_NODE_ID");
    const node_id: u16 = if (node_id_env) |v|
        std.fmt.parseUnsigned(u16, v, 10) catch prng.random().int(u16)
    else
        prng.random().int(u16);

    // Initialize Execution Context
    var context = DaemonContext{
        .allocator = allocator,
        .nix_builder = NixBuilder.init(allocator),
    };

    // Initialize Node (Phase 3: ServiceStore.init takes no args now)
    var node = try Node.init(node_id, allocator, wal_buf, &context, realExecutor);
    node.hlc = .{ .wall = @as(u64, @intCast(std.time.milliTimestamp())), .logical = 0 };

    var api_server = ApiServer.init(allocator, &node, &packet_mac_failures);

    // Start TCP transport server
    var ux = UX.init(allocator);
    var orchestrator = Orchestrator.init(allocator, &ux);
    var transport_server = TransportServer.init(allocator, &node.identity, &node, &orchestrator, &ux);
    transport_server.start() catch |err| {
        std.debug.print("[ERR] transport start failed: {any}\n", .{err});
    };

    std.debug.print("🚀 Myco Daemon {d} running.\n   UDP: 0.0.0.0:{d}\n   API: {s}\n", .{ node.id, UDP_PORT, UDS_PATH });

    // UDP Setup
    var udp_sock: ?std.posix.socket_t = null;
    if (!skip_udp) {
        const udp_addr = try std.net.Address.resolveIp("0.0.0.0", UDP_PORT);
        udp_sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
            std.debug.print("[ERR] udp socket create failed: {any}\n", .{err});
            return err;
        };
        std.posix.bind(udp_sock.?, &udp_addr.any, udp_addr.getOsSockLen()) catch |err| {
            std.debug.print("[ERR] udp bind failed: {any}\n", .{err});
            return err;
        };
    }

    // UDS Setup
    if (std.fs.path.isAbsolute(UDS_PATH)) {
        std.fs.deleteFileAbsolute(UDS_PATH) catch {};
    } else {
        std.fs.cwd().deleteFile(UDS_PATH) catch {};
    }

    const uds_sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    var uds_addr = try std.net.Address.initUnix(UDS_PATH);
    try std.posix.bind(uds_sock, &uds_addr.any, uds_addr.getOsSockLen());
    try std.posix.listen(uds_sock, 10);
    _ = std.posix.fchmod(uds_sock, 0o666) catch {};

    // Poll Setup
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = uds_sock, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = 0, .revents = 0 },
    };
    var poll_len: usize = 1;
    const udp_index: ?usize = if (skip_udp) null else blk: {
        poll_fds[poll_len] = .{ .fd = udp_sock.?, .events = std.posix.POLL.IN, .revents = 0 };
        poll_len += 1;
        break :blk poll_len - 1;
    };
    const uds_index: usize = 0;

    // ✅ ZERO-ALLOC: Stack-allocated, aligned buffer for receiving Packets directly
    var udp_buf: [1024]u8 align(@alignOf(Packet)) = undefined;

    var sync_tick: u64 = 0;

    while (true) {
        const n = try std.posix.poll(poll_fds[0..poll_len], 1000);

        // Reload peers occasionally (could be optimized, but ok for now)
        peer_manager.load() catch {};

        // --- UDP Processing ---
        if (udp_index) |idx| {
            if (poll_fds[idx].revents & std.posix.POLL.IN != 0) {
                const len = std.posix.recvfrom(udp_sock.?, &udp_buf, 0, null, null) catch 0;

                if (len == 1024) {
                    // Cast bytes to Packet pointer (Zero Copy)
                    const p: *Packet = @ptrCast(&udp_buf);
                    var packet = p.*;

                    const dest_id = if (packet.node_id != 0) packet.node_id else UDP_PORT;

                    if (!packet_force_plain) {
                        if (!PacketCrypto.open(&packet, dest_id)) {
                            if (!packet_allow_plain) {
                                _ = packet_mac_failures.fetchAdd(1, .seq_cst);
                                continue;
                            }
                        }
                    }

                    const inputs = [_]Packet{packet};

                    // ✅ ZERO-ALLOC: Call tick without external outbox
                    try node.tick(&inputs);

                    // Deliver outbound packets from internal BoundedArray
                    const peers = peer_manager.peers.items;
                    const out_slice = node.outbox.constSlice();

                    if (peers.len > 0 and out_slice.len > 0) {
                        for (out_slice) |out_pkt| {
                            for (peers) |peer| {
                                if (out_pkt.recipient) |target_pub| {
                                    if (!std.mem.eql(u8, &peer.pub_key, &target_pub)) continue;
                                }

                                var pkt = out_pkt.packet;
                                const dest_port: u16 = peer.ip.getPort();

                                if (!packet_force_plain and dest_port != 0) {
                                    pkt.node_id = dest_port;
                                    PacketCrypto.seal(&pkt, dest_port);
                                } else {
                                    pkt.node_id = dest_port;
                                }

                                const bytes = std.mem.asBytes(&pkt);
                                _ = std.posix.sendto(udp_sock.?, bytes, 0, &peer.ip.any, peer.ip.getOsSockLen()) catch {};

                                if (out_pkt.recipient != null) {
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        // --- API Processing (UDS) ---
        if (n > 0 and poll_fds[uds_index].revents & std.posix.POLL.IN != 0) {
            const client_sock = try std.posix.accept(uds_sock, null, null, 0);
            defer std.posix.close(client_sock);

            // Stack buffer for API requests
            var req_buf: [4096]u8 = undefined;
            const req_len = try std.posix.read(client_sock, &req_buf);

            if (req_len > 0) {
                const resp = try api_server.handleRequest(req_buf[0..req_len]);
                // Note: handleRequest currently allocates resp using 'allocator' (The Slab).
                // It should ideally be updated to use a passed-in stack buffer in Phase 4.
                defer allocator.free(resp);
                _ = try std.posix.write(client_sock, resp);
            }
        }

        sync_tick += 1;
        if (sync_tick % 20 == 0) {
            for (peer_manager.peers.items) |p| {
                syncWithPeer(allocator, &node, &orchestrator, &node.identity, p);
            }
        }
    }
}
fn queryDaemon(request: []const u8) !void {
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const UDS_PATH = if (uds_env) |v| v else "/tmp/myco.sock";
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = try std.net.Address.initUnix(UDS_PATH);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    _ = try std.posix.write(sock, request);
    var buf: [4096]u8 = undefined;
    const len = try std.posix.read(sock, &buf);
    std.debug.print("{s}\n", .{buf[0..len]});
}
