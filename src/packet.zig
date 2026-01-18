// Defines the fixed-size packet structure exchanged between nodes over the network/simulator.
// This file defines the fixed-size `Packet` structure, which is the fundamental unit
// of network communication within the Myco system. It specifies the layout for
// headers, metadata, security-related fields (sender public key, nonce, auth tag),
// and the payload, ensuring consistent and efficient data exchange between nodes.
//
const std = @import("std");

pub const Headers = struct {
    pub const Deploy: u8 = 1;
    pub const Sync: u8 = 2;
    pub const Request: u8 = 3;
    pub const Control: u8 = 4; // health/ping with optional ops
};

pub const Packet = extern struct {
    magic: u16 = 0x4d59, // "MY"
    version: u8 = 1,
    msg_type: u8 = 0, // Headers.*
    node_id: u16 = 0,
    zone_id: u8 = 0,
    flags: u8 = 0,
    revocation_block: u32 = 0,
    payload_len: u16 = 0,

    sender_pubkey: [32]u8 = [_]u8{0} ** 32,
    nonce: [24]u8 = [_]u8{0} ** 24,
    auth_tag: [16]u8 = [_]u8{0} ** 16,

    // Payload fills the remainder to 1024 bytes.
    payload: [936]u8 align(@alignOf(u64)) = [_]u8{0} ** 936,

    pub fn setPayload(self: *Packet, value: u64) void {
        std.mem.writeInt(u64, self.payload[0..8], value, .little);
        self.payload_len = 8;
    }

    pub fn getPayload(self: *const Packet) u64 {
        return std.mem.readInt(u64, self.payload[0..8], .little);
    }
};

pub const PayloadLen: usize = 936;

pub const Flags = struct {
    pub const PayloadCompressed: u8 = 0x01;
};

pub const MycoOp = packed struct {
    op_kind: u8, // e.g., deploy/sync/request/control
    obj_kind: u8, // e.g., service/metadata
    obj_id: u32, // service id or key
    version: u32, // CRDT version
    value_len: u16,
};

comptime {
    if (@sizeOf(Packet) != 1024) {
        @compileError("Constitutional Violation: Packet must be exactly 1024 bytes.");
    }
}
