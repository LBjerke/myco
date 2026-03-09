# Feature Index

This document tracks all implemented features in the Myco greenfield rewrite.

## Feature List

| # | Feature | Status | File |
|---|---------|--------|------|
| 01 | Project Scaffold | ✅ Complete | [01-project-scaffold.md](01-project-scaffold.md) |
| 02 | ECS World | ✅ Complete |-world.md](02 [02-ecs-ecs-world.md) |
| 03 | HLC Timestamp | ✅ Complete | [03-hlc-timestamp.md](03-hlc-timestamp.md) |
| 04 | Event Types | ✅ Complete | [04-event-types.md](04-event-types.md) |
| 05 | Inline Zig Tests | ✅ Complete | [05-inline-zig-tests.md](05-inline-zig-tests.md) |
| 06 | Node Health ECS Component | ✅ Complete | [06-node-health-component.md](06-node-health-component.md) |
| 07 | Frozen Allocator | ✅ Complete | [07-frozen-allocator.md](07-frozen-allocator.md) |
| 08 | WAL Service | ✅ Complete | [08-wal-service.md](08-wal-service.md) |
| 09 | Human-Readable Documentation | ✅ Complete | [09-human-readable-docs.md](09-human-readable-docs.md) |
| 10 | Reducer Protocol | ✅ Complete | [10-reducer-protocol.md](10-reducer-protocol.md) |
| 11 | ECS Component Expansion | ✅ Complete | [11-component-expansion.md](11-component-expansion.md) |
| 12 | Fix Runtime and Sim Errors | ✅ Complete | [12-fix-runtime-and-sim-errors.md](12-fix-runtime-and-sim-errors.md) |
| 13 | Simulation Harness & Property Testing | ✅ Complete | [13-simulation-and-property-testing.md](13-simulation-and-property-testing.md) |
| 14 | Test Utilities Module & E2E Framework | ✅ Complete | [14-test-utilities-and-e2e-framework.md](14-test-utilities-and-e2e-framework.md) |

## Status Legend

- 🚧 In Progress
- ✅ Complete
- 🔄 Planned

## Adding New Features

When implementing a new feature:

1. Create a new markdown file in `features/` following the template:
   - `# Feature: [Name]`
   - Status badge
   - Original Ask
   - Where Code Was Added/Changed (table format)
   - Architecture section with ASCII diagrams
   - Testing section
   - Summary

2. Update this index with the new feature

3. Commit with descriptive message

## Architecture Overview

```
myco-greenfield/
├── src/
│   ├── main.zig          # Tick loop shell
│   ├── ecs/world.zig    # ECS storage
│   ├── core/event.zig   # Event types
│   ├── db/wal.zig       # Write-Ahead Log
│   ├── net/hlc.zig      # Ordering primitive
│   └── util/limits.zig  # Constants
├── features/             # Feature documentation
└── proposal/            # Design reference
```

## Next Planned Features

1. **Reducer Protocol** - Functional core event processing
2. **Component Expansion** - Full ECS component tables
3. **Gossip Delta Encoding** - Network protocol
