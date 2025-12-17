// Deterministic network simulator used by tests: models latency, jitter, loss, and congestion.
// Provides send/recv primitives that mimic unreliable delivery while preserving reproducibility.
const std = @import("std");
const Random = @import("random.zig").DeterministicRandom;
const Packet = @import("../packet.zig").Packet;
const Headers = @import("../packet.zig").Headers;
const time = @import("time.zig");
const PacketCrypto = @import("../crypto/packet_crypto.zig");

pub const NodeId = u16;

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

    in_flight_packets: std.ArrayList(InFlightPacket),
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
        return .{
            .allocator = allocator,
            .rand = Random.init(seed),
            .packet_loss_rate = loss_rate,
            .clock = clock,
            .base_latency_ticks = base_latency,
            .jitter_ticks = jitter,
            // FIX: Initialize as an empty struct
            .in_flight_packets = .{},
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
        // FIX: Pass allocator to deinit
        self.in_flight_packets.deinit(self.allocator);
        self.conn_overrides.deinit();
    }

    /// Register a node id with the simulator (no-op placeholder for future hooks).
    pub fn register(self: *NetworkSimulator, id: NodeId) !void {
        if (id > self.max_node_id) self.max_node_id = id;
    }
      const MAX_PACKETS_IN_FLIGHT = 50_000;

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

    /// Attempt to enqueue a packet for delivery; accounts for congestion and random loss.
    pub fn send(self: *NetworkSimulator, src: NodeId, dest: NodeId, packet: Packet) !bool {
        self.sent_attempted += 1;
        if (self.in_flight_packets.items.len >= MAX_PACKETS_IN_FLIGHT) {
            self.dropped_congestion += 1;
            return false; // Network Congested (Dropped)
        }
        const pkt_size: usize = @sizeOf(Packet);
        if (self.bytes_in_flight + pkt_size > self.max_bytes_in_flight) {
            self.dropped_congestion += 1;
            return false;
        }

        // Partitioned links drop immediately (treated like loss).
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

        // FIX: Pass allocator to append
        try self.in_flight_packets.append(self.allocator, .{
            .packet = pkt,
            .destination_id = dest,
            .delivery_tick = delivery_time,
            .byte_len = pkt_size,
        });
        self.bytes_in_flight += pkt_size;
        self.sent_enqueued += 1;
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
        var idx: usize = self.in_flight_packets.items.len;
        while (idx > 0) {
            idx -= 1;
            const p = self.in_flight_packets.items[idx];
            if (p.destination_id == node_id and p.delivery_tick <= self.clock.now()) {
                _ = self.in_flight_packets.swapRemove(idx);
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
        }
        return null;
    }
};
