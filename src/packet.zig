const std = @import("std");

pub const Packet = extern struct {
    pub const Headers = struct {
        pub const GOSSIP: u64 = 0xCAFEBABE;
        pub const DEPLOY: u64 = 0xD34DC0DE;
        /// "Sync" - Offering a digest (ASCII "SYNCSYNC")
        pub const SYNC: u64 = 0x53594E4353594E43; 
        /// "Request" - Asking for data (ASCII "REQUEST!")
        pub const REQUEST: u64 = 0x5245515545535421;
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
