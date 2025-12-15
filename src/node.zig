const std = @import("std");
const Packet = @import("packet.zig").Packet;
const Headers = Packet.Headers;
const Identity = @import("net/handshake.zig").Identity;
const WAL = @import("db/wal.zig").WriteAheadLog;
const Service = @import("schema/service.zig").Service;
const ServiceStore = @import("sync/crdt.zig").ServiceStore;
const Entry = @import("sync/crdt.zig").Entry;

/// A packet waiting to be sent, with routing instructions.
pub const OutboundPacket = struct {
    packet: Packet,
    recipient: ?[32]u8 = null,
};

pub const Node = struct {
    id: u16,
    allocator: std.mem.Allocator,
    identity: Identity,
    wal: WAL,
    
    knowledge: u64 = 0,
    last_deployed_id: u64 = 0,
    store: ServiceStore,
    rng: std.Random.DefaultPrng,

    // NEW: The Context for Side Effects
    context: *anyopaque,
    // The Function Pointer: fn(context, Service) !void
    on_deploy: *const fn (ctx: *anyopaque, service: Service) anyerror!void,

    pub fn init(
        id: u16, 
        allocator: std.mem.Allocator, 
        disk_buffer: []u8,
        // NEW: Dependency Injection
        context: *anyopaque,
        on_deploy_fn: *const fn (*anyopaque, Service) anyerror!void
    ) !Node {
        var node = Node{
            .id = id,
            .allocator = allocator,
            .identity = Identity.initDeterministic(id),
            .wal = WAL.init(disk_buffer),
            .knowledge = 0,
            .last_deployed_id = 0,
            .store = ServiceStore.init(allocator),
            .rng = std.Random.DefaultPrng.init(id),
            // Assign Hook
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
        // 1. Update CRDT Store
        // Use ID as version for simplicity in v1
        if (try self.store.update(service.id, service.id)) {
            self.last_deployed_id = service.id;
            
            // 2. Trigger Side Effect (Build & Run)
            // We ignore errors here so the daemon doesn't crash on bad user builds
            self.on_deploy(self.context, service) catch |err| {
                std.debug.print("ERROR: Local deployment failed: {}\n", .{err});
            };

            // 3. Update WAL
            try self.wal.append(self.knowledge); // Checkpoint

            return true;
        }
        return false;
    }

    pub fn tick(self: *Node, inputs: []const Packet, outputs: *std.ArrayList(OutboundPacket), output_allocator: std.mem.Allocator) !void {
        var state_changed = false;

        for (inputs) |p| {
            if (!Identity.verify(p.sender_pubkey, &p.payload, p.signature)) continue;

            switch (p.header) {
                Headers.GOSSIP => {
                    const incoming_knowledge = p.getPayload();
                    if (incoming_knowledge > self.knowledge) {
                        self.knowledge = incoming_knowledge;
                        state_changed = true;
                    }
                },
                Headers.DEPLOY => {
                    const service: *const Service = @ptrCast(@alignCast(&p.payload));
                    const version = service.id; 
                    if (try self.store.update(service.id, version)) {
                        self.last_deployed_id = service.id;
                        state_changed = true;
                        
                        // NEW: TRIGGER THE SIDE EFFECT (Build & Run)
                        // We swallow errors here so one failed build doesn't crash the daemon
                        self.on_deploy(self.context, service.*) catch |err| {
                            std.debug.print("ERROR: Failed to deploy service {d}: {}\n", .{service.id, err});
                        };

                        var forward = Packet{ 
                            .header = Headers.DEPLOY, 
                            .sender_pubkey = self.identity.key_pair.public_key.toBytes(),
                            .payload = p.payload,
                        };
                        forward.signature = self.identity.sign(&forward.payload);
                        try outputs.append(output_allocator, .{ .packet = forward });
                    }
                },
                Headers.REQUEST => {
                    const requested_id = p.getPayload();
                    if (self.store.getVersion(requested_id) > 0) {
                        // Reconstruct/Fetch logic (In prod this fetches from DB)
                        var service = Service{ .id = requested_id, .name = undefined, .flake_uri = undefined, .exec_name = undefined };
                        service.setName("requested-service"); // Dummy name for reconstruction

                        var reply = Packet{ 
                            .header = Headers.DEPLOY, 
                            .sender_pubkey = self.identity.key_pair.public_key.toBytes(),
                        };
                        const s_bytes = std.mem.asBytes(&service);
                        @memcpy(reply.payload[0..@sizeOf(Service)], s_bytes);
                        reply.signature = self.identity.sign(&reply.payload);
                        
                        try outputs.append(output_allocator, .{ .packet = reply, .recipient = p.sender_pubkey });
                    }
                },
                Headers.SYNC => {
                    const max_entries = 920 / @sizeOf(Entry);
                    const aligned_len = max_entries * @sizeOf(Entry);
                    const entries_bytes = p.payload[0 .. aligned_len];
                    const entries: []const Entry = std.mem.bytesAsSlice(Entry, entries_bytes);

                    for (entries) |entry| {
                        if (entry.id == 0) break; 
                        const my_version = self.store.getVersion(entry.id);
                        
                        if (my_version > entry.version) {
                            var service = Service{ .id = entry.id, .name = undefined, .flake_uri = undefined, .exec_name = undefined };
                            service.setName("synced-service");
                            
                            var reply = Packet{ 
                                .header = Headers.DEPLOY, 
                                .sender_pubkey = self.identity.key_pair.public_key.toBytes(),
                            };
                            const s_bytes = std.mem.asBytes(&service);
                            @memcpy(reply.payload[0..@sizeOf(Service)], s_bytes);
                            reply.signature = self.identity.sign(&reply.payload);
                            
                            try outputs.append(output_allocator, .{ .packet = reply, .recipient = p.sender_pubkey });
                        }
                        else if (entry.version > my_version) {
                            var req = Packet{
                                .header = Headers.REQUEST,
                                .sender_pubkey = self.identity.key_pair.public_key.toBytes(),
                            };
                            req.setPayload(entry.id);
                            req.signature = self.identity.sign(&req.payload);
                            try outputs.append(output_allocator, .{ .packet = req, .recipient = p.sender_pubkey });
                        }
                    }
                },
                else => {}, 
            }
        }

        if (self.rng.random().intRangeAtMost(u8, 0, 100) < 10) {
            var p = Packet{ 
                .header = Headers.GOSSIP,
                .sender_pubkey = self.identity.key_pair.public_key.toBytes(),
            };
            p.setPayload(self.knowledge);
            p.signature = self.identity.sign(&p.payload);
            try outputs.append(output_allocator, .{ .packet = p });
        }

        if (self.rng.random().intRangeAtMost(u8, 0, 100) < 30) {
            var p = Packet{ 
                .header = Headers.SYNC,
                .sender_pubkey = self.identity.key_pair.public_key.toBytes(),
            };
            
            const max_entries = 920 / @sizeOf(Entry);
            const aligned_len = max_entries * @sizeOf(Entry);
            const entries_slice = std.mem.bytesAsSlice(Entry, p.payload[0..aligned_len]);
            const count = self.store.populateDigest(entries_slice, self.rng.random());
            if (count < max_entries) {
                entries_slice[count].id = 0; 
            }

            p.signature = self.identity.sign(&p.payload);
            try outputs.append(output_allocator, .{ .packet = p });
        }

        if (state_changed) {
            self.wal.append(self.knowledge) catch {}; 
        }
    }
};
