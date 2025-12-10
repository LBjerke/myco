const std = @import("std");
const App = @import("app.zig").App;
// We still need these for specific CLI commands that act as clients
const Protocol = @import("net/protocol.zig").Handshake;
const Wire = @import("net/protocol.zig").Wire;
const Config = @import("core/config.zig");
const Systemd = @import("infra/systemd.zig"); // Needed for logs command
const BackupManager = @import("infra/backup.zig").BackupManager; // Needed for logs command
const PeerManager = @import("net/peers.zig").PeerManager;
const Monitor = @import("ui/monitor.zig").Monitor;

pub const Context = struct {
    allocator: std.mem.Allocator,
    app: *App, // <--- REPLACED 'ux' with 'app' (which contains ux)
    args: std.process.ArgIterator,

    pub fn nextArg(self: *Context) ?[]const u8 {
        return self.args.next();
    }
};

pub const CommandHandlers = struct {
    pub fn up(ctx: *Context) !void {
        // Massive Cleanup: All logic moved to App
        return ctx.app.startDaemon();
    }

    pub fn init(ctx: *Context) !void {
        var buf: [1024]u8 = undefined;
        // Access ux via app.ux
        const name = try ctx.app.ux.prompt("Service Name (e.g. web)", .{}, &buf);
        const name_dupe = try ctx.allocator.dupe(u8, name);
        defer ctx.allocator.free(name_dupe);

        const pkg = try ctx.app.ux.prompt("Nix Package (e.g. nixpkgs#caddy)", .{}, &buf);
        const pkg_final = if (pkg.len == 0) try std.fmt.allocPrint(ctx.allocator, "nixpkgs#{s}", .{name}) else try ctx.allocator.dupe(u8, pkg);
        defer ctx.allocator.free(pkg_final);

        const port_str = try ctx.app.ux.prompt("Port (optional)", .{}, &buf);
        var port_val: ?u16 = null;
        if (port_str.len > 0) {
            port_val = std.fmt.parseInt(u16, port_str, 10) catch null;
        }

        const svc = Config.ServiceConfig{
            .name = name_dupe,
            .package = pkg_final,
            .port = port_val,
        };

        try Config.ConfigLoader.save(ctx.allocator, svc);

        ctx.app.ux.success("Created services/{s}.json", .{name});
        try ctx.app.ux.step("Run 'sudo ./myco up' to start it", .{});
    }

    pub fn deploy(ctx: *Context) !void {
        const name = ctx.nextArg() orelse return error.InvalidArgs;
        const target_raw = ctx.nextArg() orelse return error.InvalidArgs;

        // RESOLVE ALIAS
        var pm = PeerManager.init(ctx.allocator);
        defer pm.deinit();
        const ip_str = try pm.resolve(target_raw);

        // 1. Load Local Config
        const filename = try std.fmt.allocPrint(ctx.allocator, "services/{s}.json", .{name});
        defer ctx.allocator.free(filename);

        const file = std.fs.cwd().openFile(filename, .{}) catch {
            ctx.app.ux.fail("Could not find {s}", .{filename});
            return error.FileNotFound;
        };
        defer file.close();

        // Read and Parse
        var sys_buf: [4096]u8 = undefined;
        var reader = file.reader(&sys_buf);
        const content = try reader.file.readToEndAlloc(ctx.allocator, 1024 * 1024);
        defer ctx.allocator.free(content);

        const parsed = try std.json.parseFromSlice(Config.ServiceConfig, ctx.allocator, content, .{});
        defer parsed.deinit();

        // 2. Connect
        // Access Identity from App
        const address = try std.net.Address.parseIp4(ip_str, 7777);

        try ctx.app.ux.step("Connecting to {s}...", .{ip_str});
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        try Protocol.performClient(stream, &ctx.app.identity);
        ctx.app.ux.success("Authenticated", .{});

        // 3. Send
        try ctx.app.ux.step("Deploying {s} to remote node...", .{name});
        try Wire.send(stream, ctx.allocator, .DeployService, parsed.value);

        // 4. Wait for Ack
        const packet = try Wire.receive(stream, ctx.allocator);
        defer ctx.allocator.free(packet.payload);

        ctx.app.ux.success("Deployment command sent!", .{});
    }

    pub fn logs(ctx: *Context) !void {
        const name = ctx.nextArg() orelse return error.InvalidArgs;
        try ctx.app.ux.step("Streaming logs for {s} (Ctrl+C to exit)...", .{name});
        try Systemd.showLogs(ctx.allocator, name);
    }

    pub fn id(ctx: *Context) !void {
        // Access Identity from App directly
        const pub_key = try ctx.app.identity.getPublicKeyHex();
        defer ctx.allocator.free(pub_key);

        // Re-init? No, app.init() already loaded it.
        // But we might want to ensure we print what's in memory
        try ctx.app.ux.step("Loading Identity...", .{});
        ctx.app.ux.success("Node ID: {s}", .{pub_key});
    }

    pub fn ping(ctx: *Context) !void {
        const ip_str = ctx.nextArg() orelse "127.0.0.1";

        try ctx.app.ux.step("Connecting to {s}:7777...", .{ip_str});
        const address = try std.net.Address.parseIp4(ip_str, 7777);
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();
        try ctx.app.ux.step("Performing Handshake...", .{});

        try Protocol.performClient(stream, &ctx.app.identity);
        ctx.app.ux.success("Handshake Valid!", .{});
    }

    pub fn list_remote(ctx: *Context) !void {
        const ip_str = ctx.nextArg() orelse "127.0.0.1";

        const address = try std.net.Address.parseIp4(ip_str, 7777);
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        try Protocol.performClient(stream, &ctx.app.identity);
        ctx.app.ux.success("Authenticated", .{});

        try ctx.app.ux.step("Requesting Service List...", .{});
        try Wire.send(stream, ctx.allocator, .ListServices, .{});

        const packet = try Wire.receive(stream, ctx.allocator);
        defer ctx.allocator.free(packet.payload);

        if (packet.type == .ServiceList) {
            ctx.app.ux.success("Remote Services:", .{});
            const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
            _ = stdout.writeAll(packet.payload) catch {};
            _ = stdout.writeAll("\n") catch {};
        }
    }
    pub fn peer(ctx: *Context) !void {
        const action = ctx.nextArg() orelse "list";

        var pm = PeerManager.init(ctx.allocator);
        defer pm.deinit();

        if (std.mem.eql(u8, action, "add")) {
            const alias = ctx.nextArg() orelse return error.InvalidArgs;
            const ip = ctx.nextArg() orelse return error.InvalidArgs;

            try pm.add(alias, ip);
            ctx.app.ux.success("Added peer {s} ({s})", .{ alias, ip });
        }        else if (std.mem.eql(u8, action, "remove")) { // <--- NEW BLOCK
            const alias = ctx.nextArg() orelse return error.InvalidArgs;
            try pm.remove(alias);
            ctx.app.ux.success("Removed peer {s}", .{alias});
        } else if (std.mem.eql(u8, action, "list")) {
            const list = try pm.loadAll();
            if (list.items.len == 0) {
                try ctx.app.ux.step("No peers found. Use 'peer add <name> <ip>'", .{});
                return;
            }

            const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
            // Manual format to avoid buffered writer issues
            for (list.items) |p| {
                var buf: [256]u8 = undefined;
                // Simple formatting: alias [space] ip
                if (std.fmt.bufPrint(&buf, "{s} \t {s}\n", .{ p.alias, p.ip })) |s| {
                    _ = stdout.writeAll(s) catch {};
                } else |_| {}
            }
        }
    }
    // Inside CommandHandlers
    pub fn monitor(ctx: *Context) !void {
        // We don't use ctx.ux steps here because the monitor takes over the screen
        var mon = Monitor.init(ctx.allocator);
        try mon.run();
    }

    pub fn pull(ctx: *Context) !void {
        const target_raw = ctx.nextArg() orelse return error.InvalidArgs;
        const service_name = ctx.nextArg() orelse return error.InvalidArgs;

        // Resolve Peer
        var pm = PeerManager.init(ctx.allocator);
        defer pm.deinit();
        const ip_str = try pm.resolve(target_raw);

        // Connect
        const address = try std.net.Address.parseIp4(ip_str, 7777);
        try ctx.app.ux.step("Connecting to {s}...", .{ip_str});
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        try Protocol.performClient(stream, &ctx.app.identity);
        ctx.app.ux.success("Authenticated", .{});

        try ctx.app.ux.step("Fetching {s}...", .{service_name});
        try Wire.send(stream, ctx.allocator, .FetchService, service_name);

        const packet = try Wire.receive(stream, ctx.allocator);
        defer ctx.allocator.free(packet.payload);

        // HANDLE RESPONSE TYPES
        switch (packet.type) {
            .ServiceConfig => {
                const parsed = try std.json.parseFromSlice(Config.ServiceConfig, ctx.allocator, packet.payload, .{});
                defer parsed.deinit();

                try Config.ConfigLoader.save(ctx.allocator, parsed.value);
                ctx.app.ux.success("Saved services/{s}.json", .{parsed.value.name});
                try ctx.app.ux.step("Run 'sudo ./myco up' to start it.", .{});
            },
            .Error => {
                // Parse the error message (it's a JSON string)
                const parsed_msg = try std.json.parseFromSlice([]const u8, ctx.allocator, packet.payload, .{});
                defer parsed_msg.deinit();
                ctx.app.ux.fail("Remote Error: {s}", .{parsed_msg.value});
            },
            else => {
                ctx.app.ux.fail("Unexpected response type: {any}", .{packet.type});
            },
        }
    }
    /// Send a snapshot file to a remote node
    /// Usage: myco send-snapshot <filepath> <ip>
    pub fn send_snapshot(ctx: *Context) !void {
        const file_path = ctx.nextArg() orelse return error.InvalidArgs;
        const ip_str = ctx.nextArg() orelse return error.InvalidArgs;

        // 1. Open File & Get Stats
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();
        const filename = std.fs.path.basename(file_path);

        // 2. Connect
        // (Peer Resolution logic here if you want aliases)
        const address = try std.net.Address.parseIp4(ip_str, 7777);
        try ctx.app.ux.step("Connecting to {s}...", .{ip_str});
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        try Protocol.performClient(stream, &ctx.app.identity);
        ctx.app.ux.success("Authenticated", .{});

        // 3. Send Header
        try ctx.app.ux.step("Sending header...", .{});
        const header = .{ .filename = filename, .size = stat.size };
        try Wire.send(stream, ctx.allocator, .UploadStart, header);

        // 4. Stream Body
        try ctx.app.ux.step("Streaming data ({d} bytes)...", .{stat.size});
        try Wire.streamSend(stream, file, stat.size);

        // 5. Wait for Ack
        const packet = try Wire.receive(stream, ctx.allocator);
        defer ctx.allocator.free(packet.payload);
        
        ctx.app.ux.success("Snapshot sent successfully!", .{});
    }
       pub fn snapshot(ctx: *Context) !void {
        const name = ctx.nextArg() orelse return error.InvalidArgs;
        
        var bm = BackupManager.init(ctx.allocator);
        
        try ctx.app.ux.step("Creating snapshot for {s}...", .{name});
        try bm.createSnapshot(name);
        ctx.app.ux.success("Backup created successfully", .{});
    }
         pub fn restore(ctx: *Context) !void {
        const name = ctx.nextArg() orelse return error.InvalidArgs;
        const file = ctx.nextArg() orelse return error.InvalidArgs;

        var bm = BackupManager.init(ctx.allocator);

        // UX: Ask for confirmation (using prompt logic)
        // Note: For now we skip the "Are you sure?" prompt to keep the CLI simple, 
        // but in a real product, you'd add:
        // const confirm = try ctx.app.ux.prompt("Are you sure? (y/n)", .{}, &buf);
        // if (!eql(confirm, "y")) return;

        try ctx.app.ux.step("Restoring {s}...", .{name});
        try bm.restoreSnapshot(name, file);
        ctx.app.ux.success("Service restored successfully", .{});
    }
    pub fn help(ctx: *Context) !void {
        _ = ctx;
        const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        _ = stdout.writeAll("\nCommands: up, init, deploy, logs, id, ping, list-remote, peer\n") catch {};
    }
};

pub fn run(allocator: std.mem.Allocator, app: *App) !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    // Create context with APP instead of UX
    var ctx = Context{ .allocator = allocator, .app = app, .args = args };

    const cmd_str = ctx.args.next() orelse {
        return CommandHandlers.help(&ctx);
    };

    if (std.mem.eql(u8, cmd_str, "up")) return CommandHandlers.up(&ctx);
    if (std.mem.eql(u8, cmd_str, "init")) return CommandHandlers.init(&ctx);
    if (std.mem.eql(u8, cmd_str, "deploy")) return CommandHandlers.deploy(&ctx);
    if (std.mem.eql(u8, cmd_str, "logs")) return CommandHandlers.logs(&ctx);
    if (std.mem.eql(u8, cmd_str, "id")) return CommandHandlers.id(&ctx);
    if (std.mem.eql(u8, cmd_str, "ping")) return CommandHandlers.ping(&ctx);
    if (std.mem.eql(u8, cmd_str, "list-remote")) return CommandHandlers.list_remote(&ctx);
    if (std.mem.eql(u8, cmd_str, "peer")) return CommandHandlers.peer(&ctx);
    if (std.mem.eql(u8, cmd_str, "monitor")) return CommandHandlers.monitor(&ctx);
    if (std.mem.eql(u8, cmd_str, "pull")) return CommandHandlers.pull(&ctx);
    if (std.mem.eql(u8, cmd_str, "snapshot")) return CommandHandlers.snapshot(&ctx);
    if (std.mem.eql(u8, cmd_str, "restore")) return CommandHandlers.restore(&ctx);
    if (std.mem.eql(u8, cmd_str, "send-snapshot")) return CommandHandlers.send_snapshot(&ctx);
    return CommandHandlers.help(&ctx);
}
