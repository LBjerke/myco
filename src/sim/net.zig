// Deterministic network simulator used by tests: models latency, jitter, loss, and congestion.
// Provides send/recv primitives that mimic unreliable delivery while preserving reproducibility.
// This file implements the `NetworkSimulator`, a deterministic network
// simulation layer designed for robust testing of Myco's distributed behavior.
// It accurately models various network impairments, including latency, jitter,
// packet loss, and congestion, while guaranteeing reproducibility of test
// scenarios. The simulator provides `send` and `recv` primitives that mimic
// unreliable packet delivery between nodes, enabling comprehensive evaluation
// of the gossip protocol and service orchestration under realistic network conditions.
//
const std = @import("std");
const Random = @import("random.zig").DeterministicRandom;
const Packet = @import("../packet.zig").Packet;
const Headers = @import("../packet.zig").Headers;
const time = @import("time.zig");
const PacketCrypto = @import("../crypto/packet_crypto.zig");

pub const NodeId = u16;

const Index = u32;
const IndexNone: Index = std.math.maxInt(Index);
const MaxPacketsInFlight: usize = 50_000;
const WheelSize: usize = 256;

comptime {
    if ((WheelSize & (WheelSize - 1)) != 0) {
        @compileError("WheelSize must be a power of two.");
    }
}

const InFlightPacket = struct {
    packet: Packet,
    destination_id: NodeId,
    delivery_tick: u64,
    byte_len: usize,
};

/// Lossy, jittery transport for simulating packet delivery between node ids.
pub const NetworkSimulator = struct {
    allocator: std.mem.Allocator,
    rand: Random,
    packet_loss_rate: f64,

    clock: *time.Clock,
    base_latency_ticks: u64,
    jitter_ticks: u64,

    packet_pool: []InFlightPacket,
    next_index: []Index,
    free_head: Index = IndexNone,
    bucket_heads: []Index,
    ready_heads: std.ArrayListUnmanaged(Index) = .{},
    last_processed_tick: u64 = 0,
    in_flight_count: usize = 0,
    conn_overrides: std.AutoHashMap(u32, bool),
    max_node_id: NodeId = 0,
    max_bytes_in_flight: usize = 50_000 * @sizeOf(Packet),
    bytes_in_flight: usize = 0,
    crypto_enabled: bool = false,

    sent_attempted: u64 = 0,
    sent_enqueued: u64 = 0,
    sent_sync: u64 = 0,
    sent_deploy: u64 = 0,
    sent_request: u64 = 0,
    dropped_loss: u64 = 0,
    dropped_congestion: u64 = 0,
    dropped_partition: u64 = 0,
    dropped_crypto: u64 = 0,
    delivered: u64 = 0,
    delivered_sync: u64 = 0,
    delivered_deploy: u64 = 0,
    delivered_request: u64 = 0,

    /// Create a simulator with the desired loss rate, latency, and jitter.
    pub fn init(
        allocator: std.mem.Allocator,
        seed: u64,
        loss_rate: f64,
        clock: *time.Clock,
        base_latency: u64,
        jitter: u64,
        max_bytes_in_flight: usize,
        crypto_enabled: bool,
    ) !NetworkSimulator {
        const packet_pool = try allocator.alloc(InFlightPacket, MaxPacketsInFlight);
        errdefer allocator.free(packet_pool);
        const next_index = try allocator.alloc(Index, MaxPacketsInFlight);
        errdefer allocator.free(next_index);
        const bucket_heads = try allocator.alloc(Index, WheelSize);
        errdefer allocator.free(bucket_heads);

        @memset(bucket_heads, IndexNone);
        for (0..MaxPacketsInFlight) |i| {
            next_index[i] = if (i + 1 < MaxPacketsInFlight) @intCast(i + 1) else IndexNone;
        }

        return .{
            .allocator = allocator,
            .rand = Random.init(seed),
            .packet_loss_rate = loss_rate,
            .clock = clock,
            .base_latency_ticks = base_latency,
            .jitter_ticks = jitter,
            .packet_pool = packet_pool,
            .next_index = next_index,
            .free_head = if (MaxPacketsInFlight > 0) 0 else IndexNone,
            .bucket_heads = bucket_heads,
            .ready_heads = .{},
            .last_processed_tick = clock.now(),
            .in_flight_count = 0,
            .conn_overrides = std.AutoHashMap(u32, bool).init(allocator),
            .sent_sync = 0,
            .sent_deploy = 0,
            .sent_request = 0,
            .delivered_sync = 0,
            .delivered_deploy = 0,
            .delivered_request = 0,
            .max_bytes_in_flight = max_bytes_in_flight,
            .crypto_enabled = crypto_enabled,
        };
    }

    /// Free any in-flight packet buffers.
    pub fn deinit(self: *NetworkSimulator) void {
        self.allocator.free(self.packet_pool);
        self.allocator.free(self.next_index);
        self.allocator.free(self.bucket_heads);
        self.ready_heads.deinit(self.allocator);
        self.conn_overrides.deinit();
    }

    /// Register a node id with the simulator (no-op placeholder for future hooks).
    pub fn register(self: *NetworkSimulator, id: NodeId) !void {
        if (id > self.max_node_id) self.max_node_id = id;
        const needed = @as(usize, self.max_node_id) + 1;
        if (self.ready_heads.items.len < needed) {
            const prev_len = self.ready_heads.items.len;
            try self.ready_heads.resize(self.allocator, needed);
            @memset(self.ready_heads.items[prev_len..], IndexNone);
        }
    }

    fn key(a: NodeId, b: NodeId) u32 {
        return (@as(u32, a) << 16) | @as(u32, b);
    }

    fn isConnected(self: *NetworkSimulator, src: NodeId, dst: NodeId) bool {
        if (src == dst) return true;
        if (self.conn_overrides.get(key(src, dst))) |v| return v;
        return true; // default: fully connected
    }

    /// Disconnect all traffic between two groups (bidirectional).
    pub fn disconnectGroups(self: *NetworkSimulator, group_a: []const NodeId, group_b: []const NodeId) !void {
        for (group_a) |a| {
            for (group_b) |b| {
                try self.conn_overrides.put(key(a, b), false);
                try self.conn_overrides.put(key(b, a), false);
            }
        }
    }

    /// Restore full connectivity between all nodes.
    pub fn healAll(self: *NetworkSimulator) void {
        self.conn_overrides.clearRetainingCapacity();
    }

    fn allocSlot(self: *NetworkSimulator) ?Index {
        if (self.free_head == IndexNone) return null;
        const idx = self.free_head;
        self.free_head = self.next_index[idx];
        self.in_flight_count += 1;
        return idx;
    }

    fn freeSlot(self: *NetworkSimulator, idx: Index) void {
        self.next_index[idx] = self.free_head;
        self.free_head = idx;
        if (self.in_flight_count > 0) self.in_flight_count -= 1;
    }

    fn processBucket(self: *NetworkSimulator, tick: u64) void {
        const bucket_idx: usize = @intCast(tick & (WheelSize - 1));
        var head = self.bucket_heads[bucket_idx];
        self.bucket_heads[bucket_idx] = IndexNone;

        while (head != IndexNone) {
            const idx = head;
            head = self.next_index[idx];
            const pkt = self.packet_pool[idx];
            if (pkt.delivery_tick <= tick) {
                const dest = pkt.destination_id;
                if (dest < self.ready_heads.items.len) {
                    self.next_index[idx] = self.ready_heads.items[dest];
                    self.ready_heads.items[dest] = idx;
                } else {
                    if (self.bytes_in_flight >= pkt.byte_len) self.bytes_in_flight -= pkt.byte_len else self.bytes_in_flight = 0;
                    self.freeSlot(idx);
                }
            } else {
                self.next_index[idx] = self.bucket_heads[bucket_idx];
                self.bucket_heads[bucket_idx] = idx;
            }
        }
    }

    fn processDue(self: *NetworkSimulator) void {
        const now = self.clock.now();
        var tick = self.last_processed_tick;
        while (tick < now) {
            tick += 1;
            self.processBucket(tick);
        }
        self.last_processed_tick = now;
    }

    /// Attempt to enqueue a packet for delivery; accounts for congestion and random loss.
    fn enqueuePacket(self: *NetworkSimulator, dest: NodeId, packet: Packet, pkt_size: usize, delivery_time: u64) !bool {
        const slot = self.allocSlot() orelse {
            self.dropped_congestion += 1;
            return false;
        };
        self.packet_pool[slot] = .{
            .packet = packet,
            .destination_id = dest,
            .delivery_tick = delivery_time,
            .byte_len = pkt_size,
        };
        if (delivery_time <= self.clock.now()) {
            if (dest < self.ready_heads.items.len) {
                self.next_index[slot] = self.ready_heads.items[dest];
                self.ready_heads.items[dest] = slot;
            } else {
                self.freeSlot(slot);
                self.dropped_congestion += 1;
                return false;
            }
        } else {
            const bucket_idx: usize = @intCast(delivery_time & (WheelSize - 1));
            self.next_index[slot] = self.bucket_heads[bucket_idx];
            self.bucket_heads[bucket_idx] = slot;
        }
        self.bytes_in_flight += pkt_size;
        self.sent_enqueued += 1;
        return true;
    }

    pub fn send(self: *NetworkSimulator, src: NodeId, dest: NodeId, packet: Packet) !bool {
        self.sent_attempted += 1;
        const pkt_size: usize = @sizeOf(Packet);

        if (self.in_flight_count >= MaxPacketsInFlight or self.free_head == IndexNone) {
            self.dropped_congestion += 1;
            return false;
        }
        if (self.bytes_in_flight + pkt_size > self.max_bytes_in_flight) {
            self.dropped_congestion += 1;
            return false;
        }
        if (!self.isConnected(src, dest)) {
            self.dropped_partition += 1;
            return false;
        }
        if (self.rand.chance(self.packet_loss_rate)) {
            self.dropped_loss += 1;
            return false;
        }

        const jitter = self.rand.random().intRangeAtMost(u64, 0, self.jitter_ticks);
        const delivery_time = self.clock.now() + self.base_latency_ticks + jitter;

        var pkt = packet;
        if (self.crypto_enabled) {
            PacketCrypto.seal(&pkt, dest);
        }

        _ = try enqueuePacket(self, dest, pkt, pkt_size, delivery_time);

        switch (packet.msg_type) {
            Headers.Sync => self.sent_sync += 1,
            Headers.Deploy => self.sent_deploy += 1,
            Headers.Request => self.sent_request += 1,
            else => {},
        }

        return true;
    }
    /// Deliver one ready packet for the given node if available.
    pub fn recv(self: *NetworkSimulator, node_id: NodeId) ?Packet {
        if (node_id >= self.ready_heads.items.len) return null;
        self.processDue();

        var head = self.ready_heads.items[node_id];
        while (head != IndexNone) {
            const idx = head;
            head = self.next_index[idx];
            self.ready_heads.items[node_id] = head;

            const p = self.packet_pool[idx];
            self.freeSlot(idx);
            if (self.bytes_in_flight >= p.byte_len) self.bytes_in_flight -= p.byte_len else self.bytes_in_flight = 0;

            var pkt = p.packet;
            if (self.crypto_enabled) {
                if (!PacketCrypto.open(&pkt, p.destination_id)) {
                    self.dropped_crypto += 1;
                    continue;
                }
            }

            self.delivered += 1;
            switch (pkt.msg_type) {
                Headers.Sync => self.delivered_sync += 1,
                Headers.Deploy => self.delivered_deploy += 1,
                Headers.Request => self.delivered_request += 1,
                else => {},
            }
            return pkt;
        }
        return null;
    }
};
