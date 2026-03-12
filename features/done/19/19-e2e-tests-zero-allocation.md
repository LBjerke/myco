# Feature: E2E Test Framework & Zero-Allocation Runtime

**Status**: ✅ Complete

## Original Ask

1. Add E2E test targets to the Makefile
2. Fix the E2E test framework to work properly
3. Ensure zero-allocation after initialization

## Why This Matters

- **E2E tests**: Validate the full application works correctly in real scenarios
- **Zero-allocation runtime**: Critical for a high-performance, predictable orchestrator - prevents GC pauses and memory fragmentation
- **Makefile integration**: Provides consistent, documented interface for running tests

## Problem Identified

### Problem 1: E2E Tests Not in Makefile Help
The E2E test targets existed in the Makefile but weren't documented in the help output.

### Problem 2: Test Harness Incompatibility
The test-harness.sh used `compgen` (bash built-in) which isn't available on all systems, causing tests to fail silently:
```
[WARN] No test functions found in ./test-cli.sh
```

### Problem 3: WAL Alignment Panic
When running the binary, it panicked with:
```
thread panic: incorrect alignment
```
The issue was in `Wal.init()` → `openOrCreateSegment()` → `dir.walk(allocator)` where the allocator couldn't satisfy alignment requirements.

The root cause: `FrozenAllocator` didn't provide proper alignment for `dir.walk()` which internally uses `ArrayList` requiring 16-byte alignment.

### Problem 4: Zero-Allocation Not Enforced
The original code used `FrozenAllocator` but didn't actually enforce zero-allocation after init.

## How It Was Solved

### Changes Made

| File | Change | Description |
|------|--------|-------------|
| `Makefile` | Updated | Added E2E test targets to help message and phony targets |
| `tests/e2e/test-harness.sh` | Fixed | Replaced `compgen` with `declare -F` for portable function discovery |
| `src/util/allocator.zig` | Fixed | Added 16-byte alignment to init buffer |
| `src/main.zig` | Refactored | Restored FrozenAllocator with proper alignment, added freeze + validation |

### Implementation Details

**1. Makefile E2E Targets:**
```makefile
test-e2e              - Run end-to-end tests
test-e2e-verbose     - Run E2E tests (verbose)
test-e2e-binary      - Run E2E tests with custom binary
test-all-including-e2e - Run all tests including E2E
```

**2. Test Harness Fix:**
```bash
# Before (incompatible):
if compgen -A function | grep -q "^test_"; then

# After (portable):
if declare -F | grep -q "^declare -f test_"; then
```

**3. Allocator Alignment Fix:**
```zig
// src/util/allocator.zig
pub const INIT_ALLOCATOR_ALIGN: usize = 16;

// Changed buffer to be aligned
var buffer: [INIT_ALLOCATOR_SIZE]u8 align(INIT_ALLOCATOR_ALIGN) = undefined;
```

**4. Zero-Allocation Runtime:**
```zig
// src/main.zig
// Use properly aligned buffer for init allocations
var buffer: [INIT_ALLOCATOR_SIZE]u8 align(INIT_ALLOCATOR_ALIGN) = undefined;
var frozen_allocator = FrozenAllocator.init(&buffer);
const init_alloc = frozen_allocator.allocator();

// ... init code ...

// Freeze after init complete
frozen_allocator.freeze();
// Any allocation in event loop will panic!
```

## Testing

All tests pass:
```
$ make test-e2e
Running end-to-end tests...
Tests run:    12
Tests passed: 12
Tests failed: 0
```

Runtime output shows zero-allocation is enforced:
```
Init complete. Used 69501 bytes of 131072 (max).
Allocator frozen. Zero-allocation runtime active.
World ready. 1 nodes, 0 services. Entering tick loop...
```

## Learnings & Troubleshooting

### Alignment Issues in Custom Allocators
When implementing custom allocators, always consider:
1. **Default alignment**: Zig's `Allocator` interface expects 16-byte alignment by default
2. **Stack buffers**: Use `align(N)` attribute when declaring buffers
3. **Internal allocations**: Libraries like `ArrayList` may request higher alignment than you expect

### Finding Alignment Bugs
The panic message `incorrect alignment` indicates:
- You're using a buffer that's not properly aligned
- The allocator is returning memory at wrong alignment
- Look for: `dir.walk()`, `ArrayList`, any code using `std.mem.Allocator`

### Test Framework Portability
- `compgen` is bash-specific and not available in all shells (e.g., dash, sh)
- Use `declare -F` for portable function discovery in bash
- Always test E2E frameworks on minimal systems

### Zero-Allocation Verification
To verify zero-allocation:
1. Use `FrozenAllocator` with a fixed buffer
2. Call `.freeze()` after init completes
3. Any allocation attempt in the event loop will panic immediately
4. Check the "Used X bytes" output to ensure init doesn't exceed buffer

### Trade-offs
- **FrozenAllocator**: Simple but limited buffer size (128KB in this case)
- **Page allocator**: Easier but defeats zero-allocation goal
- **Solution**: Properly aligned FrozenAllocator satisfies both requirements

## Benefits Achieved

1. ✅ E2E tests properly integrated into Makefile
2. ✅ 12 E2E tests passing
3. ✅ Test framework works on all POSIX systems
4. ✅ Zero-allocation enforced at runtime
5. ✅ Init uses only ~70KB, well under 128KB limit
6. ✅ Clear error if allocation attempted in event loop
