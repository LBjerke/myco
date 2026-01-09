// CLI entry point for Myco: handles init, daemon lifecycle, deployment, and metrics.
// This file serves as the main entry point and CLI dispatcher for the Myco application.
// It handles various commands like initialization, daemon lifecycle, service deployment,
// and peer management. The daemon orchestrates gossip, API requests, and service
// deployment using Nix and systemd.
const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const NodeStorage = myco.NodeStorage;
const Limits = myco.limits;
const Scaffolder = myco.cli.init.Scaffolder;
const Packet = myco.Packet;
const ApiServer = myco.api.server.ApiServer;
const PeerManager = myco.p2p.peers.PeerManager;
const OutboundPacket = myco.OutboundPacket;
const Service = myco.schema.service.Service;
const PacketCrypto = myco.crypto.packet_crypto;
const Config = myco.core.config;
const ServiceConfig = Config.ServiceConfig;
const FrozenAllocator = myco.util.frozen_allocator.FrozenAllocator;
const noalloc_guard = myco.util.noalloc_guard;
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

fn noopExecutor(_: *anyopaque, _: Service) anyerror!void {}

var global_memory: [Limits.GLOBAL_MEMORY_SIZE]u8 = undefined;
var daemon_storage: NodeStorage = undefined;
/// CLI dispatcher for Myco commands.
pub fn main() !void {

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.deinit();
    //const allocator = gpa.allocator();
    var fba = std.heap.FixedBufferAllocator.init(&global_memory);
    var frozen_alloc = FrozenAllocator.init(fba.allocator());

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
        try runDaemon(&frozen_alloc);
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        try queryDaemon("GET /metrics HTTP/1.0\r\n\r\n");
        return;
    }
    if (std.mem.eql(u8, command, "pubkey")) {
        var hex_buf: [64]u8 = undefined;
        if (std.posix.getenv("MYCO_NODE_ID")) |node_id_raw| {
            const node_id = std.fmt.parseUnsigned(u16, node_id_raw, 10) catch {
                std.debug.print("Invalid MYCO_NODE_ID: {s}\n", .{node_id_raw});
                return;
            };
            const ident = myco.net.handshake.Identity.initDeterministic(node_id);
            const pubkey_bytes = ident.key_pair.public_key.toBytes();
            const hex = try myco.net.identity.Identity.bytesToHexBuf(hex_buf[0..], pubkey_bytes[0..]);
            try std.fs.File.stdout().writeAll(hex);
            try std.fs.File.stdout().writeAll("\n");
            return;
        }

        // Fall back to the persistent identity when no node id is provided.
        var ident = try myco.net.identity.Identity.init();
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
        \\
        \\  init      Generate flake.nix
        \\
        \\  daemon    Start the node
        \\
        \\  deploy    Deploy current directory
        \\
        \\  status    Query metrics
        \\
        \\  peer add  Add neighbor
        \\
    , .{});
}

fn makePathAbsolute(path: []const u8) !void {
    if (path.len <= 1 or path[0] != '/') return error.BadPathName;
    var root = try std.fs.openDirAbsolute("/", .{});
    defer root.close();
    try root.makePath(path[1..]);
}

fn ensureStateDirs(state_dir: []const u8) !void {
    if (std.fs.path.isAbsolute(state_dir)) {
        try makePathAbsolute(state_dir);
    } else {
        try std.fs.cwd().makePath(state_dir);
    }

    var services_buf: [Limits.PATH_MAX]u8 = undefined;
    const services_dir = try std.fmt.bufPrint(&services_buf, "{s}/services", .{state_dir});
    if (std.fs.path.isAbsolute(services_dir)) {
        try makePathAbsolute(services_dir);
    } else {
        try std.fs.cwd().makePath(services_dir);
    }
}

fn flushOutbox(
    node: *Node,
    peer_manager: *PeerManager,
    udp_sock: std.posix.socket_t,
    packet_force_plain: bool,
) void {
    const peers = peer_manager.peers.constSlice();
    const out_slice = node.outbox.constSlice();
    if (peers.len == 0 or out_slice.len == 0) return;

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
            _ = std.posix.sendto(udp_sock, bytes, 0, &peer.ip.any, peer.ip.getOsSockLen()) catch {};

            if (out_pkt.recipient != null) {
                break;
            }
        }
    }
}

const DaemonConfig = struct {
    udp_port: u16,
    skip_udp: bool,
    uds_path: []const u8,
    packet_force_plain: bool,
    packet_allow_plain: bool,
    poll_timeout_ms: i32,
    state_dir: []const u8,
    node_id: u16,
};

fn loadDaemonConfig() !DaemonConfig {
    const default_port: u16 = 7777;
    const port_env = std.posix.getenv("MYCO_PORT");
    const udp_port = if (port_env) |p|
        std.fmt.parseUnsigned(u16, p, 10) catch default_port
    else
        default_port;

    const skip_udp = std.posix.getenv("MYCO_SKIP_UDP") != null;
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const uds_path = if (uds_env) |v| v else "/tmp/myco.sock";

    const packet_force_plain = std.posix.getenv("MYCO_PACKET_PLAINTEXT") != null;
    const packet_allow_plain = packet_force_plain or (std.posix.getenv("MYCO_PACKET_ALLOW_PLAINTEXT") != null);

    const default_poll_ms: u32 = 100;
    const poll_ms_raw = if (std.posix.getenv("MYCO_POLL_MS")) |v|
        std.fmt.parseInt(u32, v, 10) catch default_poll_ms
    else
        default_poll_ms;
    const poll_timeout_ms: i32 = @intCast(@min(poll_ms_raw, @as(u32, std.math.maxInt(i32))));

    const state_dir = std.posix.getenv("MYCO_STATE_DIR") orelse "/var/lib/myco";

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const node_id_env = std.posix.getenv("MYCO_NODE_ID");
    const node_id: u16 = if (node_id_env) |v|
        std.fmt.parseUnsigned(u16, v, 10) catch prng.random().int(u16)
    else
        prng.random().int(u16);

    return DaemonConfig{
        .udp_port = udp_port,
        .skip_udp = skip_udp,
        .uds_path = uds_path,
        .packet_force_plain = packet_force_plain,
        .packet_allow_plain = packet_allow_plain,
        .poll_timeout_ms = poll_timeout_ms,
        .state_dir = state_dir,
        .node_id = node_id,
    };
}

fn initUdpSocket(port: u16) !std.posix.socket_t {
    const udp_addr = try std.net.Address.resolveIp("0.0.0.0", port);
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
        std.debug.print("[ERR] udp socket create failed: {any}\n", .{err});
        return err;
    };
    std.posix.bind(sock, &udp_addr.any, udp_addr.getOsSockLen()) catch |err| {
        std.debug.print("[ERR] udp bind failed: {any}\n", .{err});
        return err;
    };
    return sock;
}

fn initUdsSocket(path: []const u8) !std.posix.socket_t {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    var addr = try std.net.Address.initUnix(path);
    try std.posix.bind(sock, &addr.any, addr.getOsSockLen());
    try std.posix.listen(sock, 10);
    _ = std.posix.fchmod(sock, 0o666) catch {};
    return sock;
}

fn processUdpInputs(
    udp_sock: std.posix.socket_t,
    udp_buf: *align(@alignOf(Packet)) [1024]u8,
    inputs_buf: []Packet,
    config: DaemonConfig,
    packet_mac_failures: *std.atomic.Value(u64),
) usize {
    var inputs_len: usize = 0;
    while (inputs_len < inputs_buf.len) {
        const len = std.posix.recvfrom(udp_sock, udp_buf, std.posix.MSG.DONTWAIT, null, null) catch |err| switch (err) {
            error.WouldBlock => break,
            else => break,
        };

        if (len != 1024) continue;

        // Cast bytes to Packet pointer (Zero Copy)
        const p: *Packet = @ptrCast(udp_buf);
        var packet = p.*;

        const dest_id = if (packet.node_id != 0) packet.node_id else config.udp_port;

        var accept_packet = true;
        if (!config.packet_force_plain) {
            if (!PacketCrypto.open(&packet, dest_id)) {
                if (!config.packet_allow_plain) {
                    _ = packet_mac_failures.fetchAdd(1, .seq_cst);
                    accept_packet = false;
                }
            }
        }

        if (accept_packet) {
            inputs_buf[inputs_len] = packet;
            inputs_len += 1;
        }
    }
    return inputs_len;
}

fn processApiRequests(uds_sock: std.posix.socket_t, api_server: *ApiServer) !void {
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

fn daemonLoopTick(
    config: DaemonConfig,
    state: *DaemonState,
    node: *Node,
    api_server: *ApiServer,
    poll_fds_slice: []std.posix.pollfd,
    udp_index: ?usize,
    uds_index: usize,
) !void {
    noalloc_guard.check();
    const n = try std.posix.poll(poll_fds_slice, config.poll_timeout_ms);

    // Reload peers occasionally (could be optimized, but ok for now)
    state.peer_manager.load() catch {};

    // --- UDP Processing ---
    var inputs_buf: [32]Packet = undefined;
    var inputs_len: usize = 0;

    if (udp_index) |idx| {
        if (poll_fds_slice[idx].revents & std.posix.POLL.IN != 0) {
            inputs_len = processUdpInputs(state.udp_sock.?, &state.udp_buf, inputs_buf[0..], config, &state.packet_mac_failures);
        }
    }

    if (!config.skip_udp) {
        const inputs = inputs_buf[0..inputs_len];
        try node.tick(inputs);
        flushOutbox(node, &state.peer_manager, state.udp_sock.?, config.packet_force_plain);
    }

    // --- API Processing (UDS) ---
    try handleUdsPollEvent(state, api_server, poll_fds_slice, uds_index, n);
}

fn handleUdsPollEvent(
    state: *DaemonState,
    api_server: *ApiServer,
    poll_fds: []std.posix.pollfd,
    uds_index: usize,
    n: usize,
) !void {
    if (n > 0 and poll_fds[uds_index].revents & std.posix.POLL.IN != 0) {
        processApiRequests(state.uds_sock, api_server) catch {};
    }
}

/// Start the UDP+Unix-socket daemon loop handling gossip and API requests.
fn runDaemon(frozen_alloc: *FrozenAllocator) !void {
    // 1. Load Configuration
    const config = try loadDaemonConfig();

    try ensureStateDirs(config.state_dir);
    var peers_path_buf: [Limits.PATH_MAX]u8 = undefined;
    const peers_path = try std.fmt.bufPrint(&peers_path_buf, "{s}/peers.list", .{config.state_dir});

    var peer_manager = try PeerManager.init(peers_path);
    defer peer_manager.deinit();
    peer_manager.load() catch {};

    // 2. Initialize Sockets
    var udp_sock: ?std.posix.socket_t = null;
    if (!config.skip_udp) {
        udp_sock = try initUdpSocket(config.udp_port);
    }
    const uds_sock = try initUdsSocket(config.uds_path);

    // Setup initial daemon state
    var state = DaemonState{
        .packet_mac_failures = std.atomic.Value(u64).init(0),
        .udp_buf = undefined,
        .udp_sock = udp_sock,
        .uds_sock = uds_sock,
        .peer_manager = peer_manager,
    };

    // WAL Buffer (Part of the Slab concept, typically passed in or alloc'd once)
    var wal_buf: [64 * 1024]u8 = undefined;
    @memset(&wal_buf, 0);

    // Initialize Execution Context
    var context = DaemonContext{
        .nix_builder = NixBuilder.init(),
    };

    // Initialize Node (Phase 3: ServiceStore.init takes no args now)
    const skip_exec = std.posix.getenv("MYCO_SMOKE_SKIP_EXEC") != null or
        std.posix.getenv("MYCO_SKIP_EXEC") != null;
    const exec_fn: *const fn (*anyopaque, Service) anyerror!void =
        if (skip_exec) &noopExecutor else &realExecutor;
    var node = try Node.init(config.node_id, &daemon_storage, wal_buf[0..], &context, exec_fn);
    node.hlc = .{ .wall = @as(u64, @intCast(std.time.milliTimestamp())), .logical = 0 };

    var api_server = ApiServer.init(&node, &state.packet_mac_failures);

    std.debug.print("🚀 Myco Daemon {d} running.\n   UDP: 0.0.0.0:{d}\n   API: {s}\n", .{ node.id, config.udp_port, config.uds_path });

    // Freeze allocator after startup; any heap allocation in the runtime loop will panic.
    frozen_alloc.freeze();
    noalloc_guard.activate(frozen_alloc);

    // Poll Setup
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = state.uds_sock, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = 0, .revents = 0 },
    };
    var poll_len: usize = 1;
    const udp_index: ?usize = if (config.skip_udp) null else blk: {
        poll_fds[poll_len] = .{ .fd = state.udp_sock.?, .events = std.posix.POLL.IN, .revents = 0 };
        poll_len += 1;
        break :blk poll_len - 1;
    };
    const uds_index: usize = 0;

    // 3. Event Loop
    while (true) {
        try daemonLoopTick(config, &state, &node, &api_server, poll_fds[0..poll_len], udp_index, uds_index);
    }
}

// DaemonState struct definition (add this somewhere appropriate, e.g., near DaemonConfig)
const DaemonState = struct {
    packet_mac_failures: std.atomic.Value(u64),
    udp_buf: [1024]u8 align(@alignOf(Packet)),
    udp_sock: ?std.posix.socket_t,
    uds_sock: std.posix.socket_t,
    peer_manager: PeerManager,
};

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
