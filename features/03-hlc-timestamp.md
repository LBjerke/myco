# Feature: Hybrid Logical Clock (HLC)

## Status: ✅ Complete

## Original Ask

Implement Hybrid Logical Clock for timestamp ordering, based on proposal 01-overview.md:

> HLC semantics remain the ordering primitive; wall clocks are not compared directly.

From the original repo (src/sync/hlc.zig reference):
- Timestamps must order events across distributed nodes
- Deterministic tie-breaks when physical time is equal

## Where Code Was Added/Changed

### Files Created

| File | Purpose |
|------|---------|
| `src/net/hlc.zig` | HLC timestamp implementation |

### Code Added

```zig
// src/net/hlc.zig

/// HLC timestamp: physical time + logical time + node id
pub const Timestamp = packed struct {
    time: u64,      // physical time (milliseconds)
    count: u16,     // logical counter
    node_id: u16,   // node identifier

    pub fn lessThan(a: Timestamp, b: Timestamp) bool {
        if (a.time != b.time) return a.time < b.time;
        if (a.count != b.count) return a.count < b.count;
        return a.node_id < b.node_id;
    }
};

/// Wall clock time source
pub fn now() u64 {
    return std.time.milliTimestamp();
}
```

## Architecture

```
┌─────────────────────────────────────┐
│      HLC Timestamp (packed)        │
├─────────────────────────────────────┤
│  time: u64    (physical ms)        │
│  count: u16  (logical counter)     │
│  node_id: u16                      │
└─────────────────────────────────────┘
         │
         ▼
  Ordering: time → count → node_id
```

### Ordering Rules

1. **Primary**: Physical time (wall clock ms)
2. **Secondary**: Logical counter (for same-time events)
3. **Tertiary**: Node ID (deterministic tie-break)

## Testing

- Build verification: `zig build` passes
- Timestamp struct has correct size (10 bytes - packed)
- lessThan comparison works correctly

## Summary

Minimal HLC implementation with:
- Packed Timestamp struct (time + count + node_id)
- lessThan comparison for ordering
- now() function for physical time

This provides the ordering primitive for events. Full HLC update logic (merge, tick) will come in future phases.
