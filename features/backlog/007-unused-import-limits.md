# Issue: Unused Import in limits.zig

## Summary
The `std` import in `src/util/limits.zig` is never used.

## Severity
**LOW** - Code cleanliness / compiler warning issue.

## Location
- File: `src/util/limits.zig`
- Line 3: `const std = @import("std");`

## Current Behavior
```zig
const std = @import("std");  // Never used!

pub const PACKET_SIZE: usize = 1024;
// ... rest of constants ...
```

## How to Fix
Simply remove the unused import line.

```diff
- const std = @import("std");
-
```

## Verification
After removal, verify the file still compiles:
```bash
zig build test
```
