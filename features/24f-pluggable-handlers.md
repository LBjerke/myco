# Feature: Pluggable Event Handlers

> Status: 🔄 Planned (Feature 24 Phase 6)

## Summary

Implement an EventHandler interface so that different backends can be swapped without changing core code. This enables flexibility and easier testing.

## Original Ask

Currently WAL is hardcoded into core. Events should flow through user-provided handlers so that different backends can be used.

## Implementation

### Handler Trait/Interface

```zig
/// Event handler interface
/// User implements to receive events from reducer
pub const EventHandler = struct {
    /// Handle an event (called after reducer)
    handleEvent: fn(ctx: *anyopaque, world: *World, event: Event, effect: Effect) void,
    
    /// Get handler type for identification
    handlerType: HandlerType,
};

/// Handler types
pub const HandlerType = enum {
    wal,        // Persistent WAL handler
    discard,    // Testing - discard all events
    custom,     // User-defined handler
    coredump,   // Dump state on errors
    relay,      // Minimal relay mode
};

/// Create a handler
pub fn createHandler(handler_type: HandlerType, config: anytype) !*EventHandler {
    switch (handler_type) {
        .wal => return try WalHandler.create(config),
        .discard => return try DiscardHandler.create(),
        .coredump => return try CoreDumpHandler.create(config),
        .relay => return try RelayHandler.create(config),
        .custom => return error.Unimplemented,
    }
}
```

### Built-in Handlers

```zig
/// WAL Handler - persist events to mmap'd WAL
pub const WalHandler = struct {
    wal: *MmapWal,
    
    pub fn create(config: WalConfig) !*EventHandler {
        var wal = try MmapWal.init(config.path);
        return &handler;
    }
    
    pub fn handleEvent(ctx: *anyopaque, world: *World, event: Event, effect: Effect) void {
        const handler = @ptrCast(*WalHandler, @alignCast(ctx));
        handler.wal.append(event) catch {
            // Handle error - log, continue
        };
    }
};

/// Discard Handler - for testing
pub const DiscardHandler = struct {
    event_count: usize = 0,
    
    pub fn create() !*EventHandler {
        return // handler instance
    }
    
    pub fn handleEvent(ctx: *anyopaque, world: *World, event: Event, effect: Effect) void {
        // Do nothing - discard all events
        const handler = @ptrCast(*DiscardHandler, @alignCast(ctx));
        handler.event_count += 1;
    }
};

/// Relay Handler - minimal forward-only mode
pub const RelayHandler = struct {
    peer_list: []PeerAddress,
    
    pub fn create(config: RelayConfig) !*EventHandler {
        return // handler instance
    }
    
    pub fn handleEvent(ctx: *anyopaque, world: *World, event: Event, effect: Effect) void {
        // Forward to all peers - don't store locally
        const handler = @ptrCast(*RelayHandler, @alignCast(ctx));
        for (handler.peer_list) |peer| {
            network.send(peer, event);
        }
    }
};
```

### Integration with Tick Loop

```zig
/// Tick loop with pluggable handlers
fn tickLoop(world: *World, handler: *EventHandler) !void {
    while (true) {
        // Process incoming
        // ... receive packet ...
        
        // Reduce
        const result = reduce(world, event);
        
        // Emit to handler (WAL, database, or discard)
        handler.handleEvent(world, event, result.effect);
        
        // Execute effects
        // ...
    }
}
```

## Performance Impact

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Handler overhead | N/A (hardcoded) | <1% | Negligible |
| Flexibility | None | Full | ✅ User-swappable |
| Testability | Hard to test | Easy | ✅ DiscardHandler |

## Dependencies

- None - this is a core refactor

## Testing

| Test | Description |
|------|-------------|
| `test "WalHandler persists events"` | WAL integration works |
| `test "DiscardHandler discards"` | Discard works |
| `test "handler swap during runtime"` | Can swap handlers |

## Where Code Was Added/Changed

| File | Changes |
|------|---------|
| `src/net/handler.zig` | NEW FILE - EventHandler interface, WALHandler, DiscardHandler, RelayHandler |
| `src/main.zig` | Update tick loop to use handler |
| `src/lib.zig` | Export EventHandler |

## Summary

Pluggable handlers provide <1% overhead with maximum flexibility. Users can swap backends without changing core, and testing becomes much easier with DiscardHandler.