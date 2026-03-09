# Feature: Test Utilities Module & E2E Test Framework

**Status**: ✅ Complete

## Original Ask

1. Create a test utilities module to share helpers across tests
2. Set up a basic system test framework for when CLI exists

## Why This Matters

As the codebase grows, common patterns emerge:
- Creating test events
- Matching world state
- Generating test data

Having shared utilities:
- Reduces code duplication
- Ensures consistent test patterns
- Makes it easier to write new tests

The E2E framework prepares for Phase 3 when CLI/API is implemented.

## Where Code Was Added/Changed

| File | Action | Description |
|------|--------|-------------|
| `tests/test_utils.zig` | Added | Zig test utilities module |
| `tests/e2e/test-harness.sh` | Added | Bash test harness |
| `tests/e2e/test-util.sh` | Added | Bash test utilities |
| `tests/e2e/test-cli.sh` | Added | Example CLI tests |
| `tests/e2e/README.md` | Added | Documentation |
| `build.zig` | Modified | Added test-utils target |

## Test Utilities (`tests/test_utils.zig`)

### Event Builders

```zig
// Create a node join event
const event = nodeJoinEvent(.{ .node_id = 1 });

// Create a node leave event
const event = nodeLeaveEvent(.{ .node_id = 1 });

// Create a service deploy event
const event = serviceDeployEvent(.{
    .service_id = 1,
    .name = "nginx",
    .replicas = 2,
});

// Create a health change event
const event = healthChangeEvent(.{
    .node_id = 1,
    .status = 2, // unhealthy
});
```

### World State Matchers

```zig
const test_utils = @import("test_utils");

// Assert node count
try test_utils.expectNodeCount(world, 5);

// Assert node is alive
try test_utils.expectNodeAlive(world, 1);

// Assert service exists
try test_utils.expectServiceExists(world, 1);
```

### Test Context

```zig
var ctx = TestContext.init(testing.allocator);
defer {} // No cleanup needed for simple tests

try ctx.addNode(1);
try ctx.deployService(1, "web", 2);

try test_utils.expectNodeCount(ctx.getWorld(), 1);
```

### Data Generators

```zig
// Generate 10 node join events
const events = try TestDataGenerator.generateNodeJoins(1, 10, allocator);
defer allocator.free(events);

// Generate IP from node ID
const ip = TestDataGenerator.nodeIdToIp(42);
```

## E2E Test Framework (`tests/e2e/`)

### Test Harness

```bash
# Run CLI tests
./test-harness.sh ./test-cli.sh

# Verbose mode
./test-harness.sh ./test-cli.sh --verbose

# Custom binary
MYCO_BINARY=/custom/path/myco ./test-harness.sh ./test-cli.sh
```

### Writing Tests

```bash
#!/bin/bash
source "$(dirname "$0")/test-util.sh"

test_my_feature() {
    log "Testing my feature..."
    
    # Start daemon
    local pid
    pid=$(myco_start) || return 1
    
    # Run test
    local output
    output=$($MYCO_BINARY status) || return 1
    
    # Assert
    assert_contains "$output" "nodes" || return 1
    
    # Cleanup
    myco_stop "$pid"
    
    return 0
}
```

### Available Utilities

| Function | Description |
|----------|-------------|
| `log()` | Log message |
| `assert_eq()` | Assert equality |
| `assert_contains()` | Assert substring |
| `assert_file_exists()` | Assert file exists |
| `myco_start()` | Start daemon |
| `myco_stop()` | Stop daemon |
| `skip_test()` | Skip test |

## Test Execution

```bash
# Run unit tests
zig build test

# Run simulation tests
zig build test-sim

# Run test utilities tests
zig build test-utils
```

All tests pass:
- `zig build test` - 10/10 unit tests
- `zig build test-sim` - 19/19 simulation tests
- `zig build test-utils` - 10/10 utility tests

## Future Enhancements

When Phase 3 arrives:
1. Update `test-cli.sh` with actual CLI tests
2. Add API endpoint tests
3. Add integration tests with real services

## Summary

Added comprehensive testing infrastructure:

1. **Test Utilities Module** (`tests/test_utils.zig`)
   - Event builders for all event types
   - World state matchers
   - Test data generators
   - Test context helper

2. **E2E Test Framework** (`tests/e2e/`)
   - Bash test harness
   - Process management utilities
   - Assertion helpers
   - Example CLI tests (ready for Phase 3)

All tests pass. The testing infrastructure is now in place for continued development.
