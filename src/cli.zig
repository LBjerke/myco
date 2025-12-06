const std = @import("std");
const UX = @import("ux.zig").UX;
const Config = @import("config.zig");
const Nix = @import("nix.zig");
const Systemd = @import("systemd.zig");

// Context to pass around
pub const Context = struct {
    allocator: std.mem.Allocator,
    ux: *UX,
    args: std.process.ArgIterator,

    pub fn nextArg(self: *Context) ?[]const u8 {
        return self.args.next();
    }
};

pub const CommandHandlers = struct {
    pub fn up(ctx: *Context) !void {
        var loader = Config.ConfigLoader.init(ctx.allocator);
        defer loader.deinit();

        // Ensure directory exists
        std.fs.cwd().makeDir("services") catch {};

        try ctx.ux.step("Loading services...", .{});
        const configs = try loader.loadAll("services");

        if (configs.len == 0) {
            ctx.ux.fail("No services found in ./services/. Run 'myco init' first.", .{});
            return;
        }
        ctx.ux.success("Found {d} service(s)", .{configs.len});

        for (configs) |svc| {
            try ctx.ux.step("Building {s} ({s})", .{ svc.name, svc.package });

            var new_nix = Nix.Nix.init(ctx.allocator);
            const store_path = new_nix.build(svc.package) catch |err| {
                ctx.ux.fail("Build failed: {}", .{err});
                continue;
            };
            defer ctx.allocator.free(store_path);
            ctx.ux.success("Built {s}", .{svc.name});

            try ctx.ux.step("Starting {s}", .{svc.name});
            Systemd.apply(ctx.allocator, svc, store_path) catch |err| {
                ctx.ux.fail("Start failed: {}", .{err});
                continue;
            };
            ctx.ux.success("{s} is running!", .{svc.name});
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
        try Systemd.showLogs(ctx.allocator, name);
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
        try file.writeAll(json_content);

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
        return CommandHandlers.help(&ctx);
    };

    var ctx = Context{ .allocator = allocator, .ux = ux, .args = args };

    if (std.mem.eql(u8, cmd_str, "up")) {
        return CommandHandlers.up(&ctx);
    } else if (std.mem.eql(u8, cmd_str, "init")) {
        return CommandHandlers.init(&ctx);
    } else if (std.mem.eql(u8, cmd_str, "logs")) { // <--- Added
        return CommandHandlers.logs(&ctx);
    } else {
        return CommandHandlers.help(&ctx);
    }
}
