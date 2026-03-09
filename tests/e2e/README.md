# E2E Testing Framework

This directory contains the end-to-end testing framework for Myco.

## Purpose

Traditional E2E testing (browser automation) doesn't apply to a daemon like Myco. Instead, this framework tests:

- CLI command execution
- Daemon startup/shutdown
- Configuration file parsing
- WAL directory creation
- Single-instance enforcement
- Graceful shutdown

## Files

| File | Description |
|------|-------------|
| `test-harness.sh` | Main test harness that runs test scripts |
| `test-util.sh` | Common utilities for test scripts |
| `test-cli.sh` | Example CLI tests (Phase 3 ready) |
| `README.md` | This file |

## Requirements

- Bash 4.0+
- `zig` build system
- Built myco binary (`zig build`)

## Usage

### Running Tests

```bash
# Make scripts executable
chmod +x test-harness.sh test-cli.sh

# Run all CLI tests
./test-harness.sh ./test-cli.sh

# Run with verbose output
./test-harness.sh ./test-cli.sh --verbose

# Use custom binary path
MYCO_BINARY=./zig-out/bin/myco ./test-harness.sh ./test-cli.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MYCO_BINARY` | `./zig-out/bin/myco` | Path to myco binary |
| `MYCO_DATA_DIR` | `/tmp/myco-test-$$` | Data directory for tests |
| `MYCO_VERBOSE` | `0` | Enable debug output |

### Writing Tests

Create a test script:

```bash
#!/bin/bash
# my-tests.sh

source "$(dirname "$0")/test-util.sh"

# Test function - must start with "test_"
test_my_feature() {
    log "Testing my feature..."
    
    # Start myco
    local pid
    pid=$(myco_start) || return 1
    
    # Run your test
    local output
    output=$($MYCO_BINARY status) || return 1
    
    # Assert
    assert_contains "$output" "nodes" || return 1
    
    # Cleanup
    myco_stop "$pid"
    
    return 0
}
```

Then run:

```bash
./test-harness.sh ./my-tests.sh
```

## Test Status

These tests are **placeholder tests** - they demonstrate the testing pattern but will only pass once Phase 3 (CLI & API) is implemented.

Currently implemented:
- Binary existence check
- Help output
- Version output
- Daemon startup/shutdown
- WAL directory creation
- Error handling
- Single instance prevention

Not yet implemented (Phase 3):
- `myco status` command
- `myco deploy` command  
- `myco node add` command
- Configuration file parsing

## Integration with CI

Add to your CI pipeline:

```yaml
# .github/workflows/test.yml
- name: Run E2E tests
  run: |
    zig build
    cd tests/e2e
    chmod +x test-harness.sh test-cli.sh
    ./test-harness.sh ./test-cli.sh
```

## Debugging

Enable debug output:

```bash
TEST_DEBUG=1 ./test-harness.sh ./test-cli.sh --verbose
```

Keep data directory after tests:

```bash
# Data dir is kept if tests fail
ls -la /tmp/myco-test-*
```
