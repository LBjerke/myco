// This file contains a benchmark test for the packet-level cryptography
// implemented in `myco.crypto.packet_crypto`. Its purpose is to measure the
// performance of the `seal` (encryption) and `open` (decryption) operations
// on a full packet payload. This benchmark provides crucial insights into
// the cryptographic overhead and efficiency of secure communication within
// the Myco network.
//
const std = @import("std");
const myco = @import("myco");

const Packet = myco.Packet;
const PacketCrypto = myco.crypto.packet_crypto;

test "benchmark packet crypto" {
    // Generate identities for Alice and Bob for encryption/decryption
    var seed_a: [32]u8 = undefined; std.crypto.random.bytes(&seed_a);
    const kp_a = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_a);
    
    var seed_b: [32]u8 = undefined; std.crypto.random.bytes(&seed_b);
    const kp_b = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_b);

    var pkt = Packet{};
    pkt.payload_len = @intCast(pkt.payload.len);
    for (pkt.payload, 0..) |_, idx| {
        pkt.payload[idx] = @truncate(idx);
    }
    pkt.sender_pubkey = kp_a.public_key.bytes; // Alice's public key as sender

    const dest_id: u16 = 4242; // This is now a dummy and not used by new crypto
    _ = dest_id; // Silence unused variable warning
    const iters: usize = 2000;

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        // Seal from A to B
        PacketCrypto.seal(&pkt, seed_a, kp_b.public_key.bytes) catch unreachable;
        // Open at B (using Bob's seed, and pkt's sender_pubkey which is Alice's)
        _ = PacketCrypto.open(&pkt, seed_b) catch unreachable;
    }
    const elapsed_ns = timer.read();
    const ns_per_op = if (iters == 0) 0 else elapsed_ns / (iters * 2);
    std.debug.print("[bench] packet_crypto seal+open: {d} ns/op\n", .{ns_per_op});
}
