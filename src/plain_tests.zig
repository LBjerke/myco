// Aggregated unit tests that need the module root at src/.
// This file serves as an aggregation point for various unit tests located throughout
// different submodules of the Myco project. By importing these tests, it allows for
// their consolidated execution, particularly for tests that require the module root
// context or are part of a broader test suite.
//
test {
    _ = @import("db/wal.zig");
    _ = @import("net/handshake.zig");
    _ = @import("p2p/peers.zig");
    _ = @import("runtime_noalloc_test.zig");
    _ = @import("util/ux.zig");
    _ = @import("engine/nix.zig");
}
