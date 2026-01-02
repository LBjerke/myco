// This file contains unit tests for the `myco.net.transport` module,
// specifically focusing on the `handshakeOptionsFromEnv` function.
// It verifies that when no relevant environment variables are set, the
// transport layer correctly defaults to disabling both forced and allowed
// plaintext communication. This ensures that secure (encrypted) connections
// are prioritized by default, validating the expected security posture
// of the Myco network's transport layer.
//
const std = @import("std");
const myco = @import("myco");
const transport = myco.net.transport;

test "transport: handshakeOptionsFromEnv defaults to plaintext disabled" {
    const opts = transport.handshakeOptionsFromEnv();
    try std.testing.expect(!opts.force_plaintext);
    try std.testing.expect(!opts.allow_plaintext);
}
