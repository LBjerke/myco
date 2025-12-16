const std = @import("std");
const Random = @import("random.zig").DeterministicRandom;
const Packet = @import("../packet.zig").Packet;
const time = @import("time.zig");

pub const NodeId = u16;

const InFlightPacket = struct {
    packet: Packet,
    destination_id: NodeId,
    delivery_tick: u64,
};

pub const NetworkSimulator = struct {
    allocator: std.mem.Allocator,
    rand: Random,
    packet_loss_rate: f64,
    
    clock: *time.Clock,
    base_latency_ticks: u64,
    jitter_ticks: u64,

    in_flight_packets: std.ArrayList(InFlightPacket),

    pub fn init(
        allocator: std.mem.Allocator,
        seed: u64,
        loss_rate: f64,
        clock: *time.Clock,
        base_latency: u64,
        jitter: u64,
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
        };
    }

    pub fn deinit(self: *NetworkSimulator) void {
        // FIX: Pass allocator to deinit
        self.in_flight_packets.deinit(self.allocator);
    }

    pub fn register(_: *NetworkSimulator, _: NodeId) !void {}
      const MAX_PACKETS_IN_FLIGHT = 10_000;

    pub fn send(self: *NetworkSimulator, _: NodeId, dest: NodeId, packet: Packet) !bool {
          if (self.in_flight_packets.items.len >= MAX_PACKETS_IN_FLIGHT) {
            return false; // Network Congested (Dropped)
        }

        if (self.rand.chance(self.packet_loss_rate)) {
            return false;
        }

        const jitter = self.rand.random().intRangeAtMost(u64, 0, self.jitter_ticks);
        const delivery_time = self.clock.now() + self.base_latency_ticks + jitter;

        // FIX: Pass allocator to append
        try self.in_flight_packets.append(self.allocator, .{
            .packet = packet,
            .destination_id = dest,
            .delivery_tick = delivery_time,
        });

        return true;
    }

    pub fn recv(self: *NetworkSimulator, node_id: NodeId) ?Packet {
        for (self.in_flight_packets.items, 0..) |*p, i_rev| {
            const i = self.in_flight_packets.items.len - 1 - i_rev;
            
            if (p.destination_id == node_id and p.delivery_tick <= self.clock.now()) {
                const delivered_packet = p.packet;
                _ = self.in_flight_packets.swapRemove(i);
                return delivered_packet;
            }
        }
        return null;
    }
};
