// CLI entry point for Myco: handles init, daemon lifecycle, deployment, and metrics.
const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const Scaffolder = myco.cli.init.Scaffolder;
const Packet = myco.Packet;
const ApiServer = myco.api.server.ApiServer;
const PeerManager = myco.p2p.peers.PeerManager;
const OutboundPacket = myco.OutboundPacket;
const Service = myco.schema.service.Service;

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

    std.debug.print("⚙️ [Executor] Deploying Service: {s} (ID: {d})\n", .{service.getName(), service.id});

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

/// CLI dispatcher for Myco commands.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) { printUsage(); return; }
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
    if (std.mem.eql(u8, command, "peer")) {
         if (args.len < 5 or !std.mem.eql(u8, args[2], "add")) {
            std.debug.print("Usage: myco peer add <PUBKEY_HEX> <IP:PORT>\n", .{});
            return;
        }
        const key = args[3];
        const ip = args[4];
        var pm = PeerManager.init(allocator, "peers.list");
        defer pm.deinit();
        pm.add(key, ip) catch |err| { std.debug.print("Failed to add peer: {}\n", .{err}); return; };
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

/// Start the UDP+Unix-socket daemon loop handling gossip and API requests.
fn runDaemon(allocator: std.mem.Allocator) !void {
    const UDP_PORT = 7777;
    const UDS_PATH = "/tmp/myco.sock";

    const ram = try allocator.alloc(u8, 64 * 1024 * 1024);
    var fba = std.heap.FixedBufferAllocator.init(ram);
    const wal_buf = try allocator.alloc(u8, 64 * 1024);
    @memset(wal_buf, 0); // Clear WAL

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    
    // FIX: Initialize the Execution Context
    var context = DaemonContext{
        .allocator = allocator,
        .nix_builder = NixBuilder.init(allocator),
    };

    // FIX: Pass 5 arguments to Node.init
    var node = try Node.init(
        prng.random().int(u16), 
        fba.allocator(), 
        wal_buf,
        &context,     // Context pointer
        realExecutor  // Function pointer
    );

    var api_server = ApiServer.init(allocator, &node);

    std.debug.print("🚀 Myco Daemon {d} running.\n   UDP: 0.0.0.0:{d}\n   API: {s}\n", .{node.id, UDP_PORT, UDS_PATH});

    const udp_addr = try std.net.Address.resolveIp("0.0.0.0", UDP_PORT);
    const udp_sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    try std.posix.bind(udp_sock, &udp_addr.any, udp_addr.getOsSockLen());

    std.fs.cwd().deleteFile(UDS_PATH) catch {};
    
    // FIX: Use umask to ensure socket is world-writable (avoid chmod issues)
    const uds_sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    var uds_addr = try std.net.Address.initUnix(UDS_PATH);
    try std.posix.bind(uds_sock, &uds_addr.any, uds_addr.getOsSockLen());
    try std.posix.listen(uds_sock, 10);
        try std.posix.fchmod(uds_sock, 0o666);

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = udp_sock, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = uds_sock, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var udp_buf: [1024]u8 = undefined;
    var outbox = std.ArrayList(OutboundPacket){};

    while (true) {
        _ = try std.posix.poll(&poll_fds, -1);

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const len = std.posix.recvfrom(udp_sock, &udp_buf, 0, null, null) catch 0;
            if (len == 1024) {
                const p: *const Packet = @ptrCast(@alignCast(&udp_buf));
                const inputs = [_]Packet{p.*};
                outbox.clearRetainingCapacity();
                try node.tick(&inputs, &outbox, allocator);
            }
        }
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const client_sock = try std.posix.accept(uds_sock, null, null, 0);
            defer std.posix.close(client_sock);
            var req_buf: [4096]u8 = undefined;
            const req_len = try std.posix.read(client_sock, &req_buf);
            const resp = try api_server.handleRequest(req_buf[0..req_len]);
            defer allocator.free(resp);
            _ = try std.posix.write(client_sock, resp);
        }
    }
}

fn queryDaemon(request: []const u8) !void {
    const UDS_PATH = "/tmp/myco.sock";
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = try std.net.Address.initUnix(UDS_PATH);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    _ = try std.posix.write(sock, request);
    var buf: [4096]u8 = undefined;
    const len = try std.posix.read(sock, &buf);
    std.debug.print("{s}\n", .{buf[0..len]});
}
