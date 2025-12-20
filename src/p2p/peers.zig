// Manages persistent peer identities and addresses for gossip connectivity.
// Zero-alloc, fixed-capacity implementation.
const std = @import("std");

pub const MAX_PEERS: usize = 256;

pub const Peer = struct {
    pub_key: [32]u8,
    ip: std.net.Address,
};

/// Fixed-capacity peer manager with on-disk round-trip using stack buffers.
pub const PeerManager = struct {
    peers: [MAX_PEERS]Peer = undefined,
    len: usize = 0,
    file_path: []const u8,

    fn hexNibble(c: u8) !u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidPubKey,
        };
    }

    fn decodePubKey(hex: []const u8) ![32]u8 {
        if (hex.len != 64) return error.InvalidPubKey;
        var out: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const hi = try hexNibble(hex[i * 2]);
            const lo = try hexNibble(hex[i * 2 + 1]);
            out[i] = (hi << 4) | lo;
        }
        return out;
    }

    /// Initialize an empty peer manager bound to a file path.
    pub fn init(_: std.mem.Allocator, file_path: []const u8) PeerManager {
        return .{
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *PeerManager) void {
        _ = self;
    }

    /// Add a peer from hex pubkey and ip:port, then persist to disk.
    pub fn add(self: *PeerManager, pub_key_hex: []const u8, ip_str: []const u8) !void {
        // Load existing peers so repeated CLI calls append instead of overwriting.
        self.load() catch {};

        if (self.len == self.peers.len) return error.TableFull;

        const key_bytes = try decodePubKey(pub_key_hex);

        var iter = std.mem.splitScalar(u8, ip_str, ':');
        const ip_part = iter.next() orelse return error.InvalidAddress;
        const port_part = iter.next() orelse "7777";
        const port = try std.fmt.parseInt(u16, port_part, 10);

        const address = try std.net.Address.resolveIp(ip_part, port);

        // Avoid duplicate entries if the peer already exists.
        for (self.peers[0..self.len]) |p| {
            if (std.mem.eql(u8, &p.pub_key, &key_bytes) and p.ip.eql(address)) {
                return;
            }
        }

        self.peers[self.len] = .{ .pub_key = key_bytes, .ip = address };
        self.len += 1;

        try self.save();
    }

    /// Persist the peer list to the configured file.
    fn save(self: *PeerManager) !void {
        const file = try std.fs.cwd().createFile(self.file_path, .{ .truncate = true });
        defer file.close();
        var line_buf: [256]u8 = undefined;

        for (self.peers[0..self.len]) |p| {
            var hex_buf: [64]u8 = undefined;
            for (p.pub_key, 0..) |b, idx| {
                const pos = idx * 2;
                const hi = "0123456789abcdef"[b >> 4];
                const lo = "0123456789abcdef"[b & 0x0f];
                hex_buf[pos] = hi;
                hex_buf[pos + 1] = lo;
            }

            var ip_buf: [128]u8 = undefined;
            const ip_str = try std.fmt.bufPrint(&ip_buf, "{f}", .{p.ip});

            const line = try std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ hex_buf, ip_str });
            try file.writeAll(line);
        }
    }

    /// Load peers from the configured file if present.
    pub fn load(self: *PeerManager) !void {
        self.len = 0;

        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        var buf: [64 * 1024]u8 = undefined;
        const read_len = try file.readAll(&buf);
        var content = buf[0..read_len];
        while (content.len > 0) {
            const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
            const line = content[0..line_end];
            content = if (line_end < content.len) content[line_end + 1 ..] else content[content.len..];
            if (line.len == 0) continue;

            var parts = std.mem.splitScalar(u8, line, ' ');
            const hex = parts.next() orelse continue;
            const addr_str = parts.next() orelse continue;
            if (self.len == self.peers.len) return error.TableFull;

            var key_bytes: [32]u8 = undefined;
            if (std.fmt.hexToBytes(&key_bytes, hex) catch null == null) continue;

            var addr_it = std.mem.splitScalar(u8, addr_str, ':');
            const ip_part = addr_it.next() orelse continue;
            const port_part = addr_it.next() orelse "7777";
            const port = std.fmt.parseInt(u16, port_part, 10) catch continue;
            const address = std.net.Address.resolveIp(ip_part, port) catch continue;

            self.peers[self.len] = .{ .pub_key = key_bytes, .ip = address };
            self.len += 1;
        }
    }
};

test "PeerManager: add/save/load round-trips peers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_root, "peers.list" });
    defer allocator.free(file_path);

    const pk_hex = "0101010101010101010101010101010101010101010101010101010101010101"; // 32 bytes hex

    var mgr = PeerManager.init(allocator, file_path);
    try mgr.add(pk_hex, "127.0.0.1:7777");
    try std.testing.expectEqual(@as(usize, 1), mgr.len);

    var mgr_reload = PeerManager.init(allocator, file_path);
    try mgr_reload.load();

    try std.testing.expectEqual(@as(usize, 1), mgr_reload.len);
    try std.testing.expectEqualSlices(u8, &mgr.peers[0].pub_key, &mgr_reload.peers[0].pub_key);
}
