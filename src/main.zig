// CLI entry point for Myco: handles init, daemon lifecycle, deployment, and metrics.
const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const OutboxList = myco.node.OutboxList;
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
const GossipEngine = myco.net.gossip.GossipEngine;
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

    // Smoke mode skips orchestration so CI/local smokes converge without Nix/systemd work.
    if (std.posix.getenv("MYCO_SMOKE_SKIP_EXEC") != null) {
        std.debug.print("[Executor] Smoke mode enabled, skipping Nix/systemd.\n", .{});
        return;
    }

    // 1. Prepare Paths
    var bin_buf: [128]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "/var/lib/myco/bin/{d}", .{service.id});

    // Recursive makePath to ensure parent dirs exist
    std.fs.cwd().makePath(bin_dir) catch {};

    // 2. Nix Build
    var out_link_buf: [160]u8 = undefined;
    const out_link = try std.fmt.bufPrint(&out_link_buf, "{s}/result", .{bin_dir});

    // Build the flake (using the NixBuilder wrapper)
    // false = real execution (not dry run)
    _ = try ctx.nix_builder.build(service.getFlake(), out_link, false);

    // 3. Systemd Unit Generation
    var unit_buf: [2048]u8 = undefined;
    const unit_content = try SystemdCompiler.compile(service, &unit_buf);

    // Use /run/systemd/system for ephemeral units on NixOS
    var unit_path_buf: [160]u8 = undefined;
    const unit_path = try std.fmt.bufPrint(&unit_path_buf, "/run/systemd/system/myco-{d}.service", .{service.id});

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

    var service_name_buf: [64]u8 = undefined;
    const service_name = try std.fmt.bufPrint(&service_name_buf, "myco-{d}", .{service.id});

    const start_cmd = [_][]const u8{ "systemctl", "restart", service_name };
    var start_child = std.process.Child.init(&start_cmd, allocator);
    _ = try start_child.spawnAndWait();

    std.debug.print("✅ [Executor] Service {s} is LIVE.\n", .{service.getName()});
}

/// CLI dispatcher for Myco commands.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
        runDaemon(allocator) catch |err| {
            std.debug.print("daemon failed: {any}\n", .{err});
            return;
        };
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        try queryDaemon("GET /metrics HTTP/1.0\r\n\r\n");
        return;
    }
    if (std.mem.eql(u8, command, "rotate-token")) {
        if (args.len < 3) {
            std.debug.print("Usage: myco rotate-token <new_token> [prev_token]\n", .{});
            return;
        }
        const new_tok = args[2];
        const prev_tok = if (args.len > 3) args[3] else null;
        const path_env = std.posix.getenv("MYCO_API_TOKEN_PATH");
        const token_path = path_env orelse "/var/lib/myco/api.token";
        writeApiTokens(token_path, new_tok, prev_tok) catch |err| {
            std.debug.print("Failed to write token file: {}\n", .{err});
            return;
        };
        std.debug.print("✅ API token written to {s}\n", .{token_path});
        return;
    }
    if (std.mem.eql(u8, command, "gen-token")) {
        const path_env = std.posix.getenv("MYCO_API_TOKEN_PATH");
        const token_path = path_env orelse "/var/lib/myco/api.token";
        var rand_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);
        var hex_buf: [64]u8 = std.fmt.bytesToHex(rand_bytes, .lower);

        var existing = loadApiTokens(allocator);
        defer freeApiTokens(allocator, &existing);
        const prev = existing.curr;

        writeApiTokens(token_path, &hex_buf, prev) catch |err| {
            std.debug.print("Failed to write token file: {}\n", .{err});
            return;
        };
        std.debug.print("✅ New API token: {s}\n", .{&hex_buf});
        std.debug.print("✅ Written to {s} (previous kept if present)\n", .{token_path});
        return;
    }
    if (std.mem.eql(u8, command, "pubkey")) {
        // Ensure identity exists and print public key hex for cluster wiring.
        changeToStateDirIfSet();
        var ident = try myco.net.identity.Identity.init(allocator);
        defer {
            // Nothing to deinit in Identity today.
        }
        const hex = try ident.getPublicKeyHex();
        defer allocator.free(hex);
        _ = try std.posix.write(std.posix.STDOUT_FILENO, hex);
        _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
        return;
    }
    if (std.mem.eql(u8, command, "peer")) {
        if (args.len < 5 or !std.mem.eql(u8, args[2], "add")) {
            std.debug.print("Usage: myco peer add <PUBKEY_HEX> <IP:PORT>\n", .{});
            return;
        }
        changeToStateDirIfSet();
        const key = args[3];
        const ip = args[4];
        var pm = PeerManager.init(allocator, "peers.list");
        defer pm.deinit();
        pm.add(key, ip) catch |err| {
            std.debug.print("Failed to add peer: {}\n", .{err});
            return;
        };
        std.debug.print("✅ Peer added to peers.list\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "deploy")) {
        changeToStateDirIfSet();
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
        \\  rotate-token <new> [prev]  Persist API token file
        \\  gen-token  Generate and persist a new API token
        \\  peer add  Add neighbor
        \\
    , .{});
}

fn handshakeOptionsFromEnv() HandshakeOptions {
    const force_plain = std.posix.getenv("MYCO_TRANSPORT_PLAINTEXT") != null;
    const allow_plain = force_plain or (std.posix.getenv("MYCO_TRANSPORT_ALLOW_PLAINTEXT") != null);
    const psk = std.posix.getenv("MYCO_TRANSPORT_PSK");
    return .{
        .allow_plaintext = allow_plain,
        .force_plaintext = force_plain,
        .psk = psk,
    };
}

const ApiTokens = struct {
    curr: ?[]u8,
    prev: ?[]u8,
};

fn changeToStateDirIfSet() void {
    if (std.posix.getenv("MYCO_STATE_DIR")) |dir| {
        std.fs.cwd().makePath(dir) catch {};
        std.process.changeCurDir(dir) catch {};
    }
}

fn loadApiTokens(allocator: std.mem.Allocator) ApiTokens {
    const path_env = std.posix.getenv("MYCO_API_TOKEN_PATH");
    const token_path = path_env orelse "/var/lib/myco/api.token";
    var curr: ?[]u8 = null;
    var prev: ?[]u8 = null;

    if (std.fs.cwd().openFile(token_path, .{})) |file| {
        defer file.close();
        const content = file.readToEndAlloc(allocator, 4096) catch null;
        if (content) |c| {
            defer allocator.free(c);
            var it = std.mem.splitScalar(u8, c, '\n');
            if (it.next()) |line| {
                if (line.len > 0) curr = allocator.dupe(u8, line) catch null;
            }
            if (it.next()) |line| {
                if (line.len > 0) prev = allocator.dupe(u8, line) catch null;
            }
        }
    } else |_| {}

    const env_curr = std.posix.getenv("MYCO_API_TOKEN");
    const env_prev = std.posix.getenv("MYCO_API_TOKEN_PREV");
    if (env_curr) |e| curr = allocator.dupe(u8, e) catch curr;
    if (env_prev) |e| prev = allocator.dupe(u8, e) catch prev;
    return .{ .curr = curr, .prev = prev };
}

fn writeApiTokens(path: []const u8, curr: []const u8, prev: ?[]const u8) !void {
    var tmp_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    const dir = std.fs.path.dirname(path) orelse ".";
    std.fs.cwd().makePath(dir) catch {};

    const file = try std.fs.cwd().createFile(tmp_path, .{});
    defer file.close();

    try file.writeAll(curr);
    try file.writeAll("\n");
    if (prev) |p| try file.writeAll(p);
    try file.sync();
    try std.fs.cwd().rename(tmp_path, path);
}

fn freeApiTokens(allocator: std.mem.Allocator, tokens: *ApiTokens) void {
    if (tokens.curr) |c| allocator.free(c);
    if (tokens.prev) |p| allocator.free(p);
    tokens.curr = null;
    tokens.prev = null;
}

fn tokensEqual(a: ApiTokens, b: ApiTokens) bool {
    const eq = struct {
        fn optEq(x: ?[]u8, y: ?[]u8) bool {
            if (x == null and y == null) return true;
            if (x == null or y == null) return false;
            return std.mem.eql(u8, x.?, y.?);
        }
    };
    return eq.optEq(a.curr, b.curr) and eq.optEq(a.prev, b.prev);
}

fn serveFetchFromDisk(allocator: std.mem.Allocator, session: *TransportClient, payload: []const u8) !void {
    const parsed_name = try std.json.parseFromSlice([]const u8, allocator, payload, .{});
    defer parsed_name.deinit();
    const name = parsed_name.value;

    var path_buf: [128]u8 = undefined;
    const filename = try std.fmt.bufPrint(&path_buf, "services/{s}.json", .{name});

    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed_cfg = try std.json.parseFromSlice(ServiceConfig, allocator, content, .{});
    defer parsed_cfg.deinit();

    try session.send(.ServiceConfig, parsed_cfg.value);
}

fn syncWithPeer(allocator: std.mem.Allocator, identity: *myco.net.handshake.Identity, peer: myco.p2p.peers.Peer) void {
    const opts = handshakeOptionsFromEnv();
    var client = TransportClient.connectAddress(allocator, identity, peer.ip, opts) catch return;
    defer client.close();

    var engine = GossipEngine.init(allocator);
    const summary = engine.generateSummary() catch return;
    defer allocator.free(summary);

    client.send(.Gossip, summary) catch return;

    while (true) {
        const pkt = client.receive() catch break;
        defer allocator.free(pkt.payload);

        switch (pkt.type) {
            .FetchService => serveFetchFromDisk(allocator, &client, pkt.payload) catch {},
            .GossipDone => break,
            else => {},
        }
    }
}

/// Start the UDP+Unix-socket daemon loop handling gossip and API requests.
fn runDaemon(allocator: std.mem.Allocator) !void {
    const udp_port_env = std.posix.getenv("MYCO_PORT");
    const UDP_PORT: u16 = if (udp_port_env) |p| std.fmt.parseInt(u16, p, 10) catch 7777 else 7777;
    const bind_addr_env = std.posix.getenv("MYCO_BIND_ADDR") orelse "127.0.0.1";
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const packet_force_plain = std.posix.getenv("MYCO_PACKET_PLAINTEXT") != null;
    const packet_allow_plain = packet_force_plain or (std.posix.getenv("MYCO_PACKET_ALLOW_PLAINTEXT") != null);
    const state_dir = std.posix.getenv("MYCO_STATE_DIR") orelse "/var/lib/myco";
    std.fs.cwd().makePath(state_dir) catch {};
    std.process.changeCurDir(state_dir) catch {};
    const uds_default = try std.fmt.allocPrint(allocator, "{s}/myco.sock", .{state_dir});
    defer allocator.free(uds_default);
    const UDS_PATH = uds_env orelse uds_default;
    const api_tcp_env = std.posix.getenv("MYCO_API_TCP_PORT");
    var api_tcp_port: ?u16 = if (api_tcp_env) |p| std.fmt.parseInt(u16, p, 10) catch null else null;
    var packet_mac_failures = std.atomic.Value(u64).init(0);
    PacketCrypto.configureFromEnv();
    var peer_manager = PeerManager.init(allocator, "peers.list");
    defer peer_manager.deinit();
    peer_manager.load() catch {};

    const ram = try allocator.alloc(u8, 64 * 1024 * 1024);
    var fba = std.heap.FixedBufferAllocator.init(ram);
    const wal_buf = try allocator.alloc(u8, 64 * 1024);
    @memset(wal_buf, 0); // Clear WAL

    const env_node_id = std.posix.getenv("MYCO_NODE_ID");
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const chosen_id: u16 = blk: {
        if (env_node_id) |e| {
            break :blk std.fmt.parseInt(u16, e, 10) catch prng.random().int(u16);
        }
        break :blk prng.random().int(u16);
    };

    // FIX: Initialize the Execution Context
    var context = DaemonContext{
        .allocator = allocator,
        .nix_builder = NixBuilder.init(allocator),
    };

    // FIX: Pass 5 arguments to Node.init
    var node = try Node.init(chosen_id, fba.allocator(), wal_buf, &context, // Context pointer
        realExecutor // Function pointer
    );
    node.hlc = .{ .wall = @as(u64, @intCast(std.time.milliTimestamp())), .logical = 0 };

    var api_tokens = loadApiTokens(allocator);
    var api_server = ApiServer.init(allocator, &node, &packet_mac_failures, api_tokens.curr, api_tokens.prev);

    // Start TCP transport server for gossip/deploy.
    var ux = UX.init(allocator);
    var orchestrator = Orchestrator.init(allocator, &ux);
    var transport_server = TransportServer.init(allocator, &node.identity, &node, &orchestrator, &ux);
    transport_server.start() catch {};

    std.debug.print("[daemon] binding UDP {d} on {s}\n", .{ UDP_PORT, bind_addr_env });
    const udp_addr = try std.net.Address.resolveIp(bind_addr_env, UDP_PORT);
    const udp_sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    try std.posix.bind(udp_sock, &udp_addr.any, udp_addr.getOsSockLen());
    std.debug.print("[daemon] UDP bound\n", .{});

    std.fs.cwd().deleteFile(UDS_PATH) catch {};

    // UDS API (optional; skip if denied)
    var uds_sock: ?std.posix.socket_t = null;
    const uds_try = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| blk: {
        if (err == error.AccessDenied or err == error.PermissionDenied) break :blk null;
        return err;
    };
    if (uds_try) |fd| {
        var uds_addr = try std.net.Address.initUnix(UDS_PATH);
        if (std.posix.bind(fd, &uds_addr.any, uds_addr.getOsSockLen())) |_| {
            try std.posix.listen(fd, 10);
            std.posix.fchmod(fd, 0o666) catch {};
            uds_sock = fd;
        } else |err| {
            std.posix.close(fd);
            if (err != error.AccessDenied and err != error.PermissionDenied) return err;
        }
    }

    // TCP API fallback
    if (uds_sock == null and api_tcp_port == null) {
        api_tcp_port = 7778;
    }
    var tcp_sock: ?std.posix.socket_t = null;
    if (api_tcp_port) |port| {
        const addr = try std.net.Address.resolveIp("127.0.0.1", port);
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &[_]u8{1}) catch {};
        if (std.posix.bind(sock, &addr.any, addr.getOsSockLen())) |_| {
            try std.posix.listen(sock, 16);
            tcp_sock = sock;
        } else |err| {
            std.posix.close(sock);
            if (err != error.AccessDenied and err != error.PermissionDenied) return err;
        }
    }

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = udp_sock, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = 0, .revents = 0 },
        .{ .fd = 0, .events = 0, .revents = 0 },
    };
    var poll_len: usize = 1;
    if (uds_sock) |fd| {
        poll_fds[poll_len] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        poll_len += 1;
    }
    if (tcp_sock) |fd| {
        poll_fds[poll_len] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        poll_len += 1;
    }

    if (uds_sock) |sock_fd| {
        _ = sock_fd;
        std.debug.print("🚀 Myco Daemon {d} running.\n   UDP: 0.0.0.0:{d}\n   API (UDS): {s}\n", .{ node.id, UDP_PORT, UDS_PATH });
    } else if (tcp_sock) |fd| {
        _ = fd;
        std.debug.print("🚀 Myco Daemon {d} running.\n   UDP: 0.0.0.0:{d}\n   API (TCP): 127.0.0.1:{d}\n", .{ node.id, UDP_PORT, api_tcp_port.? });
    } else {
        std.debug.print("🚀 Myco Daemon {d} running.\n   UDP: 0.0.0.0:{d}\n   API: disabled\n", .{ node.id, UDP_PORT });
    }

    var udp_buf: [1024]u8 = undefined;
    var outbox = OutboxList{};
    var sync_tick: u64 = 0;

    while (true) {
        _ = std.posix.poll(poll_fds[0..poll_len], 100) catch {};

        peer_manager.load() catch {};

        // Periodically refresh transport PSK and packet keys from env (hot reload).
        if (sync_tick % 200 == 0) {
            PacketCrypto.configureFromEnv();
        }

        var ticked = false;
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const len = std.posix.recvfrom(udp_sock, &udp_buf, 0, null, null) catch 0;
            if (len == 1024) {
                const p: *const Packet = @ptrCast(@alignCast(&udp_buf));
                var packet = p.*;

                const dest_id = if (packet.node_id != 0) packet.node_id else UDP_PORT;

                if (!packet_force_plain) {
                    if (!PacketCrypto.open(&packet, dest_id)) {
                        if (!packet_allow_plain) {
                            _ = packet_mac_failures.fetchAdd(1, .seq_cst);
                        }
                        // fall through to periodic tick
                    } else {
                        const inputs = [_]Packet{packet};
                        outbox.clearRetainingCapacity();
                        try node.tick(&inputs, &outbox, allocator);
                        ticked = true;
                    }
                } else {
                    const inputs = [_]Packet{packet};
                    outbox.clearRetainingCapacity();
                    try node.tick(&inputs, &outbox, allocator);
                    ticked = true;
                }
            }
        }
        if (uds_sock) |sock_fd| {
            if (poll_len > 1 and poll_fds[1].revents & std.posix.POLL.IN != 0) {
                const client_sock = try std.posix.accept(sock_fd, null, null, 0);
                defer std.posix.close(client_sock);
                var req_buf: [4096]u8 = undefined;
                const req_len = try std.posix.read(client_sock, &req_buf);
                var resp_buf: [2048]u8 = undefined;
                const resp = api_server.handleRequestBuf(req_buf[0..req_len], &resp_buf) catch |err| {
                    const fallback = "HTTP/1.0 500 Internal Server Error\r\n\r\n";
                    _ = std.posix.write(client_sock, fallback) catch {};
                    std.debug.print("[!] API handle error: {any}\n", .{err});
                    continue;
                };
                _ = std.posix.write(client_sock, resp) catch {};
            }
        }
        if (tcp_sock) |sock_fd| {
            var idx: usize = 1;
            if (uds_sock != null) idx = 2;
            if (poll_len > idx and poll_fds[idx].revents & std.posix.POLL.IN != 0) {
                const client_sock = try std.posix.accept(sock_fd, null, null, 0);
                defer std.posix.close(client_sock);
                var req_buf: [4096]u8 = undefined;
                const req_len = try std.posix.read(client_sock, &req_buf);
                var resp_buf: [2048]u8 = undefined;
                const resp = api_server.handleRequestBuf(req_buf[0..req_len], &resp_buf) catch |err| {
                    const fallback = "HTTP/1.0 500 Internal Server Error\r\n\r\n";
                    _ = std.posix.write(client_sock, fallback) catch {};
                    std.debug.print("[!] API handle error: {any}\n", .{err});
                    continue;
                };
                _ = std.posix.write(client_sock, resp) catch {};
            }
        }

        // If no inbound packets ticked the node, still drive gossip with an empty tick.
        if (!ticked) {
            outbox.clearRetainingCapacity();
            const empty: [0]Packet = .{};
            try node.tick(&empty, &outbox, allocator);
        }

        // Deliver outbound packets to known peers (encrypt unless forced plaintext).
        const peers = peer_manager.peers[0..peer_manager.len];
        if (peers.len > 0 and outbox.items.len > 0) {
            for (outbox.items) |out_pkt| {
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
                        break; // targeted delivery; don't fan out further
                    }
                }
            }
        }

        sync_tick += 1;
        if (sync_tick % 200 == 0) {
            var new_tokens = loadApiTokens(allocator);
            if (!tokensEqual(api_tokens, new_tokens)) {
                freeApiTokens(allocator, &api_tokens);
                api_tokens = new_tokens;
                api_server.auth_token = api_tokens.curr;
                api_server.auth_token_prev = api_tokens.prev;
                std.debug.print("🔄 API tokens reloaded\n", .{});
            } else {
                freeApiTokens(allocator, &new_tokens);
            }
        }
        if (sync_tick % 20 == 0) {
            for (peer_manager.peers[0..peer_manager.len]) |p| {
                syncWithPeer(allocator, &node.identity, p);
            }
        }
    }
}

fn queryDaemon(request: []const u8) !void {
    const tcp_env = std.posix.getenv("MYCO_API_TCP_PORT");
    if (tcp_env) |p| {
        const port = std.fmt.parseInt(u16, p, 10) catch return error.InvalidArgument;
        const addr = try std.net.Address.resolveIp("127.0.0.1", port);
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(sock);
        try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
        var req_buf: [2048]u8 = undefined;
        const api_token = std.posix.getenv("MYCO_API_TOKEN");
        const split = std.mem.indexOf(u8, request, "\r\n\r\n");
        const req_slice: []const u8 = blk: {
            if (api_token) |tok| {
                if (split) |idx| {
                    const req = try std.fmt.bufPrint(&req_buf, "{s}\r\nAuthorization: Bearer {s}\r\n\r\n{s}", .{ request[0..idx], tok, request[idx + 4 ..] });
                    break :blk req;
                } else {
                    const req = try std.fmt.bufPrint(&req_buf, "{s}\r\nAuthorization: Bearer {s}\r\n\r\n", .{ request, tok });
                    break :blk req;
                }
            } else {
                break :blk request;
            }
        };
        _ = try std.posix.write(sock, req_slice);
        var buf: [4096]u8 = undefined;
        const len = try std.posix.read(sock, &buf);
        _ = try std.posix.write(std.posix.STDOUT_FILENO, buf[0..len]);
        _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
        return;
    }

    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const UDS_PATH = if (uds_env) |v| v else "/tmp/myco.sock";
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = try std.net.Address.initUnix(UDS_PATH);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    var req_buf: [2048]u8 = undefined;
    const api_token = std.posix.getenv("MYCO_API_TOKEN");
    const split = std.mem.indexOf(u8, request, "\r\n\r\n");
    const req_slice: []const u8 = blk: {
        if (api_token) |tok| {
            if (split) |idx| {
                const req = try std.fmt.bufPrint(&req_buf, "{s}\r\nAuthorization: Bearer {s}\r\n\r\n{s}", .{ request[0..idx], tok, request[idx + 4 ..] });
                break :blk req;
            } else {
                const req = try std.fmt.bufPrint(&req_buf, "{s}\r\nAuthorization: Bearer {s}\r\n\r\n", .{ request, tok });
                break :blk req;
            }
        } else {
            break :blk request;
        }
    };
    _ = try std.posix.write(sock, req_slice);
    var buf: [4096]u8 = undefined;
    const len = try std.posix.read(sock, &buf);
    _ = try std.posix.write(std.posix.STDOUT_FILENO, buf[0..len]);
    _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
}
