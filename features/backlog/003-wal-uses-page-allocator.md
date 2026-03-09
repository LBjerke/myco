# Issue: WAL Uses Page Allocator After Freeze

## Summary
The WAL implementation uses `std.heap.page_allocator` for temporary allocations (formatting paths, etc.) after the frozen allocator is frozen. This defeats the purpose of the zero-allocation runtime.

## Severity
**HIGH** - This will cause a panic when the allocator is frozen and WAL operations are attempted.

## Location
- File: `src/db/wal.zig`
- Multiple locations use `std.heap.page_allocator`:
  - Line 174-179: `openOrCreateSegment()` - segment path formatting
  - Line 220-225: `append()` - temp path formatting  
  - Line 232-237: `append()` - buffer allocation
  - Line 289-294: `rotateSegment()` - segment path formatting
  - Line 332-337: `replay()` - segment path formatting
  - Line 354-356: `replay()` - buffer allocation for reading file
  - Line 418-423: `getTotalEventCount()` - segment path formatting

## Current Behavior
```zig
// Line 174-179 in wal.zig
const segment_path = try std.fmt.allocPrint(
    std.heap.page_allocator,  // <-- Uses system allocator!
    "{s}/segment-{:0>4}",
    .{ self.dir_path, segment_id },
);
```

The comment on `append()` says "This allocates during init phase only" but the code doesn't enforce this and will panic if called after freeze.

## Expected Behavior
All WAL operations that need temporary allocations should either:
1. Use a pre-allocated buffer (passed in during init)
2. Return an error if called after freeze
3. Document that WAL operations are only valid during init phase

## How to Fix
Option 1 (Recommended): Pre-allocate all needed buffers in Wal.init()
- Add a `temp_buffer: []u8` field to Wal struct
- Use fixed buffer streams for all path formatting
- Pass buffer to all internal functions that need temporary memory

Option 2: Add a `frozen` check
- Add `frozen: bool` field to Wal
- Add `freeze()` method that sets frozen = true
- Check frozen in append() and return error if true

## Relevant Code
- `src/util/allocator.zig` - FrozenAllocator implementation
- `src/main.zig` - Shows the intended freeze ordering
- `src/db/wal.zig` - WAL implementation

## Buffer Sizes Needed
- Segment path: ~30 bytes ("data/wal/segment-0000".len)
- Temp file path: ~30 bytes  
- Read buffer: max segment size = header(25) + 1000 events * ~50 bytes = ~50KB

## Testing
After fix, verify:
1. WAL operations work during init phase
2. Calling WAL.append() after freeze() returns error or is prevented
