const std = @import("std");

pub const Peer = struct {
    pub_key: [32]u8,
    ip: std.net.Address,
};

pub const PeerManager = struct {
    allocator: std.mem.Allocator,
    peers: std.ArrayList(Peer),
    file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) PeerManager {
        return .{
            .allocator = allocator,
            .peers = .{},
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *PeerManager) void {
        self.peers.deinit(self.allocator);
    }

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

 //   pub fn load(self: *PeerManager) !void {
        // (Implementation for loading from the file would go here)
  //  }
};
