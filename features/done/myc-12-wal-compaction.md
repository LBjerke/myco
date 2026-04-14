# MYC-12: WAL Compaction

## Issue Reference
- **ID:** MYC-12
- **Title:** Implement Write-Ahead Log (WAL) Compaction
- **Status:** In Review

## Summary
Implemented WAL compaction and snapshotting mechanism to enable disk space reclamation and faster recovery times. The WAL now manages two artifacts: a snapshot file for compacted state and a log file for events since the last snapshot.

## Key Changes

### src/db/wal.zig
- Extended `Entry` struct from single `value: u64` to `id: u64, version: u64` for CRDT support
- Added `SnapshotHeader` with magic number, data length, and CRC
- Split buffer into `log_buffer` and `snap_buffer` regions
- Added `compact()` function for atomic snapshot + truncate
- Updated `recover()` to load snapshot first, then replay log entries
- Added CRC validation for both snapshot and log entries

### src/node.zig
- Updated WAL initialization to use split log/snap buffers
- Added compaction trigger logic (every 10 appends in simulation)
- Added snapshot serialization using scratch buffer

### tests/unit_wal.zig
- Updated tests for new `append(id, version)` signature
- Added test for snapshot + log combined recovery

## Testing Approach
- Core tests pass: `test-units`, `test-cli`, `test-engine`
- WAL unit tests verify:
  - Append and recovery
  - Corruption detection in log
  - Snapshot + log combined recovery
  - CRC validation

## PR Link
(Will be added after PR creation)