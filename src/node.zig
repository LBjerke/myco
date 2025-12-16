// Core node implementation: owns identity, service CRDT, WAL, and gossip behavior.
// Each node is a deterministic replica used by both the real system and the simulator.
const std = @import("std");
const build = @import("std").build;

const crypto_enabled = false;

const Packet = @import("packet.zig").Packet;
const Headers = @import("packet.zig").Headers;
const Identity = @import("net/handshake.zig").Identity;
const WAL = @import("db/wal.zig").WriteAheadLog;
const Service = @import("schema/service.zig").Service;
const ServiceStore = @import("sync/crdt.zig").ServiceStore;
const Entry = @import("sync/crdt.zig").Entry;

pub const OutboundPacket = struct {
    packet: Packet,
    recipient: ?[32]u8 = null,
};

const MissingItem = struct {
    id: u64,
    source_peer: [32]u8,
};

/// Distributed node state and behavior: storage, replication, and networking hooks.
pub const Node = struct {
    id: u16,
    allocator: std.mem.Allocator,
    identity: Identity,
    wal: WAL,
    knowledge: u64 = 0,
    hlc: u64 = 0,
    store: ServiceStore,
    service_data: std.AutoHashMap(u64, Service),
    last_deployed_id: u64 = 0,
    rng: std.Random.DefaultPrng,
    context: *anyopaque,
    on_deploy: *const fn (ctx: *anyopaque, service: Service) anyerror!void,

    // Buffer of outstanding items we need to request from peers. Keep it large enough
    // to cover the expected fanout in simulations so we don't silently drop work.
    missing_list: [128]MissingItem = [_]MissingItem{.{ .id = 0, .source_peer = [_]u8{0} ** 32 }} ** 128,
    missing_count: usize = 0,
    dirty_sync: bool = false,
    tick_counter: u64 = 0,

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
            .hlc = 0,
            .store = ServiceStore.init(allocator),
            .service_data = std.AutoHashMap(u64, Service).init(allocator),
            .last_deployed_id = 0,
            .rng = std.Random.DefaultPrng.init(id),
            .context = context,
            .on_deploy = on_deploy_fn,
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
        self.hlc += 1;
        return self.hlc;
    }

    /// Locally deploy a service and propagate it via gossip if it is new or updated.
    pub fn injectService(self: *Node, service: Service) !bool {
        const version = self.nextVersion();
        if (try self.store.update(service.id, version)) {
            self.last_deployed_id = service.id;
            try self.service_data.put(service.id, service);
            self.on_deploy(self.context, service) catch {};
            self.dirty_sync = true;
            return true;
        }
        return false;
    }

    /// Single tick of protocol logic: pull missing items, process inbound packets, gossip digest.
    pub fn tick(self: *Node, inputs: []const Packet, outputs: *std.ArrayList(OutboundPacket), output_allocator: std.mem.Allocator) !void {
        self.tick_counter += 1;
        // 1. Process a few items from the "To-Do" list to accelerate catch-up.
        var missing_budget: usize = 64; // aggressive pull budget
        while (self.missing_count > 0 and missing_budget > 0) : (missing_budget -= 1) {
            self.missing_count -= 1;
            const item = self.missing_list[self.missing_count];
            if (self.store.getVersion(item.id) == 0) {
                var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                req.setPayload(item.id);
                req.payload_len = 8;
                // THIS IS THE CRITICAL FIX: Send the request DIRECTLY to the peer that has the data.
                try outputs.append(output_allocator, .{ .packet = req, .recipient = item.source_peer });
            }
        }

        // 2. Process incoming packets.
        for (inputs) |p| {
            switch (p.msg_type) {
                Headers.Deploy => {
                    if (p.payload_len < 8 + @sizeOf(Service)) continue;
                    const version = std.mem.readInt(u64, p.payload[0..8], .little);
                    const service_bytes = p.payload[8 .. 8 + @sizeOf(Service)];
                    const service: *const Service = @ptrCast(@alignCast(service_bytes));
                    if (try self.store.update(service.id, version)) {
                        self.last_deployed_id = service.id;
                        try self.service_data.put(service.id, service.*);
                        self.on_deploy(self.context, service.*) catch {};
                        self.dirty_sync = true;

                        // ACTIVE RUMOR MONGERING (Hot Potato)
                        const fanout = 10; // aggressive fanout for faster spread
                        for (0..fanout) |_| {
                            var forward = p;
                            forward.sender_pubkey = self.identity.key_pair.public_key.toBytes();
                            forward.payload_len = p.payload_len;
                            try outputs.append(output_allocator, .{ .packet = forward, .recipient = null });
                        }
                    }
                },
                Headers.Request => {
                    const requested_id = p.getPayload();
                    if (self.service_data.get(requested_id)) |service_value| {
                        var reply = Packet{ .msg_type = Headers.Deploy, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                        const version = self.store.getVersion(requested_id);
                        std.mem.writeInt(u64, reply.payload[0..8], version, .little);
                        const s_bytes = std.mem.asBytes(&service_value);
                        @memcpy(reply.payload[8 .. 8 + @sizeOf(Service)], s_bytes);
                        reply.payload_len = @intCast(8 + @sizeOf(Service));
                        try outputs.append(output_allocator, .{ .packet = reply, .recipient = p.sender_pubkey });
                    }
                },
                Headers.Sync, Headers.Control => {
                    const max_entries = 952 / @sizeOf(Entry);
                    const aligned_len = max_entries * @sizeOf(Entry);
                    const entries: []const Entry = std.mem.bytesAsSlice(Entry, p.payload[0..aligned_len]);

                    for (entries) |entry| {
                        if (entry.id == 0) break;
                        const my_version = self.store.getVersion(entry.id);

                        if (entry.version > my_version) {
                            // I am behind. Add to my to-do list if we don't already have it.
                            var already_tracked = false;
                            for (self.missing_list[0..self.missing_count]) |missing| {
                                if (missing.id == entry.id) {
                                    already_tracked = true;
                                    break;
                                }
                            }

                            if (!already_tracked) {
                                if (self.missing_count < self.missing_list.len) {
                                    self.missing_list[self.missing_count] = .{
                                        .id = entry.id,
                                        .source_peer = p.sender_pubkey,
                                    };
                                    self.missing_count += 1;
                                } else {
                                    // Queue is saturated; replace a random slot to avoid starvation.
                                    const idx = self.rng.random().intRangeAtMost(usize, 0, self.missing_list.len - 1);
                                    self.missing_list[idx] = .{
                                        .id = entry.id,
                                        .source_peer = p.sender_pubkey,
                                    };
                                }
                            }

                            // Act immediately: request the missing item from the advertising peer.
                            // This avoids reliance on the queued pull path when the queue stays empty.
                            var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                            req.setPayload(entry.id);
                            req.payload_len = 8;
                            try outputs.append(output_allocator, .{ .packet = req, .recipient = p.sender_pubkey });
                        }
                    }
                },
                else => {},
            }
        }

        // 3. Periodic Gossip for discovery (very aggressive).
        // Aggressive: always send digest.
        if (true) {
            var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            const max_entries = 952 / @sizeOf(Entry);
            const aligned_len = max_entries * @sizeOf(Entry);
            const entries_slice = std.mem.bytesAsSlice(Entry, p.payload[0..aligned_len]);
            const count = self.store.populateDigest(entries_slice, self.rng.random());
            const used = count * @sizeOf(Entry);
            if (count < max_entries) entries_slice[count].id = 0;
            p.payload_len = @intCast(used);
            try outputs.append(output_allocator, .{ .packet = p });
            self.dirty_sync = false;
        }

        // Lightweight health/control message with a digest piggybacked frequently.
        if (self.tick_counter % 10 == 0) {
            var p = Packet{ .msg_type = Headers.Control, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            const max_entries = 80;
            const aligned_len = max_entries * @sizeOf(Entry);
            const usable_len = @min(aligned_len, p.payload.len);
            const slice_len = usable_len - (usable_len % @sizeOf(Entry));
            const entries_slice = std.mem.bytesAsSlice(Entry, p.payload[0..slice_len]);
            const count = self.store.populateDigest(entries_slice, self.rng.random());
            const used = count * @sizeOf(Entry);
            if (count < max_entries) entries_slice[count].id = 0;
            p.payload_len = @intCast(used);
            try outputs.append(output_allocator, .{ .packet = p });
        }
    }
};
