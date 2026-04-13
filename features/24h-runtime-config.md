# Feature: Runtime Configuration for Memory

> Status: 🔄 Planned (Feature 24 Phase 8)

## Summary

Allow runtime configuration of memory limits instead of compile-time constants. This enables flexible memory usage for different deployment scenarios.

## Original Ask

Currently limits are compile-time constants. Make them runtime-configurable so users can tune memory usage for their specific hardware.

## Implementation

```zig
/// Runtime configuration for memory-bound resources
pub const RuntimeConfig = struct {
    /// Maximum nodes in the cluster (default 16, max 64)
    max_nodes: u8 = 16,
    
    /// Maximum services in the cluster (default 64, max 256)
    max_services: u8 = 64,
    
    /// WAL write buffer size (default 8 KB, max 64 KB)
    wal_buffer_size: usize = 8 * 1024,
    
    /// WAL temp buffer size (default 8 KB, max 64 KB)
    wal_temp_size: usize = 8 * 1024,
    
    /// mmap WAL region size (default 4 MB, max 16 MB)
    wal_mmap_size: usize = 4 * 1024 * 1024,
    
    /// Gossip buffer size
    gossip_buffer_size: usize = 4096,
    
    /// Validate configuration
    pub fn validate(config: *const RuntimeConfig) !void {
        if (config.max_nodes > 64) return error.TooManyNodes;
        if (config.max_services > 256) return error.TooManyServices;
        if (config.wal_buffer_size > 64 * 1024) return error.WalBufferTooLarge;
        // ... more validation
    }
};

/// Runtime-configurable world
pub const RuntimeWorld = struct {
    /// Actual limits based on config
    max_nodes: usize,
    max_services: usize,
    
    /// Dynamic arrays based on config
    nodes: []Node,
    node_index: []u16,
    services: []ServiceSpec,
    service_index: []u16,
    
    /// Create world from config
    pub fn init(config: RuntimeConfig, allocator: std.mem.Allocator) !RuntimeWorld {
        try config.validate();
        
        return .{
            .max_nodes = config.max_nodes,
            .max_services = config.max_services,
            .nodes = try allocator.alloc(Node, config.max_nodes),
            .node_index = try allocator.alloc(u16, config.max_nodes + 1),
            .services = try allocator.alloc(ServiceSpec, config.max_services),
            .service_index = try allocator.alloc(u16, config.max_services + 1),
        };
    }
};
```

## Memory Reduction Options

| Option | Default | Reduced | Memory Saved |
|--------|---------|---------|---------------|
| Max nodes | 16 | 16 (runtime) | ~50 bytes |
| Max services | 64 | 64 (runtime) | ~200 bytes |
| WAL write buffer | 64 KB | 8 KB | 56 KB |
| WAL temp buffer | 64 KB | 8 KB | 56 KB |
| Packet pool | 64 KB | 0 (stack) | 64 KB |
| mmap WAL | 16 MB | 4 MB | 12 KB |

## Performance Impact

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Memory usage | Fixed | Configurable | ✅ Flexible |
| Pi Zero fit | ~140 KB | Down to ~50 KB | **64%** |

## Dependencies

- None - can be done anytime

## Where Code Was Added/Changed

| File | Changes |
|------|---------|
| `src/util/config.zig` | NEW FILE - RuntimeConfig struct |

## Summary

Runtime configuration enables flexible memory usage for different hardware, from Pi Zero (reduced) to server (maximum).