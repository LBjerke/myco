pub const MAX_PEERS: usize = 50;
pub const MAX_SERVICES: usize = 256;
pub const MAX_CONNECTIONS: usize = 32;
pub const PACKET_SIZE: usize = 1024;
// 64MB Global Slab
pub const GLOBAL_MEMORY_SIZE: usize = 64 * 1024 * 1024; 
// Standard Linux PATH_MAX
pub const PATH_MAX: usize = 4096; 
// Max items to track for gossip repair
pub const MAX_MISSING_ITEMS: usize = 1024;
