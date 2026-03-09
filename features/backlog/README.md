# Refactoring Backlog

This folder contains issues identified during code review of the Myco codebase.

---

## ✅ COMPLETED ISSUES

### Critical
- [001 - WAL Replay Not Deserializing Events](./001-wal-replay-not-deserializing.md) ✅ FIXED
- [003 - WAL Uses Page Allocator After Freeze](./003-wal-uses-page-allocator.md) ✅ FIXED

### High
- [002 - Simulation Service Deploy Test Bug](./002-simulation-service-deploy-test-bug.md) ✅ FIXED

### Medium
- [004 - Reducer Code Duplication](./004-reducer-code-duplication.md) ✅ FIXED

### Low
- [006 - Weak Checksum Implementation](./006-weak-checksum.md) ✅ FIXED (documented as intentionally weak)
- [008 - Hardcoded WAL Path](./008-hardcoded-wal-path.md) ✅ FIXED (added env var support)
- [009 - Undefined Arrays in World.init](./009-undefined-arrays-world-init.md) ✅ FIXED (documented)

---

## PHASE 1: REMAINING ISSUES

### Medium Priority
- [016 - Global Mutable State in Allocator](./016-global-mutable-state-allocator.md)
- [014 - CLI Commands](./014-cli-commands.md) (also Phase 3)
- [015 - WAL Compaction/Snapshotting](./015-wal-compaction.md) (also Phase 5)

---

## PHASE 2: NETWORKING (Planned)

### Critical
- [010 - Gossip Protocol Implementation](./010-gossip-protocol.md)
- [011 - Node-to-Node Communication](./011-node-to-node-communication.md)

### High
- [012 - Delta Encoding for Efficient Sync](./012-delta-encoding.md)

### Medium
- [013 - Packet Size Optimization](./013-packet-size-optimization.md)

---

## Quick Fixes (Low Effort)

1. **Global mutable state** (Issue #016) - Refactor to return allocator from init()

---

## Recommended Priority

### Immediate (Phase 1 remaining)
1. **Global mutable state** (Issue #016) - Clean up architectural debt
2. **CLI commands** (Issue #014) - User-facing feature for testing

### Phase 2 Networking
1. **Node communication** (Issue #011) - Foundation for all networking
2. **Gossip protocol** (Issue #010) - Core cluster functionality
3. **Delta encoding** (Issue #012) - Efficiency improvement
4. **Packet optimization** (Issue #013) - Final polish
