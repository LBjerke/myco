// Core node implementation: owns identity, service CRDT, WAL, and gossip behavior.
// Each node is a deterministic replica used by both the real system and the simulator.
// This file implements the core distributed node behavior for the Myco system.
// The `Node` struct manages its identity, service Conflict-Free Replicated Data Type (CRDT) state,
// Write-Ahead Logging (WAL), and handles the gossip protocol for data replication and communication.
// It includes functionalities for packet compression/decompression and digest encoding/decoding
// to facilitate efficient and reliable data exchange between nodes.
//
const std = @import("std");
const build = @import("std").build;
const myco = @import("myco"); // ADDED THIS IMPORT

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
pub const codec = @import("node/codec.zig");

const MissingSetSize: usize = limits.MAX_MISSING_ITEMS * 2;

comptime {
    if ((MissingSetSize & (MissingSetSize - 1)) != 0) {
        @compileError("MissingSetSize must be a power of two.");
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
    scratch_payload: [codec.PayloadExpandedLen]u8 align(codec.PayloadExpandedAlign),
    snap_scratch_buffer: [limits.SNAPSHOT_SCRATCH_SIZE]u8, // Added for WAL snapshots
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
    on_deploy: *const fn (*anyopaque, Service) anyerror!void,

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

        // Split disk_buffer for WAL (Log and Snapshot)
        // Hardcode split for simplicity for now.
        // A more robust solution would use a header to dynamically determine sizes.
        const WAL_TOTAL_SIZE = disk_buffer.len;
        const WAL_SNAPSHOT_SIZE = WAL_TOTAL_SIZE / 4; // 25% for snapshot
        const WAL_LOG_SIZE = WAL_TOTAL_SIZE - WAL_SNAPSHOT_SIZE;

        const log_buf = disk_buffer[0..WAL_LOG_SIZE];
        const snap_buf = disk_buffer[WAL_LOG_SIZE..WAL_TOTAL_SIZE];

        var node = Node{
            .id = id,
            .identity = Identity.initDeterministic(id),
            .wal = WAL.init(log_buf, snap_buf), // New WAL init
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

        // Recover state from WAL
        const RecoverContext = struct {
            node_ptr: *Node,
        };
        var recover_ctx = RecoverContext{ .node_ptr = &node };

        const loader = struct {
            fn load_log_entry(ctx: *anyopaque, item_id: u64, ver: u64) void {
                const c: *RecoverContext = @ptrCast(@alignCast(ctx));
                _ = c.node_ptr.store.update(item_id, ver) catch {};
            }
            fn load_snapshot(ctx: *anyopaque, data: []const u8) void {
                const c: *RecoverContext = @ptrCast(@alignCast(ctx));
                // For now, snapshot is just a raw dump of ServiceStore items
                var fbs = std.io.fixedBufferStream(data);
                var reader = fbs.reader();
                while (true) {
                    const item_id = reader.readInt(u64, .little) catch break;
                    const version = reader.readInt(u64, .little) catch break;
                    const active = reader.readInt(u8, .little) catch break; // active: bool is 1 byte
                    if (active != 0) {
                        _ = c.node_ptr.store.update(item_id, version) catch {};
                    }
                }
            }
        };

        // Instead of returning a u64, recover now updates the store directly
        node.wal.recover(&recover_ctx, loader.load_log_entry, loader.load_snapshot) catch {};

        // Remove old knowledge logic, as it's replaced by service store recovery
        // if (recovered_state > 0) {
        //     node.knowledge = recovered_state;
        // } else {
        //     node.knowledge = id;
        //     try node.wal.append(node.knowledge);
        // }
        node.knowledge = id; // Keep knowledge for now, but not WAL-backed.

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

    fn handleDigestEntries(self: *Node, entries: []const myco.sync.crdt.Entry, sender_pubkey: [32]u8) void {
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
        if (payload.len < codec.SectionHeaderLen or (payload[0] & codec.SectionMarker) == 0) {
            const decoded = self.storage.scratch_decode[0..];
            const decoded_len = codec.decodeDigest(payload, decoded);
            self.handleDigestEntries(decoded[0..decoded_len], sender_pubkey);
            return;
        }

        var cursor: usize = 0;
        while (cursor + codec.SectionHeaderLen <= payload.len) {
            const kind_byte = payload[cursor];
            const kind_id = kind_byte & 0x7f;
            cursor += 1;
            const section_len = std.mem.readInt(u16, @ptrCast(payload[cursor .. cursor + 2].ptr), .little);
            cursor += 2;
            if (cursor + section_len > payload.len) break;

            const section = payload[cursor .. cursor + section_len];
            switch (kind_id) {
                @intFromEnum(codec.CrdtKind.services_delta),
                @intFromEnum(codec.CrdtKind.services_recent),
                => {
                    const decoded = self.storage.scratch_decode[0..];
                    const decoded_len = codec.decodeDigestColumnar(section, decoded);
                    self.handleDigestEntries(decoded[0..decoded_len], sender_pubkey);
                },
                @intFromEnum(codec.CrdtKind.services_sample) => {
                    const decoded = self.storage.scratch_decode[0..];
                    const decoded_len = codec.decodeDigestColumnar(section, decoded);
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
            if (std.mem.eql(u8, slot.service.getName(), name)) {
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
            try self.wal.append(service.id, version); // Append service update to WAL
            // Trigger compaction (e.g., every 10 appends for simulation)
            if (self.wal.log_cursor / @sizeOf(myco.db.wal.Entry) > 10) {
                // Serialize current store to snapshot
                var fbs = std.io.fixedBufferStream(self.storage.snap_scratch_buffer[0..]);
                var writer = fbs.writer();
                var serialized_len: usize = 0;
                for (self.store.items) |item| {
                    if (item.active) {
                        try writer.writeInt(u64, item.id, .little);
                        try writer.writeInt(u64, item.version, .little);
                        try writer.writeInt(u8, @intFromBool(item.active), .little);
                        serialized_len += 17; // u64 + u64 + u8
                    }
                }
                try self.wal.compact(self.storage.snap_scratch_buffer[0..serialized_len]);
            }
            return true;
        }
        return false;
    }

    fn processMissingItems(self: *Node) !void {
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
    }

    fn handleDeployHeader(self: *Node, p: Packet) !void {
        if (p.payload_len < 8 + @sizeOf(Service)) return;
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
    }

    fn handleRequestHeader(self: *Node, p: Packet) !void {
        const requested_id = p.getPayload();
        if (self.getServiceById(requested_id)) |service_value| {
            var reply = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            const version = self.store.getVersion(requested_id);
            std.mem.writeInt(u64, reply.payload[0..8], version, .little);
            const s_bytes = std.mem.asBytes(service_value);
            @memcpy(reply.payload[8 .. 8 + @sizeOf(Service)], s_bytes);
            reply.payload_len = @intCast(8 + @sizeOf(Service));
            _ = self.enqueue(reply, p.sender_pubkey);
        }
    }

    fn handleSyncControlHeaders(self: *Node, p: Packet) !void {
        const payload_len: usize = @min(@as(usize, p.payload_len), p.payload.len);
        var payload = p.payload[0..payload_len];
        if ((p.flags & PacketFlags.PayloadCompressed) != 0) {
            var expanded = self.storage.scratch_payload[0..];
            const decompressed_len = codec.decompressPayload(payload, expanded) orelse return;
            payload = expanded[0..decompressed_len];
        }
        self.handleDigestPayload(payload, p.sender_pubkey);
    }

    fn handleIncomingPacket(self: *Node, p: Packet) !void {
        switch (p.msg_type) {
            Headers.Deploy => try self.handleDeployHeader(p),
            Headers.Request => try self.handleRequestHeader(p),
            Headers.Sync, Headers.Control => try self.handleSyncControlHeaders(p),
            else => {},
        }
    }
    fn generateAndSendGossip(self: *Node) !void {
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
            const expanded_len = codec.encodeSyncPayload(expanded, delta_entries[0..delta_len], sample_entries[0..sample_len]);
            if (expanded_len > 0) {
                if (expanded_len <= p.payload.len) {
                    @memcpy(p.payload[0..expanded_len], expanded[0..expanded_len]);
                    p.payload_len = @intCast(expanded_len);
                    _ = self.enqueue(p, null);
                } else if (codec.compressPayload(expanded[0..expanded_len], p.payload[0..])) |compressed_len| {
                    p.flags |= PacketFlags.PayloadCompressed;
                    p.payload_len = compressed_len;
                    _ = self.enqueue(p, null);
                } else {
                    const fallback_len = codec.encodeSyncPayload(expanded[0..expanded_len], delta_entries[0..delta_len], sample_entries[0..sample_len]);
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
            const expanded_len = codec.encodeControlPayload(expanded, recent_entries[0..recent_len], sample_entries[0..sample_len]);
            if (expanded_len > 0) {
                if (expanded_len <= p.payload.len) {
                    @memcpy(p.payload[0..expanded_len], expanded[0..expanded_len]);
                    p.payload_len = @intCast(expanded_len);
                    _ = self.enqueue(p, null);
                } else if (codec.compressPayload(expanded[0..expanded_len], p.payload[0..])) |compressed_len| {
                    p.flags |= PacketFlags.PayloadCompressed;
                    p.payload_len = compressed_len;
                    _ = self.enqueue(p, null);
                } else {
                    const fallback_len = codec.encodeControlPayload(expanded[0..expanded_len], recent_entries[0..recent_len], sample_entries[0..sample_len]);
                    if (fallback_len > 0) {
                        p.payload_len = @intCast(fallback_len);
                        _ = self.enqueue(p, null);
                    }
                }
            }
        }
    }

    /// Single tick of protocol logic: pull missing items, process inbound packets, gossip digest.
    pub fn tick(self: *Node, inputs: []const Packet) !void {
        noalloc_guard.check();
        self.tick_counter += 1;
        self.outbox.len = 0;

        try self.processMissingItems();

        for (inputs) |p| {
            try self.handleIncomingPacket(p);
        }

        try self.generateAndSendGossip();
    }
};

fn readFanoutEnv() ?u8 {
    if (std.posix.getenv("MYCO_GOSSIP_FANOUT")) |bytes| {
        return std.fmt.parseInt(u8, bytes, 10) catch null;
    }
    return null;
}
