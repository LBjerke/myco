# Issue: No Delta Encoding for Efficient Sync

## Summary
Full state is sent on every gossip round, which is inefficient. Need delta encoding to only send changes since last sync.

## Critical Constraint: ZERO ALLOCATIONS AFTER STARTUP
> The hot path must have **zero heap allocations**. All buffers must be pre-allocated during init phase.

## Severity
**HIGH** - Important for bandwidth efficiency

## Phase
Phase 2: Networking

## Location
- Likely in: `src/net/gossip.zig` or new `src/net/delta.zig`
- Updates to: packet serialization

## Requirements
1. **Track versions**: Each state entry has HLC version
2. **Delta detection**: Know what's changed since last sync with each peer
3. **Efficient encoding**: 
   - Varint for IDs (delta varints after first)
   - Delta-of-delta with zigzag for HLC versions
   - Columnar encoding for compact传输
4. **Merge handling**: Apply received deltas correctly

## Encoding Strategy (from proposal 04)

### IDs
- First ID: full varint
- Subsequent IDs: delta varints

### HLC Versions
```
wall_ms: delta-of-delta with zigzag
logical: varint
```

### Section Flow
```
Dirty keys → stable order → encode IDs → encode versions → optional compress
```

## Current State
- HLC timestamps exist in `src/net/hlc.zig`
- No version tracking on ECS entries yet
- Need to add "dirty" tracking to world state

## Suggested Implementation
1. Add version/dirty tracking to ECS components:
   - Track last gossip version for each entry
   - Mark entries dirty when changed
   - Clear dirty flag after gossip
2. Implement delta encoder:
   - Filter to dirty entries only
   - Sort by ID for delta encoding
   - Encode with varint/delta-of-delta
3. Handle merge:
   - Receive deltas from peers
   - Apply with max(version) semantics for CRDT

## Dependencies
- Issue #010: Gossip Protocol (needs delta encoding)
- Issue #011: Node Communication (needs to send deltas)
- ECS world state in `src/ecs/world.zig`

## Testing
1. Verify delta is smaller than full state
2. Test convergence with multiple nodes exchanging deltas
3. Edge cases: empty deltas, full sync needed, version conflicts
