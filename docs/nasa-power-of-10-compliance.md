# NASA Power of 10 Compliance Guide

> A guide to adopting NASA's Power of 10 rules for safety-critical code in myco-greenfield

## Overview

The **Power of 10** rules were created in 2006 by Gerard J. Holzmann of NASA/JPL Laboratory for Reliable Software. They are intended to eliminate coding practices that make code difficult to review or statically analyze. While originally designed for C, these rules provide valuable guidance for any safety-conscious codebase—including our Zig implementation.

**Why adopt these rules?**
- Reduces bugs through defensive programming
- Makes code easier to review and understand
- Enables static analysis verification
- Improves testability
- Follows practices used in space missions

---

## The Ten Rules

### Rule 1: Simple Control Flow

> Restrict all code to very simple control flow constructs—do not use goto statements, setjmp or longjmp constructs, or direct or indirect recursion.

**Status:** ✅ Compliant

Zig does not have `goto` or `setjmp`/`longjmp`. Our codebase does not use recursion in hot paths.

**Recommendations:**
- Avoid recursive functions in performance-critical code
- Use iteration instead of recursion

---

### Rule 2: Bounded Loops

> Give all loops a fixed upper bound. It must be trivially possible for a checking tool to prove statically that the loop cannot exceed a preset upper bound on the number of iterations.

**Status:** 🟡 Partial

**Current Issues:**
- The WAL replay loop in `src/db/wal.zig` has a potential infinite loop bug (documented in `features/tech_debt/020-code-complexity-analysis.md`)

**Implementation:**
```zig
// Add iteration counter with assertion
var iterations: usize = 0;
const max_iterations = 1000; // Proven upper bound

while (condition) {
    // Assert bound is not exceeded
    if (iterations >= max_iterations) {
        @panic("Loop exceeded maximum iterations");
    }
    iterations += 1;
    
    // ... loop body
}
```

---

### Rule 3: No Dynamic Memory After Initialization

> Do not use dynamic memory allocation after initialization.

**Status:** ✅ Compliant

Our codebase uses a **FrozenAllocator** pattern:
- All allocations happen during initialization
- Runtime is zero-allocation (stack-only)
- Buffer sizes defined in `src/util/limits.zig`

**Implementation:**
```zig
// In src/util/allocator.zig
pub const FrozenAllocator = struct {
    // ... allocations only allowed during setup
};
```

---

### Rule 4: Function Size Limits

> No function should be longer than what can be printed on a single sheet of paper in a standard format. Typically, no more than about 60 lines of code per function.

**Status:** 🔴 Needs Work

**Current Problem Functions:**

| Function | Current Lines | Target |
|----------|--------------|--------|
| `main()` | 185 | 60 |
| `wal.replay()` | 83 | 60 |
| `wal.append()` | 69 | 60 |
| `wal.openOrCreateSegment()` | 57 | 60 |

**Refactoring Strategy:**
1. Extract helper functions for distinct responsibilities
2. Use the "Extract Method" pattern
3. Keep functions to a single level of abstraction

**Example:**
```zig
// Before: Large function
pub fn main() void {
    // 185 lines of initialization, parsing, loop
}

// After: Delegation to helpers
pub fn main() void {
    const args = parseArgs() catch return;
    const world = try initWorld(args);
    runEventLoop(world);
}
```

---

### Rule 5: Assertion Density

> The code's assertions density should average to minimally two assertions per function. Assertions must be used to check for anomalous conditions that should never happen in real-life executions.

**Status:** 🔴 Needs Work

**Current State:** Only test assertions exist (`std.testing.expect*`)  
**Target:** 2+ runtime assertions per function

#### Creating Assertions

We use a custom assertion library at `src/util/assert.zig`:

```zig
const assert = @import("util/assert.zig");

/// Runtime assertion - panics if condition is false
pub inline fn assert(cond: bool, msg: []const u8) void {
    if (!cond) @panic(msg);
}

/// Assert pointer is not null
pub inline fn assertNotNull(ptr: anytype, msg: []const u8) void {
    if (ptr == null) @panic(msg);
}

/// Assert value within bounds
pub inline fn assertBounds(val: usize, max: usize, msg: []const u8) void {
    if (val >= max) @panic(msg);
}
```

#### Where to Add Assertions

**Event Processing (`src/core/event.zig`):**
```zig
pub fn deserialize(reader: anytype) !Event {
    // Assert event type is valid
    const type_int = try reader.readByte();
    assert(type_int < @typeInfo(EventType).Enum.fields.len, "Invalid event type");
    
    // Assert buffer has enough data
    assertBounds(read_pos + 4, buffer.len, "Buffer underflow in deserialize");
    
    // ... rest of deserialization
}
```

**WAL Operations (`src/db/wal.zig`):**
```zig
pub fn append(self: *Wal, event: *const WalEvent) !void {
    // Assert loop bounds
    var attempts: usize = 0;
    const max_attempts = 3;
    
    while (attempts < max_attempts) : (attempts += 1) {
        assert(attempts < max_attempts, "Too many retry attempts");
        // ... write logic
    }
}
```

---

### Rule 6: Minimal Scope

> Declare all data objects at the smallest possible level of scope.

**Status:** ✅ Compliant

Zig encourages this naturally:
- Variables are scoped to blocks
- `const` by default
- No global mutable state (see FrozenAllocator pattern)

---

### Rule 7: Check Return Values

> Each calling function must check the return value of nonvoid functions, and each called function must check the validity of all parameters provided by the caller.

**Status:** ✅ Compliant

Zig's type system enforces this:
- `try` keyword propagates errors
- `catch` handles errors explicitly
- Optional types (`?T`) require handling

**Example:**
```zig
// Zig enforces checking return values
const result = try someFunction();
const maybe_value: ?T = maybeFunction();
if (maybe_value) |value| {
    // Handle value
}
```

---

### Rule 8: Limited Preprocessor

> The use of the preprocessor must be limited to the inclusion of header files and simple macros. Token pasting, variable argument lists, and recursive macro calls are not allowed.

**Status:** ✅ Compliant

Zig has no C preprocessor. We use:
- Compile-time code generation (`@import`, `comptime`)
- Inline functions instead of macros
- No conditional compilation abuse

---

### Rule 9: Restricted Pointers

> The use of pointers must be restricted. Specifically, no more than one level of dereference should be used. Function pointers are not permitted.

**Status:** 🟡 Partial

Zig's safety features help:
- Optional pointers (`?*T`) require null checks
- No function pointers in hot paths
- Explicit dereferencing required

**Recommendations:**
- Review `src/db/wal.zig` for pointer usage
- Add assertions before dereferencing optional pointers

---

### Rule 10: Compiler Warnings

> All code must be compiled, from the first day of development, with all compiler warnings enabled at the most pedantic setting available. All code must compile without warnings.

**Status:** ✅ Compliant

Our build system:
- Uses Zig's strict compiler warnings
- Runs `zig fmt` for formatting consistency
- Uses Lizard for complexity analysis

**Makefile targets:**
```bash
make format    # Format code
make check    # Run all checks
make analyze  # Run static analysis
```

---

## Implementation Priority

| Priority | Rule | Effort | Impact |
|----------|------|--------|--------|
| 1 | Rule 5: Assertions | Medium | High |
| 2 | Rule 4: Function sizes | High | High |
| 3 | Rule 2: Loop bounds | Low | High |
| 4 | Rule 9: Pointers | Low | Medium |

---

## Code Quality Targets

| Metric | Current | Target |
|--------|---------|--------|
| Max Cyclomatic Complexity | 41 | < 10 |
| Average CCN | 4.8 | < 4 |
| Functions > 60 lines | 4 | 0 |
| Assertions per function | ~0.2 | 2+ |
| Unbounded loops | 1 | 0 |

---

## References

- [The Power of 10: Rules for Developing Safety-Critical Code](https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code) (Wikipedia)
- [JPL C Coding Standard](https://www.jpl.nasa.gov/info/policies/CodingStandard.pdf)
- IEEE Computer: "The Power of 10" (Holzmann, 2006)

---

## Related Documentation

- [Code Complexity Analysis](../features/tech_debt/020-code-complexity-analysis.md)
- [Tech Debt: NASA Power of 10 Compliance](../features/tech_debt/027-nasa-power-of-10-compliance.md)
- [Code Standards](../.opencode/context/core/standards/code-quality.md)
