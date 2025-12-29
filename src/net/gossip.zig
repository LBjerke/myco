// Gossip helper for summarizing and comparing service versions between peers (no alloc).
const std = @import("std");
const limits = @import("../core/limits.zig");
const Node = @import("../node.zig").Node;
const Packet = @import("../packet.zig").Packet;
const json_noalloc = @import("../util/json_noalloc.zig");

/// Minimal view of a service for gossip comparison.
pub const ServiceSummary = struct {
    name: []const u8,
    version: u64,
};

comptime {
    const payload_size = @sizeOf(@TypeOf(@as(Packet, undefined).payload));
    const max_entry_len = 9 + limits.MAX_SERVICE_NAME + 12 + 20 + 1; // {"name":"..","version":<u64>}
    const max_entries = (payload_size - 1) / (max_entry_len + 1); // commas between entries
    if (limits.MAX_GOSSIP_SUMMARY > max_entries) {
        @compileError("MAX_GOSSIP_SUMMARY exceeds packet payload capacity");
    }
}

/// Engine for building and comparing gossip summaries against local node state.
pub const GossipEngine = struct {
    summaries: [limits.MAX_GOSSIP_SUMMARY]ServiceSummary = undefined,
    summary_name_bufs: [limits.MAX_GOSSIP_SUMMARY][limits.MAX_SERVICE_NAME]u8 = undefined,
    summary_len: usize = 0,

    needed_names: [limits.MAX_GOSSIP_SUMMARY][]const u8 = undefined,
    needed_name_bufs: [limits.MAX_GOSSIP_SUMMARY][limits.MAX_SERVICE_NAME]u8 = undefined,
    needed_len: usize = 0,

    pub fn init() GossipEngine {
        return .{};
    }

    /// Generate a summary of local services, capped to MAX_GOSSIP_SUMMARY entries.
    pub fn generateSummary(self: *GossipEngine, node: *const Node) []const ServiceSummary {
        self.summary_len = 0;
        for (node.serviceSlots()) |slot| {
            if (!slot.active) continue;
            if (self.summary_len >= limits.MAX_GOSSIP_SUMMARY) break;

            const name = slot.service.getName();
            if (name.len > limits.MAX_SERVICE_NAME) continue;

            @memcpy(self.summary_name_bufs[self.summary_len][0..name.len], name);
            self.summaries[self.summary_len] = .{
                .name = self.summary_name_bufs[self.summary_len][0..name.len],
                .version = node.getVersion(slot.id),
            };
            self.summary_len += 1;
        }
        return self.summaries[0..self.summary_len];
    }

    /// Compare remote summary to local state; returns names to fetch (capped).
    pub fn compare(self: *GossipEngine, node: *const Node, remote_list: []const ServiceSummary) []const []const u8 {
        self.needed_len = 0;
        for (remote_list) |remote| {
            if (self.needed_len >= limits.MAX_GOSSIP_SUMMARY) break;
            const local = node.getServiceByName(remote.name);
            if (local) |svc| {
                const local_version = node.getVersion(svc.id);
                if (remote.version > local_version) {
                    self.addNeeded(remote.name);
                }
            } else {
                self.addNeeded(remote.name);
            }
        }
        return self.needed_names[0..self.needed_len];
    }

    fn addNeeded(self: *GossipEngine, name: []const u8) void {
        if (self.needed_len >= limits.MAX_GOSSIP_SUMMARY) return;
        if (name.len > limits.MAX_SERVICE_NAME) return;
        @memcpy(self.needed_name_bufs[self.needed_len][0..name.len], name);
        self.needed_names[self.needed_len] = self.needed_name_bufs[self.needed_len][0..name.len];
        self.needed_len += 1;
    }

    pub fn parseSummary(self: *GossipEngine, input: []const u8) ![]const ServiceSummary {
        var idx: usize = 0;
        self.summary_len = 0;
        try json_noalloc.expectChar(input, &idx, '[');

        while (true) {
            json_noalloc.skipWhitespace(input, &idx);
            if (idx >= input.len) return error.UnexpectedToken;
            if (input[idx] == ']') {
                idx += 1;
                break;
            }

            try json_noalloc.expectChar(input, &idx, '{');
            var name: []const u8 = "";
            var version: u64 = 0;

            while (true) {
                var key_buf: [16]u8 = undefined;
                const key = try json_noalloc.parseString(input, &idx, key_buf[0..]);
                try json_noalloc.expectChar(input, &idx, ':');

                if (std.mem.eql(u8, key, "name")) {
                    if (self.summary_len >= limits.MAX_GOSSIP_SUMMARY) return error.GossipSummaryFull;
                    name = try json_noalloc.parseString(input, &idx, self.summary_name_bufs[self.summary_len][0..]);
                } else if (std.mem.eql(u8, key, "version")) {
                    version = try json_noalloc.parseU64(input, &idx);
                } else {
                    try json_noalloc.skipValue(input, &idx);
                }

                json_noalloc.skipWhitespace(input, &idx);
                if (idx >= input.len) return error.UnexpectedToken;
                if (input[idx] == ',') {
                    idx += 1;
                    continue;
                }
                if (input[idx] == '}') {
                    idx += 1;
                    break;
                }
                return error.UnexpectedToken;
            }

            if (name.len > 0) {
                self.summaries[self.summary_len] = .{ .name = name, .version = version };
                self.summary_len += 1;
            }

            json_noalloc.skipWhitespace(input, &idx);
            if (idx >= input.len) return error.UnexpectedToken;
            if (input[idx] == ',') {
                idx += 1;
                continue;
            }
            if (input[idx] == ']') {
                idx += 1;
                break;
            }
            return error.UnexpectedToken;
        }

        return self.summaries[0..self.summary_len];
    }

    pub fn parseNameList(self: *GossipEngine, input: []const u8) ![]const []const u8 {
        var idx: usize = 0;
        self.needed_len = 0;
        try json_noalloc.expectChar(input, &idx, '[');

        while (true) {
            json_noalloc.skipWhitespace(input, &idx);
            if (idx >= input.len) return error.UnexpectedToken;
            if (input[idx] == ']') {
                idx += 1;
                break;
            }

            if (self.needed_len >= limits.MAX_GOSSIP_SUMMARY) return error.GossipSummaryFull;
            const name = try json_noalloc.parseString(input, &idx, self.needed_name_bufs[self.needed_len][0..]);
            self.needed_names[self.needed_len] = name;
            self.needed_len += 1;

            json_noalloc.skipWhitespace(input, &idx);
            if (idx >= input.len) return error.UnexpectedToken;
            if (input[idx] == ',') {
                idx += 1;
                continue;
            }
            if (input[idx] == ']') {
                idx += 1;
                break;
            }
            return error.UnexpectedToken;
        }

        return self.needed_names[0..self.needed_len];
    }
};
