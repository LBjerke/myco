const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const Packet = myco.Packet;
const Headers = Packet.Headers;
const Service = myco.schema.service.Service;
const net = myco.sim.net;
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
    // FIX: Store a POINTER to the allocator, so the struct doesn't move.
    fba: *std.heap.FixedBufferAllocator, 
    outbox: std.ArrayList(Packet),
    sys_alloc: std.mem.Allocator,
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
    
    pub fn deinit(self: *NodeWrapper, alloc: std.mem.Allocator) void {
        self.outbox.deinit(alloc);
        // FIX: Cleanup heap allocations
        alloc.destroy(self.fba); 
        alloc.free(self.mem);
        alloc.free(self.disk);
    }
};

test "Phase 5: CRDT Anti-Entropy Convergence" {
    const alloc = std.testing.allocator;
    var network = try net.NetworkSimulator.init(alloc, 111, 0.0);
    defer network.deinit();

    var alice = try NodeWrapper.init(0, alloc);
    defer alice.deinit(alloc);
    try network.register(0);

    var bob = try NodeWrapper.init(1, alloc);
    defer bob.deinit(alloc);
    try network.register(1);

    // 1. INJECT SERVICE INTO ALICE
    const service_id = 999;
    _ = try alice.real_node.store.update(service_id, service_id); 
    alice.real_node.last_deployed_id = service_id;

    try std.testing.expectEqual(@as(u64, 0), bob.real_node.store.getVersion(service_id));

    // 2. RUN TICKS (Sync Process)
    std.debug.print("\n[MycoSync] Starting Convergence Loop...\n", .{});
    
    var converged = false;
    for (0..1000) |i| {
        alice.outbox.clearRetainingCapacity();
        bob.outbox.clearRetainingCapacity();

        // Alice Tick
        {
            var inbox = std.ArrayList(Packet){}; 
            defer inbox.deinit(alloc); 
            while (network.recv(0)) |p| try inbox.append(alloc, p); 
            try alice.real_node.tick(inbox.items, &alice.outbox, alloc);
        }
        
        // Bob Tick
        {
            var inbox = std.ArrayList(Packet){};
            defer inbox.deinit(alloc);
            while (network.recv(1)) |p| try inbox.append(alloc, p);
            try bob.real_node.tick(inbox.items, &bob.outbox, alloc);
        }

        // Deliver Packets
        for (alice.outbox.items) |p| {
             if (p.header == Headers.SYNC) std.debug.print("[{d}] Alice -> SYNC\n", .{i});
             if (p.header == Headers.DEPLOY) std.debug.print("[{d}] Alice -> DEPLOY (Push/Reply)\n", .{i});
             _ = try network.send(0, 1, p);
        }
        for (bob.outbox.items) |p| {
             if (p.header == Headers.REQUEST) std.debug.print("[{d}] Bob -> REQUEST (Pull)\n", .{i});
             _ = try network.send(1, 0, p);
        }

        if (bob.real_node.store.getVersion(service_id) == service_id) {
            std.debug.print("[{d}] Bob Acquired Service!\n", .{i});
            converged = true;
            break;
        }
    }

    if (!converged) return error.CRDT_DidNotSync;
    
    std.debug.print("[MycoSync] Success: Bob learned Service {d} from Alice.\n", .{service_id});
}
