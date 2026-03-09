# Issue: No Gossip Protocol Implementation

## Summary
The system has no mechanism for nodes to communicate and share state. The gossip protocol is essential for:
- Cluster membership (discovering other nodes)
- State synchronization between nodes
- Convergence of CRDTs across the cluster

## Critical Constraint: ZERO ALLOCATIONS AFTER STARTUP
> The hot path must have **zero heap allocations**. All buffers must be pre-allocated during init phase.

## Severity
**CRITICAL** - This is Phase 2 core functionality

## Phase
Phase 2: Networking

## Location
- New file needed: `src/net/gossip.zig`
- May need updates to: `src/main.zig`, `src/ecs/world.zig`

## Requirements
1. **Node Discovery**: Mechanism to find peer nodes (broadcast, static list, or DNS)
2. **State Exchange**: Periodic gossip of node metadata, service specs, placements
3. **Delta Encoding**: Only send changed state (as per proposal 04)
4. **Packet Format**: Sectioned payload with component kinds (NodeMeta, ServiceSpec, Placement)
5. **Convergence**: Ensure all nodes eventually see the same state

## Relevant Code/Proposals
- `proposal/04-wal-and-gossip.md` - Gossip encoding details
- `proposal/05-placement-reconcile-and-testing.md` - CRDT convergence
- `src/net/hlc.zig` - HLC timestamps for ordering
- `src/ecs/world.zig` - State that needs to be gossiped
- `src/util/limits.zig` - MAX_NODES, MAX_SERVICES limits

## Packet Format (from proposal)
```
Packet.payload (<= 944 bytes):
  SectionHeader(kind=NodeMeta, len=...) | section bytes
  SectionHeader(kind=ServiceSpec, len=...) | section bytes  
  SectionHeader(kind=Placement, len=...) | section bytes
```

## Suggested Approach
1. Create basic node membership tracking
2. Implement periodic gossip tick (every GOSSIP_INTERVAL_MS)
3. Use section headers with varint encoding for IDs
4. Delta encode HLC versions with delta-of-delta + zigzag
5. Add optional compression if payload helps

## Dependencies
- HLC timestamps (already implemented in `src/net/hlc.zig`)
- ECS world state (already implemented)
- Packet size limits from `src/util/limits.zig` (PACKET_SIZE = 1024)

## Test Strategy
1. Simulation tests with multiple "nodes" sharing state
2. Verify convergence under partition
3. Test delta encoding efficiency
