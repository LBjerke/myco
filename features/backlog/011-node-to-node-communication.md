# Issue: No Node-to-Node Communication

## Summary
Nodes cannot send or receive network packets to synchronize state. Need a networking layer for:
- Binding to a port to listen for incoming gossip
- Connecting to peer nodes to send gossip
- Handling UDP/TCP communication

## Critical Constraint: ZERO ALLOCATIONS AFTER STARTUP
> The hot path must have **zero heap allocations**. All buffers must be pre-allocated during init phase.

## Severity
**CRITICAL** - Required for Phase 2

## Phase
Phase 2: Networking

## Location
- New file: `src/net/transport.zig` or similar
- Integration: `src/main.zig` tick loop

## Requirements
1. **UDP-based gossip**: Use UDP for efficient broadcast-style communication
2. **Peer addressing**: Store peer IP:port addresses
3. **Packet serialization**: Convert gossip payloads to/from bytes
4. **Non-blocking I/O**: Must work with the tick loop (no blocking calls)

## Current Constraints
- Zero-allocation runtime after init (no heap allocations in tick loop)
- Fixed packet size (1024 bytes from limits.zig)
- Must integrate with frozen allocator during init only

## Suggested Approach
1. During init phase:
   - Parse configuration for peer addresses
   - Allocate send/receive buffers (pre-allocated from frozen allocator)
   - Open UDP socket and bind to port
2. In tick loop:
   - Non-blocking receive to process incoming packets
   - Periodic send to peer nodes

## Relevant Code
- `src/util/limits.zig` - PACKET_SIZE = 1024
- `src/net/hlc.zig` - Timestamps for message ordering
- `src/net/gossip.zig` - Will use this transport

## Packet Size Calculation
- Total: 1024 bytes
- Network header: ~60 bytes (IP + UDP)
- Available for payload: ~944 bytes
- This matches proposal 04 specification

## Dependencies
- Issue #010: Gossip Protocol (must be implemented first or parallel)
- WAL must be working (already implemented)

## Test Strategy
1. Unit tests for packet serialization/deserialization
2. Simulation with fake network
3. Integration tests with multiple real nodes (if possible)
