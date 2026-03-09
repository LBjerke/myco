# Issue: No WAL Compaction/Snapshotting

## Summary
WAL grows unbounded - replay time will increase indefinitely. Need compaction as per proposal 04.

## Critical Constraint: ZERO ALLOCATIONS AFTER STARTUP
> The hot path must have **zero heap allocations**. All buffers must be pre-allocated during init phase.
> Note: Compaction happens during init phase (before freeze), so this is less critical but still important.

## Severity
**MEDIUM** - Performance issue that will affect long-running systems

## Phase
Phase 1 (remaining) - or Phase 5 (Production Hardening)

## Location
- `src/db/wal.zig` - needs new compaction functions
- New file: `src/db/snapshot.zig` maybe

## Problem
- WAL is append-only with segments
- Each restart replays entire history
- Long-running systems will have slow startup

## Requirements (from proposal 04)
1. **Periodic compaction**: Create snapshots periodically
2. **Snapshot format**: Serialize current ECS world state
3. **Checkpoint entry**: Write checkpoint marker to new WAL segment
4. **Cleanup**: Remove old WAL segments after successful snapshot

## Compaction Flow (from proposal)
```
Before:
  wal.0001 + wal.0002 + wal.0003 + wal.0004

Compact:
  snapshot(world) -> snap.bin
  write checkpoint -> wal.0005
  delete old segments

After:
  snap.bin + wal.0005
```

## Implementation Suggestions
1. **Snapshot during init phase** (before freeze):
   - Serialize all ECS tables to binary
   - Write to `snap.bin` or similar
2. **On startup**:
   - Load snapshot if exists
   - Replay WAL from checkpoint forward
3. **Periodic trigger**:
   - Time-based (every N minutes)
   - Event-based (after N events)
   - Manual trigger

## Dependencies
- WAL implementation (#003 already done)
- ECS world serialization

## Testing
1. Create snapshot, modify state, restart - should see both
2. Test with corrupted snapshot
3. Test snapshot version upgrades (future)
