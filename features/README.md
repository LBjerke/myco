# Feature Index

This document tracks all implemented features in the Myco greenfield rewrite.

## Feature List

| # | Feature | Status | File |
|---|---------|--------|------|
| 01 | Project Scaffold | ✅ Complete | [01-project-scaffold.md](01-project-scaffold.md) |
| 02 | ECS World | ✅ Complete | [02-ecs-world.md](02-ecs-world.md) |
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
| 15 | WAL Replay Deserialization Fix | ✅ Complete | [15-wal-replay-deserialization-fix.md](15-wal-replay-deserialization-fix.md) |
| 16 | Fix Simulation Service Deploy Test | ✅ Complete | [16-fix-simulation-service-deploy-test.md](16-fix-simulation-service-deploy-test.md) |
| 17 | Fix WAL Page Allocator Usage | ✅ Complete | [17-fix-wal-page-allocator-usage.md](17-fix-wal-page-allocator-usage.md) |
| 18 | Refactor Reducer Code Duplication | ✅ Complete | [18-refactor-reducer-code-duplication.md](18-refactor-reducer-code-duplication.md) |
| 19 | WAL Path Environment Variable | ✅ Complete | [19-wal-path-environment-variable.md](19-wal-path-environment-variable.md) |
| 20 | Zlinter Integration | ✅ Complete | [20-zlinter-integration.md](20-zlinter-integration.md) |
| 21 | Fix Zlinter Errors | ✅ Complete | [21-fix-zlinter-errors.md](21-fix-zlinter-errors.md) |
| 22 | CI Pipeline & Makefile Removal | ✅ Complete | [22-ci-pipeline-and-makefile-removal.md](22-ci-pipeline-and-makefile-removal.md) |
| 23 | Tiger Style Compliance | ✅ Complete | [23-tiger-style-compliance.md](23-tiger-style-compliance.md) |
| 24a | O(1) Index-Based Lookups | ✅ Complete | [24a-o1-index-lookups.md](24a-o1-index-lookups.md) |
| 24b | Name Table for Service Names | ✅ Complete | [24b-name-table.md](24b-name-table.md) |
| 24c | Sorted Insertion for Sync | ✅ Complete | [24c-sorted-insertion.md](24c-sorted-insertion.md) |
| 24d | CRDT Stores (Node/Service) | ✅ Complete | [24d-crdt-stores.md](24d-crdt-stores.md) |
| 24e | Delta CRDT | 🔄 Planned | [24e-delta-crdt.md](24e-delta-crdt.md) |
| 24f | Pluggable Event Handlers | 🔄 Planned | [24f-pluggable-handlers.md](24f-pluggable-handlers.md) |
| 24g | Memory-Mapped WAL | 🔄 Planned | [24g-mmap-wal.md](24g-mmap-wal.md) |
| 24h | Runtime Configuration | 🔄 Planned | [24h-runtime-config.md](24h-runtime-config.md) |
| 24i | Unified Buffer & Run Flags | 🔄 Planned | [24i-unified-buffer-run-flags.md](24i-unified-buffer-run-flags.md) |
| 25 | Zero-Allocation Hot Path | 🔄 Planned | [25-zero-allocation-hot-path.md](25-zero-allocation-hot-path.md) |
| 26 | Myco Edge - Stateless Gossip Relay | 🔄 Planned | [26-myco-edge-stateless-gossip-relay.md](26-myco-edge-stateless-gossip-relay.md) |
| 27 | Disaster Recovery - Snapshots & Services as Code | 🔄 Planned | [27-disaster-recovery-snapshots.md](27-disaster-recovery-snapshots.md) |
| 28 | Sharded WAL for Cluster Scale | 🔄 Future | (documentation in progress) |

## Future Features (Roadmap)

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
│   ├── lib.zig          # Library exports
│   ├── ecs/world.zig    # ECS storage
│   ├── core/event.zig   # Event types
│   ├── core/reducer.zig # Reducer protocol
│   ├── db/wal.zig       # Write-Ahead Log
│   ├── net/hlc.zig      # Ordering primitive
│   └── util/            # Utilities
├── tests/                # Test suites
├── docs/                 # Documentation
│   └── archive/proposal/ # Design references
└── features/            # Feature documentation
```

## Next Planned Features (Phase 2+)

1. **Networking** - Gossip protocol and node-to-node communication
2. **CLI & API** - Command-line interface and API server
3. **Orchestration** - systemd unit generation and service deployment
