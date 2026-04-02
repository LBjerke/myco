# Tests

Myco uses Zig's built-in test framework plus custom simulation and E2E tests.

## Test Commands

```bash
# Run all unit tests
zig build test

# Run simulation tests (property-based testing)
zig build test-sim

# Run test utility tests
zig build test-utils

# Run end-to-end tests
zig build e2e

# Run full CI suite (all checks)
zig build ci
```

## Test Types

### Unit Tests
- Inline tests in source files (e.g., `src/util/allocator.zig`)
- Run with `zig build test`

### Simulation Tests (`tests/simulation.zig`)
- Property-based testing for the ECS and reducer system
- Tests deterministic behavior
- Run with `zig build test-sim`

### Test Utilities (`tests/test_utils.zig`)
- Tests for helper functions used in tests
- Run with `zig build test-utils`

### E2E Tests (`tests/e2e/`)
- Shell script based end-to-end tests
- Tests the full binary workflow
- Run with `zig build e2e`

## CI Pipeline

The full CI suite runs:
```
fmt → lint → build → test → test-sim → test-utils → complexity → duplication → tiger-style → e2e
```

Run with: `zig build ci`

## Notes

- On macOS with sandbox issues, set: `ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache`
- Simulation knobs (if any) live in `docs/ENV.md`
