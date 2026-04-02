# Feature: Add Lizard Code Duplication Check and Remove Makefile

**Status**: ✅ Complete

## Original Ask

1. Add lizard code duplication check to `build.zig` similar to the existing complexity check
2. Add the duplication check to the `zig build ci` command
3. Remove the Makefile and document all zig build commands in the README

## Why This Matters

- **Code quality**: Detecting duplicated code helps identify refactoring opportunities
- **Simplification**: Moving from Makefile to pure Zig build reduces tooling dependencies
- **Documentation**: All build commands are now documented in README.md

## How It Was Solved

### Changes Made

| File | Change | Description |
|------|--------|-------------|
| `build.zig` | Modified | Added duplication step using `lizard -Eduplicate` |
| `build.zig` | Modified | Updated `ci` step to include duplication check |
| `README.md` | Modified | Added comprehensive build command documentation |
| `Makefile` | Removed | No longer needed - replaced by zig build |

### Implementation Details

#### Lizard Duplication Check

Added to `build.zig` after the complexity check:

```zig
// Code duplication check step using lizard
const duplication_step = b.step("duplication", "Check for duplicate code");
const duplication_cmd = b.addSystemCommand(&.{
    "lizard",
    "-Eduplicate",
    "-l",
    "zig",
    "src/",
});
duplication_step.dependOn(&duplication_cmd.step);
ci_step.dependOn(duplication_step);
```

The `-Eduplicate` flag enables lizard's copy-paste detection (code clone detection).

#### CI Pipeline Update

Updated the `ci` step description to include duplication:

```zig
const ci_step = b.step("ci", "Run the full suite of CI checks (fmt, lint, build, test, test-sim, test-utils, complexity, duplication, e2e)");
```

#### Makefile Removal

The Makefile was deprecated and then removed entirely. All commands are now available via `zig build`:

- `zig build` - Build the project
- `zig build -Doptimize=ReleaseFast` - Release build
- `zig build test` - Run unit tests
- `zig build test-sim` - Run simulation tests
- `zig build test-utils` - Run test utility tests
- `zig build e2e` - Run end-to-end tests
- `zig build ci` - Run full CI suite
- `zig build lint` - Run linter
- `zig build format` - Format code
- `zig build test:fmt` - Check formatting
- `zig build docs` - Generate documentation
- `zig build install` - Install binary
- `zig build uninstall` - Uninstall binary

## Usage

```bash
# Run full CI suite (includes duplication check)
zig build ci

# Run duplication check standalone
zig build duplication

# Build commands (replacing make targets)
zig build                    # was: make build
zig build -Doptimize=ReleaseFast  # was: make build-release
zig build test              # was: make test
zig build lint              # was: make lint
rm -rf zig-out              # was: make clean
./zig-out/bin/myco          # was: make run
```

## Current State

The duplication check runs as part of CI but does not fail the build by default. Lizard reports the duplicate rate but does not enforce a threshold automatically. The current codebase has ~20% duplicate rate.

### Future Enhancements

To enforce a maximum duplicate rate, a wrapper script could be added to `build.zig` that parses lizard's output and fails if the rate exceeds a threshold.

## Testing

```bash
# Run duplication check
zig build duplication

# Run full CI
zig build ci

# Verify all tests pass
zig build test
zig build test-sim
zig build test-utils
```

## Learnings

- Lizard supports code duplication detection via `-Eduplicate` flag
- The Makefile was largely redundant since `zig build` covers all core commands
- Remaining Makefile targets (like E2E verbose mode) are edge cases better documented in README
- Zig 0.15.2 does not have `zig analyze` - the old Makefile target never worked

## Related Issues

- Part of ongoing effort to simplify build tooling
- Complements existing zlinter integration (feature #20)
