// Persistent peer book for the CLI, zero-alloc fixed-capacity implementation.
const std = @import("std");

pub const MAX_PEERS: usize = 256;
pub const MAX_ALIAS: usize = 64;
pub const MAX_IP: usize = 64;

pub const Peer = struct {
    alias: []const u8,
    ip: []const u8,
};

pub const PeerManager = struct {
    aliases: [MAX_PEERS][MAX_ALIAS]u8 = [_][MAX_ALIAS]u8{[_]u8{0} ** MAX_ALIAS} ** MAX_PEERS,
    ips: [MAX_PEERS][MAX_IP]u8 = [_][MAX_IP]u8{[_]u8{0} ** MAX_IP} ** MAX_PEERS,
    len: usize = 0,

    pub fn init(_: std.mem.Allocator) PeerManager {
        return .{};
    }

    pub fn deinit(self: *PeerManager) void {
        _ = self;
    }

    fn sliceToNull(buf: []const u8) []const u8 {
        return std.mem.sliceTo(buf, 0);
    }

    fn setField(dst: []u8, src: []const u8) !void {
        if (src.len > dst.len) return error.TooLong;
        @memset(dst, 0);
        @memcpy(dst[0..src.len], src);
    }

    fn getStateDir() []const u8 {
        if (std.posix.getenv("MYCO_STATE_DIR")) |env| return env;
        return "/var/lib/myco";
    }

    fn peersPath(buf: []u8) ![]u8 {
        const dir = getStateDir();
        return std.fmt.bufPrint(buf, "{s}/peers.json", .{dir});
    }

    /// Add or update a peer by alias, persisting to disk.
    pub fn add(self: *PeerManager, alias: []const u8, ip: []const u8) !void {
        var idx_opt: ?usize = null;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, sliceToNull(&self.aliases[i]), alias)) {
                idx_opt = i;
                break;
            }
        }

        const idx = idx_opt orelse blk: {
            if (self.len == self.aliases.len) return error.TableFull;
            self.len += 1;
            break :blk self.len - 1;
        };

        try setField(&self.aliases[idx], alias);
        try setField(&self.ips[idx], ip);

        try self.save();
    }

    /// Load peers from disk (if present) into the fixed table.
    pub fn load(self: *PeerManager) !void {
        self.len = 0;
        var path_buf: [256]u8 = undefined;
        const path = self.peersPath(&path_buf) catch return;

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        var buf: [64 * 1024]u8 = undefined;
        const read_len = try file.readAll(&buf);
        var content = buf[0..read_len];
        while (content.len > 0 and self.len < self.aliases.len) {
            const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
            const line = content[0..line_end];
            content = if (line_end < content.len) content[line_end + 1 ..] else content[content.len..];
            if (line.len == 0) continue;

            var parts = std.mem.splitScalar(u8, line, ' ');
            const alias = parts.next() orelse continue;
            const ip = parts.next() orelse continue;

            try setField(&self.aliases[self.len], alias);
            try setField(&self.ips[self.len], ip);
            self.len += 1;
        }
    }

    /// Atomically write peers to disk.
    fn save(self: *PeerManager) !void {
        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path = try self.peersPath(&path_buf);

        var tmp_buf: [256]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

        std.fs.makeDirAbsolute(std.fs.path.dirname(path) orelse ".") catch {};

        {
            const file = try std.fs.createFileAbsolute(tmp_path, .{});
            defer file.close();
            var line_buf: [MAX_ALIAS + MAX_IP + 2]u8 = undefined;
            for (self.aliases[0..self.len], self.ips[0..self.len]) |a, ip| {
                const alias_s = sliceToNull(&a);
                const ip_s = sliceToNull(&ip);
                const line = try std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ alias_s, ip_s });
                try file.writeAll(line);
            }
            try file.sync();
        }

        try std.fs.renameAbsolute(tmp_path, path);
    }

    /// Resolve an alias to its IP string; falls back to returning the name.
    pub fn resolve(self: *PeerManager, name: []const u8) ![]const u8 {
        try self.load();
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, sliceToNull(&self.aliases[i]), name)) {
                return sliceToNull(&self.ips[i]);
            }
        }
        return name;
    }

    /// Remove a peer by alias if it exists.
    pub fn remove(self: *PeerManager, alias: []const u8) !void {
        try self.load();
        var found = false;
        var i: usize = 0;
        while (i < self.len) {
            if (std.mem.eql(u8, sliceToNull(&self.aliases[i]), alias)) {
                const last = self.len - 1;
                self.aliases[i] = self.aliases[last];
                self.ips[i] = self.ips[last];
                self.len -= 1;
                found = true;
                break;
            }
            i += 1;
        }
        if (!found) return error.PeerNotFound;
        try self.save();
    }
};
