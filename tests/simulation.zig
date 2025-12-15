const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const Packet = myco.Packet;
const Headers = Packet.Headers;
const Service = myco.schema.service.Service;
const net = myco.sim.net;
const OutboundPacket = myco.OutboundPacket;
// NEW: Import the API Server
const ApiServer = myco.api.server.ApiServer;

const NODE_COUNT: u16 = 50;
const SIM_TICKS: u64 = 3000; 
const MEMORY_LIMIT_PER_NODE: usize = 512 * 1024; 
const DISK_SIZE_PER_NODE: usize = 64 * 1024;     

fn mockExecutor(_: *anyopaque, service: Service) anyerror!void {
    // In simulation, we just log. We don't want to run Nix.
    _ = service;
    // std.debug.print("   [Sim] Mock Deploy Service ID: {d}\n", .{service.id});
}
const NodeWrapper = struct {
    real_node: Node,
    mem: []u8,
    disk: []u8,
    fba: *std.heap.FixedBufferAllocator,
    outbox: std.ArrayList(OutboundPacket),
    sys_alloc: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    
    // NEW: Attach the API Server to the wrapper
    api: ApiServer,

        pub fn init(id: u16, sys_alloc: std.mem.Allocator) !NodeWrapper {
        const mem = try sys_alloc.alloc(u8, MEMORY_LIMIT_PER_NODE);
        const disk = try sys_alloc.alloc(u8, DISK_SIZE_PER_NODE);
        @memset(disk, 0);

        const fba = try sys_alloc.create(std.heap.FixedBufferAllocator);
        fba.* = std.heap.FixedBufferAllocator.init(mem);

        return .{
            .mem = mem,
            .disk = disk,
            .fba = fba,
            // PASS THE MOCK EXECUTOR
            .real_node = try Node.init(
                id, 
                fba.allocator(), 
                disk,
                fba, // Pass any valid pointer as context (unused)
                mockExecutor
            ),
            .outbox = .{},
            .sys_alloc = sys_alloc,
            .rng = std.Random.DefaultPrng.init(@as(u64, id) + 0xDEADBEEF),
            .api = undefined,
        };
    }

    pub fn deinit(self: *NodeWrapper, sys_alloc: std.mem.Allocator) void {
        self.outbox.deinit(sys_alloc);
        sys_alloc.destroy(self.fba);
        sys_alloc.free(self.mem);
        sys_alloc.free(self.disk);
    }

    pub fn tick(self: *NodeWrapper, simulator: *net.NetworkSimulator, key_map: *std.StringHashMap(u16)) !void {
        var inbox = std.ArrayList(Packet){};
        defer inbox.deinit(self.sys_alloc);
        
        while (simulator.recv(self.real_node.id)) |p| {
            try inbox.append(self.sys_alloc, p);
        }

        self.outbox.clearRetainingCapacity();
        try self.real_node.tick(inbox.items, &self.outbox, self.sys_alloc);

        for (self.outbox.items) |out| {
            if (out.recipient) |dest_key| {
                if (key_map.get(&dest_key)) |target_id| {
                     _ = try simulator.send(self.real_node.id, target_id, out.packet);
                }
            } else {
                const target = self.rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
                if (target != self.real_node.id) {
                    _ = try simulator.send(self.real_node.id, target, out.packet);
                }
            }
        }
    }
};

test "Phase 5: The Grand Simulation (Dynamic Injection)" {
    const allocator = std.testing.allocator;
    std.debug.print("\n[MycoSim] Initializing Dynamic Simulation...\n", .{});

    // 1. Setup Network (20% Loss)
    var network = try net.NetworkSimulator.init(allocator, 12345, 0.2); 
    defer network.deinit();

    var nodes = try allocator.alloc(NodeWrapper, NODE_COUNT);
    defer allocator.free(nodes);

    var key_map = std.StringHashMap(u16).init(allocator);
    defer key_map.deinit();

    for (nodes, 0..) |*wrapper, i| {
        wrapper.* = try NodeWrapper.init(@intCast(i), allocator);
        try network.register(@intCast(i));
        wrapper.api = ApiServer.init(allocator, &wrapper.real_node);
        const pk_bytes = wrapper.real_node.identity.key_pair.public_key.toBytes();
        try key_map.put(try allocator.dupe(u8, &pk_bytes), @intCast(i));
    }
    defer {
        var it = key_map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        for (nodes) |*wrapper| wrapper.deinit(allocator);
    }

    // NOTE: We do NOT inject services here. We start empty.
    var services_injected: u64 = 0;

    std.debug.print("[MycoSim] Running {d} ticks with CONTINUOUS INJECTION...\n", .{SIM_TICKS});
    
    // 2. RUN SIMULATION LOOP
    for (0..SIM_TICKS) |t| {
        // --- DYNAMIC INJECTION EVENT ---
        // Every 30 ticks, inject a NEW service into a RANDOM node
        if (t > 0 and t % 30 == 0 and services_injected < 50) {
            const service_id = 1000 + services_injected;
            // Round-robin injection: Node 0 gets S1000, Node 1 gets S1001...
            const target_node_idx = services_injected % NODE_COUNT;
            
            // "Deploy" to that node
            _ = try nodes[target_node_idx].real_node.store.update(service_id, service_id);
            nodes[target_node_idx].real_node.last_deployed_id = service_id;
            
            services_injected += 1;
            // std.debug.print("   + [Tick {d}] User Deployed Service {d} -> Node {d}\n", .{t, service_id, target_node_idx});
        }

        // Run the Physics
        for (nodes) |*wrapper| {
            try wrapper.tick(&network, &key_map);
        }
        
        // --- OBSERVABILITY ---
        // Log Node 0's brain every 100 ticks so we can see it learning
        if (t % 100 == 0) {
            const resp = try nodes[0].api.handleRequest("GET /metrics");
            defer allocator.free(resp);
            
            // Extract just the "services_known" line for cleaner output
            var iter = std.mem.splitScalar(u8, resp, '\n');
            _ = iter.next(); // Skip HTTP 200
            _ = iter.next(); // Skip Blank
            _ = iter.next(); // Skip node_id
            _ = iter.next(); // Skip knowledge
            const known_line = iter.next() orelse "???";
            
            std.debug.print("[Tick {d: >4}] Total Injected: {d: >2} | {s}\n", .{t, services_injected, known_line});
        }
    }
    std.debug.print("\n", .{});

    // 3. FINAL VERIFICATION
    var perfect_nodes: usize = 0;
    for (nodes) |*wrapper| {
        const count = wrapper.real_node.store.versions.count();
        if (count == 50) perfect_nodes += 1;
    }

    std.debug.print("[MycoSim] Final Status: {d}/{d} Nodes have all 50 services.\n", .{perfect_nodes, NODE_COUNT});

    if (perfect_nodes != NODE_COUNT) {
        return error.ClusterDidNotConverge;
    }

    std.debug.print("[MycoSim] SUCCESS: Dynamic Convergence Verified.\n", .{});
}
