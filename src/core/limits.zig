const build_options = @import("build_options");

pub const MAX_PEERS: usize = build_options.max_peers;
pub const MAX_SERVICES: usize = build_options.max_services;
pub const MAX_CONNECTIONS: usize = 32;
pub const PACKET_SIZE: usize = 1024;
// 64MB Global Slab
pub const GLOBAL_MEMORY_SIZE: usize = 64 * 1024 * 1024;
// Standard Linux PATH_MAX
pub const PATH_MAX: usize = 4096;
// Max items to track for gossip repair
pub const MAX_MISSING_ITEMS: usize = 1024;
// Outbox capacity for per-tick outbound packets
pub const MAX_OUTBOX: usize = 256;
// Max JSON config size for disk/transport payloads
pub const MAX_CONFIG_JSON: usize = 900 * 1024;
// Max gossip entries to keep JSON payloads under packet limits
pub const MAX_GOSSIP_SUMMARY: usize = 64;
// Recent deltas to piggyback on health/control messages
pub const MAX_RECENT_DELTAS: usize = 256;
// Fixed-size schema caps (keep in sync with schema/service.zig)
pub const MAX_SERVICE_NAME: usize = 32;
pub const MAX_FLAKE_URI: usize = 128;
pub const MAX_EXEC_NAME: usize = 32;
// Peer file parsing limits
pub const MAX_PEER_LINE: usize = 128;
// UX/API formatting buffers
pub const MAX_LOG_LINE: usize = 1024;
pub const MAX_API_RESPONSE: usize = 2048;
