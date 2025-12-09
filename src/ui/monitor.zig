const std = @import("std");
const PeerManager = @import("../net/peers.zig").PeerManager;
const Peer = @import("../net/peers.zig").Peer;

pub const Monitor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Monitor {
        return .{ .allocator = allocator };
    }

    pub fn run(self: *Monitor) !void {
        const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

        _ = stdout.writeAll("\x1b[?25l") catch {};
        defer {
            _ = stdout.writeAll("\x1b[?25h") catch {};
        }

        while (true) {
            // Init PM per frame to reset memory arena
            var pm = PeerManager.init(self.allocator);

            _ = stdout.writeAll("\x1b[2J\x1b[H") catch {};
            try self.drawHeader(stdout);

            // FIX: Removed unused 'var peers' logic. Used if/else on the result directly.
            if (pm.loadAll()) |list| {
                // We own the list structure, but items are in pm.arena
                var p_list = list;

                if (p_list.items.len == 0) {
                    _ = stdout.writeAll("\n  No peers configured. Run 'myco peer add <name> <ip>'\n") catch {};
                } else {
                    for (p_list.items) |p| {
                        const status = self.checkHealth(p.ip);
                        try self.drawRow(stdout, p.alias, p.ip, status);
                    }
                }

                // FIX: Pass the arena allocator to deinit
                p_list.deinit(pm.arena.allocator());
            } else |_| {
                _ = stdout.writeAll("\n  [!] Error loading peers database.\n") catch {};
            }

            // Cleanup PM (frees all strings loaded this frame)
            pm.deinit();

            _ = stdout.writeAll("\n[Ctrl+C] to Quit\n") catch {};
            std.Thread.sleep(2 * std.time.ns_per_s);
        }
    }

    fn drawHeader(self: *Monitor, out: std.fs.File) !void {
        //       _ = self;
        _ = out.writeAll("MYCO CLUSTER MONITOR [v0.2.0]\n") catch {};
        _ = out.writeAll("================================================================\n") catch {};
        const header = try std.fmt.allocPrint(self.allocator, "{s:<15} | {s:<20} | {s:<10}\n", .{ "ALIAS", "ADDRESS", "STATUS" });
        defer self.allocator.free(header);
        _ = out.writeAll(header) catch {};
        _ = out.writeAll("----------------------------------------------------------------\n") catch {};
    }

    fn drawRow(self: *Monitor, out: std.fs.File, alias: []const u8, ip: []const u8, status: bool) !void {
        const status_str = if (status) "\x1b[32mONLINE\x1b[0m" else "\x1b[31mDOWN\x1b[0m";
        const row = try std.fmt.allocPrint(self.allocator, "{s:<15} | {s:<20} | {s}\n", .{ alias, ip, status_str });
        defer self.allocator.free(row);
        _ = out.writeAll(row) catch {};
    }

    fn checkHealth(self: *Monitor, ip: []const u8) bool {
        _ = self;
        const address = std.net.Address.parseIp4(ip, 7777) catch return false;
        const stream = std.net.tcpConnectToAddress(address) catch return false;
        stream.close();
        return true;
    }
};
