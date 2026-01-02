// Persistent peer book for the CLI, backed by JSON in a state directory.
// This file manages a persistent peer book for the Myco system, used both by
// the CLI for peer configuration and by the daemon for network discovery.
// It defines the `PeerManager` struct, which provides functionalities to add,
// load, save, resolve, and remove peer information (alias and IP address)
// from a JSON file stored in the system's state directory. This module is
// crucial for maintaining a dynamic and configurable list of known peers
// within the Myco network.
//
const std = @import("std");

pub const Peer = struct {
    alias: []const u8,
    ip: []const u8,
};

/// Manages peers for CLI commands and daemon discovery.
pub const PeerManager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    /// Create a peer manager with its own arena for short-lived allocations.
    pub fn init(allocator: std.mem.Allocator) PeerManager {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Free arena allocations.
    pub fn deinit(self: *PeerManager) void {
        self.arena.deinit();
    }

    // Helper to get state dir
    fn getStateDir(allocator: std.mem.Allocator) ![]const u8 {
        if (std.posix.getenv("MYCO_STATE_DIR")) |env| {
            return allocator.dupe(u8, env);
        }
        return allocator.dupe(u8, "/var/lib/myco");
    }

    /// Add or update a peer by alias, persisting to disk.
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

    /// Load peers from disk (if present) into an arena-backed list.
    pub fn loadAll(self: *PeerManager) !std.ArrayList(Peer) {
        const arena = self.arena.allocator();
        var list = try std.ArrayList(Peer).initCapacity(arena, 0);

        // FIX: Use Env Var
        const dir_path = try getStateDir(self.allocator);
        defer self.allocator.free(dir_path);

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

    /// Atomically write peers to disk.
    fn save(self: *PeerManager, peers: []Peer) !void {
        // FIX: Use Env Var
        const dir_path = try getStateDir(self.allocator);
        defer self.allocator.free(dir_path);

        std.fs.makeDirAbsolute(dir_path) catch {};

        const path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, "peers.json" });
        defer self.allocator.free(path);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            const file = try std.fs.createFileAbsolute(tmp_path, .{});
            defer file.close();

            const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(peers, .{ .whitespace = .indent_4 })});
            defer self.allocator.free(json_str);

            _ = try std.posix.write(file.handle, json_str);
            try std.posix.fsync(file.handle);
        }

        try std.fs.renameAbsolute(tmp_path, path);
    }

    /// Resolve an alias to its IP string; falls back to returning the name.
    pub fn resolve(self: *PeerManager, name: []const u8) ![]const u8 {
        const peers = try self.loadAll();
        for (peers.items) |p| {
            if (std.mem.eql(u8, p.alias, name)) {
                return p.ip;
            }
        }
        return name;
    }

    // Support Remove command we added earlier
    /// Remove a peer by alias if it exists.
    pub fn remove(self: *PeerManager, alias: []const u8) !void {
        const list = try self.loadAll();
        var new_list = try std.ArrayList(Peer).initCapacity(self.arena.allocator(), list.items.len);

        var found = false;
        for (list.items) |p| {
            if (!std.mem.eql(u8, p.alias, alias)) {
                try new_list.append(self.arena.allocator(), p);
            } else {
                found = true;
            }
        }

        if (found) {
            try self.save(new_list.items);
        } else {
            return error.PeerNotFound;
        }
    }
};
