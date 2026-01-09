// CLI entry point for Myco: handles init, daemon lifecycle, deployment, and metrics.
// This file serves as the main entry point and CLI dispatcher for the Myco application.
// It handles various commands like initialization, daemon lifecycle, service deployment,
// and peer management. The daemon orchestrates gossip, API requests, and service
// deployment using Nix and systemd.
const std = @import("std");
const myco = @import("myco");

const Limits = myco.limits;
const Scaffolder = myco.cli.init.Scaffolder;
const PeerManager = myco.p2p.peers.PeerManager;

const runDaemon = @import("daemon/runner.zig").runDaemon;
const queryDaemon = @import("daemon/runner.zig").queryDaemon;
const realExecutor = @import("daemon/executor.zig").realExecutor;
const noopExecutor = @import("daemon/executor.zig").noopExecutor;

var global_memory: [Limits.GLOBAL_MEMORY_SIZE]u8 = undefined;
var daemon_storage: myco.NodeStorage = undefined; // myco.NodeStorage, not NodeStorage

/// CLI dispatcher for Myco commands.
pub fn main() !void {

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.deinit();
    //const allocator = gpa.allocator();
    var fba = std.heap.FixedBufferAllocator.init(&global_memory);
    var frozen_alloc = myco.util.frozen_allocator.FrozenAllocator.init(fba.allocator());

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
        try runDaemon(&frozen_alloc, &daemon_storage, realExecutor, noopExecutor);
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
