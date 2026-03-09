# Issue: Hardcoded WAL Path in main.zig

## Summary
The WAL directory path is hardcoded as `"data/wal"` in main.zig, making it impossible to configure without code changes.

## Severity
**LOW** - Works for development, but limits deployment flexibility.

## Location
- File: `src/main.zig`
- Line 37: `var wal = try Wal.init(alloc, "data/wal");`

## Current Behavior
```zig
// Line 37
var wal = try Wal.init(alloc, "data/wal");
```

The README even notes this:
```markdown
# Currently takes no arguments - edit src/main.zig to change WAL path
```

## How to Fix
Option 1: Command-line arguments
```zig
pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const wal_path = if (args.len > 1) args[1] else "data/wal";
    var wal = try Wal.init(alloc, wal_path);
}
```

Option 2: Environment variable
```zig
const wal_path = std.process.getEnvVarOwned(allocator, "MYCO_WAL_PATH") 
    catch "data/wal";
```

Option 3: Configuration file
- Create a config file format (TOML, JSON)
- Parse config file at startup
- Support config file path via CLI arg

## Related
- Issue: #009 - Undefined arrays in World.init (cosmetic)
- Future: Config file parsing was listed in Phase 3 roadmap

## Dependencies
Would benefit from having a proper CLI argument parsing library or using Zig's standard library for argument parsing.
