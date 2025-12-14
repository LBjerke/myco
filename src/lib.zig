pub const node = @import("node.zig");
pub const Node = node.Node;
pub const Packet = @import("packet.zig").Packet;

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
};

pub const db = struct {
    pub const wal = @import("db/wal.zig");
};

pub const sim = struct {
    pub const net = @import("sim/net.zig");
    pub const time = @import("sim/time.zig");
    pub const random = @import("sim/random.zig");
};
