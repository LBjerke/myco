// Manages persistent peer identities and addresses for gossip connectivity.
const std = @import("std");

pub const Peer = struct {
    pub_key: [32]u8,
    ip: std.net.Address,
};

/// Tracks peer list on disk and in memory.
pub const PeerManager = struct {
    allocator: std.mem.Allocator,
    peers: std.ArrayListUnmanaged(Peer),
    file_path: []const u8,

    /// Initialize an empty peer manager bound to a file path.
    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) PeerManager {
        return .{
            .allocator = allocator,
            .peers = .{},
            .file_path = file_path,
        };
    }

    /// Release memory held by the peer list.
    pub fn deinit(self: *PeerManager) void {
        self.peers.deinit(self.allocator);
    }

    /// Add a peer from hex pubkey and ip:port, then persist to disk.
    pub fn add(self: *PeerManager, pub_key_hex: []const u8, ip_str: []const u8) !void {
        var key_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&key_bytes, pub_key_hex);

        var iter = std.mem.splitScalar(u8, ip_str, ':');
        const ip_part = iter.next() orelse return error.InvalidAddress;
        const port_part = iter.next() orelse "7777";
        const port = try std.fmt.parseInt(u16, port_part, 10);

        const address = try std.net.Address.resolveIp(ip_part, port);

        try self.peers.append(self.allocator, .{ .pub_key = key_bytes, .ip = address });

        try self.save();
    }

    /// Persist the peer list to the configured file.
    fn save(self: *PeerManager) !void {
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(self.allocator);
        const writer = buffer.writer(self.allocator);

        for (self.peers.items) |p| {
            // 1. Manually format Hex (Robust against stdlib API flux)
            for (p.pub_key) |b| {
                try writer.print("{x:0>2}", .{b});
            }
            
            // 2. Add separator
            try writer.writeByte(' ');

            // 3. Format IP Address safely to a string buffer
            var ip_buf: [128]u8 = undefined;
            // "{}" invokes the standard format method on std.net.Address
            const ip_str = try std.fmt.bufPrint(&ip_buf, "{f}", .{p.ip});
            
            // 4. Write IP and newline
            try writer.print("{s}\n", .{ip_str});
        }

        const file = try std.fs.cwd().createFile(self.file_path, .{});
        defer file.close();

        _ = try std.posix.write(file.handle, buffer.items);
    }

    /// Load peers from the configured file if present.
    pub fn load(self: *PeerManager) !void {
        self.peers.clearRetainingCapacity();

        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(contents);

        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, ' ');
            const hex = parts.next() orelse continue;
            const addr_str = parts.next() orelse continue;
            var key_bytes: [32]u8 = undefined;
            if (std.fmt.hexToBytes(&key_bytes, hex) catch null == null) continue;

            var addr_it = std.mem.splitScalar(u8, addr_str, ':');
            const ip_part = addr_it.next() orelse continue;
            const port_part = addr_it.next() orelse "7777";
            const port = std.fmt.parseInt(u16, port_part, 10) catch continue;
            const address = std.net.Address.resolveIp(ip_part, port) catch continue;

            try self.peers.append(self.allocator, .{ .pub_key = key_bytes, .ip = address });
        }
    }
};
