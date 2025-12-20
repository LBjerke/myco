// Packet-level crypto: derive a per-link key from sender pubkey + dest id,
// encrypt payload with ChaCha20-Poly1305 (AEAD), and authenticate with a 128-bit tag.
const std = @import("std");
const Packet = @import("../packet.zig").Packet;
const Blake3 = std.crypto.hash.Blake3;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const AdLen = 46; // fixed bytes of bound header fields + sender key

const default_secret = "myco-default-packet-key";

const SecretSlot = struct {
    key: [32]u8 = undefined,
    epoch: u32 = 0,
    valid: bool = false,
};

const ConfigSnapshot = struct {
    k0: [32]u8,
    e0: u32,
    k1: [32]u8,
    e1: u32,
    v1: bool,
};

var slots = [_]SecretSlot{ .{}, .{} };
var configured = std.atomic.Value(bool).init(false);
var psk_mix: [32]u8 = [_]u8{0} ** 32;

fn hashSecret(secret_bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    var h = Blake3.init(.{});
    h.update(secret_bytes);
    h.final(&out);
    return out;
}

fn snapshot() ConfigSnapshot {
    return .{
        .k0 = slots[0].key,
        .e0 = slots[0].epoch,
        .k1 = slots[1].key,
        .e1 = slots[1].epoch,
        .v1 = slots[1].valid,
    };
}

fn equals(a: ConfigSnapshot, b: ConfigSnapshot) bool {
    return std.mem.eql(u8, &a.k0, &b.k0) and a.e0 == b.e0 and std.mem.eql(u8, &a.k1, &b.k1) and a.e1 == b.e1 and a.v1 == b.v1;
}

pub fn configure(current_secret: []const u8, current_epoch: u32, prev_secret: ?[]const u8, prev_epoch: ?u32) void {
    slots[0] = .{ .key = hashSecret(current_secret), .epoch = current_epoch, .valid = true };
    slots[1] = if (prev_secret) |ps|
        .{ .key = hashSecret(ps), .epoch = prev_epoch orelse current_epoch, .valid = true }
    else
        .{};
    configured.store(true, .seq_cst);
}

pub fn configureFromEnv() void {
    const env_secret = std.posix.getenv("MYCO_PACKET_KEY");
    const env_epoch = std.posix.getenv("MYCO_PACKET_EPOCH");
    const prev_secret = std.posix.getenv("MYCO_PACKET_KEY_PREV");
    const prev_epoch_env = std.posix.getenv("MYCO_PACKET_EPOCH_PREV");
    const psk_env = std.posix.getenv("MYCO_GOSSIP_PSK");
    const curr_epoch = if (env_epoch) |e| std.fmt.parseInt(u32, e, 10) catch 1 else 1;
    const prev_epoch = if (prev_epoch_env) |e| std.fmt.parseInt(u32, e, 10) catch curr_epoch else curr_epoch;
    psk_mix = hashSecret(psk_env orelse "");
    if (prev_secret) |ps| {
        configure(env_secret orelse default_secret, curr_epoch, ps, prev_epoch);
    } else {
        configure(env_secret orelse default_secret, curr_epoch, null, null);
    }
}

fn refreshFromEnvIfChanged() void {
    const before = snapshot();
    configureFromEnv();
    const after = snapshot();
    if (configured.load(.seq_cst) and equals(before, after)) {
        return;
    }
}

fn deriveKey(secret: [32]u8, sender_pubkey: [32]u8, dest_id: u16, epoch: u32) [32]u8 {
    var key: [32]u8 = undefined;
    var hasher = Blake3.init(.{ .key = secret });
    const epoch_bytes = [4]u8{
        @truncate(epoch),
        @truncate(epoch >> 8),
        @truncate(epoch >> 16),
        @truncate(epoch >> 24),
    };
    hasher.update(&epoch_bytes);
    hasher.update(&psk_mix);
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
    refreshFromEnvIfChanged();

    var nonce: [Aead.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    // Prefix nonce with epoch for key rotation.
    const curr_epoch = slots[0].epoch;
    nonce[0] = @truncate(curr_epoch);
    nonce[1] = @truncate(curr_epoch >> 8);
    nonce[2] = @truncate(curr_epoch >> 16);
    nonce[3] = @truncate(curr_epoch >> 24);
    pkt.nonce = nonce;

    const key = deriveKey(slots[0].key, pkt.sender_pubkey, dest_id, curr_epoch);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);
    const payload_slice = pkt.payload[0..len];
    var ad_buf: [AdLen]u8 = undefined;
    const ad = makeAssociatedData(pkt, &ad_buf);

    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(payload_slice, &tag, payload_slice, ad, pkt.nonce, key);
    pkt.auth_tag = tag;
}

pub fn open(pkt: *Packet, dest_id: u16) bool {
    refreshFromEnvIfChanged();
    const epoch: u32 = @as(u32, pkt.nonce[0]) |
        (@as(u32, pkt.nonce[1]) << 8) |
        (@as(u32, pkt.nonce[2]) << 16) |
        (@as(u32, pkt.nonce[3]) << 24);
    var key: ?[32]u8 = null;
    for (slots) |slot| {
        if (slot.valid and slot.epoch == epoch) {
            key = slot.key;
            break;
        }
    }
    if (key == null) return false;
    const derived = deriveKey(key.?, pkt.sender_pubkey, dest_id, epoch);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);
    const payload_slice = pkt.payload[0..len];
    var ad_buf: [AdLen]u8 = undefined;
    const ad = makeAssociatedData(pkt, &ad_buf);

    if (Aead.decrypt(payload_slice, payload_slice, pkt.auth_tag, ad, pkt.nonce, derived)) |_| {
        return true;
    } else |_| {
        return false;
    }
}
