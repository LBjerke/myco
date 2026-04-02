# Feature: Integrate Zlinter for Code Linting

**Status**: ✅ Complete

## Original Ask

Add [zlinter](https://github.com/KurtWagner/zlinter) to the project to catch code style issues, naming conventions, and potential bugs early in the development cycle.

## Why This Matters

A linter integrated into the build system:
- Catches style issues automatically during development
- Enforces consistent naming conventions across the codebase
- Detects deprecated API usage before it becomes problematic
- Reduces code review overhead for style feedback
- Improves overall code quality with zero ongoing effort

## How It Was Solved

### Changes Made

| File | Change | Description |
|------|--------|-------------|
| `build.zig` | Added | Integrated zlinter with recommended rules |
| `Makefile` | Added | Added `make lint` target |
| `zig.lock` | Added | zlinter dependency tracked |

### Implementation Details

Added zlinter dependency with the following rules:
- `field_naming` - Ensures struct field names follow conventions
- `declaration_naming` - Enforces naming conventions for declarations
- `function_naming` - Validates function naming patterns
- `file_naming` - Ensures files follow Zig naming conventions
- `switch_case_ordering` - Checks switch case ordering
- `no_unused` - Detects unused declarations
- `no_deprecated` - Warns about deprecated API usage
- `no_orelse_unreachable` - Detects unnecessary `orelse unreachable`

## Usage

```bash
# Run linter via Makefile
make lint

# Or directly via Zig build
zig build lint

# Lint specific paths
zig build lint -- --include src/net/

# Run with auto-fix (experimental - use with caution!)
zig build lint -- --rule field_ordering --rule no_unused --fix
```

## Current State

Zlinter is integrated and working. The initial run detected:
- 29 errors (naming convention violations, deprecated API usage)
- 28 warnings (minor style issues)

These are pre-existing issues in the codebase that can be addressed incrementally or left as-is if the rules are too strict for this project.

### Configuration Options

To disable specific rules or adjust severity, edit `build.zig`:

```zig
builder.addRule(.{ .builtin = .no_deprecated }, .{
    .severity = .warning,  // or .off to disable
});
```

To add exclude paths:

```zig
builder.addPaths(.{
    .include = &.{ b.path("src/"), b.path("tests/") },
    .exclude = &.{ b.path("src/generated.zig") },
});
```

## Testing

```
zig build lint
# Returns exit code 0 if no errors
```

## Learnings

- Zlinter integrates directly into `build.zig` - no separate binary needed
- First run is slower as the cache warms up
- Can selectively disable rules or paths if needed
- The `--fix` flag is experimental - always use source control

## Related Issues

- This enables automated code quality checks in CI/CD pipelines
- Can be added to pre-commit hooks for immediate feedback
