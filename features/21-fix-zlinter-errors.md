# Tech Debt: Fix Zlinter Lint Errors

**Status**: ✅ Complete (see `features/done/21/21-fix-zlinter-errors.md`)

## Overview

Zlinter integration detected 29 errors and 28 warnings across the codebase. This document catalogs the issues and provides guidance on how to fix them.

## Errors (29 total)

### Declaration Naming (snake_case required)

These constants use SCREAMING_SNAKE_CASE but zlinter expects `snake_case` for declarations.

| File | Line | Current Name | Suggested Fix |
|------|------|--------------|---------------|
| `src/main.zig` | 18 | `VERSION` | `version` |
| `src/db/wal.zig` | 12 | `MAX_EVENTS_PER_SEGMENT` | `max_events_per_segment` |
| `src/db/wal.zig` | 15 | `SEGMENT_MAGIC` | `segment_magic` |
| `src/db/wal.zig` | 16 | `SEGMENT_VERSION` | `segment_version` |
| `src/db/wal.zig` | 19 | `SEGMENT_PREFIX` | `segment_prefix` |
| `src/db/wal.zig` | 21 | `TEMP_PREFIX` | `temp_prefix` |
| `src/db/wal.zig` | 283 | `temp_pathOwned` | `temp_path_owned` |
| `src/util/allocator.zig` | 136 | `INIT_ALLOCATOR_SIZE` | `init_allocator_size` |
| `src/util/allocator.zig` | 137 | `INIT_ALLOCATOR_ALIGN` | `init_allocator_align` |
| `src/util/limits.zig` | 5 | `PACKET_SIZE` | `packet_size` |
| `src/util/limits.zig` | 7 | `MAX_NODES` | `max_nodes` |
| `src/util/limits.zig` | 8 | `MAX_SERVICES` | `max_services` |
| `src/util/limits.zig` | 9 | `MAX_REPLICAS_PER_SERVICE` | `max_replicas_per_service` |
| `src/util/limits.zig` | 10 | `MAX_PLACEMENTS` | `max_placements` |
| `src/util/limits.zig` | 12 | `MAX_NODE_ID` | `max_node_id` |
| `src/util/limits.zig` | 13 | `MAX_SERVICE_ID` | `max_service_id` |
| `src/util/limits.zig` | 15 | `GOSSIP_INTERVAL_MS` | `gossip_interval_ms` |
| `src/util/limits.zig` | 16 | `TICK_INTERVAL_MS` | `tick_interval_ms` |
| `src/util/limits.zig` | 19 | `WAL_HEADER_SIZE` | `wal_header_size` |
| `src/util/limits.zig` | 20 | `WAL_TEMP_BUFFER_SIZE` | `wal_temp_buffer_size` |
| `src/util/limits.zig` | 21 | `WAL_WRITE_BUFFER_SIZE` | `wal_write_buffer_size` |
| `src/util/limits.zig` | 22 | `WAL_MAX_SEGMENTS` | `wal_max_segments` |
| `src/util/limits.zig` | 23 | `WAL_SEGMENT_PREFIX` | `wal_segment_prefix` |
| `src/util/limits.zig` | 24 | `WAL_TEMP_PREFIX` | `wal_temp_prefix` |
| `src/net/hlc.zig` | 20 | `time_source` | `time_source` (function - should be camelCase) |

### Namespace Naming

| File | Line | Current Name | Suggested Fix |
|------|------|--------------|---------------|
| `tests/test_utils.zig` | 151 | `WorldMatchers` | `world_matchers` |
| `tests/test_utils.zig` | 226 | `TestDataGenerator` | `test_data_generator` |

### Function Naming

| File | Line | Current Name | Suggested Fix |
|------|------|--------------|---------------|
| `src/util/allocator.zig` | 139 | `createAlignedBuffer` | `CreateAlignedBuffer` (TitleCase for functions returning `type`) |

### Field Naming

| File | Line | Current Name | Suggested Fix |
|------|------|--------------|---------------|
| `tests/simulation.zig` | 89 | `check_fn` | `checkFn` (camelCase for struct fields) |

## Warnings (28 total)

### Deprecated API Usage

These use deprecated `fixedBufferStream`, `deprecatedWriter`, etc. Should migrate to `Reader`/`Writer`:

| File | Lines | Issue |
|------|-------|-------|
| `src/main.zig` | 21, 37 | `deprecatedWriter()` → `writer()` |
| `src/db/wal.zig` | 129, 216, 429 | `fixedBufferStream()` → `reader()` |
| `src/db/wal.zig` | 228, 294 | `writeAll()` - OK, but context uses deprecated writer |
| `src/core/event.zig` | 320, 355, 384, 400, 417, 438, 451 | `fixedBufferStream()` → `reader()` |

**Migration example:**
```zig
// Before (deprecated)
var fbs = std.io.fixedBufferStream(&buffer);
const data = try fbs.reader().readAll_alloc(alloc, 1024);

// After (recommended)
var fbs = std.io.FixedBufferStream(*[N]u8){ .buffer = &buffer };
const data = try fbs.reader().readAllAlloc(alloc, 1024);
```

### Short Declaration Names

These declarations have names shorter than 3 characters:

| File | Line | Name | Note |
|------|------|------|------|
| `src/db/wal.zig` | 148, 357 | `id` | Short but meaningful in context |
| `src/net/hlc.zig` | 39, 51, 63, 75, 87, 99 | `a` | Test variable - acceptable |
| `src/core/event.zig` | 460 | `ts` | Test variable - acceptable |

### Unused Declarations

| File | Line | Declaration | Note |
|------|------|------------|------|
| `src/util/allocator.zig` | 139 | `createAlignedBuffer` | Function defined but never called |
| `tests/runner.zig` | 5 | `sim` | Import unused in this file |

## Suggested Approach

### Option 1: Fix All at Once

Run a bulk rename session to fix all naming issues:

```bash
# Use zig's built-in tools or a rename refactoring tool
# Example using zlinter's --fix (experimental):
zig build lint -- --rule declaration_naming --fix
```

### Option 2: Disable Strict Rules (Recommended for Now)

Since many of these are style preferences rather than bugs, consider disabling strict rules in `build.zig`:

```zig
builder.addRule(.{ .builtin = .declaration_naming }, .{
    .severity = .off,  // Disable - too many false positives for const names
});
builder.addRule(.{ .builtin = .no_deprecated }, .{
    .severity = .off,  // Disable - Zig API is still stabilizing
});
```

### Option 3: Fix Incrementally

Fix errors file-by-file, starting with the most impactful:
1. `src/util/limits.zig` - Core constants
2. `src/db/wal.zig` - Core constants
3. `src/main.zig` - Entry point
4. `src/util/allocator.zig` - Allocator utilities
5. `tests/` - Test utilities

## Impact Assessment

| Category | Count | Risk of Fixing |
|----------|-------|----------------|
| Constant renames | 25 | Low - just renaming, no logic changes |
| Namespace renames | 2 | Medium - may break external references |
| Function renames | 1 | Medium - if called elsewhere |
| Field renames | 1 | Medium - may break callers |
| Deprecated API | 12 | Medium - API changes, need to verify behavior |
| Unused code | 2 | Low - safe to remove or use |

## Related Issues

- Feature #20 - Zlinter Integration
- Depends on: Zig standard library API stabilization
