const std = @import("std");
const Packet = @import("packet.zig").Packet;
// FIX: Access Headers via the Packet namespace
const Headers = Packet.Headers; 
const Identity = @import("net/handshake.zig").Identity;
const WAL = @import("db/wal.zig").WriteAheadLog;
const Service = @import("schema/service.zig").Service;

pub const Node = struct {
    id: u16,
    allocator: std.mem.Allocator,
    identity: Identity,
    wal: WAL,
    
    // STATE
    knowledge: u64 = 0,
    last_deployed_id: u64 = 0,

    pub fn init(id: u16, allocator: std.mem.Allocator, disk_buffer: []u8) !Node {
        var node = Node{
            .id = id,
            .allocator = allocator,
            .identity = Identity.initDeterministic(id),
            .wal = WAL.init(disk_buffer),
            .knowledge = 0,
            .last_deployed_id = 0,
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

    pub fn tick(self: *Node, inputs: []const Packet, outputs: *std.ArrayList(Packet), output_allocator: std.mem.Allocator) !void {
        var state_changed = false;

        for (inputs) |p| {
            if (!Identity.verify(p.sender_pubkey, &p.payload, p.signature)) continue;

            // SWITCH ON PACKET TYPE
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
                    if (service.id > self.last_deployed_id) {
                        self.last_deployed_id = service.id;
                        state_changed = true; 
                    }
                },
                else => {}, 
            }
        }

        if (self.knowledge < 100 and self.knowledge % 37 == 0) { 
            self.knowledge += 1;
            state_changed = true;
        }

        if (state_changed) {
            self.wal.append(self.knowledge) catch {}; 
        }

        var p = Packet{ 
            .header = Headers.GOSSIP,
            .sender_pubkey = self.identity.key_pair.public_key.toBytes(),
        };
        p.setPayload(self.knowledge);
        p.signature = self.identity.sign(&p.payload);
        try outputs.append(output_allocator, p);
    }
};
