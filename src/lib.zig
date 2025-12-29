// Public API surface aggregating core types and submodules for consumers/tests.
pub const node = @import("node.zig");
pub const Node = node.Node;
pub const Packet = @import("packet.zig").Packet;
pub const Headers = @import("packet.zig").Headers;
pub const limits = @import("core/limits.zig");

// ... inside pub const cli ...
pub const cli = struct {
    pub const init = @import("cli/init.zig");
    pub const deploy = @import("cli/deploy.zig"); // ADD THIS
};
// ... (previous imports)

pub const api = struct {
    pub const server = @import("api/server.zig");
};
pub const p2p = struct {
    pub const peers = @import("p2p/peers.zig");
};

// ... (rest of file)
// NEW: Schemas
pub const schema = struct {
    pub const service = @import("schema/service.zig");
};

// NEW: Engine Components
pub const engine = struct {
    pub const systemd = @import("engine/systemd.zig");
    // ADD THIS:
    pub const nix = @import("engine/nix.zig");
};

pub const net = struct {
    pub const handshake = @import("net/handshake.zig");
    pub const identity = @import("net/identity.zig");
    pub const protocol = @import("net/protocol.zig");
    pub const transport = @import("net/transport.zig");
    pub const gossip = @import("net/gossip.zig");
};

pub const db = struct {
    pub const wal = @import("db/wal.zig");
};

pub const sim = struct {
    pub const net = @import("sim/net.zig");
    pub const time = @import("sim/time.zig");
    pub const random = @import("sim/random.zig");
};
// ... (previous imports)

pub const sync = struct {
    // REPLACED merkle with crdt
    pub const crdt = @import("sync/crdt.zig");
    pub const delta_crdt = @import("sync/delta_crdt.zig");
    pub const hlc = @import("sync/hlc.zig");
};

pub const OutboundPacket = node.OutboundPacket;
// ... (rest of file)

pub const crypto = struct {
    pub const packet_crypto = @import("crypto/packet_crypto.zig");
};

pub const util = struct {
    pub const ux = @import("util/ux.zig");
    pub const frozen_allocator = @import("util/frozen_allocator.zig");
    pub const json_noalloc = @import("util/json_noalloc.zig");
    pub const process_noalloc = @import("util/process_noalloc.zig");
};

pub const core = struct {
    pub const config = @import("core/config.zig");
    pub const orchestrator = @import("core/orchestrator.zig");
};
