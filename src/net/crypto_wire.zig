// AES-GCM helper for Wire messages: derive a shared key from two pubkeys and seal/open payloads.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Key = [32]u8;
pub const Nonce = [12]u8;
pub const Tag = [16]u8;

/// Deterministically derive a shared key from server and client pubkeys.
pub fn deriveKey(server_pub: [32]u8, client_pub: [32]u8) Key {
    var hasher = Sha256.init(.{});
    hasher.update(&server_pub);
    hasher.update(&client_pub);
    return hasher.finalResult();
}

pub const SealResult = struct {
    nonce: Nonce,
    tag: Tag,
    ct_len: usize,
};

pub fn seal(key: Key, plaintext: []const u8, ct_out: []u8) !SealResult {
    if (ct_out.len < plaintext.len) return error.BufferTooSmall;

    var nonce: Nonce = undefined;
    std.crypto.random.bytes(&nonce);

    var tag: Tag = undefined;
    AesGcm.encrypt(ct_out[0..plaintext.len], &tag, plaintext, &[_]u8{}, nonce, key);

    return .{ .nonce = nonce, .tag = tag, .ct_len = plaintext.len };
}

pub fn open(key: Key, nonce: Nonce, tag: Tag, ct: []const u8, pt_out: []u8) ![]const u8 {
    if (pt_out.len < ct.len) return error.BufferTooSmall;
    try AesGcm.decrypt(pt_out[0..ct.len], ct, tag, &[_]u8{}, nonce, key);
    return pt_out[0..ct.len];
}
