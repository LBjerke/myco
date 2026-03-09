# Feature 12: Runtime and Simulation Fixes

## 1. WAL `NotOpenForReading` Error

### Issue
The `myco` daemon failed to start, throwing `error.NotOpenForReading` during the WAL initialization phase. This occurred because the `Wal.init` and `rotateSegment` functions used `std.fs.cwd().createFile()` without explicitly enabling the `.read` flag, but then immediately attempted to read the segment header to verify magic bytes and versioning.

### Fix
Added `.read = true` to all `createFile` calls in `src/db/wal.zig`.

### Why
Zig's `createFile` defaults to write-only access for the returned file handle. Since the Myco WAL protocol requires reading the header immediately after creation (to initialize in-memory state) or during replay, read access must be granted at the time of file creation or re-opening.

## 2. Reducer: Node Rejoin Logic

### Issue
The `network_partition` simulation scenario failed. When a node "left" (marked `alive = false`) and subsequently "rejoined" (new `node_join` event), the reducer would see the node already existed in the table and return `.none` effect without updating its status, leaving the node permanently dead in the ECS world.

### Fix
Modified `src/core/reducer.zig` to explicitly set `node.alive = true` when a `node_join` event matches an existing node ID.

### Why
In a decentralized system, a `node_join` event for an existing ID is the standard signal that a node has recovered or a network partition has healed. The state must be updated to reflect that the node is once again a valid target for service placement.

## 3. Simulation Test Infrastructure

### Issue
The simulation harness (`tests/simulation.zig`) failed to compile due to:
- Relative imports being blocked by Zig's module system.
- Unused parameters in `runStep`.
- Mismatched function types for the `verify` step callbacks.
- Logic errors in `parseIpv4` causing incorrect IP bytes.

### Fix
- Updated `build.zig` to export `src/lib.zig` as a module named `myco`.
- Refactored `tests/simulation.zig` to use the `myco` module instead of relative paths.
- Changed `VerifyStep.check_fn` from a function type to a function pointer (`*const fn`).
- Fixed `parseIpv4` to correctly track the `part_idx` independently of the string cursor.

### Why
These changes bring the simulation harness into alignment with Zig 0.15.x best practices. Using a dedicated module for the library under test is more robust than relative imports, and using function pointers for callbacks allows scenarios to be defined at comptime while still being executable at runtime.

## 4. IP Parsing Logic

### Issue
The `parseIpv4` helper was using the string start index as the array index, causing it to write bytes to the wrong positions in the IP address array if the octets were not a specific length.

### Fix
Introduced a dedicated `part_idx` counter to ensure octets are written to indices 0, 1, 2, and 3 regardless of the character position in the input string.

### Why
Reliable IP parsing is critical for the `node_join` events used in the simulation, as incorrect IPs would lead to verification failures when checking node identity in the ECS world.
