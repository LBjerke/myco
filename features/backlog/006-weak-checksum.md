# Issue: Weak Checksum Implementation

## Summary
The checksum implementation in `WalEvent.calculateChecksum()` is not a real CRC32 or cryptographic hash - it just XORs parts of the timestamp together. This provides minimal error detection.

## Severity
**LOW** - Currently documented as "simple hash-based checksum", but could cause issues if used for actual data integrity verification.

## Location
- File: `src/core/event.zig`
- Function: `WalEvent.calculateChecksum()` (lines 214-221)

## Current Behavior
```zig
// Lines 214-221
pub fn calculateChecksum(event: Event) u32 {
    // Simple hash-based checksum for now
    var hash: u32 = 0;
    const timestamp = event.getTimestamp();
    hash ^= @truncate(timestamp.time);
    hash ^= (@as(u32, timestamp.count) << 16);
    hash ^= (@as(u32, timestamp.node_id) << 8);
    return hash;
}
```

## Problems
1. Only considers timestamp, not event data
2. XOR is easily defeated (swapping bytes would not be detected)
3. Collisions are likely for similar timestamps
4. Not a proper CRC32 or hash function

## How to Fix
Option 1: Document as intentionally weak (acceptable for now)
- Add clear comments explaining this is for basic sanity checks only
- Not for detecting malicious tampering

Option 2: Use proper CRC32 (recommended for production)
```zig
// Use std.hash.Crc32 if available, or implement simple CRC32
pub fn calculateChecksum(event: Event, writer: anytype) !u32 {
    // Serialize to a buffer first, then compute CRC
    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try event.serialize(fbs.writer());
    
    // Compute CRC32 of the serialized data
    // ... 
}
```

Option 3: Use std.hash.SipHash or similar
- Better collision resistance
- Constant time

## Relevant Code
- `src/core/event.zig` - WalEvent struct and checksum usage
- `src/db/wal.zig` - Checksum is written but never verified on read

## Note
The checksum is calculated but never actually verified during WAL reads (due to the replay bug). This makes the weak checksum even less impactful currently.
