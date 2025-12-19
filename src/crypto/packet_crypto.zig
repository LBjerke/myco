// Packet-level crypto: derive a per-link key from sender pubkey + dest id,
// encrypt payload with ChaCha20-Poly1305 (AEAD), and authenticate with a 128-bit tag.
const std = @import("std");
const Packet = @import("../packet.zig").Packet;
const Blake3 = std.crypto.hash.Blake3;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const AdLen = 46; // fixed bytes of bound header fields + sender key

fn deriveKey(sender_pubkey: [32]u8, dest_id: u16) [32]u8 {
    var key: [32]u8 = undefined;
    var hasher = Blake3.init(.{});
    hasher.update(&sender_pubkey);
    const dest_bytes = [2]u8{
        @as(u8, @truncate(dest_id)),
        @as(u8, @truncate(dest_id >> 8)),
    };
    hasher.update(&dest_bytes);
    hasher.final(&key);
    return key;
}

fn makeAssociatedData(pkt: *const Packet, buf: *[AdLen]u8) []const u8 {
    // Bind immutable fields to the AEAD tag so header tampering is detected.
    // Layout: magic|version|msg_type|node_id|zone_id|flags|revocation_block|payload_len|sender_pubkey
    var idx: usize = 0;
    buf[idx] = @truncate(pkt.magic);
    buf[idx + 1] = @truncate(pkt.magic >> 8);
    idx += 2;
    buf[idx] = pkt.version;
    idx += 1;
    buf[idx] = pkt.msg_type;
    idx += 1;
    buf[idx] = @truncate(pkt.node_id);
    buf[idx + 1] = @truncate(pkt.node_id >> 8);
    idx += 2;
    buf[idx] = pkt.zone_id;
    idx += 1;
    buf[idx] = pkt.flags;
    idx += 1;
    buf[idx] = @truncate(pkt.revocation_block);
    buf[idx + 1] = @truncate(pkt.revocation_block >> 8);
    buf[idx + 2] = @truncate(pkt.revocation_block >> 16);
    buf[idx + 3] = @truncate(pkt.revocation_block >> 24);
    idx += 4;
    buf[idx] = @truncate(pkt.payload_len);
    buf[idx + 1] = @truncate(pkt.payload_len >> 8);
    idx += 2;
    @memcpy(buf[idx .. idx + pkt.sender_pubkey.len], &pkt.sender_pubkey);
    idx += pkt.sender_pubkey.len;
    return buf[0..idx];
}

pub fn seal(pkt: *Packet, dest_id: u16) void {
    var nonce: [Aead.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    pkt.nonce = nonce;

    const key = deriveKey(pkt.sender_pubkey, dest_id);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);
    const payload_slice = pkt.payload[0..len];
    var ad_buf: [AdLen]u8 = undefined;
    const ad = makeAssociatedData(pkt, &ad_buf);

    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(payload_slice, &tag, payload_slice, ad, pkt.nonce, key);
    pkt.auth_tag = tag;
}

pub fn open(pkt: *Packet, dest_id: u16) bool {
    const key = deriveKey(pkt.sender_pubkey, dest_id);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);
    const payload_slice = pkt.payload[0..len];
    var ad_buf: [AdLen]u8 = undefined;
    const ad = makeAssociatedData(pkt, &ad_buf);

    if (Aead.decrypt(payload_slice, payload_slice, pkt.auth_tag, ad, pkt.nonce, key)) |_| {
        return true;
    } else |_| {
        return false;
    }
}
