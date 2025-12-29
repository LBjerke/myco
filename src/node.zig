// Core node implementation: owns identity, service CRDT, WAL, and gossip behavior.
// Each node is a deterministic replica used by both the real system and the simulator.
const std = @import("std");
const build = @import("std").build;

const crypto_enabled = false;

const Packet = @import("packet.zig").Packet;
const Headers = @import("packet.zig").Headers;
const limits = @import("core/limits.zig");
const Identity = @import("net/handshake.zig").Identity;
const WAL = @import("db/wal.zig").WriteAheadLog;
const Service = @import("schema/service.zig").Service;
const ServiceStore = @import("sync/crdt.zig").ServiceStore;
const Entry = @import("sync/crdt.zig").Entry;
const Hlc = @import("sync/hlc.zig").Hlc;
const BoundedArray = @import("util/bounded_array.zig").BoundedArray;
const noalloc_guard = @import("util/noalloc_guard.zig");

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
    const count = std.mem.readInt(u16, @ptrCast(payload[data_start..data_start + 2].ptr), .little);
    if (count == 0) return false;

    payload[header_pos] = SectionMarker | @intFromEnum(kind);
    std.mem.writeInt(u16, @ptrCast(payload[header_pos + 1 .. header_pos + 3].ptr), used, .little);
    cursor.* = data_start + used;
    return true;
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

    fn handleDigestEntries(self: *Node, entries: []const Entry, sender_pubkey: [32]u8) void {
        for (entries) |entry| {
            if (entry.id == 0) continue;
            self.observeVersion(entry.version);
            const my_version = Hlc.unpack(self.store.getVersion(entry.id));
            const incoming = Hlc.unpack(entry.version);

            if (Hlc.newer(incoming, my_version)) {
                var already_tracked = false;

                for (self.missing_list.constSlice()) |missing| {
                    if (missing.id == entry.id) {
                        already_tracked = true;
                        break;
                    }
                }

                if (!already_tracked) {
                    const new_item = MissingItem{
                        .id = entry.id,
                        .source_peer = sender_pubkey,
                    };

                    self.missing_list.append(new_item) catch |err| {
                        if (err == error.Overflow) {
                            const idx = self.rng.random().intRangeAtMost(usize, 0, self.missing_list.len - 1);
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
            var decoded: [512]Entry = undefined;
            const decoded_len = decodeDigest(payload, decoded[0..]);
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
                @intFromEnum(CrdtKind.services_sample),
                => {
                    var decoded: [512]Entry = undefined;
                    const decoded_len = decodeDigest(section, decoded[0..]);
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
            if (self.store.getVersion(item.id) == 0) {
                var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                req.setPayload(item.id);
                req.payload_len = 8;
                // THIS IS THE CRITICAL FIX: Send the request DIRECTLY to the peer that has the data.
                if (!self.enqueue(req, item.source_peer)) break;
            }
            self.missing_list.len -= 1;
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
                    const payload = p.payload[0..payload_len];
                    self.handleDigestPayload(payload, p.sender_pubkey);
                },
                else => {},
            }
        }

        // 3. Periodic Gossip for discovery (very aggressive).
        // Send delta digest of recent updates.
        {
            var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            var digest_buf: [512]Entry = undefined;
            var cursor: usize = 0;
            const delta_len = self.store.drainDirty(digest_buf[0..]);
            if (delta_len > 0) {
                _ = appendDigestSection(.services_delta, digest_buf[0..delta_len], p.payload[0..], &cursor);
                self.dirty_sync = false;
            }

            if (cursor < p.payload.len) {
                // Periodic snapshot sample to help rebooted nodes catch up.
                if (self.tick_counter % 50 == 0) {
                    const sample_len = self.store.populateDigest(digest_buf[0..64], self.rng.random());
                    if (sample_len > 0) {
                        _ = appendDigestSection(.services_sample, digest_buf[0..sample_len], p.payload[0..], &cursor);
                    }
                }
            }

            if (cursor > 0) {
                p.payload_len = @intCast(cursor);
                _ = self.enqueue(p, null);
            }
        }

        // Lightweight health/control message with a digest piggybacked frequently (still delta-based).
        if (self.tick_counter % 10 == 0) {
            var p = Packet{ .msg_type = Headers.Control, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            var digest_buf: [512]Entry = undefined;
            var cursor: usize = 0;
            const recent_len = self.store.copyRecent(digest_buf[0..]);
            if (recent_len > 0) {
                _ = appendDigestSection(.services_recent, digest_buf[0..recent_len], p.payload[0..], &cursor);
            }

            if (cursor < p.payload.len) {
                if (self.tick_counter % 50 == 0) {
                    const sample_len = self.store.populateDigest(digest_buf[0..64], self.rng.random());
                    if (sample_len > 0) {
                        _ = appendDigestSection(.services_sample, digest_buf[0..sample_len], p.payload[0..], &cursor);
                    }
                }
            }

            if (cursor > 0) {
                p.payload_len = @intCast(cursor);
                _ = self.enqueue(p, null);
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
