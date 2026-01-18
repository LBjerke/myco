const std = @import("std");
const packet_crypto = @import("../src/crypto/packet_crypto.zig");

test {
    std.testing.refAllDecls(packet_crypto);
}
