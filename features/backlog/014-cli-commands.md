# Issue: No CLI Commands

## Summary
Users cannot interact with the system - there's no CLI for deploying services, adding peers, etc.

## Critical Constraint: ZERO ALLOCATIONS AFTER STARTUP
> The hot path must have **zero heap allocations**. All buffers must be pre-allocated during init phase.

## Severity
**HIGH** - User-facing feature needed for Phase 2/3

## Phase
Phase 1 (remaining) / Phase 3 (CLI & API)

## Location
- New file: `src/cli.zig` or similar
- Integration: `src/main.zig`

## Requirements
1. **Command parsing**: Parse CLI arguments like `myco deploy <service> --replicas=3`
2. **Commands needed** (from README):
   - `myco deploy` - Deploy a service
   - `myco peer add` - Add a peer node
   - `myco pubkey` - Show public key
3. **IPC to daemon**: CLI needs to communicate with running daemon
   - Unix socket, env var, or other mechanism

## Current Behavior
- `src/main.zig` just runs as a daemon
- No argument handling

## Suggested Approach
1. Simple approach: Daemon reads from stdin or a socket
2. Better: Separate CLI binary that communicates via Unix socket
3. Use Zig's standard library for argument parsing

## Code Suggestion
```zig
// Simple CLI command dispatch
const Command = enum {
    deploy,
    peer_add,
    pubkey,
    status,
};

pub fn parseArgs(args: [][]const u8) !Command {
    if (args.len == 0) return error.NoCommand;
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "deploy")) return .deploy;
    if (std.mem.eql(u8, cmd, "peer")) return .peer_add;
    // ...
    return error.UnknownCommand;
}
```

## Dependencies
- Gossip protocol to discover peers (#010)
- Service deployment logic in reducer

## Testing
1. Parse various command formats
2. Test error handling for invalid commands
3. Integration test with running daemon
