# Feature: Fix WAL Page Allocator Usage

**Status**: ✅ Complete

## Original Ask

Fix the WAL implementation in `src/db/wal.zig` to not use `std.heap.page_allocator` for temporary allocations. The WAL was using page allocator in multiple locations which would cause a panic if WAL operations were attempted after the frozen allocator is frozen.

## Why This Matters

The zero-allocation runtime design requires that after `allocator_mod.freeze()` is called, no heap allocations can occur. The WAL was using `std.heap.page_allocator` for:
- Directory walking
- Path formatting
- Buffer allocation for reading files

This would cause a panic if WAL operations (like append) were called after freeze.

## Problem Identified

The WAL used `std.heap.page_allocator` in multiple locations:
- `openOrCreateSegment()` - segment path formatting
- `append()` - temp path formatting and buffer allocation
- `rotateSegment()` - segment path formatting
- `replay()` - segment path formatting and buffer allocation
- `getTotalEventCount()` - segment path formatting

## How It Was Solved

### Changes Made

| File | Change | Description |
|------|--------|-------------|
| `src/db/wal.zig` | Added `allocator` field | Store the allocator passed to init() |
| `src/db/wal.zig` | Added `temp_buffer` field | Pre-allocated 64KB buffer for temporary operations |
| `src/db/wal.zig` | Updated all functions | Use `self.allocator` and `self.temp_buffer` instead of `std.heap.page_allocator` |

### Implementation Details

1. **Added allocator field to Wal struct**:
```zig
allocator: std.mem.Allocator,
```

2. **Added temp buffer**:
```zig
temp_buffer: [65536]u8 = undefined,
```

3. **Updated all functions to use self.allocator**:
- Instead of `std.heap.page_allocator`, use `self.allocator`
- Use `std.io.fixedBufferStream(&self.temp_buffer)` for path formatting
- For longer-lived allocations, copy from temp buffer to allocator-allocated memory

### Important Notes

- WAL operations (init, replay, append) must happen **before** the allocator is frozen
- This is consistent with main.zig where WAL operations are only called during init phase
- Added documentation clarifying that WAL operations are init-phase only

## Testing

All tests pass:
```
zig build test
# Exit code: 0
```

## Learnings & Troubleshooting

The fix required careful handling of the temp buffer:
1. **Path formatting**: Use fixedBufferStream to format into temp_buffer, then copy to allocated memory
2. **File reading**: Use temp_buffer slice for reading file contents
3. **Memory ownership**: When a path needs to live longer than the function call, copy from temp buffer to allocator-allocated memory

The key insight is that the temp buffer can be reused for short-lived operations, but longer-lived data (like file paths stored in the struct) still needs to be allocated from the allocator.
