const std = @import("std");
const UX = @import("ux.zig").UX;
const config = @import("config.zig");
const nix = @import("nix.zig");
const systemd = @import("systemd.zig");
const watchdog = @import("watchdog.zig").Watchdog;

// Context to pass around
pub const Context = struct {
    allocator: std.mem.Allocator,
    ux: *UX,
    args: std.process.ArgIterator,

    pub fn nextArg(self: *Context) ?[]const u8 {
        return self.args.next();
    }
};

pub const command_handlers = struct {
       pub fn up(ctx: *Context) !void {
        // 1. Initialize Watchdog
        // Checks environment variables. If running manually, this returns null.
        // If running under Systemd with WatchdogSec=..., this returns a struct.
        var wd_opt = try watchdog.init(ctx.allocator);
        defer if (wd_opt) |*wd| wd.deinit();

        
        if (wd_opt) |*wd| {
            try wd.start(); // Start the background pinger thread
            ctx.ux.success("Watchdog enabled (Interval: {d}us)", .{wd.interval_us});
        } else {
            // Not an error, just means we are running in a terminal manually
            try ctx.ux.step("No Watchdog detected (Running manually?)", .{});
        }

        // 2. Initialize Config Loader
        var loader = config.ConfigLoader.init(ctx.allocator);
        defer loader.deinit();

        // Ensure directory exists
        std.fs.cwd().makeDir("services") catch {};

        try ctx.ux.step("Loading services...", .{});
        const configs = try loader.loadAll("services");
        
        if (configs.len == 0) {
            ctx.ux.fail("No services found in ./services/. Run 'sudo ./myco init' first.", .{});
            return;
        }
        ctx.ux.success("Found {d} service(s)", .{configs.len});

        // 3. The Reconcile Loop
        for (configs) |svc| {
            try ctx.ux.step("Building {s} ({s})", .{svc.name, svc.package});
            
            var new_nix = nix.Nix.init(ctx.allocator);
            const store_path = new_nix.build(svc.package) catch |err| {
                ctx.ux.fail("Build failed: {}", .{err});
                continue;
            };
            defer ctx.allocator.free(store_path);
            ctx.ux.success("Built {s}", .{svc.name});

            try ctx.ux.step("Starting {s}", .{svc.name});
            systemd.apply(ctx.allocator, svc, store_path) catch |err| {
                ctx.ux.fail("Start failed: {}", .{err});
                continue;
            };
            ctx.ux.success("{s} is running!", .{svc.name});
        }

        // 4. Notify Ready & Park
        if (wd_opt) |*wd| {
            // Tell Systemd initialization is done
            wd.notifyReady();

            // CRITICAL: If we are managed by Systemd (Watchdog is active),
            // we must NOT exit. If we exit, Systemd thinks the service died/finished.
            // We enter a sleep loop to keep the process alive while the 
            // Watchdog thread keeps pinging in the background.
            
            try ctx.ux.step("Myco Daemon Active. Press Ctrl+C to stop.", .{});
            
            while (true) {
                // Sleep efficiently (10 seconds)
                std.Thread.sleep(10 * std.time.ns_per_s);
            }
        }
    }

    pub fn logs(ctx: *Context) !void {
        const name = ctx.nextArg() orelse {
            ctx.ux.fail("Missing service name. Usage: myco logs <name>", .{});
            return error.InvalidArgs;
        };

        // UX Polish: Tell them how to exit
        try ctx.ux.step("Streaming logs for {s} (Ctrl+C to exit)...", .{name});

        // This will block until the user hits Ctrl+C
        try systemd.showLogs(ctx.allocator, name);
    }
    pub fn init(ctx: *Context) !void {
        var buf: [1024]u8 = undefined;

        // 1. Ask Questions
        const name = try ctx.ux.prompt("Service Name (e.g. web)", .{}, &buf);
        const name_dupe = try ctx.allocator.dupe(u8, name);
        defer ctx.allocator.free(name_dupe); // <--- FIX: Free memory when function exits

        const pkg = try ctx.ux.prompt("Nix Package (e.g. nixpkgs#caddy)", .{}, &buf);
        const pkg_final = if (pkg.len == 0) try std.fmt.allocPrint(ctx.allocator, "nixpkgs#{s}", .{name}) else try ctx.allocator.dupe(u8, pkg);
        defer ctx.allocator.free(pkg_final); // <--- FIX: Free memory when function exits

        const port_str = try ctx.ux.prompt("Port (optional)", .{}, &buf);
        var port_val: u16 = 0;
        var has_port = false;
        if (port_str.len > 0) {
            port_val = std.fmt.parseInt(u16, port_str, 10) catch 0;
            if (port_val > 0) has_port = true;
        }

        // 2. Construct JSON String Manually (Bypassing std.json flux)
        // We use {{ and }} to escape the braces for the JSON format
        const json_content = if (has_port)
            try std.fmt.allocPrint(ctx.allocator, "{{\n    \"name\": \"{s}\",\n    \"package\": \"{s}\",\n    \"port\": {d}\n}}", .{ name_dupe, pkg_final, port_val })
        else
            try std.fmt.allocPrint(ctx.allocator, "{{\n    \"name\": \"{s}\",\n    \"package\": \"{s}\",\n    \"port\": null\n}}", .{ name_dupe, pkg_final });

        defer ctx.allocator.free(json_content);

        // 3. Write File
        const filename = try std.fmt.allocPrint(ctx.allocator, "services/{s}.json", .{name_dupe});
        defer ctx.allocator.free(filename);

        std.fs.cwd().makeDir("services") catch {};

        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        // Use writeAll directly
        var sys_buf: [4096]u8 = undefined;
        var file_writer = file.writer(&sys_buf);
        const stdout = &file_writer.interface;
        try stdout.writeAll(json_content);

        ctx.ux.success("Created {s}", .{filename});
        try ctx.ux.step("Run 'sudo ./myco up' to start it", .{});
    }

    pub fn help(ctx: *Context) !void {
        _ = ctx;
        // FIX: Use manual handle construction
        const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

        // FIX: Use writeAll with pre-formatted strings or multiple calls
        _ = stdout.writeAll("\nUsage: myco <command>\n\nCommands:\n") catch {};
        _ = stdout.writeAll("  up      Start all services defined in ./services\n") catch {};
        _ = stdout.writeAll("  init    Create a new service configuration interactively\n") catch {};
        _ = stdout.writeAll("  logs    Stream logs for a specific service\n") catch {}; // <--- Added
        _ = stdout.writeAll("  help    Show this menu\n\n") catch {};
    }
};

pub fn run(allocator: std.mem.Allocator, ux: *UX) !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    const cmd_str = args.next() orelse {
        var ctx = Context{ .allocator = allocator, .ux = ux, .args = args };
        return command_handlers.help(&ctx);
    };

    var ctx = Context{ .allocator = allocator, .ux = ux, .args = args };

    if (std.mem.eql(u8, cmd_str, "up")) {
        return command_handlers.up(&ctx);
    } else if (std.mem.eql(u8, cmd_str, "init")) {
        return command_handlers.init(&ctx);
    } else if (std.mem.eql(u8, cmd_str, "logs")) { // <--- Added
        return command_handlers.logs(&ctx);
    } else {
        return command_handlers.help(&ctx);
    }
}
