const std = @import("std");
const Random = @import("random.zig").DeterministicRandom;
const Packet = @import("../packet.zig").Packet;

pub const NodeId = u16;

pub const NetworkSimulator = struct {
    allocator: std.mem.Allocator,
    rand: Random,
    packet_loss_rate: f64,
    
    // Zig 0.15: ArrayList is now unmanaged (holds no allocator)
    queues: std.AutoHashMap(NodeId, std.ArrayList(Packet)),

    pub fn init(allocator: std.mem.Allocator, seed: u64, loss_rate: f64) !NetworkSimulator {
        return .{
            .allocator = allocator,
            .rand = Random.init(seed),
            .packet_loss_rate = loss_rate,
            .queues = std.AutoHashMap(NodeId, std.ArrayList(Packet)).init(allocator),
        };
    }

    pub fn deinit(self: *NetworkSimulator) void {
        var it = self.queues.iterator();
        while (it.next()) |entry| {
            // FIX: Pass allocator to deinit
            entry.value_ptr.deinit(self.allocator);
        }
        self.queues.deinit();
    }

    pub fn register(self: *NetworkSimulator, node_id: NodeId) !void {
        // FIX: Initialize with empty struct, no allocator needed for creation
        try self.queues.put(node_id, .{});
    }

    pub fn send(self: *NetworkSimulator, _: NodeId, dest: NodeId, packet: Packet) !bool {
        if (self.rand.chance(self.packet_loss_rate)) {
            return false;
        }

        if (self.queues.getPtr(dest)) |queue| {
            // FIX: Pass allocator to append
            try queue.append(self.allocator, packet);
            return true;
        }
        return false;
    }

    pub fn recv(self: *NetworkSimulator, node: NodeId) ?Packet {
        if (self.queues.getPtr(node)) |queue| {
            if (queue.items.len > 0) {
                return queue.pop();
            }
        }
        return null;
    }
};
