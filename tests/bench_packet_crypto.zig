const std = @import("std");
const myco = @import("myco");

const Packet = myco.Packet;
const PacketCrypto = myco.crypto.packet_crypto;

test "benchmark packet crypto" {
    var pkt = Packet{};
    pkt.payload_len = @intCast(pkt.payload.len);
    for (pkt.payload, 0..) |_, idx| {
        pkt.payload[idx] = @truncate(idx);
    }
    var pubkey: [32]u8 = undefined;
    for (pubkey, 0..) |_, idx| pubkey[idx] = @truncate(idx * 3);
    pkt.sender_pubkey = pubkey;

    const dest_id: u16 = 4242;
    const iters: usize = 2000;

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        PacketCrypto.seal(&pkt, dest_id);
        _ = PacketCrypto.open(&pkt, dest_id);
    }
    const elapsed_ns = timer.read();
    const ns_per_op = if (iters == 0) 0 else elapsed_ns / (iters * 2);
    std.debug.print("[bench] packet_crypto seal+open: {d} ns/op\n", .{ns_per_op});
}
