// Gossip helper for summarizing and comparing service versions between peers.
const std = @import("std");
const Config = @import("../core/config.zig");

/// Minimal view of a service for gossip comparison.
pub const ServiceSummary = struct {
    name: []const u8,
    version: u64,
};

/// Engine for building and comparing gossip summaries against local config state.
pub const GossipEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GossipEngine {
        return .{ .allocator = allocator };
    }

    /// Generate a summary of all local services
    pub fn generateSummary(self: *GossipEngine) ![]ServiceSummary {
        var loader = Config.ConfigLoader.init(self.allocator);
        defer loader.deinit();

        // We catch error and return empty list if dir doesn't exist
        const configs = loader.loadAll("services") catch &[_]Config.ServiceConfig{};

        var list = try std.ArrayList(ServiceSummary).initCapacity(self.allocator, configs.len);
        // Note: The strings in ServiceSummary will point to the loader's arena.
        // We must duplicate them if we want them to survive past loader.deinit.

        for (configs) |c| {
            try list.append(self.allocator, ServiceSummary{
                .name = try self.allocator.dupe(u8, c.name),
                .version = c.version,
            });
        }

        return list.toOwnedSlice(self.allocator);
    }

    /// Compare local state vs remote summary to determine which services to fetch.
    pub fn compare(self: *GossipEngine, remote_list: []const ServiceSummary) ![]const []const u8 {
        var loader = Config.ConfigLoader.init(self.allocator);
        defer loader.deinit();
        const local_configs = loader.loadAll("services") catch &[_]Config.ServiceConfig{};

        var needed = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);

        for (remote_list) |remote| {
            var found = false;
            for (local_configs) |local| {
                if (std.mem.eql(u8, remote.name, local.name)) {
                    found = true;
                    if (remote.version > local.version) {
                        // Remote is newer! We need it.
                        try needed.append(self.allocator, try self.allocator.dupe(u8, remote.name));
                    }
                }
            }
            if (!found) {
                // We don't have it at all! We need it.
                try needed.append(self.allocator, try self.allocator.dupe(u8, remote.name));
            }
        }

        return needed.toOwnedSlice(self.allocator);
    }
};
