# Issue: Packet Size Not Optimized to 1024-byte Target

## Summary
The system should target 1024-byte packets (as defined in limits.zig PACKET_SIZE), but:
- No mechanism exists to ensure packets fit
- No compression is implemented
- Gossip encoding may exceed budget

## Critical Constraint: ZERO ALLOCATIONS AFTER STARTUP
> The hot path must have **zero heap allocations**. All buffers must be pre-allocated during init phase.

## Severity
**MEDIUM** - Important for network efficiency

## Phase
Phase 2: Networking

## Location
- `src/net/gossip.zig`
- `src/net/transport.zig` 
- `src/util/limits.zig` (PACKET_SIZE = 1024)

## Requirements
1. **Size budget enforcement**: Ensure gossip payloads don't exceed available space
2. **Compression**: Optional lightweight compression if it reduces size
3. **Chunking**: Handle cases where state exceeds single packet
4. **Priority**: Send most important sections first

## Size Budget
- Total packet: 1024 bytes
- Network overhead: ~60 bytes (UDP + IP header)
- Available payload: ~964 bytes
- From proposal: ~944 bytes (accounting for variance)

## Current Constraints
- No compression library integrated
- No chunking mechanism
- No section prioritization

## Suggested Implementation
1. **Size budgeting**:
   - Calculate payload size before sending
   - If exceeds budget, prioritize sections:
     1. NodeMeta (cluster membership)
     2. Placement (service availability)
     3. ServiceSpecSummary (service definitions)
   - If still exceeds, chunk across multiple packets

2. **Compression** (optional):
   - Simple schemes like LZ4 or deflate if beneficial
   - Compare compressed vs raw, send smaller

3. **Chunking protocol**:
   - Add sequence number to packets
   - Reassemble at receiver
   - Handle missing chunks with timeout

## Dependencies
- Issue #010: Gossip Protocol (generates packets)
- Issue #011: Node Communication (sends packets)
- Issue #012: Delta Encoding (reduces packet size)

## Testing
1. Generate worst-case state and verify fits in budget
2. Test compression ratio with realistic data
3. Test chunking with large state
4. Verify no packet loss causes issues
