const std = @import("std");
const myco = @import("myco");

const Headers = myco.Packet.Headers;
const Service = myco.schema.service.Service;
const Identity = myco.net.handshake.Identity; // Needed to sign the injection

const Node = myco.Node;
const Packet = myco.Packet;
const net = myco.sim.net;

const NODE_COUNT: u16 = 50;
const SIM_TICKS: u64 = 1000;
// Memory for Heap (RAM)
const MEMORY_LIMIT_PER_NODE: usize = 512 * 1024;
// Memory for Disk (WAL)
const DISK_SIZE_PER_NODE: usize = 64 * 1024; 

const NodeWrapper = struct {
    real_node: Node,
    // RAM
    ram_buffer: []u8,
    fba: std.heap.FixedBufferAllocator,
    // DISK (Persists across reboots if we don't free it)
    disk_buffer: []u8,
    
    outbox: std.ArrayList(Packet),
    sys_alloc: std.mem.Allocator,
    rng: std.Random.DefaultPrng,

    pub fn init(id: u16, sys_alloc: std.mem.Allocator) !NodeWrapper {
        const ram = try sys_alloc.alloc(u8, MEMORY_LIMIT_PER_NODE); 
        var fba = std.heap.FixedBufferAllocator.init(ram);
        
        const disk = try sys_alloc.alloc(u8, DISK_SIZE_PER_NODE);
        // Zero out disk to simulate fresh drive
        @memset(disk, 0);

        return .{
            .ram_buffer = ram,
            .fba = fba,
            .disk_buffer = disk,
            // Pass the Disk Buffer to the Node
            .real_node = try Node.init(id, fba.allocator(), disk),
            .outbox = .{},
            .sys_alloc = sys_alloc,
            .rng = std.Random.DefaultPrng.init(@as(u64, id) + 0xDEADBEEF),
        };
    }

    /// Simulate a Power Failure (Crash).
    /// Wipes RAM, Re-initializes Node, but KEEPS Disk Buffer.
    pub fn crash_and_restart(self: *NodeWrapper) !void {
        // 1. Wipe RAM (Reset Allocator)
        self.fba.reset();
        
        // 2. Re-init Node (This calls wal.recover())
        // We reuse the EXISTING self.disk_buffer
        self.real_node = try Node.init(self.real_node.id, self.fba.allocator(), self.disk_buffer);
        
        // 3. Reset Networking
        self.outbox.clearRetainingCapacity();
    }

    pub fn deinit(self: *NodeWrapper, sys_alloc: std.mem.Allocator) void {
        self.outbox.deinit(sys_alloc);
        sys_alloc.free(self.ram_buffer);
        sys_alloc.free(self.disk_buffer);
    }

    pub fn tick(self: *NodeWrapper, simulator: *net.NetworkSimulator) !void {
        var inbox = std.ArrayList(Packet){};
        defer inbox.deinit(std.testing.allocator);
        
        while (simulator.recv(self.real_node.id)) |p| {
            try inbox.append(std.testing.allocator, p);
        }

        self.outbox.clearRetainingCapacity();
        try self.real_node.tick(inbox.items, &self.outbox, self.sys_alloc);

        for (self.outbox.items) |p| {
            const target = self.rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
            if (target != self.real_node.id) {
                _ = try simulator.send(self.real_node.id, target, p);
            }
        }
    }
};

test "Phase 3: Persistence (Crash Recovery)" {
    const allocator = std.testing.allocator;
    std.debug.print("\n[MycoSim] Initializing Cluster with WAL...\n", .{});

    var network = try net.NetworkSimulator.init(allocator, 12345, 0.5);
    defer network.deinit();

    var nodes = try allocator.alloc(NodeWrapper, NODE_COUNT);
    defer allocator.free(nodes);

    for (nodes, 0..) |*wrapper, i| {
        wrapper.* = try NodeWrapper.init(@intCast(i), allocator);
        try network.register(@intCast(i));
    }
    defer for (nodes) |*wrapper| wrapper.deinit(allocator);

    // 1. Run Halfway
    const HALFWAY = SIM_TICKS / 2;
    std.debug.print("[MycoSim] Running pre-crash ({d} ticks)...\n", .{HALFWAY});
    for (0..HALFWAY) |_| {
        for (nodes) |*wrapper| try wrapper.tick(&network);
    }

    // 2. KILL NODE 0
    const val_before = nodes[0].real_node.knowledge;
    std.debug.print("[MycoSim] ⚡ KILLING NODE 0 (Value: {d}) ⚡\n", .{val_before});
    
    // This simulates power loss. RAM is gone.
    try nodes[0].crash_and_restart();
    
    const val_after = nodes[0].real_node.knowledge;
    std.debug.print("[MycoSim] 🔄 NODE 0 REBOOTED (Recovered: {d})\n", .{val_after});

    // ASSERTION: WAL Recovery worked
    if (val_after != val_before) {
        std.debug.print("CRITICAL: Data Loss! Expected {d}, got {d}\n", .{val_before, val_after});
        return error.DataLossDetected;
    }

    // 3. Finish Simulation
    std.debug.print("[MycoSim] Resuming simulation...\n", .{});
    for (HALFWAY..SIM_TICKS) |_| {
        for (nodes) |*wrapper| try wrapper.tick(&network);
    }

    // 4. Verify Final Convergence
    const first = nodes[0].real_node.knowledge;
    for (nodes) |*wrapper| {
        if (wrapper.real_node.knowledge != first) return error.CRDT_DidNotConverge;
    }
    std.debug.print("[MycoSim] SUCCESS: Convergence + Persistence Verified.\n", .{});
}

test "Phase 4: Service Deployment Injection" {
    const allocator = std.testing.allocator;
    std.debug.print("\n[MycoSim] Testing Service Deployment...\n", .{});

    var network = try net.NetworkSimulator.init(allocator, 999, 0.0); // 0% Loss for this test
    defer network.deinit();

    // Just testing with 2 nodes to verify logic
    var nodes = try allocator.alloc(NodeWrapper, 2);
    defer allocator.free(nodes);

    for (nodes, 0..) |*wrapper, i| {
        wrapper.* = try NodeWrapper.init(@intCast(i), allocator);
        try network.register(@intCast(i));
    }
    defer for (nodes) |*wrapper| wrapper.deinit(allocator);

    // 1. CREATE A SERVICE
    var service = Service{
        .id = 555, // The Target Deployment ID
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };
    service.setName("critical-backend");
    
    // 2. PACK IT INTO A PACKET
    var deploy_packet = Packet{
        .header = Headers.DEPLOY,
        // We simulate an admin key sending this
        .sender_pubkey = undefined, 
    };
    
    // Generate an Admin Identity just for signing
    const admin = Identity.initDeterministic(999999);
    deploy_packet.sender_pubkey = admin.key_pair.public_key.toBytes();
    
    // Copy Service struct into Payload
    const service_bytes = std.mem.asBytes(&service);
    @memcpy(deploy_packet.payload[0..@sizeOf(Service)], service_bytes);
    
    // Sign it
    deploy_packet.signature = admin.sign(&deploy_packet.payload);

    // 3. INJECT INTO NODE 0
    // We bypass the network sim and manually push to Node 0's inbox
    // In reality, we'd use the API (Phase 6) to do this.
    _ = try network.send(9999, 0, deploy_packet);

    // 4. TICK NODE 0
    try nodes[0].tick(&network);

    // 5. ASSERTION
    std.debug.print("Node 0 Last Deployed ID: {d}\n", .{nodes[0].real_node.last_deployed_id});
    
    if (nodes[0].real_node.last_deployed_id != 555) {
        return error.DeploymentNotTriggered;
    }

    std.debug.print("[MycoSim] SUCCESS: Service 555 Deployed successfully.\n", .{});
}
