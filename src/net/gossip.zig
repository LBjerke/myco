// Gossip helper for summarizing and comparing service versions between peers (no alloc).
// This file implements the `GossipEngine`, which is central to how Myco nodes
// summarize and compare service versions with their peers without incurring
// dynamic memory allocations. It provides functionalities to generate
// a compact summary of local services, compare this summary against remote
// peer summaries to determine needed updates, and parse various gossip-related
// payloads. This module is crucial for decentralized service state discovery
// and synchronization across the Myco network.
//
const std = @import("std");
const limits = @import("../core/limits.zig");
const Node = @import("../node.zig").Node;
const Packet = @import("../packet.zig").Packet;
const json_noalloc = @import("../util/json_noalloc.zig");
const noalloc_guard = @import("../util/noalloc_guard.zig");

/// Minimal view of a service for gossip comparison.
pub const ServiceSummary = struct {
    name: []const u8,
    version: u64,
};

const payload_capacity = @sizeOf(@TypeOf(@as(Packet, undefined).payload));
const summary_entry_overhead: usize = 22; // {"name":"..","version":<u64>}

fn decimalLen(value: u64) usize {
    var v = value;
    var len: usize = 1;
    while (v >= 10) : (v /= 10) {
        len += 1;
    }
    return len;
}

fn jsonEscapedLen(input: []const u8) usize {
    var len: usize = 0;
    for (input) |byte| {
        if (byte == '"' or byte == '\\') {
            len += 2;
        } else if (byte == '\n' or byte == '\r' or byte == '\t' or byte == 0x08 or byte == 0x0c) {
            len += 2;
        } else if (byte <= 0x1f) {
            len += 6;
        } else {
            len += 1;
        }
    }
    return len;
}

fn summaryEntrySize(name: []const u8, version: u64) usize {
    return summary_entry_overhead + jsonEscapedLen(name) + decimalLen(version);
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
    pub fn generateSummary(self: *GossipEngine, node: *Node) []const ServiceSummary {
        noalloc_guard.check();
        self.summary_len = 0;

        const slots = node.serviceSlots();
        if (slots.len == 0) return self.summaries[0..0];

        var used: usize = 2; // "[]"
        var idx: usize = node.gossip_cursor % slots.len;
        var scanned: usize = 0;
        while (scanned < slots.len and self.summary_len < limits.MAX_GOSSIP_SUMMARY) : (scanned += 1) {
            const slot = slots[idx];
            if (slot.active) {
                const name = slot.service.getName();
                if (name.len <= limits.MAX_SERVICE_NAME) {
                    const version = node.getVersion(slot.id);
                    const entry_size = summaryEntrySize(name, version);
                    const comma: usize = if (self.summary_len > 0) 1 else 0;
                    if (used + entry_size + comma > payload_capacity) {
                        node.gossip_cursor = idx;
                        return self.summaries[0..self.summary_len];
                    }
                    @memcpy(self.summary_name_bufs[self.summary_len][0..name.len], name);
                    self.summaries[self.summary_len] = .{
                        .name = self.summary_name_bufs[self.summary_len][0..name.len],
                        .version = version,
                    };
                    self.summary_len += 1;
                    used += entry_size + comma;
                }
            }

            idx += 1;
            if (idx == slots.len) idx = 0;
        }

        node.gossip_cursor = idx;
        return self.summaries[0..self.summary_len];
    }

    /// Compare remote summary to local state; returns names to fetch (capped).
    pub fn compare(self: *GossipEngine, node: *const Node, remote_list: []const ServiceSummary) []const []const u8 {
        noalloc_guard.check();
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
        noalloc_guard.check();
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
        noalloc_guard.check();
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
