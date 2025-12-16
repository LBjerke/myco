const std = @import("std");
const build = @import("std").build;

const crypto_enabled = false;

const Packet = @import("packet.zig").Packet;
const Headers = Packet.Headers;
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

pub const Node = struct {
    id: u16,
    allocator: std.mem.Allocator,
    identity: Identity,
    wal: WAL,
    knowledge: u64 = 0,
    store: ServiceStore,
    service_data: std.AutoHashMap(u64, Service),
    last_deployed_id: u64 = 0,
    rng: std.Random.DefaultPrng,
    context: *anyopaque,
    on_deploy: *const fn (ctx: *anyopaque, service: Service) anyerror!void,

    missing_list: [16]MissingItem = [_]MissingItem{.{ .id = 0, .source_peer = [_]u8{0} ** 32 }} ** 16,
    missing_count: usize = 0,

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

    pub fn injectService(self: *Node, service: Service) !bool {
        if (try self.store.update(service.id, service.id)) {
            self.last_deployed_id = service.id;
            try self.service_data.put(service.id, service);
            self.on_deploy(self.context, service) catch {};
            return true;
        }
        return false;
    }

    pub fn tick(self: *Node, inputs: []const Packet, outputs: *std.ArrayList(OutboundPacket), output_allocator: std.mem.Allocator) !void {
        // 1. Process one item from the "To-Do" list.
        if (self.missing_count > 0) {
            self.missing_count -= 1;
            const item = self.missing_list[self.missing_count];
            if (self.store.getVersion(item.id) == 0) {
                var req = Packet{ .header = Headers.REQUEST, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                req.setPayload(item.id);
                if (comptime crypto_enabled) {
                    req.signature = self.identity.sign(&req.payload);
                }
                // THIS IS THE CRITICAL FIX: Send the request DIRECTLY to the peer that has the data.
                try outputs.append(output_allocator, .{ .packet = req, .recipient = item.source_peer });
            }
        }

        // 2. Process incoming packets.
        for (inputs) |p| {
            if (comptime crypto_enabled) {
                if (!Identity.verify(p.sender_pubkey, &p.payload, p.signature)) continue;
            }

            switch (p.header) {
                Headers.DEPLOY => {
                    const service: *const Service = @ptrCast(@alignCast(&p.payload));
                    if (try self.store.update(service.id, service.id)) {
                        self.last_deployed_id = service.id;
                        try self.service_data.put(service.id, service.*);
                        self.on_deploy(self.context, service.*) catch {};

                        // ACTIVE RUMOR MONGERING (Hot Potato)
                        const fanout = 2;
                        for (0..fanout) |_| {
                            var forward = p;
                            forward.sender_pubkey = self.identity.key_pair.public_key.toBytes();
                            if (comptime crypto_enabled) {
                                forward.signature = self.identity.sign(&forward.payload);
                            }
                            try outputs.append(output_allocator, .{ .packet = forward, .recipient = null });
                        }
                    }
                },
                Headers.REQUEST => {
                    const requested_id = p.getPayload();
                    if (self.service_data.get(requested_id)) |service_value| {
                        var reply = Packet{ .header = Headers.DEPLOY, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                        const s_bytes = std.mem.asBytes(&service_value);
                        @memcpy(reply.payload[0..@sizeOf(Service)], s_bytes);
                        if (comptime crypto_enabled) {
                            reply.signature = self.identity.sign(&reply.payload);
                        }
                        try outputs.append(output_allocator, .{ .packet = reply, .recipient = p.sender_pubkey });
                    }
                },
                Headers.SYNC => {
                    const max_entries = 920 / @sizeOf(Entry);
                    const aligned_len = max_entries * @sizeOf(Entry);
                    const entries: []const Entry = std.mem.bytesAsSlice(Entry, p.payload[0..aligned_len]);

                    for (entries) |entry| {
                        if (entry.id == 0) break;
                        const my_version = self.store.getVersion(entry.id);

                        if (entry.version > my_version) {
                            // I am behind. Add to my to-do list if there's space.
                            if (self.missing_count < self.missing_list.len) {
                                self.missing_list[self.missing_count] = .{
                                    .id = entry.id,
                                    .source_peer = p.sender_pubkey,
                                };
                                self.missing_count += 1;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // 3. Periodic Gossip for discovery.
        if (self.rng.random().intRangeAtMost(u8, 0, 100) < 50) {
            var p = Packet{ .header = Headers.SYNC, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            const max_entries = 920 / @sizeOf(Entry);
            const aligned_len = max_entries * @sizeOf(Entry);
            const entries_slice = std.mem.bytesAsSlice(Entry, p.payload[0..aligned_len]);
            const count = self.store.populateDigest(entries_slice, self.rng.random());
            if (count < max_entries) entries_slice[count].id = 0;
            if (comptime crypto_enabled) {
                p.signature = self.identity.sign(&p.payload);
            }
            try outputs.append(output_allocator, .{ .packet = p });
        }
    }
};
