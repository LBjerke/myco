// Aggregated unit tests that need the module root at src/.
test {
    _ = @import("db/wal.zig");
    _ = @import("net/handshake.zig");
    _ = @import("p2p/peers.zig");
    _ = @import("util/ux.zig");
    _ = @import("engine/nix.zig");
}
