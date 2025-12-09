const std = @import("std");
const UX = @import("util/ux.zig").UX;
const Identity = @import("net/identity.zig").Identity;
const Orchestrator = @import("core/orchestrator.zig").Orchestrator;
const Transport = @import("net/transport.zig").Server;
const Watchdog = @import("infra/watchdog.zig").Watchdog;
const Config = @import("core/config.zig");

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
        while (true) std.Thread.sleep(1 * std.time.ns_per_s);
    }
};
