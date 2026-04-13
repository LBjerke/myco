# Feature: Myco Edge - Stateless Gossip Relay for Cloudflare Workers

> Status: 🔄 Planned

## Summary

Implement Myco as a lightweight Cloudflare Workers-based edge coordinator that propagates cluster state across network segments. Runs entirely in-memory without persistent storage - state is naturally maintained by the Pi Zero nodes in the cluster.

## Use Case

Organizations with distributed Pi Zero clusters across multiple network segments (different regions, VPCs, or firewall boundaries) need a way to propagate state between segments. Myco Edge provides:

- **Cross-region coordination**: Enable gossip between Pi Zeros in different Cloudflare edge locations
- **Network segmentation**: Bridge clusters behind different firewalls/VPCs
- **Lightweight relay**: No persistence needed - state lives on Pi Zeros, Edge is just a relay
- **Cost-effective**: Runs on Cloudflare Workers free tier for most deployments

## Original Ask

Create a minimal Myco implementation that:
1. Runs on Cloudflare Workers (WASM via Zig)
2. Keeps all state in-memory (no D1, no R2, no Durable Objects)
3. Participates in gossip protocol as a relay node
4. Survives restarts by reconverging via gossip from Pi Zero peers
5. Costs essentially nothing to run

## Architecture

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Normal Operation                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│    Pi Zero A ◄────── Gossip ──────► Myco Edge (Worker)    │
│         │                                    │              │
│         │         Gossip                    │              │
│         ▼                                    ▼              │
│    Pi Zero B ◄────────────────────────► Pi Zero C          │
│         │                                    │              │
│    Each Pi Zero has FULL cluster state locally              │
│    Myco Edge is just a relay, not the source of truth       │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Edge Goes Down                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│    Pi Zero A ◄──── Gossip ──────► Pi Zero B ◄──► Pi Zero C │
│         │                                        │            │
│         │         Cluster keeps running!        │            │
│         │         Each Pi has complete state   │            │
│         ▼                                        ▼            │
│    Node state: intact                    Node state: intact │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Edge Comes Back                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│    Pi Zero A ──► sends current state ──► Myco Edge (empty) │
│         │                                       ▲            │
│         │          Edge learns state           │            │
│         │          via gossip                  │            │
│         └─────────────────────────────────────┘            │
│    Pi Zero B ──► sends current state ──► Myco Edge         │
│    Pi Zero C ──► sends current state ──► Myco Edge         │
│                                                             │
│    Edge reconverges via CRDT, resumes propagating           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Why This Works

| Property | How Myco Handles It |
|----------|---------------------|
| **No single source of truth** | CRDT - every node has complete state |
| **State recovery** | Gossip - when Edge reconnects, peers send state |
| **Conflict resolution** | HLC timestamps - deterministic merge |
| **Network partition** | Both sides keep working, reconcile when reconnected |

### Network Topology

```
                    ┌─────────────────────────────────────┐
                    │        Myco Edge (Worker)          │
                    │   ┌─────────────────────────────┐  │
                    │   │   In-memory state cache   │  │
                    │   │   - Nodes (learned)        │  │
                    │   │   - Services (learned)    │  │
                    │   │   - Placements (learned)  │  │
                    │   └─────────────────────────────┘  │
                    │              │                     │
                    └──────────────┼─────────────────────┘
                                   │ HTTP Gossip
                    ┌──────────────┼─────────────────────┐
                    │              │       Region A      │
                    │     ┌────────▼────────┐          │
                    │     │     Pi Zero     │          │
                    │     │  (has full WAL) │          │
                    │     └─────────────────┘          │
                    │              │                   │
         ┌──────────┴──────────────┴───────────┐        │
         │            Gossip between Pis       │        │
         │     (raw UDP/TCP, same as before)   │        │
         └─────────────────────────────────────┘        │
                         │                   │
           ┌─────────────┘           ┌─────────────┘
           │       Region B          │       Region C
           ▼                           ▼
    ┌─────────────┐            ┌─────────────┐
    │  Pi Zero    │            │  Pi Zero    │
    │ (has WAL)   │            │ (has WAL)   │
    └─────────────┘            └─────────────┘

Each Pi Zero has full cluster state via WAL
Myco Edge is just a gossip participant, not the source
```

## Implementation

### Target: Cloudflare Workers

- Compile Zig to WASM via `zig build -target wasm32-freestanding`
- Use Workers' fetch handler as the event loop
- No external storage - state is in-memory only

### Entry Point

```zig
/// Myco Edge entry point - request handler for Cloudflare Workers
export fn fetch(request: Request) Response {
    // Parse gossip message from Pi Zero
    // Apply via reducer (same as core)
    // Forward to other connected peers
    // Return current state as response
}
```

### State Management

```zig
/// Myco Edge world - just a cache, not durable
pub const EdgeWorld = struct {
    /// Replicated state (learned from peers)
    nodes: [limits.max_nodes]Node,
    node_count: usize = 0,
    
    /// Learned state from gossip
    services: [limits.max_services]ServiceSpec,
    service_count: usize = 0,
    
    /// Peer connections (HTTP endpoints)
    peers: [64]Peer,
    peer_count: usize = 0,
    
    /// Last gossip timestamp for reconciliation
    last_sync_ms: u64 = 0,
    
    /// Initialize empty - will learn via gossip
    pub fn init() EdgeWorld {
        return EdgeWorld{
            .nodes = undefined,
            .node_count = 0,
            .services = undefined,
            .service_count = 0,
            .peers = undefined,
            .peer_count = 0,
            .last_sync_ms = 0,
        };
    }
};
```

### Gossip Transport

```zig
/// HTTP-based gossip for Workers
/// Replaces raw UDP/TCP with fetch() calls
pub const WorkerGossip = struct {
    /// Send gossip to a peer via HTTP
    pub fn sendToPeer(peer_endpoint: []const u8, digest: GossipDigest) !void {
        const client = std.http.Client{ .allocator = ... };
        defer client.deinit();
        
        var req = try client.open(.POST, try std.Uri.parse(peer_endpoint));
        defer req.deinit();
        
        // Send digest as JSON
        try req.writeHeader();
        try req.writeBody(try encodeDigestJson(digest));
        
        const resp = try req.send();
        // ... handle response
    }
    
    /// Receive gossip from a peer
    pub fn handleGossipRequest(world: *EdgeWorld, body: []u8) !void {
        const digest = try decodeDigestJson(body);
        
        // Merge via CRDT - same as core reducer
        for (digest.nodes) |node_state| {
            _ = NodeStore.merge(&world.node_store, node_state);
        }
        
        // Forward to other connected peers (rumor mongering)
        for (world.peers[0..world.peer_count]) |peer| {
            // Forward the new state we just learned
        }
    }
};
```

### Handler Structure

```zig
/// Main request handler for Workers
pub export fn fetch(env: *cws_env_t, request: cws_request_t) cws_response_t {
    // Parse request method and path
    const method = cws_request_method(request);
    const path = cws_request_path(request);
    
    switch (method) {
        .GET => {
            // Return current state (for peer sync)
            return encodeStateResponse(world);
        },
        .POST => {
            // Receive gossip from peer
            const body = cws_request_body(request);
            WorkerGossip.handleGossipRequest(world, body);
            return okResponse();
        },
        else => return methodNotAllowed(),
    }
}
```

## Performance Characteristics

### Request Profile

| Operation | CPU | Memory |
|-----------|-----|--------|
| Receive gossip (POST) | ~5ms | +state |
| Send gossip (GET peer) | ~5ms | -state |
| Reconverge on startup | ~10ms | parse |

### Capacity

| Metric | Value |
|--------|-------|
| Max connected peers | 64 |
| State size | ~250 KB |
| Gossip message size | ~1-5 KB |
| Requests/second (est.) | ~100 |

## Cost Analysis

### Cloudflare Workers Pricing

| Resource | Free Tier | Paid Tier |
|----------|-----------|-----------|
| Requests | 100K/day | $0.30/million |
| CPU | 10ms/request | $0.02/million CPU-ms |
| Storage | N/A | N/A |
| Egress | Free | Free |

### Projected Costs

| Cluster Size | Daily Requests | Monthly Cost |
|--------------|----------------|--------------|
| 3 nodes | ~260K | **$0** (Free tier) |
| 5 nodes | ~430K | **$0** (Free tier) |
| 10 nodes | ~860K | **$0** (Free tier, tight) |
| 20 nodes | ~1.7M | **$5** (base minimum) |
| 50 nodes | ~4.3M | **$5.50** |
| 100 nodes | ~8.6M | **$6.50** |

### Verdict: Essentially Free

- **Small clusters (3-10 nodes)**: Runs on **Free tier**
- **Medium clusters (10-50 nodes)**: **$5-6/month**
- **Even 100 nodes**: Only pays the $5/month minimum

## Tradeoffs

| Aspect | Implication |
|--------|--------------|
| **Edge offline** | Cluster survives - Pi Zeros keep running |
| **Edge loses memory** | No problem - gossip to learn state again |
| **Network partition** | Both sides work, reconcile when reconnected |
| **No persistence** | State lives on Pi Zeros, Edge is just cache |
| **Cross-region gossip** | Adds one hop but enables global coordination |

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Edge starts with no peers | Wait for peers to connect, learn state |
| Edge receives stale state | CRDT/HLC handles merge - newer wins |
| All Pi Zeros restart | Wait for at least one to come back |
| Network partition | Both partitions work, reconcile on reconnect |
| Worker evicted | Just reconnect and learn state again |

## Testing

### Unit Tests

| Test | Description |
|------|-------------|
| `test "state merges via CRDT"` | Verify newer HLC wins |
| `test "learns state from peer"` | Simulate gossip receive |
| `test "forwards to other peers"` | Rumor mongering works |
| `test "reconverges after restart"` | Simulate empty start + gossip |

### Integration Tests

| Test | Description |
|------|-------------|
| `test "two workers sync state"` | Both Workers learn same state |
| `test "worker + pi zero sync"` | Hybrid cluster works |
| `test "partition then rejoin"` | Simulate network split |

## Where Code Was Added/Changed

| File | Changes |
|------|---------|
| `src/net/worker_gossip.zig` | NEW - HTTP gossip for Workers |
| `src/ecs/edge_world.zig` | NEW - Lightweight edge world struct |
| `src/main_edge.zig` | NEW - Worker entry point |
| `build_worker.zig` | NEW - Build script for WASM |
| `src/lib.zig` | Add EdgeWorld, WorkerGossip exports |

## Comparison: Myco Edge vs Full Myco

| Feature | Full Myco (Pi Zero) | Myco Edge (Worker) |
|---------|---------------------|-------------------|
| **State storage** | WAL (durable) | In-memory (cache) |
| **Service execution** | systemd | None (relay only) |
| **Startup** | Replay WAL | Gossip from peers |
| **Persistence** | Full | None |
| **Cost** | Hardware | $0-5/mo |

## Summary

Myco Edge provides a lightweight, cost-effective way to propagate cluster state across network boundaries. Key benefits:

- **Essentially free**: Runs on Workers free tier
- **No persistence needed**: State lives on Pi Zeros
- **Resilient**: If Edge dies, cluster survives
- **Simple**: No D1/R2/Durable Objects complexity
- **Hybrid**: Works with existing Pi Zero clusters

This is ideal for organizations with distributed Pi Zero deployments that need cross-region coordination without the complexity of a centralized database.