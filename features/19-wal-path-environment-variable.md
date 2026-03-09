# Feature: Add WAL Path Configuration via Environment Variable

**Status**: ✅ Complete

## Original Ask

Fix the hardcoded WAL path in `src/main.zig` - the path `"data/wal"` was hardcoded, making it impossible to configure without code changes.

## Why This Matters

For deployment flexibility, the WAL path should be configurable:
- Different environments may need different storage locations
- Testing may require isolated WAL directories
- Production deployments need flexibility

## How It Was Solved

### Changes Made

| File | Change | Description |
|------|--------|-------------|
| `src/main.zig` | Modified | Added environment variable support for WAL path |

### Implementation Details

Added support for `MYCO_WAL_PATH` environment variable:

```zig
// Get WAL path from environment variable or use default
const wal_path = blk: {
    const result = std.process.getEnvVarOwned(alloc, "MYCO_WAL_PATH") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            // Use default path
            break :blk try alloc.dupe(u8, "data/wal");
        }
        return err;
    };
    break :blk result;
};
defer alloc.free(wal_path);
```

### Usage

```bash
# Use default path (data/wal)
./myco

# Custom WAL path
MYCO_WAL_PATH=/tmp/myco-wal ./myco
```

## Testing

All tests pass:
```
zig build test
# Exit code: 0
```

## Learnings

Using a block label (`:blk`) with `break :blk` is the cleanest way to handle complex error handling in Zig when you need to return a value from a catch block.

## Related Issues

- Issue #009 - Undefined arrays in World.init (also addressed)
