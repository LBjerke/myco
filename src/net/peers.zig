const std = @import("std");

pub const Peer = struct {
    alias: []const u8,
    ip: []const u8,
};

pub const PeerManager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) PeerManager {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *PeerManager) void {
        self.arena.deinit();
    }

    pub fn add(self: *PeerManager, alias: []const u8, ip: []const u8) !void {
        var list = try self.loadAll();

        var exists = false;
        for (list.items) |*p| {
            if (std.mem.eql(u8, p.alias, alias)) {
                p.ip = try self.arena.allocator().dupe(u8, ip);
                exists = true;
                break;
            }
        }

        if (!exists) {
            try list.append(self.arena.allocator(), Peer{
                .alias = try self.arena.allocator().dupe(u8, alias),
                .ip = try self.arena.allocator().dupe(u8, ip),
            });
        }

        try self.save(list.items);
    }

    pub fn loadAll(self: *PeerManager) !std.ArrayList(Peer) {
        const arena = self.arena.allocator();
        var list = try std.ArrayList(Peer).initCapacity(arena, 0);

        const dir_path = "/var/lib/myco";
        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, "peers.json" });
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return list;
            return err;
        };
        defer file.close();

        var sys_buf: [4096]u8 = undefined;
        var reader = file.reader(&sys_buf);
        const max_size = 1024 * 1024;
        const content = try reader.file.readToEndAlloc(arena, max_size);

        const parsed = try std.json.parseFromSlice([]Peer, arena, content, .{ .ignore_unknown_fields = true });

        for (parsed.value) |p| {
            try list.append(arena, p);
        }

        return list;
    }

    fn save(self: *PeerManager, peers: []Peer) !void {
        const dir_path = "/var/lib/myco";
        std.fs.makeDirAbsolute(dir_path) catch {};

        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, "peers.json" });
        defer self.allocator.free(path);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            const file = try std.fs.createFileAbsolute(tmp_path, .{});
            defer file.close();

            // FIX: Replaced std.json.stringify with std.fmt.allocPrint + std.json.fmt
            // This bypasses the Writer/Buffer API issues in 0.15.2
            const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(peers, .{ .whitespace = .indent_4 })});
            defer self.allocator.free(json_str);

            // Raw write to disk
            _ = try std.posix.write(file.handle, json_str);
            try std.posix.fsync(file.handle);
        }

        try std.fs.renameAbsolute(tmp_path, path);
    }

    pub fn resolve(self: *PeerManager, name: []const u8) ![]const u8 {
        const peers = try self.loadAll();
        for (peers.items) |p| {
            if (std.mem.eql(u8, p.alias, name)) {
                return p.ip;
            }
        }
        return name;
    }
};
