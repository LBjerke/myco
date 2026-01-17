// Manages persistent peer identities and addresses for gossip connectivity.
// This file implements the `PeerManager`, which is responsible for managing a
// persistent list of peer identities and their corresponding network addresses.
// It provides functionalities to add new peers, save the current peer list to
// a designated file (`peers.list`), load peers from this file, and clear the
// list. This module is crucial for maintaining the connectivity graph necessary
// for gossip and other network operations within the peer-to-peer system.
//
const std = @import("std");
const limits = @import("../core/limits.zig");
const BoundedArray = @import("../util/bounded_array.zig").BoundedArray;

pub const Peer = struct {
    pub_key: [32]u8,
    ip: std.net.Address,
};

fn writeHexLower(dest: []u8, bytes: []const u8) !usize {
    const hex = "0123456789abcdef";
    if (dest.len < bytes.len * 2) return error.BufferTooSmall;
    var idx: usize = 0;
    for (bytes) |b| {
        dest[idx] = hex[(b >> 4) & 0x0f];
        dest[idx + 1] = hex[b & 0x0f];
        idx += 2;
    }
    return idx;
}

/// Tracks peer list on disk and in memory (fixed capacity).
pub const PeerManager = struct {
    peers: BoundedArray(Peer, limits.MAX_PEERS),
    file_path_buf: [limits.PATH_MAX]u8 = undefined,
    file_path_len: usize = 0,

    /// Initialize an empty peer manager bound to a file path.
    pub fn init(file_path: []const u8) !PeerManager {
        var mgr = PeerManager{
            .peers = try BoundedArray(Peer, limits.MAX_PEERS).init(0),
            .file_path_buf = undefined,
            .file_path_len = 0,
        };
        try mgr.setFilePath(file_path);
        return mgr;
    }

    fn setFilePath(self: *PeerManager, file_path: []const u8) !void {
        if (file_path.len > self.file_path_buf.len) return error.PathTooLong;
        @memcpy(self.file_path_buf[0..file_path.len], file_path);
        self.file_path_len = file_path.len;
    }

    fn filePath(self: *const PeerManager) []const u8 {
        return self.file_path_buf[0..self.file_path_len];
    }

    /// Release memory held by the peer list (no-op for fixed storage).
    pub fn deinit(self: *PeerManager) void {
        _ = self;
    }

    /// Add a peer from hex pubkey and ip:port, then persist to disk.
    pub fn add(self: *PeerManager, pub_key_hex: []const u8, ip_str: []const u8) !void {
        // Load existing peers so repeated CLI invocations accumulate instead of overwriting.
        self.load() catch {};

        var key_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&key_bytes, pub_key_hex);

        var iter = std.mem.splitScalar(u8, ip_str, ':');
        const ip_part = iter.next() orelse return error.InvalidAddress;
        const port_part = iter.next() orelse "7777";
        const port = try std.fmt.parseInt(u16, port_part, 10);

        const address = try std.net.Address.resolveIp(ip_part, port);

        // Deduplicate: update in-place if the key already exists.
        for (self.peers.buffer[0..self.peers.len]) |*p| {
            if (std.mem.eql(u8, &p.pub_key, &key_bytes)) {
                p.ip = address;
                try self.save();
                return;
            }
        }

        if (self.peers.len >= limits.MAX_PEERS) return error.PeerListFull;
        try self.peers.append(.{ .pub_key = key_bytes, .ip = address });

        try self.save();
    }

    /// Persist the peer list to the configured file.
    fn save(self: *PeerManager) !void {
        const file = try std.fs.cwd().createFile(self.filePath(), .{});
        defer file.close();

        for (self.peers.constSlice()) |p| {
            var line_buf: [limits.MAX_PEER_LINE]u8 = undefined;
            var pos = try writeHexLower(&line_buf, &p.pub_key);

            if (pos + 1 >= line_buf.len) return error.PeerLineTooLong;
            line_buf[pos] = ' ';
            pos += 1;

            var ip_buf: [limits.MAX_PEER_LINE]u8 = undefined;
            const ip_str = try std.fmt.bufPrint(&ip_buf, "{f}", .{p.ip});
            if (pos + ip_str.len + 1 > line_buf.len) return error.PeerLineTooLong;
            @memcpy(line_buf[pos..][0..ip_str.len], ip_str);
            pos += ip_str.len;

            line_buf[pos] = '\n';
            pos += 1;

            try file.writeAll(line_buf[0..pos]);
        }
    }

    fn parsePeerLine(line: []const u8) ?Peer {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) return null;

        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        const hex = parts.next() orelse return null;
        const addr_str = parts.next() orelse return null;
        var key_bytes: [32]u8 = undefined;
        if (std.fmt.hexToBytes(&key_bytes, hex) catch null == null) return null;

        var addr_it = std.mem.splitScalar(u8, addr_str, ':');
        const ip_part = addr_it.next() orelse return null;
        const port_part = addr_it.next() orelse "7777";
        const port = std.fmt.parseInt(u16, port_part, 10) catch return null;
        const address = std.net.Address.resolveIp(ip_part, port) catch return null;

        return .{ .pub_key = key_bytes, .ip = address };
    }

    /// Load peers from the configured file if present.
    pub fn load(self: *PeerManager) !void {
        self.peers.clear();

        const file = std.fs.cwd().openFile(self.filePath(), .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        var read_buf: [limits.MAX_PEER_LINE]u8 = undefined;
        var reader = file.reader(&read_buf);

        while (true) {
            const maybe_line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.PeerLineTooLong,
                else => return err,
            };
            const line = maybe_line orelse break;

            if (parsePeerLine(line)) |peer| {
                if (self.peers.len >= limits.MAX_PEERS) return error.PeerListFull;
                try self.peers.append(peer);
            }
        }
    }
};

test "PeerManager: add/save/load round-trips peers" {
    const allocator = std.testing.allocator;

    // Use zig-cache for test artifacts so we don't litter the repo root.
    const base = try std.fs.path.join(allocator, &[_][]const u8{ "zig-cache", "tmp-peers-test" });
    defer allocator.free(base);
    std.fs.cwd().makePath(base) catch {};

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ base, "peers.list" });
    defer allocator.free(file_path);
    std.fs.cwd().deleteFile(file_path) catch {}; // ensure clean slate

    const pk_hex = "0101010101010101010101010101010101010101010101010101010101010101"; // 32 bytes hex

    var mgr = try PeerManager.init(file_path);
    defer mgr.deinit();
    try mgr.add(pk_hex, "127.0.0.1:7777");
    try std.testing.expectEqual(@as(usize, 1), mgr.peers.len);

    var mgr_reload = try PeerManager.init(file_path);
    defer mgr_reload.deinit();
    try mgr_reload.load();

    try std.testing.expectEqual(@as(usize, 1), mgr_reload.peers.len);
    try std.testing.expectEqualSlices(u8, &mgr.peers.constSlice()[0].pub_key, &mgr_reload.peers.constSlice()[0].pub_key);
}
