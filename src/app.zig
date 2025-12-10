const std = @import("std");
const UX = @import("util/ux.zig").UX;
const Identity = @import("net/identity.zig").Identity;
const Orchestrator = @import("core/orchestrator.zig").Orchestrator;
const Transport = @import("net/transport.zig").Server;
const Watchdog = @import("infra/watchdog.zig").Watchdog;
const HostsManager = @import("infra/hosts.zig").HostsManager;
const Config = @import("core/config.zig");
const PeerManager = @import("net/peers.zig").PeerManager;
const GossipEngine = @import("net/gossip.zig").GossipEngine;
const Protocol = @import("net/protocol.zig").Handshake;
const Wire = @import("net/protocol.zig").Wire;

pub const App = struct {
    allocator: std.mem.Allocator,
    ux: *UX,

    // Core Components
    identity: Identity,
    orchestrator: Orchestrator,

    // Runtime State
    transport: ?Transport = null,
    watchdog: ?Watchdog = null,

    pub fn init(allocator: std.mem.Allocator, ux: *UX) !App {
        // 1. Load Identity (Handles its own fs errors gracefully)
        const identity = try Identity.init(allocator);

        // 2. Init Orchestrator
        const orchestrator = Orchestrator.init(allocator, ux);

        return App{
            .allocator = allocator,
            .ux = ux,
            .identity = identity,
            .orchestrator = orchestrator,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.watchdog) |*wd| wd.deinit();
        // Identity and Orchestrator use the main allocator, no explicit deinit needed for them
        // unless they hold internal state (Identity keys are just bytes)
    }
    fn gossipTick(self: *App) !void {
        var pm = PeerManager.init(self.allocator);
        defer pm.deinit();
        
        // Load peers
        const list = pm.loadAll() catch return;
        var p_list = list;
        defer p_list.deinit(pm.arena.allocator());

        if (p_list.items.len == 0) return;

        // Pick Random Peer (Simple first item for now)
        const peer = p_list.items[0]; 
        
        // Parsing IP:Port
        var ip_part = peer.ip;
        var port: u16 = 7777;

        if (std.mem.indexOf(u8, peer.ip, ":")) |idx| {
            ip_part = peer.ip[0..idx];
            const port_str = peer.ip[idx+1..];
            port = std.fmt.parseInt(u16, port_str, 10) catch 7777;
        }

        // Connect
        const address = std.net.Address.parseIp4(ip_part, port) catch return;
        const stream = std.net.tcpConnectToAddress(address) catch return;
        defer stream.close();

        // Handshake
        Protocol.performClient(stream, &self.identity) catch |err| {
            self.ux.log("Gossip Handshake failed with {s}: {any}", .{peer.alias, err});
            return;
        };

        // Generate Local Summary
        var engine = GossipEngine.init(self.allocator);
        const summary = try engine.generateSummary();
        defer {
            for (summary) |s| self.allocator.free(s.name);
            self.allocator.free(summary);
        }

        // Send Gossip Packet
        try Wire.send(stream, self.allocator, .Gossip, summary);
        
        // FIX: Enter a Listen Loop. 
        // We act as a Server now, responding to requests from the peer 
        // until they close the connection.
        while (true) {
            const packet = Wire.receive(stream, self.allocator) catch |err| {
                // EndOfStream means peer is done with us. This is success.
                if (err != error.EndOfStream) {
                     self.ux.log("Gossip connection dropped: {any}", .{err});
                }
                break;
            };
            defer self.allocator.free(packet.payload);

            switch (packet.type) {
                // If peer wants to fetch config from us because we advertised it
                // If peer pushes something to us (future) or just sends keepalives
                .FetchService => {
                    self.handleClientFetch(stream, packet.payload) catch |e| {
                        self.ux.log("Failed to serve config: {any}", .{e});
                    };
                },
                // FIX: Exit loop when Server says done
                .GossipDone => {
                    // self.ux.log("Gossip exchange complete.", .{});
                    break;
                },
                else => {},
            }
        }
    }

    // Helper for gossipTick to serve files back to the peer
    fn handleClientFetch(self: *App, stream: std.net.Stream, payload: []const u8) !void {
        // Parse payload (json string name)
        const parsed_name = try std.json.parseFromSlice([]const u8, self.allocator, payload, .{});
        defer parsed_name.deinit();
        const name = parsed_name.value;

        const filename = try std.fmt.allocPrint(self.allocator, "services/{s}.json", .{name});
        defer self.allocator.free(filename);

        const file = std.fs.cwd().openFile(filename, .{}) catch {
            try Wire.send(stream, self.allocator, .Error, "Config not found");
            return;
        };
        defer file.close();

        var sys_buf: [4096]u8 = undefined;
        var reader = file.reader(&sys_buf);
        const content = try reader.file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        const parsed_cfg = try std.json.parseFromSlice(Config.ServiceConfig, self.allocator, content, .{});
        defer parsed_cfg.deinit();

        try Wire.send(stream, self.allocator, .ServiceConfig, parsed_cfg.value);
    }

    /// The Main Daemon Loop (Logic moved from cli.zig)
    pub fn startDaemon(self: *App) !void {
        // 1. Watchdog
        self.watchdog = try Watchdog.init(self.allocator);
        if (self.watchdog) |*wd| {
            try wd.start();
            self.ux.success("Watchdog enabled (Interval: {d}us)", .{wd.interval_us});
        } else {
            try self.ux.step("No Watchdog detected (Running manually?)", .{});
        }

        // 2. Transport
        // We initialize it here because it needs pointers to 'self' components
        self.transport = Transport.init(self.allocator, &self.identity, &self.orchestrator, self.ux);
        if (self.transport) |*srv| {
            try srv.start();
            self.ux.success("Mesh Network Active (Port 7777)", .{});
        }

        // 3. Initial Reconciliation
        var loader = Config.ConfigLoader.init(self.allocator);
        defer loader.deinit();

        std.fs.cwd().makeDir("services") catch {}; // Ensure dir exists

        try self.ux.step("Loading services...", .{});
        const configs = try loader.loadAll("services");

        if (configs.len == 0) {
            // Non-fatal for the daemon, just warn
            self.ux.success("No services found in ./services/ (Waiting for network)", .{});
        } else {
            self.ux.success("Found {d} service(s)", .{configs.len});
            for (configs) |svc| {
                self.orchestrator.reconcile(svc) catch continue;
            }
        }

        // 4. Notify Ready
        if (self.watchdog) |*wd| {
            wd.notifyReady();
        }

        // 5. Park
        try self.ux.step("Myco Daemon Active. Listening on :7777. Press Ctrl+C to stop.", .{});
        var hosts_mgr = HostsManager.init(self.allocator);
        while (true) {
                   self.gossipTick() catch |err| {
             self.ux.log("Gossip tick failed: {any}", .{err});
        };

            hosts_mgr.update() catch {};
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }
};
