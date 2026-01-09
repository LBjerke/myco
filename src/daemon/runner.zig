const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const NodeStorage = myco.NodeStorage; // Used in DaemonState for node.storage
const Limits = myco.limits;
const Packet = myco.Packet;
const ApiServer = myco.api.server.ApiServer;
const PeerManager = myco.p2p.peers.PeerManager;
const PacketCrypto = myco.crypto.packet_crypto;
const FrozenAllocator = myco.util.frozen_allocator.FrozenAllocator;
const noalloc_guard = myco.util.noalloc_guard;
const DaemonConfig = @import("config.zig").DaemonConfig;
const loadDaemonConfig = @import("config.zig").loadDaemonConfig;
const ensureStateDirs = @import("config.zig").ensureStateDirs;
const initUdpSocket = @import("config.zig").initUdpSocket;
const initUdsSocket = @import("config.zig").initUdsSocket;
const DaemonContext = @import("executor.zig").DaemonContext;
const realExecutor = @import("executor.zig").realExecutor;
const noopExecutor = @import("executor.zig").noopExecutor;

pub const DaemonState = struct {
    packet_mac_failures: std.atomic.Value(u64),
    udp_buf: [1024]u8 align(@alignOf(Packet)),
    udp_sock: ?std.posix.socket_t,
    uds_sock: std.posix.socket_t,
    peer_manager: PeerManager,
};

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

pub fn runDaemon(
    frozen_alloc: *FrozenAllocator,
    daemon_storage: *NodeStorage,
    real_executor_fn: *const fn (*anyopaque, myco.schema.service.Service) anyerror!void,
    noop_executor_fn: *const fn (*anyopaque, myco.schema.service.Service) anyerror!void,
) !void {
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
        .nix_builder = myco.engine.nix.NixBuilder.init(),
    };

    // Initialize Node (Phase 3: ServiceStore.init takes no args now)
    const skip_exec = std.posix.getenv("MYCO_SMOKE_SKIP_EXEC") != null or
        std.posix.getenv("MYCO_SKIP_EXEC") != null;
    const exec_fn: *const fn (*anyopaque, myco.schema.service.Service) anyerror!void =
        if (skip_exec) noop_executor_fn else real_executor_fn;
    var node = try Node.init(config.node_id, daemon_storage, wal_buf[0..], &context, exec_fn);
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

pub fn queryDaemon(request: []const u8) !void {
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
