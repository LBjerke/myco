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
const json_noalloc = myco.util.json_noalloc;
const FrozenAllocator = myco.util.frozen_allocator.FrozenAllocator;
const noalloc_guard = myco.util.noalloc_guard;
const Orchestrator = myco.core.orchestrator.Orchestrator;
const proc_noalloc = myco.util.process_noalloc;

const SystemdCompiler = myco.engine.systemd;
const NixBuilder = myco.engine.nix.NixBuilder;

// Context to hold dependencies for the executor callback.
const DaemonContext = struct {
    nix_builder: NixBuilder,
};

/// Executor invoked on service deploys: builds via Nix and (re)starts a systemd unit.
fn realExecutor(ctx_ptr: *anyopaque, service: Service) anyerror!void {
    const ctx: *DaemonContext = @ptrCast(@alignCast(ctx_ptr));

    std.debug.print("⚙️ [Executor] Deploying Service: {s} (ID: {d})\n", .{ service.getName(), service.id });

    // 1. Prepare Paths
    var bin_dir_buf: [Limits.PATH_MAX]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_dir_buf, "/var/lib/myco/bin/{d}", .{service.id});

    // Recursive makePath to ensure parent dirs exist
    std.fs.cwd().makePath(bin_dir) catch {};

    // 2. Nix Build
    var out_link_buf: [Limits.PATH_MAX]u8 = undefined;
    const out_link = try std.fmt.bufPrint(&out_link_buf, "{s}/result", .{bin_dir});

    // Build the flake (using the NixBuilder wrapper)
    // false = real execution (not dry run)
    _ = try ctx.nix_builder.build(service.getFlake(), out_link, false);

    // 3. Systemd Unit Generation
    var unit_buf: [2048]u8 = undefined;
    const unit_content = try SystemdCompiler.compile(service, &unit_buf);

    // Use /run/systemd/system for ephemeral units on NixOS
    var unit_path_buf: [Limits.PATH_MAX]u8 = undefined;
    const unit_path = try std.fmt.bufPrint(&unit_path_buf, "/run/systemd/system/myco-{d}.service", .{service.id});

    // Write Unit File
    {
        const file = try std.fs.cwd().createFile(unit_path, .{});
        defer file.close();
        try file.writeAll(unit_content);
    }

    // 4. Reload and Start
    const systemctl_z: [:0]const u8 = "systemctl";
    const daemon_reload_z: [:0]const u8 = "daemon-reload";
    const daemon_reload = [_:null]?[*:0]const u8{ systemctl_z.ptr, daemon_reload_z.ptr, null };
    try proc_noalloc.spawnAndWait(&daemon_reload);

    var service_name_buf: [64]u8 = undefined;
    const service_name = try std.fmt.bufPrint(&service_name_buf, "myco-{d}", .{service.id});
    var service_name_z_buf: [64]u8 = undefined;
    const service_name_z = try proc_noalloc.toZ(service_name, &service_name_z_buf);

    const restart_z: [:0]const u8 = "restart";
    const start_cmd = [_:null]?[*:0]const u8{ systemctl_z.ptr, restart_z.ptr, service_name_z, null };
    try proc_noalloc.spawnAndWait(&start_cmd);

    std.debug.print("✅ [Executor] Service {s} is LIVE.\n", .{service.getName()});
}

var global_memory: [Limits.GLOBAL_MEMORY_SIZE]u8 = undefined;
/// CLI dispatcher for Myco commands.
pub fn main() !void {

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.deinit();
    //const allocator = gpa.allocator();
    var fba = std.heap.FixedBufferAllocator.init(&global_memory);
    var frozen_alloc = FrozenAllocator.init(fba.allocator());
    const allocator = frozen_alloc.allocator();

    var args_it = std.process.args();
    _ = args_it.next(); // skip argv[0]
    const command_z = args_it.next() orelse {
        printUsage();
        return;
    };
    const command = command_z[0..command_z.len];

    if (std.mem.eql(u8, command, "init")) {
        const cwd = std.fs.cwd();
        const scaffolder = Scaffolder.init(cwd);
        try scaffolder.generate();
        std.debug.print("✅ Initialized Myco project.\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "daemon")) {
        try runDaemon(allocator, &frozen_alloc);
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        try queryDaemon("GET /metrics HTTP/1.0\r\n\r\n");
        return;
    }
    if (std.mem.eql(u8, command, "pubkey")) {
        // Ensure identity exists and print public key hex for cluster wiring.
        var ident = try myco.net.identity.Identity.init();
        var hex_buf: [64]u8 = undefined;
        const hex = try ident.getPublicKeyHexBuf(&hex_buf);
        try std.fs.File.stdout().writeAll(hex);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, command, "peer")) {
        const action_z = args_it.next() orelse {
            std.debug.print("Usage: myco peer add <PUBKEY_HEX> <IP:PORT>\n", .{});
            return;
        };
        const action = action_z[0..action_z.len];
        if (!std.mem.eql(u8, action, "add")) {
            std.debug.print("Usage: myco peer add <PUBKEY_HEX> <IP:PORT>\n", .{});
            return;
        }
        const key_z = args_it.next() orelse {
            std.debug.print("Usage: myco peer add <PUBKEY_HEX> <IP:PORT>\n", .{});
            return;
        };
        const ip_z = args_it.next() orelse {
            std.debug.print("Usage: myco peer add <PUBKEY_HEX> <IP:PORT>\n", .{});
            return;
        };
        const key = key_z[0..key_z.len];
        const ip = ip_z[0..ip_z.len];
        const state_dir = std.posix.getenv("MYCO_STATE_DIR") orelse "/var/lib/myco";
        var peers_path_buf: [Limits.PATH_MAX]u8 = undefined;
        const peers_path = try std.fmt.bufPrint(&peers_path_buf, "{s}/peers.list", .{state_dir});
        var pm = try PeerManager.init(peers_path);
        defer pm.deinit();
        pm.add(key, ip) catch |err| {
            std.debug.print("Failed to add peer: {}\n", .{err});
            return;
        };
        std.debug.print("✅ Peer added to peers.list\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "deploy")) {
        try myco.cli.deploy.run();
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

fn serveFetchFromNode(node: *Node, session: *TransportClient, payload: []const u8) !void {
    noalloc_guard.check();
    var idx: usize = 0;
    var name_buf: [Limits.MAX_SERVICE_NAME]u8 = undefined;
    const name = json_noalloc.parseString(payload, &idx, name_buf[0..]) catch {
        try session.send(.Error, "Invalid service request");
        return;
    };
    json_noalloc.skipWhitespace(payload, &idx);
    if (idx != payload.len) {
        try session.send(.Error, "Invalid service request");
        return;
    }

    const svc = node.getServiceByName(name) orelse {
        try session.send(.Error, "Service config not found");
        return;
    };

    const version = node.getVersion(svc.id);
    const cfg = Config.fromService(svc, version);

    try session.send(.ServiceConfig, cfg);
}

fn syncWithPeer(
    allocator: std.mem.Allocator,
    node: *Node,
    orchestrator: *Orchestrator,
    identity: *myco.net.handshake.Identity,
    peer: myco.p2p.peers.Peer,
    state_dir: []const u8,
    config_io: *Config.ConfigIO,
) void {
    noalloc_guard.check();
    const opts = handshakeOptionsFromEnv();
    std.debug.print("[sync] dialing peer {any}\n", .{peer.ip});
    var client = TransportClient.connectAddress(allocator, identity, peer.ip, opts) catch return;
    defer client.close();

    var engine = GossipEngine.init();
    const summary = engine.generateSummary(node);

    client.send(.Gossip, summary) catch return;

    while (true) {
        const pkt = client.receive() catch break;
        const payload_len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);
        const payload = pkt.payload[0..payload_len];

        switch (@as(MessageType, @enumFromInt(pkt.msg_type))) {
            .FetchService => serveFetchFromNode(node, &client, payload) catch {},
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
        var engine_pull = GossipEngine.init();
        const remote = engine_pull.parseSummary(list_payload) catch return;
        const needed = engine_pull.compare(node, remote);

        for (needed) |name| {
            client.send(.FetchService, name) catch continue;
            const cfg_pkt = client.receive() catch continue;
            const cfg_payload_len: usize = @min(@as(usize, cfg_pkt.payload_len), cfg_pkt.payload.len);
            const cfg_payload = cfg_pkt.payload[0..cfg_payload_len];
            if (@as(MessageType, @enumFromInt(cfg_pkt.msg_type)) != .ServiceConfig) continue;

            var scratch = Config.ConfigScratch{};
            const cfg = Config.parseServiceConfigJson(cfg_payload, &scratch) catch continue;

            Config.saveNoAlloc(state_dir, cfg, config_io) catch {};

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

            _ = node.injectService(svc) catch {};
            orchestrator.reconcile(cfg) catch {};
        }
    }
}

/// Start the UDP+Unix-socket daemon loop handling gossip and API requests.
/// Start the UDP+Unix-socket daemon loop handling gossip and API requests.
fn runDaemon(allocator: std.mem.Allocator, frozen_alloc: *FrozenAllocator) !void {
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
    var peers_path_buf: [Limits.PATH_MAX]u8 = undefined;
    const peers_path = try std.fmt.bufPrint(&peers_path_buf, "{s}/peers.list", .{state_dir});

    var peer_manager = try PeerManager.init(peers_path);
    defer peer_manager.deinit();
    peer_manager.load() catch {};

    // WAL Buffer (Part of the Slab concept, typically passed in or alloc'd once)
    var wal_buf: [64 * 1024]u8 = undefined;
    @memset(&wal_buf, 0);

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const node_id_env = std.posix.getenv("MYCO_NODE_ID");
    const node_id: u16 = if (node_id_env) |v|
        std.fmt.parseUnsigned(u16, v, 10) catch prng.random().int(u16)
    else
        prng.random().int(u16);

    // Initialize Execution Context
    var context = DaemonContext{
        .nix_builder = NixBuilder.init(),
    };

    // Initialize Node (Phase 3: ServiceStore.init takes no args now)
    var node = try Node.init(node_id, allocator, wal_buf[0..], &context, realExecutor);
    node.hlc = .{ .wall = @as(u64, @intCast(std.time.milliTimestamp())), .logical = 0 };

    var api_server = ApiServer.init(&node, &packet_mac_failures);

    // Start TCP transport server
    var ux = UX.init();
    var orchestrator = Orchestrator.init(&ux);
    var transport_server = TransportServer.init(allocator, state_dir, &node.identity, &node, &orchestrator, &ux);
    var config_io = Config.ConfigIO{};
    transport_server.start() catch |err| {
        std.debug.print("[ERR] transport start failed: {any}\n", .{err});
    };

    std.debug.print("🚀 Myco Daemon {d} running.\n   UDP: 0.0.0.0:{d}\n   API: {s}\n", .{ node.id, UDP_PORT, UDS_PATH });

    // Freeze allocator after startup; any heap allocation in the runtime loop will panic.
    frozen_alloc.freeze();
    noalloc_guard.activate(frozen_alloc);

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
        noalloc_guard.check();
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
                    const peers = peer_manager.peers.constSlice();
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
                _ = try std.posix.write(client_sock, resp);
            }
        }

        sync_tick += 1;
        if (sync_tick % 20 == 0) {
            for (peer_manager.peers.constSlice()) |p| {
                syncWithPeer(allocator, &node, &orchestrator, &node.identity, p, state_dir, &config_io);
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
