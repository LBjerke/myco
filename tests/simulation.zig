const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const Packet = myco.Packet;
const Headers = Packet.Headers;
const Service = myco.schema.service.Service;
const net = myco.sim.net;
const OutboundPacket = myco.OutboundPacket;
const ApiServer = myco.api.server.ApiServer;
const time = myco.sim.time;

// --- AGGRESSIVE TEST PARAMETERS ---
const NODE_COUNT: u16 = 50;
const SIM_TICKS: u64 = 8000;
const PACKET_LOSS: f64 = 0.25; // 25% packet loss
const LATENCY: u64 = 10;
const JITTER: u64 = 20;

const MEMORY_LIMIT_PER_NODE: usize = 512 * 1024;
const DISK_SIZE_PER_NODE: usize = 64 * 1024;

fn mockExecutor(_: *anyopaque, service: Service) anyerror!void {
    _ = service;
}

const NodeWrapper = struct {
    real_node: Node,
    mem: []u8,
    disk: []u8,
    fba: *std.heap.FixedBufferAllocator,
    outbox: std.ArrayList(OutboundPacket),
    sys_alloc: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
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
            .real_node = try Node.init(id, fba.allocator(), disk, fba, mockExecutor),
            .outbox = .{},
            .sys_alloc = sys_alloc,
            .rng = std.Random.DefaultPrng.init(@as(u64, id) + 0xDEADBEEF),
            .api = undefined,
        };
    }
    
    pub fn deinit(self: *NodeWrapper, sys_alloc: std.mem.Allocator) void {
        self.outbox.deinit(sys_alloc);
        self.real_node.service_data.deinit();
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

test "Phase 5: The Grand Simulation (Final Protocol)" {
    const allocator = std.testing.allocator;
    std.debug.print("\n[MycoSim] Initializing Final Protocol Simulation...\n", .{});

    var clock = time.Clock{};
    
    var network = try net.NetworkSimulator.init(allocator, 12345, PACKET_LOSS, &clock, LATENCY, JITTER); 
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

    var services_injected: u64 = 0;
    const TOTAL_SERVICES = NODE_COUNT; 

    std.debug.print("[MycoSim] Running {d} ticks with CONTINUOUS INJECTION...\n", .{SIM_TICKS});
    
    for (0..SIM_TICKS) |t| {
        clock.tick();

        if (t > 0 and t % 100 == 0 and services_injected < TOTAL_SERVICES) {
            const service_id = 1000 + services_injected;
            const target_node_idx = services_injected % NODE_COUNT;

            var service = Service{.id = service_id, .name=undefined, .flake_uri=undefined, .exec_name=undefined};
            service.setName("real-service");
            service.setFlake("github:myco/service");
            
            _ = try nodes[target_node_idx].real_node.injectService(service);
            
            services_injected += 1;
        }

        for (nodes) |*wrapper| {
            try wrapper.tick(&network, &key_map);
        }
        
        if (t % 500 == 0) {
            const resp = try nodes[0].api.handleRequest("GET /metrics");
            defer allocator.free(resp);
            
            var iter = std.mem.splitScalar(u8, resp, '\n');
            _ = iter.next(); _ = iter.next(); _ = iter.next(); _ = iter.next();
            const known_line = iter.next() orelse "???";
            
            std.debug.print("[Tick {d: >4}] Total Injected: {d: >2} | {s}\n", .{t, services_injected, known_line});
        }
    }
    std.debug.print("\n", .{});

    var perfect_nodes: usize = 0;
    for (nodes) |*wrapper| {
        const count = wrapper.real_node.store.versions.count();
        if (count == TOTAL_SERVICES) perfect_nodes += 1;
    }

    std.debug.print("[MycoSim] Final Status: {d}/{d} Nodes have all {d} services.\n", .{ perfect_nodes, NODE_COUNT, TOTAL_SERVICES });

    if (perfect_nodes != NODE_COUNT) {
        return error.ClusterDidNotConverge;
    }

    std.debug.print("[MycoSim] SUCCESS: Convergence Verified.\n", .{});
}
