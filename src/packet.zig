const std = @import("std");

pub const Packet = extern struct {
    /// Magic Constants for Packet Headers
    pub const Headers = struct {
        /// "Gossip" - Protocol Maintenance (Hex for Cafe Babe)
        pub const GOSSIP: u64 = 0xCAFEBABE;
        /// "Deploy" - Service Injection (Hex for Deployed Code)
        pub const DEPLOY: u64 = 0xD34DC0DE;
    };

    header: u64 = 0,
    sender_pubkey: [32]u8 = [_]u8{0} ** 32,
    signature: [64]u8 = [_]u8{0} ** 64,
    
    // Payload: 920 bytes
    payload: [920]u8 = [_]u8{0} ** 920,

    pub fn setPayload(self: *Packet, value: u64) void {
        std.mem.writeInt(u64, self.payload[0..8], value, .little);
    }

    pub fn getPayload(self: *const Packet) u64 {
        return std.mem.readInt(u64, self.payload[0..8], .little);
    }
};

comptime {
    if (@sizeOf(Packet) != 1024) {
        @compileError("Constitutional Violation: Packet must be exactly 1024 bytes.");
    }
}
