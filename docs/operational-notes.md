# Operational Notes

> **Status**: This document contains notes about planned features. Most items are not yet implemented.

## Compatibility and Invariants (Planned)

- Packet size: 1024 bytes (not yet enforced - `src/packet.zig` not implemented)
- Service payload size: ≤ 920 bytes to fit inside packet payload (not yet implemented)
- CRDT semantics: last-write-wins via Hybrid Logical Clocks; do not compare wall clocks directly
- WAL layout: `src/db/wal.zig` appends fixed-size entries with CRC32. See implemented WAL for current format.

## Implemented Invariants

- **Zero allocations**: Hot path must be allocation-free after initialization
- **Function length**: ≤70 lines (enforced by `zig build tiger-style`)
- **Line length**: ≤100 characters

## Gossip/CRDT Behavior (Planned)

- `MYCO_GOSSIP_FANOUT`: rumor fanout (default 4) for forwarding Deploy packets.
- Delta digest sent when dirty.
- Sample digest every 50 ticks when idle.
- Control message every 10 ticks with optional delta digest.
- Miss handling: up to 1024 missing ids tracked.

## Implemented Components

| Component | File | Status |
|-----------|------|--------|
| Frozen allocator | `src/util/allocator.zig` | ✅ Implemented |
| WAL | `src/db/wal.zig` | ✅ Implemented |
| ECS | `src/ecs/world.zig` | ✅ Implemented |
| Events | `src/core/event.zig` | ✅ Implemented |
| Reducers | `src/core/reducer.zig` | ✅ Implemented |
| HLC | `src/net/hlc.zig` | ✅ Implemented |
| Packet format | `src/packet.zig` | ⏳ Not implemented |
| Gossip protocol | - | ⏳ Not implemented |
| CLI/API | - | ⏳ Not implemented |
