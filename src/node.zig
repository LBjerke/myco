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

/// Distributed node state and behavior: storage, replication, and networking hooks.
pub const Node = struct {
    id: u16,
    allocator: std.mem.Allocator,
    identity: Identity,
    wal: WAL,
    knowledge: u64 = 0,
    hlc: Hlc,
    store: ServiceStore,
    service_data: [limits.MAX_SERVICES]ServiceSlot,
    last_deployed_id: u64 = 0,
    rng: std.Random.DefaultPrng,
    context: *anyopaque,
    on_deploy: *const fn (ctx: *anyopaque, service: Service) anyerror!void,

    // Buffer of outstanding items we need to request from peers. Keep it large enough
    // to cover the expected fanout in simulations so we don't silently drop work.
    //missing_list: [1024]MissingItem = [_]MissingItem{.{ .id = 0, .source_peer = [_]u8{0} ** 32 }} ** 1024,
    missing_list: BoundedArray(MissingItem, limits.MAX_MISSING_ITEMS),
    //missing_count: usize = 0,
    dirty_sync: bool = false,
    tick_counter: u64 = 0,
    gossip_fanout: u8 = 4,
    outbox: BoundedArray(OutboundPacket, 64),

    /// Construct a node with deterministic identity, WAL-backed knowledge, and CRDT state.
    pub fn init(
        id: u16,
        allocator: std.mem.Allocator,
        disk_buffer: []u8,
        context: *anyopaque,
        on_deploy_fn: *const fn (*anyopaque, Service) anyerror!void,
    ) !Node {
        var node = Node{
            .id = id,
            .allocator = allocator,
            .identity = Identity.initDeterministic(id),
            .wal = WAL.init(disk_buffer),
            .knowledge = 0,
            .hlc = Hlc.initNow(),
            .store = ServiceStore.init(),
            .service_data = [_]ServiceSlot{.{ .id = 0, .service = std.mem.zeroes(Service), .active = false }} ** limits.MAX_SERVICES,
            .last_deployed_id = 0,
            .rng = std.Random.DefaultPrng.init(id),
            .context = context,
            .on_deploy = on_deploy_fn,
            .gossip_fanout = readFanoutEnv() orelse 4,
            .missing_list = try BoundedArray(MissingItem, limits.MAX_MISSING_ITEMS).init(0),
            .outbox = try BoundedArray(OutboundPacket, 64).init(0),
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

    fn nextVersion(self: *Node) u64 {
        return self.hlc.nextNow();
    }

    fn observeVersion(self: *Node, version: u64) void {
        _ = self.hlc.observeNow(version);
    }

    pub fn putService(self: *Node, service: Service) !void {
        for (&self.service_data) |*slot| {
            if (slot.active and slot.id == service.id) {
                slot.service = service;
                return;
            }
        }
        for (&self.service_data) |*slot| {
            if (!slot.active) {
                slot.* = .{ .id = service.id, .service = service, .active = true };
                return;
            }
        }
        return error.StoreFull;
    }

    pub fn getServiceById(self: *const Node, id: u64) ?*const Service {
        for (&self.service_data) |*slot| {
            if (slot.active and slot.id == id) return &slot.service;
        }
        return null;
    }

    pub fn getServiceByName(self: *const Node, name: []const u8) ?*const Service {
        for (&self.service_data) |*slot| {
            if (slot.active and std.mem.eql(u8, slot.service.getName(), name)) {
                return &slot.service;
            }
        }
        return null;
    }

    pub fn serviceSlots(self: *const Node) []const ServiceSlot {
        return self.service_data[0..];
    }

    pub fn getVersion(self: *const Node, id: u64) u64 {
        return self.store.getVersion(id);
    }

    /// Locally deploy a service and propagate it via gossip if it is new or updated.
    pub fn injectService(self: *Node, service: Service) !bool {
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
        self.tick_counter += 1;
        self.outbox.len = 0;
        // 1. Process a few items from the "To-Do" list to accelerate catch-up.
        var missing_budget: usize = 64; // aggressive pull budget
        while (self.missing_list.len > 0 and missing_budget > 0) : (missing_budget -= 1) {
            // Manual "pop" operation
            self.missing_list.len -= 1;
            const item = self.missing_list.get(self.missing_list.len);
            if (self.store.getVersion(item.id) == 0) {
                var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                req.setPayload(item.id);
                req.payload_len = 8;
                // THIS IS THE CRITICAL FIX: Send the request DIRECTLY to the peer that has the data.
                try self.outbox.append(.{ .packet = req, .recipient = item.source_peer });
            }
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
                            try self.outbox.append(.{ .packet = forward, .recipient = null });
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
                        try self.outbox.append(.{ .packet = reply, .recipient = p.sender_pubkey });
                    }
                },
                Headers.Sync, Headers.Control => {
                    var decoded: [512]Entry = undefined;
                    const payload_len: usize = @min(@as(usize, p.payload_len), p.payload.len);
                    const payload = p.payload[0..payload_len];
                    const decoded_len = decodeDigest(payload, decoded[0..]);

                    for (decoded[0..decoded_len]) |entry| {
                        if (entry.id == 0) continue;
                        self.observeVersion(entry.version);
                        const my_version = Hlc.unpack(self.store.getVersion(entry.id));
                        const incoming = Hlc.unpack(entry.version);

                        if (Hlc.newer(incoming, my_version)) {
                            // I am behind. Add to my to-do list if we don't already have it.
                            var already_tracked = false;

                            // ✅ NEW: Use constSlice() to iterate existing items
                            for (self.missing_list.constSlice()) |missing| {
                                if (missing.id == entry.id) {
                                    already_tracked = true;
                                    break;
                                }
                            }

                            if (!already_tracked) {
                                const new_item = MissingItem{
                                    .id = entry.id,
                                    .source_peer = p.sender_pubkey,
                                };

                                // ✅ NEW: Attempt to append; handle overflow by overwriting a random slot
                                self.missing_list.append(new_item) catch |err| {
                                    if (err == error.Overflow) {
                                        // Queue is saturated; replace a random slot to avoid starvation.
                                        // Direct buffer access is allowed here because we know len == capacity
                                        const idx = self.rng.random().intRangeAtMost(usize, 0, self.missing_list.len - 1);
                                        self.missing_list.buffer[idx] = new_item;
                                    }
                                };
                            }

                            // Act immediately: request the missing item from the advertising peer.
                            var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                            req.setPayload(entry.id);
                            req.payload_len = 8;

                            // ✅ NEW: Use internal outbox (ignore error if outbox full, we'll catch up later)
                            self.outbox.append(.{ .packet = req, .recipient = p.sender_pubkey }) catch {};
                        }
                    }
                },
                else => {},
            }
        }

        // 3. Periodic Gossip for discovery (very aggressive).
        // Send delta digest of recent updates.
        {
            var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            var digest_buf: [512]Entry = undefined;
            const delta_len = self.store.drainDirty(digest_buf[0..]);
            if (delta_len > 0) {
                const used = encodeDigest(digest_buf[0..delta_len], p.payload[0..]);
                p.payload_len = @intCast(used);
                try self.outbox.append(.{ .packet = p });
                self.dirty_sync = false;
            } else if (self.tick_counter % 50 == 0) {
                // Periodic snapshot sample to help rebooted nodes catch up when no new writes occurred.
                const sample_len = self.store.populateDigest(digest_buf[0..64], self.rng.random());
                if (sample_len > 0) {
                    const used = encodeDigest(digest_buf[0..sample_len], p.payload[0..]);
                    p.payload_len = @intCast(used);
                    try self.outbox.append(.{ .packet = p });
                }
            }
        }

        // Lightweight health/control message with a digest piggybacked frequently (still delta-based).
        if (self.tick_counter % 10 == 0) {
            var p = Packet{ .msg_type = Headers.Control, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            var digest_buf: [512]Entry = undefined;
            const delta_len = self.store.drainDirty(digest_buf[0..]);
            if (delta_len > 0) {
                const used = encodeDigest(digest_buf[0..delta_len], p.payload[0..]);
                p.payload_len = @intCast(used);
                try self.outbox.append(.{ .packet = p });
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
