const std = @import("std");
const myco = @import("myco");
const transport = myco.net.transport;

test "transport: handshakeOptionsFromEnv defaults to plaintext disabled" {
    const opts = transport.handshakeOptionsFromEnv();
    try std.testing.expect(!opts.force_plaintext);
    try std.testing.expect(!opts.allow_plaintext);
}
