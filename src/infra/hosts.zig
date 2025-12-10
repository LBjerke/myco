const std = @import("std");
const Config = @import("../core/config.zig");
const PeerManager = @import("../net/peers.zig").PeerManager;

pub const HostsManager = struct {
    allocator: std.mem.Allocator,

    const MARKER_START = "# --- MYCO START ---";
    const MARKER_END = "# --- MYCO END ---";
    const HOSTS_FILE = "/etc/hosts";

    pub fn init(allocator: std.mem.Allocator) HostsManager {
        return .{ .allocator = allocator };
    }

    /// Rebuilds the /etc/hosts entries based on peers and services
    pub fn update(self: *HostsManager) !void {
        var entries = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer entries.deinit(self.allocator);

        const writer = entries.writer(self.allocator);

        try writer.writeAll(MARKER_START);
        try writer.writeAll("\n");

        // A. Add Peers
        var pm = PeerManager.init(self.allocator);
        defer pm.deinit();

        if (pm.loadAll()) |list| {
            var p_list = list;
            defer p_list.deinit(pm.arena.allocator());

            for (p_list.items) |p| {
                try writer.print("{s}\t{s}\n", .{ p.ip, p.alias });
            }
        } else |_| {}

        // B. Add Local Services
        var loader = Config.ConfigLoader.init(self.allocator);
        defer loader.deinit();

        const configs = loader.loadAll("services") catch &[_]Config.ServiceConfig{};

        for (configs) |svc| {
            try writer.print("127.0.0.1\t{s}\n", .{svc.name});
        }

        try writer.writeAll(MARKER_END);
        try writer.writeAll("\n");

        try self.patchFile(entries.items);
    }

    fn patchFile(self: *HostsManager, new_block: []const u8) !void {
        // FIX: Check writability BEFORE opening to avoid EROFS panic on NixOS
        // W_OK = 2. We verify we can write.
        std.posix.access(HOSTS_FILE, 2) catch return;

        // Note: We use a catch block here just in case open still fails
        const file = std.fs.cwd().openFile(HOSTS_FILE, .{ .mode = .read_write }) catch return;
        defer file.close();

        const stat = try file.stat();

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);

        const content = try reader.file.readToEndAlloc(self.allocator, @intCast(stat.size));
        defer self.allocator.free(content);

        var output = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer output.deinit(self.allocator);

        const start_idx = std.mem.indexOf(u8, content, MARKER_START);
        const end_idx = std.mem.indexOf(u8, content, MARKER_END);

        if (start_idx != null and end_idx != null) {
            try output.appendSlice(self.allocator, content[0..start_idx.?]);
            try output.appendSlice(self.allocator, new_block);
            const suffix_start = end_idx.? + MARKER_END.len + 1;
            if (suffix_start < content.len) {
                try output.appendSlice(self.allocator, content[suffix_start..]);
            }
        } else {
            try output.appendSlice(self.allocator, content);
            if (!std.mem.endsWith(u8, content, "\n")) try output.appendSlice(self.allocator, "\n");
            try output.appendSlice(self.allocator, new_block);
        }

        try file.seekTo(0);
        try file.setEndPos(0);

        _ = try std.posix.write(file.handle, output.items);
    }
};
