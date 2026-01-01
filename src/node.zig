// Core node implementation: owns identity, service CRDT, WAL, and gossip behavior.
// Each node is a deterministic replica used by both the real system and the simulator.
const std = @import("std");
const build = @import("std").build;

const crypto_enabled = false;

const Packet = @import("packet.zig").Packet;
const Headers = @import("packet.zig").Headers;
const PacketFlags = @import("packet.zig").Flags;
const PacketPayloadLen = @import("packet.zig").PayloadLen;
const PacketPayloadAlign = @alignOf(@TypeOf(@as(Packet, undefined).payload));
const limits = @import("core/limits.zig");
const Identity = @import("net/handshake.zig").Identity;
const WAL = @import("db/wal.zig").WriteAheadLog;
const Service = @import("schema/service.zig").Service;
const ServiceStore = @import("sync/crdt.zig").ServiceStore;
const Entry = @import("sync/crdt.zig").Entry;
const Hlc = @import("sync/hlc.zig").Hlc;
const BoundedArray = @import("util/bounded_array.zig").BoundedArray;
const noalloc_guard = @import("util/noalloc_guard.zig");

const PayloadExpandedLen: usize = PacketPayloadLen * 2;
const PayloadExpandedAlign = @max(PacketPayloadAlign, @alignOf(u64));
const CompressMaxDistance: usize = 64;
const CompressMaxMatch: usize = 66;
const MissingSetSize: usize = limits.MAX_MISSING_ITEMS * 2;

comptime {
    if ((MissingSetSize & (MissingSetSize - 1)) != 0) {
        @compileError("MissingSetSize must be a power of two.");
    }
}

fn varintLen(value: u64) usize {
    var v = value;
    var len: usize = 1;
    while (v >= 0x80) {
        v >>= 7;
        len += 1;
    }
    return len;
}

fn writeVarint(value: u64, dest: []u8) usize {
    var v = value;
    var idx: usize = 0;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        dest[idx] = byte;
        idx += 1;
        if (v == 0) break;
    }
    return idx;
}

fn readVarint(src: []const u8, cursor: *usize) ?u64 {
    var shift: u6 = 0;
    var value: u64 = 0;
    while (cursor.* < src.len and shift <= 63) {
        const byte = src[cursor.*];
        cursor.* += 1;
        value |= (@as(u64, byte & 0x7f) << shift);
        if ((byte & 0x80) == 0) return value;
        if (shift > 57) return null;
        shift += 7;
    }
    return null;
}

fn zigzagEncodeI64(value: i64) u64 {
    const bits = @as(u64, @bitCast(value));
    const sign = @as(u64, @bitCast(value >> 63));
    return (bits << 1) ^ sign;
}

fn zigzagDecodeU64(value: u64) i64 {
    return @as(i64, @bitCast(value >> 1)) ^ -@as(i64, @intCast(value & 1));
}

fn compressPayload(src: []const u8, dest: []u8) ?u16 {
    if (src.len == 0 or src.len > std.math.maxInt(u16)) return null;
    if (dest.len < 2) return null;

    std.mem.writeInt(u16, dest[0..2], @intCast(src.len), .little);
    var out: usize = 2;
    var literal_start: usize = 0;
    var i: usize = 0;

    while (i < src.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        const max_dist: usize = @min(i, CompressMaxDistance);

        if (max_dist > 0) {
            var dist: usize = 1;
            while (dist <= max_dist) : (dist += 1) {
                var match_len: usize = 0;
                while (match_len < CompressMaxMatch and i + match_len < src.len and src[i + match_len] == src[i - dist + match_len]) : (match_len += 1) {}
                if (match_len >= 3 and match_len > best_len) {
                    best_len = match_len;
                    best_dist = dist;
                    if (match_len == CompressMaxMatch) break;
                }
            }
        }

        if (best_len >= 3) {
            var lit_idx: usize = literal_start;
            while (lit_idx < i) {
                const chunk: usize = @min(i - lit_idx, 128);
                if (out + 1 + chunk > dest.len) return null;
                dest[out] = @intCast(chunk - 1);
                out += 1;
                @memcpy(dest[out .. out + chunk], src[lit_idx .. lit_idx + chunk]);
                out += chunk;
                lit_idx += chunk;
            }

            if (out + 2 > dest.len) return null;
            dest[out] = 0x80 | @as(u8, @intCast(best_len - 3));
            dest[out + 1] = @intCast(best_dist);
            out += 2;
            i += best_len;
            literal_start = i;
        } else {
            i += 1;
        }
    }

    if (literal_start < src.len) {
        var lit_idx: usize = literal_start;
        while (lit_idx < src.len) {
            const chunk: usize = @min(src.len - lit_idx, 128);
            if (out + 1 + chunk > dest.len) return null;
            dest[out] = @intCast(chunk - 1);
            out += 1;
            @memcpy(dest[out .. out + chunk], src[lit_idx .. lit_idx + chunk]);
            out += chunk;
            lit_idx += chunk;
        }
    }

    if (out >= src.len) return null;
    return @intCast(out);
}

fn decompressPayload(src: []const u8, dest: []u8) ?u16 {
    if (src.len < 2) return null;

    const out_len = std.mem.readInt(u16, src[0..2], .little);
    if (out_len == 0 or out_len > dest.len) return null;

    var out_pos: usize = 0;
    var in_pos: usize = 2;

    while (out_pos < out_len and in_pos < src.len) {
        const control = src[in_pos];
        in_pos += 1;
        if ((control & 0x80) == 0) {
            const run_len: usize = @as(usize, control) + 1;
            if (in_pos + run_len > src.len or out_pos + run_len > out_len) return null;
            @memcpy(dest[out_pos .. out_pos + run_len], src[in_pos .. in_pos + run_len]);
            in_pos += run_len;
            out_pos += run_len;
        } else {
            const run_len: usize = @as(usize, control & 0x7f) + 3;
            if (in_pos >= src.len or out_pos + run_len > out_len) return null;
            const dist = src[in_pos];
            in_pos += 1;
            if (dist == 0 or dist > out_pos) return null;
            var k: usize = 0;
            while (k < run_len) : (k += 1) {
                dest[out_pos + k] = dest[out_pos + k - dist];
            }
            out_pos += run_len;
        }
    }

    if (out_pos != out_len) return null;
    return out_len;
}

/// Encode a digest using LEB128 varints to stuff as many entries as possible into the 952-byte payload.
pub fn encodeDigest(entries: []const Entry, dest: []u8) u16 {
    if (dest.len < 2) return 0;

    var cursor: usize = 2; // reserve space for count
    var written: u16 = 0;

    for (entries) |entry| {
        const needed = varintLen(entry.id) + varintLen(entry.version);
        if (cursor + needed > dest.len) break;
        cursor += writeVarint(entry.id, dest[cursor..]);
        cursor += writeVarint(entry.version, dest[cursor..]);
        written += 1;
    }

    std.mem.writeInt(u16, dest[0..2], written, .little);
    return @intCast(cursor);
}

/// Encode a digest in columnar format (ids, wall deltas, logicals) to maximize payload usage.
pub fn encodeDigestColumnar(entries: []const Entry, dest: []u8) u16 {
    if (dest.len < 2) return 0;

    var total_len: usize = 2;
    var count: usize = 0;
    var prev_wall: i64 = 0;

    for (entries, 0..) |entry, idx| {
        const id_len = varintLen(entry.id);
        const wall: u64 = entry.version >> 16;
        const logical: u64 = entry.version & 0xffff;
        const wall_len = if (idx == 0)
            varintLen(wall)
        else
            varintLen(zigzagEncodeI64(@as(i64, @intCast(wall)) - prev_wall));
        const logical_len = varintLen(logical);
        if (total_len + id_len + wall_len + logical_len > dest.len) break;
        total_len += id_len + wall_len + logical_len;
        count += 1;
        prev_wall = @as(i64, @intCast(wall));
    }

    if (count == 0) return 0;
    std.mem.writeInt(u16, dest[0..2], @intCast(count), .little);

    var cursor: usize = 2;
    for (entries[0..count]) |entry| {
        cursor += writeVarint(entry.id, dest[cursor..]);
    }

    prev_wall = 0;
    for (entries[0..count], 0..) |entry, idx| {
        const wall: u64 = entry.version >> 16;
        if (idx == 0) {
            cursor += writeVarint(wall, dest[cursor..]);
        } else {
            const delta = @as(i64, @intCast(wall)) - prev_wall;
            cursor += writeVarint(zigzagEncodeI64(delta), dest[cursor..]);
        }
        prev_wall = @as(i64, @intCast(wall));
    }

    for (entries[0..count]) |entry| {
        const logical: u64 = entry.version & 0xffff;
        cursor += writeVarint(logical, dest[cursor..]);
    }

    return @intCast(cursor);
}

/// Decode a compressed digest back into Entry structs (up to out.len entries).
pub fn decodeDigest(src: []const u8, out: []Entry) usize {
    if (src.len < 2 or out.len == 0) return 0;

    const target = std.mem.readInt(u16, src[0..2], .little);
    var cursor: usize = 2;
    var idx: usize = 0;

    while (idx < out.len and idx < target) {
        const id = readVarint(src, &cursor) orelse break;
        const version = readVarint(src, &cursor) orelse break;
        out[idx] = .{ .id = id, .version = version };
        idx += 1;
    }

    return idx;
}

/// Decode a columnar digest into Entry structs (up to out.len entries).
pub fn decodeDigestColumnar(src: []const u8, out: []Entry) usize {
    if (src.len < 2 or out.len == 0) return 0;

    const target = std.mem.readInt(u16, src[0..2], .little);
    const count: usize = @min(out.len, @as(usize, target));
    var cursor: usize = 2;

    for (0..count) |i| {
        const id = readVarint(src, &cursor) orelse return 0;
        out[i].id = id;
        out[i].version = 0;
    }

    var prev_wall: i64 = 0;
    for (0..count) |i| {
        const raw = readVarint(src, &cursor) orelse return 0;
        var wall: i64 = undefined;
        if (i == 0) {
            wall = @as(i64, @intCast(raw));
        } else {
            wall = prev_wall + zigzagDecodeU64(raw);
        }
        if (wall < 0) return 0;
        out[i].version = @as(u64, @intCast(wall)) << 16;
        prev_wall = wall;
    }

    for (0..count) |i| {
        const logical = readVarint(src, &cursor) orelse return 0;
        out[i].version |= @min(logical, 0xffff);
    }

    return count;
}

const CrdtKind = enum(u8) {
    services_delta = 1,
    services_recent = 2,
    services_sample = 3,
};

const SectionMarker: u8 = 0x80;
const SectionHeaderLen: usize = 3; // kind + u16 len

fn appendDigestSection(kind: CrdtKind, entries: []const Entry, payload: []u8, cursor: *usize) bool {
    if (entries.len == 0) return false;
    if (cursor.* + SectionHeaderLen + 2 > payload.len) return false;

    const header_pos = cursor.*;
    const data_start = header_pos + SectionHeaderLen;
    const used = encodeDigest(entries, payload[data_start..]);
    if (used == 0 or data_start + used > payload.len) return false;
    const count = std.mem.readInt(u16, @ptrCast(payload[data_start .. data_start + 2].ptr), .little);
    if (count == 0) return false;

    payload[header_pos] = SectionMarker | @intFromEnum(kind);
    std.mem.writeInt(u16, @ptrCast(payload[header_pos + 1 .. header_pos + 3].ptr), used, .little);
    cursor.* = data_start + used;
    return true;
}

fn appendDigestSectionColumnar(kind: CrdtKind, entries: []const Entry, payload: []u8, cursor: *usize) bool {
    if (entries.len == 0) return false;
    if (cursor.* + SectionHeaderLen + 2 > payload.len) return false;

    const header_pos = cursor.*;
    const data_start = header_pos + SectionHeaderLen;
    const used = encodeDigestColumnar(entries, payload[data_start..]);
    if (used == 0 or data_start + used > payload.len) return false;
    const count = std.mem.readInt(u16, @ptrCast(payload[data_start .. data_start + 2].ptr), .little);
    if (count == 0) return false;

    payload[header_pos] = SectionMarker | @intFromEnum(kind);
    std.mem.writeInt(u16, @ptrCast(payload[header_pos + 1 .. header_pos + 3].ptr), used, .little);
    cursor.* = data_start + used;
    return true;
}

fn encodeSyncPayload(payload: []u8, delta_entries: []const Entry, sample_entries: []const Entry) usize {
    var cursor: usize = 0;
    if (delta_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_delta, delta_entries, payload, &cursor);
    }
    if (cursor < payload.len and sample_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_sample, sample_entries, payload, &cursor);
    }
    return cursor;
}

fn encodeControlPayload(payload: []u8, recent_entries: []const Entry, sample_entries: []const Entry) usize {
    var cursor: usize = 0;
    if (recent_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_recent, recent_entries, payload, &cursor);
    }
    if (cursor < payload.len and sample_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_sample, sample_entries, payload, &cursor);
    }
    return cursor;
}

test "digest compression round-trips and beats fixed-width size" {
    var payload: [952]u8 = undefined;
    var entries: [64]Entry = undefined;

    for (entries, 0..) |_, idx| {
        entries[idx] = .{ .id = idx + 1, .version = (idx + 1) * 3 };
    }

    const used_bytes: u16 = encodeDigest(entries[0..], payload[0..]);
    const encoded_len: usize = @intCast(used_bytes);

    var decoded: [64]Entry = undefined;
    const decoded_len = decodeDigest(payload[0..encoded_len], decoded[0..]);

    try std.testing.expectEqual(entries.len, decoded_len);
    for (entries, 0..) |expected, i| {
        try std.testing.expectEqual(expected.id, decoded[i].id);
        try std.testing.expectEqual(expected.version, decoded[i].version);
    }

    try std.testing.expect(encoded_len < entries.len * @sizeOf(Entry));
}

test "columnar digest round-trips" {
    var payload: [952]u8 = undefined;
    var entries: [64]Entry = undefined;

    const base_wall: u64 = 1_700_000_000_000;
    for (entries, 0..) |_, idx| {
        const wall = base_wall + @as(u64, idx);
        const logical: u16 = @intCast(idx % 7);
        entries[idx] = .{ .id = idx + 1, .version = (wall << 16) | logical };
    }

    const col_bytes: u16 = encodeDigestColumnar(entries[0..], payload[0..]);
    const col_len: usize = @intCast(col_bytes);

    var decoded: [64]Entry = undefined;
    const decoded_len = decodeDigestColumnar(payload[0..col_len], decoded[0..]);

    try std.testing.expectEqual(entries.len, decoded_len);
    for (entries, 0..) |expected, i| {
        try std.testing.expectEqual(expected.id, decoded[i].id);
        try std.testing.expectEqual(expected.version, decoded[i].version);
    }
}
pub const OutboundPacket = struct {
    packet: Packet,
    recipient: ?[32]u8 = null,
};

const MissingItem = struct {
    id: u64,
    source_peer: [32]u8,
};

pub const ServiceSlot = struct {
    id: u64,
    service: Service,
    active: bool,
};

pub const NodeOptions = struct {
    gossip_fanout: ?u8 = null,
};

pub const NodeStorage = struct {
    service_data: [limits.MAX_SERVICES]ServiceSlot,
    missing_list: BoundedArray(MissingItem, limits.MAX_MISSING_ITEMS),
    outbox: BoundedArray(OutboundPacket, limits.MAX_OUTBOX),
    missing_set_keys: [MissingSetSize]u64,
    missing_set_states: [MissingSetSize]u8,
    scratch_delta: [limits.MAX_SERVICES]Entry,
    scratch_recent: [limits.MAX_RECENT_DELTAS]Entry,
    scratch_sample: [64]Entry,
    scratch_decode: [512]Entry,
    scratch_payload: [PayloadExpandedLen]u8 align(PayloadExpandedAlign),
};

/// Distributed node state and behavior: storage, replication, and networking hooks.
pub const Node = struct {
    id: u16,
    identity: Identity,
    wal: WAL,
    knowledge: u64 = 0,
    hlc: Hlc,
    store: ServiceStore,
    storage: *NodeStorage,
    last_deployed_id: u64 = 0,
    rng: std.Random.DefaultPrng,
    context: *anyopaque,
    on_deploy: *const fn (ctx: *anyopaque, service: Service) anyerror!void,

    // Buffer of outstanding items we need to request from peers. Keep it large enough
    // to cover the expected fanout in simulations so we don't silently drop work.
    //missing_list: [1024]MissingItem = [_]MissingItem{.{ .id = 0, .source_peer = [_]u8{0} ** 32 }} ** 1024,
    // Storage-backed buffers (provided by caller)
    missing_list: *BoundedArray(MissingItem, limits.MAX_MISSING_ITEMS),
    //missing_count: usize = 0,
    dirty_sync: bool = false,
    tick_counter: u64 = 0,
    gossip_fanout: u8 = 4,
    gossip_cursor: usize = 0,
    outbox: *BoundedArray(OutboundPacket, limits.MAX_OUTBOX),

    /// Construct a node with deterministic identity, WAL-backed knowledge, and CRDT state.
    pub fn init(
        id: u16,
        storage: *NodeStorage,
        disk_buffer: []u8,
        context: *anyopaque,
        on_deploy_fn: *const fn (*anyopaque, Service) anyerror!void,
    ) !Node {
        return initWithOptions(id, storage, disk_buffer, context, on_deploy_fn, .{});
    }

    pub fn initWithOptions(
        id: u16,
        storage: *NodeStorage,
        disk_buffer: []u8,
        context: *anyopaque,
        on_deploy_fn: *const fn (*anyopaque, Service) anyerror!void,
        opts: NodeOptions,
    ) !Node {
        @memset(&storage.service_data, std.mem.zeroes(ServiceSlot));
        storage.missing_list.len = 0;
        storage.outbox.len = 0;
        @memset(&storage.missing_set_keys, 0);
        @memset(&storage.missing_set_states, 0);

        var node = Node{
            .id = id,
            .identity = Identity.initDeterministic(id),
            .wal = WAL.init(disk_buffer),
            .knowledge = 0,
            .hlc = Hlc.initNow(),
            .store = ServiceStore.init(),
            .storage = storage,
            .last_deployed_id = 0,
            .rng = std.Random.DefaultPrng.init(id),
            .context = context,
            .on_deploy = on_deploy_fn,
            .gossip_fanout = opts.gossip_fanout orelse readFanoutEnv() orelse 4,
            .gossip_cursor = 0,
            .missing_list = &storage.missing_list,
            .outbox = &storage.outbox,
        };
        const recovered_state = node.wal.recover();
        if (recovered_state > 0) {
            node.knowledge = recovered_state;
        } else {
            node.knowledge = id;
            try node.wal.append(node.knowledge);
        }
        return node;
    }

    fn enqueue(self: *Node, packet: Packet, recipient: ?[32]u8) bool {
        self.outbox.append(.{ .packet = packet, .recipient = recipient }) catch return false;
        return true;
    }

    fn missingSetHash(id: u64) usize {
        var x = id;
        x ^= x >> 33;
        x *%= 0xff51afd7ed558ccd;
        x ^= x >> 33;
        x *%= 0xc4ceb9fe1a85ec53;
        x ^= x >> 33;
        return @intCast(x);
    }

    fn missingSetClear(self: *Node) void {
        @memset(&self.storage.missing_set_states, 0);
        @memset(&self.storage.missing_set_keys, 0);
    }

    fn missingSetContains(self: *Node, id: u64) bool {
        if (id == 0) return false;
        const mask = MissingSetSize - 1;
        var idx = missingSetHash(id) & mask;
        var probes: usize = 0;
        while (probes < MissingSetSize) : (probes += 1) {
            const state = self.storage.missing_set_states[idx];
            if (state == 0) return false;
            if (state == 1 and self.storage.missing_set_keys[idx] == id) return true;
            idx = (idx + 1) & mask;
        }
        return false;
    }

    fn missingSetInsert(self: *Node, id: u64) bool {
        if (id == 0) return false;
        const mask = MissingSetSize - 1;
        var idx = missingSetHash(id) & mask;
        var first_tomb: ?usize = null;
        var probes: usize = 0;
        while (probes < MissingSetSize) : (probes += 1) {
            const state = self.storage.missing_set_states[idx];
            if (state == 0) {
                const target = if (first_tomb) |t| t else idx;
                self.storage.missing_set_keys[target] = id;
                self.storage.missing_set_states[target] = 1;
                return true;
            }
            if (state == 1 and self.storage.missing_set_keys[idx] == id) return false;
            if (state == 2 and first_tomb == null) first_tomb = idx;
            idx = (idx + 1) & mask;
        }
        if (first_tomb) |t| {
            self.storage.missing_set_keys[t] = id;
            self.storage.missing_set_states[t] = 1;
            return true;
        }
        return false;
    }

    fn missingSetRemove(self: *Node, id: u64) void {
        if (id == 0) return;
        const mask = MissingSetSize - 1;
        var idx = missingSetHash(id) & mask;
        var probes: usize = 0;
        while (probes < MissingSetSize) : (probes += 1) {
            const state = self.storage.missing_set_states[idx];
            if (state == 0) return;
            if (state == 1 and self.storage.missing_set_keys[idx] == id) {
                self.storage.missing_set_states[idx] = 2;
                return;
            }
            idx = (idx + 1) & mask;
        }
    }

    fn handleDigestEntries(self: *Node, entries: []const Entry, sender_pubkey: [32]u8) void {
        for (entries) |entry| {
            if (entry.id == 0) continue;
            self.observeVersion(entry.version);
            const my_version = Hlc.unpack(self.store.getVersion(entry.id));
            const incoming = Hlc.unpack(entry.version);

            if (Hlc.newer(incoming, my_version)) {
                const inserted = self.missingSetInsert(entry.id);
                if (inserted) {
                    const new_item = MissingItem{
                        .id = entry.id,
                        .source_peer = sender_pubkey,
                    };

                    self.missing_list.append(new_item) catch |err| {
                        if (err == error.Overflow) {
                            const idx = self.rng.random().intRangeAtMost(usize, 0, self.missing_list.len - 1);
                            const replaced = self.missing_list.buffer[idx];
                            self.missingSetRemove(replaced.id);
                            self.missing_list.buffer[idx] = new_item;
                        }
                    };
                }

                var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                req.setPayload(entry.id);
                req.payload_len = 8;
                _ = self.enqueue(req, sender_pubkey);
            }
        }
    }

    fn handleDigestPayload(self: *Node, payload: []const u8, sender_pubkey: [32]u8) void {
        if (payload.len < SectionHeaderLen or (payload[0] & SectionMarker) == 0) {
            const decoded = self.storage.scratch_decode[0..];
            const decoded_len = decodeDigest(payload, decoded);
            self.handleDigestEntries(decoded[0..decoded_len], sender_pubkey);
            return;
        }

        var cursor: usize = 0;
        while (cursor + SectionHeaderLen <= payload.len) {
            const kind_byte = payload[cursor];
            const kind_id = kind_byte & 0x7f;
            cursor += 1;
            const section_len = std.mem.readInt(u16, @ptrCast(payload[cursor .. cursor + 2].ptr), .little);
            cursor += 2;
            if (cursor + section_len > payload.len) break;

            const section = payload[cursor .. cursor + section_len];
            switch (kind_id) {
                @intFromEnum(CrdtKind.services_delta),
                @intFromEnum(CrdtKind.services_recent),
                => {
                    const decoded = self.storage.scratch_decode[0..];
                    const decoded_len = decodeDigestColumnar(section, decoded);
                    self.handleDigestEntries(decoded[0..decoded_len], sender_pubkey);
                },
                @intFromEnum(CrdtKind.services_sample) => {
                    const decoded = self.storage.scratch_decode[0..];
                    const decoded_len = decodeDigestColumnar(section, decoded);
                    self.handleDigestEntries(decoded[0..decoded_len], sender_pubkey);
                },
                else => {},
            }

            cursor += section_len;
        }
    }

    fn nextVersion(self: *Node) u64 {
        return self.hlc.nextNow();
    }

    fn observeVersion(self: *Node, version: u64) void {
        _ = self.hlc.observeNow(version);
    }

    pub fn putService(self: *Node, service: Service) !void {
        for (&self.storage.service_data) |*slot| {
            if (slot.active and slot.id == service.id) {
                slot.service = service;
                return;
            }
        }
        for (&self.storage.service_data) |*slot| {
            if (!slot.active) {
                slot.* = .{ .id = service.id, .service = service, .active = true };
                return;
            }
        }
        return error.StoreFull;
    }

    pub fn getServiceById(self: *const Node, id: u64) ?*const Service {
        for (&self.storage.service_data) |*slot| {
            if (slot.active and slot.id == id) return &slot.service;
        }
        return null;
    }

    pub fn getServiceByName(self: *const Node, name: []const u8) ?*const Service {
        for (&self.storage.service_data) |*slot| {
            if (slot.active and std.mem.eql(u8, slot.service.getName(), name)) {
                return &slot.service;
            }
        }
        return null;
    }

    pub fn serviceSlots(self: *const Node) []const ServiceSlot {
        return self.storage.service_data[0..];
    }

    pub fn getVersion(self: *const Node, id: u64) u64 {
        return self.store.getVersion(id);
    }

    /// Locally deploy a service and propagate it via gossip if it is new or updated.
    pub fn injectService(self: *Node, service: Service) !bool {
        noalloc_guard.check();
        const version = self.nextVersion();
        if (try self.store.update(service.id, version)) {
            self.last_deployed_id = service.id;
            try self.putService(service);
            self.on_deploy(self.context, service) catch {};
            self.dirty_sync = true;
            return true;
        }
        return false;
    }

    /// Single tick of protocol logic: pull missing items, process inbound packets, gossip digest.
    pub fn tick(self: *Node, inputs: []const Packet) !void {
        noalloc_guard.check();
        self.tick_counter += 1;
        self.outbox.len = 0;
        // 1. Process a few items from the "To-Do" list to accelerate catch-up.
        var missing_budget: usize = 64; // aggressive pull budget
        while (self.missing_list.len > 0 and missing_budget > 0) : (missing_budget -= 1) {
            // Manual "pop" operation
            const item = self.missing_list.get(self.missing_list.len - 1);
            self.missingSetRemove(item.id);
            if (self.store.getVersion(item.id) == 0) {
                var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                req.setPayload(item.id);
                req.payload_len = 8;
                // THIS IS THE CRITICAL FIX: Send the request DIRECTLY to the peer that has the data.
                if (!self.enqueue(req, item.source_peer)) break;
            }
            self.missing_list.len -= 1;
        }
        if (self.missing_list.len == 0) {
            self.missingSetClear();
        }

        // 2. Process incoming packets.
        for (inputs) |p| {
            switch (p.msg_type) {
                Headers.Deploy => {
                    if (p.payload_len < 8 + @sizeOf(Service)) continue;
                    const version = std.mem.readInt(u64, p.payload[0..8], .little);
                    self.observeVersion(version);
                    const service_bytes = p.payload[8 .. 8 + @sizeOf(Service)];
                    const service: *const Service = @ptrCast(@alignCast(service_bytes));
                    const incoming = Hlc.unpack(version);
                    const current = Hlc.unpack(self.store.getVersion(service.id));
                    if (Hlc.newer(incoming, current) and (try self.store.update(service.id, version))) {
                        self.last_deployed_id = service.id;
                        try self.putService(service.*);
                        self.on_deploy(self.context, service.*) catch {};
                        self.dirty_sync = true;

                        // ACTIVE RUMOR MONGERING (Hot Potato)
                        for (0..self.gossip_fanout) |_| {
                            var forward = p;
                            forward.sender_pubkey = self.identity.key_pair.public_key.toBytes();
                            forward.payload_len = p.payload_len;
                            if (!self.enqueue(forward, null)) break;
                        }
                    }
                },
                Headers.Request => {
                    const requested_id = p.getPayload();
                    if (self.getServiceById(requested_id)) |service_value| {
                        var reply = Packet{ .msg_type = Headers.Deploy, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                        const version = self.store.getVersion(requested_id);
                        std.mem.writeInt(u64, reply.payload[0..8], version, .little);
                        const s_bytes = std.mem.asBytes(service_value);
                        @memcpy(reply.payload[8 .. 8 + @sizeOf(Service)], s_bytes);
                        reply.payload_len = @intCast(8 + @sizeOf(Service));
                        _ = self.enqueue(reply, p.sender_pubkey);
                    }
                },
                Headers.Sync, Headers.Control => {
                    const payload_len: usize = @min(@as(usize, p.payload_len), p.payload.len);
                    var payload = p.payload[0..payload_len];
                    if ((p.flags & PacketFlags.PayloadCompressed) != 0) {
                        var expanded = self.storage.scratch_payload[0..];
                        const decompressed_len = decompressPayload(payload, expanded) orelse continue;
                        payload = expanded[0..decompressed_len];
                    }
                    self.handleDigestPayload(payload, p.sender_pubkey);
                },
                else => {},
            }
        }

        // 3. Periodic Gossip for discovery (very aggressive).
        // Send delta digest of recent updates.
        {
            var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            const delta_entries = self.storage.scratch_delta[0..];
            const delta_len = self.store.drainDirty(delta_entries);
            if (delta_len > 0) self.dirty_sync = false;

            const sample_entries = self.storage.scratch_sample[0..];
            const sample_len: usize = if (self.tick_counter % 50 == 0)
                self.store.populateDigest(sample_entries, self.rng.random())
            else
                0;

            var expanded = self.storage.scratch_payload[0..];
            const expanded_len = encodeSyncPayload(expanded, delta_entries[0..delta_len], sample_entries[0..sample_len]);
            if (expanded_len > 0) {
                if (expanded_len <= p.payload.len) {
                    @memcpy(p.payload[0..expanded_len], expanded[0..expanded_len]);
                    p.payload_len = @intCast(expanded_len);
                    _ = self.enqueue(p, null);
                } else if (compressPayload(expanded[0..expanded_len], p.payload[0..])) |compressed_len| {
                    p.flags |= PacketFlags.PayloadCompressed;
                    p.payload_len = compressed_len;
                    _ = self.enqueue(p, null);
                } else {
                    const fallback_len = encodeSyncPayload(p.payload[0..], delta_entries[0..delta_len], sample_entries[0..sample_len]);
                    if (fallback_len > 0) {
                        p.payload_len = @intCast(fallback_len);
                        _ = self.enqueue(p, null);
                    }
                }
            }
        }

        // Lightweight health/control message with a digest piggybacked frequently (still delta-based).
        if (self.tick_counter % 10 == 0) {
            var p = Packet{ .msg_type = Headers.Control, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            const recent_entries = self.storage.scratch_recent[0..];
            const recent_len = self.store.copyRecent(recent_entries);

            const sample_entries = self.storage.scratch_sample[0..];
            const sample_len: usize = if (self.tick_counter % 50 == 0)
                self.store.populateDigest(sample_entries, self.rng.random())
            else
                0;

            var expanded = self.storage.scratch_payload[0..];
            const expanded_len = encodeControlPayload(expanded, recent_entries[0..recent_len], sample_entries[0..sample_len]);
            if (expanded_len > 0) {
                if (expanded_len <= p.payload.len) {
                    @memcpy(p.payload[0..expanded_len], expanded[0..expanded_len]);
                    p.payload_len = @intCast(expanded_len);
                    _ = self.enqueue(p, null);
                } else if (compressPayload(expanded[0..expanded_len], p.payload[0..])) |compressed_len| {
                    p.flags |= PacketFlags.PayloadCompressed;
                    p.payload_len = compressed_len;
                    _ = self.enqueue(p, null);
                } else {
                    const fallback_len = encodeControlPayload(p.payload[0..], recent_entries[0..recent_len], sample_entries[0..sample_len]);
                    if (fallback_len > 0) {
                        p.payload_len = @intCast(fallback_len);
                        _ = self.enqueue(p, null);
                    }
                }
            }
        }
    }
};

fn readFanoutEnv() ?u8 {
    if (std.posix.getenv("MYCO_GOSSIP_FANOUT")) |bytes| {
        return std.fmt.parseInt(u8, bytes, 10) catch null;
    }
    return null;
}
