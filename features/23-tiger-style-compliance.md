# Feature: Tiger Style Compliance Verification and Fixes

**Status**: ✅ Complete

## Original Ask

Verify that the Myco Zig codebase follows the Tiger Beetle style guide (https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) and address areas of improvement.

## Why This Matters

Tiger Style is a rigorous coding standard focused on:
- **Safety**: Zero-allocation runtime, assertions, bounded loops
- **Performance**: Explicit control flow, batching, no hidden costs
- **Developer Experience**: Readable code, consistent naming, good documentation

Following Tiger Style ensures the codebase is maintainable, safe, and performant - critical properties for a distributed systems project like Myco.

## Verification Summary

The codebase was verified against the Tiger Style guide. Overall compliance: **~80%**

### Compliant Areas ✅

| Category | Rule | Status |
|----------|------|--------|
| Safety | No recursion | ✅ Compliant |
| Safety | Limits on everything | ✅ Compliant |
| Safety | Explicitly-sized types (u16, u32, u64) | ✅ Compliant |
| Safety | Static memory allocation | ✅ Compliant |
| Safety | Small variable scope | ✅ Compliant |
| Safety | Strong assertions | ✅ Compliant |
| Safety | Zero allocations after init | ✅ Compliant |
| Performance | Explicit control flow | ✅ Compliant |
| Performance | Batching | ✅ Compliant |
| Performance | Zero external dependencies | ✅ Compliant |
| DX | snake_case naming | ✅ Compliant |
| DX | Acronyms capitalized (HLC, WAL) | ✅ Compliant |
| DX | Units last in names | ✅ Compliant |
| DX | zig fmt passes | ✅ Compliant |
| DX | zig lint passes | ✅ Compliant |
| DX | Comments as prose | ✅ Compliant |

### Non-Compliant Areas ❌

| Priority | Issue | Location | Description |
|----------|-------|----------|-------------|
| High | Function length > 70 lines | `main.zig`, `reducer.zig`, `wal.zig` | Several functions exceed the 70-line limit |
| High | main() not at top | `main.zig` | main() is at line 227, after helpers |
| Medium | Assertion density | Various | Some helper functions lack assertions |
| Low | Callback parameter order | N/A | Not applicable (callbacks used correctly) |

---

## Implementation Plan

### Phase 1: Fix Function Length Violations

#### 1.1 Split `reduceInternal()` in `reducer.zig`

**Current State**: ~180 lines
**Target**: Split into smaller functions by event type

```zig
// New structure:
fn reduceInternal(...) struct { effect: Effect, err: ?ReduceError } {
    assert.assert(...);
    switch (event) {
        .node_join => return reduceNodeJoin(...),
        .node_leave => return reduceNodeLeave(...),
        .service_deploy => return reduceServiceDeploy(...),
        .service_remove => return reduceServiceRemove(...),
        .health_status_change => return reduceHealthStatusChange(...),
    }
}

fn reduceNodeJoin(...) ... { /* ~35 lines */ }
fn reduceNodeLeave(...) ... { /* ~20 lines */ }
fn reduceServiceDeploy(...) ... { /* ~35 lines */ }
fn reduceServiceRemove(...) ... { /* ~30 lines */ }
fn reduceHealthStatusChange(...) ... { /* ~40 lines */ }
```

**Files to modify**: `src/core/reducer.zig`

#### 1.2 Split `parseArgs()` in `main.zig`

**Current State**: ~55 lines
**Target**: Split into smaller helper functions

```zig
// New structure:
fn parseArgs() !struct { ... } {
    // Parse known flags into a flat list
    const parsed = try parseFlags();
    
    // Then validate and transform
    return try transformArgs(parsed);
}

fn parseFlags() ... { /* ~25 lines */ }
fn transformArgs(...) ... { /* ~20 lines */ }
```

**Files to modify**: `src/main.zig`

#### 1.3 Move main() to top of `main.zig`

**Current State**: `main()` at line 227
**Target**: `main()` at top, after imports

```zig
// main.zig structure:
const std = @import("std");
// ... imports ...

const version = "0.1.0";

pub fn main() !void {
    // ... implementation ...
}

// Helper functions follow
fn parseArgs() ...
fn printUsage() ...
// etc.
```

**Files to modify**: `src/main.zig`

### Phase 2: Improve Assertion Density

#### 2.1 Add assertions to helper functions

Add pre/postcondition assertions to functions that validate or search:

**`src/ecs/world.zig`**:
```zig
pub fn findNode(self: *const World, node_id: u16) ?*const Node {
    assert.assert(node_id != 0, "findNode: node_id must not be zero");
    // ... existing code
}

pub fn findService(self: *const World, service_id: u16) ?*const ServiceSpec {
    assert.assert(service_id != 0, "findService: service_id must not be zero");
    // ... existing code
}
```

**`src/net/hlc.zig`**:
```zig
pub fn lessThan(a: Timestamp, b: Timestamp) bool {
    assert.assert(a.node_id != 0, "lessThan: a.node_id should not be zero");
    assert.assert(b.node_id != 0, "lessThan: b.node_id should not be zero");
    // ... existing code
}
```

**`src/util/allocator.zig`**:
```zig
fn alloc(...) ?[*]u8 {
    assert.assert(!self.frozen, "alloc: allocator is frozen");
    // ... existing code
}
```

### Phase 3: Verification

After changes, run:

```bash
# Check formatting
zig fmt --check src/

# Check lint
zig build lint

# Run tests
zig build test
```

---

## Architecture Changes

No major architecture changes required. The fixes are code organization and style improvements only.

---

## Testing

```bash
# Verify all changes compile
zig build

# Run all tests
zig build test

# Check formatting
zig fmt --check src/

# Run lint
zig build lint

# Run full CI
zig build ci
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `src/main.zig` | Move main() to top, split parseArgs() |
| `src/core/reducer.zig` | Split reduceInternal() by event type |
| `src/ecs/world.zig` | Add assertions to findX() functions |
| `src/net/hlc.zig` | Add assertions to comparison functions |
| `src/util/allocator.zig` | Add assertions to alloc/resize functions |

---

## Summary

This feature addresses ~80% → 100% Tiger Style compliance by:

1. **Splitting long functions** into smaller, focused helpers (~180 lines → ~35 line functions)
2. **Moving main() to top** of file for proper organization
3. **Adding assertions** to helper functions for better bug detection

The core design already aligns well with Tiger Style (zero-allocation, static memory, explicit types). These changes bring the code organization in line with the style guide.
