// Unit tests for CRDT sync behavior between two nodes over the simulator network.
// This file contains unit tests designed to verify the CRDT (Conflict-Free
// Replicated Data Type) synchronization behavior between two Myco nodes over
// a simulated network. These tests specifically focus on anti-entropy convergence,
// ensuring that service versions are correctly propagated and synchronized
// between nodes even when starting with discrepancies. It simulates the
// injection of a service into one node and then monitors whether the other
// node successfully acquires and converges to the correct service state,
// validating the core synchronization mechanisms.
//
const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const NodeStorage = myco.NodeStorage;
const Packet = myco.Packet;
const Headers = myco.Headers;
const Service = myco.schema.service.Service;
const Entry = myco.sync.crdt.Entry;
const Hlc = myco.sync.hlc.Hlc;
const net = myco.sim.net;
const node_impl = myco.node;
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
    sys_alloc: std.mem.Allocator,
    pub fn init(id: u16, sys_alloc: std.mem.Allocator) !NodeWrapper {
        const mem = try sys_alloc.alloc(u8, MEMORY_LIMIT_PER_NODE);
        const disk = try sys_alloc.alloc(u8, DISK_SIZE_PER_NODE);
        @memset(disk, 0);

        const fba = try sys_alloc.create(std.heap.FixedBufferAllocator);
        fba.* = std.heap.FixedBufferAllocator.init(mem);

        const storage = try fba.allocator().create(NodeStorage);
        return .{
            .mem = mem,
            .disk = disk,
            .fba = fba,
            // PASS THE MOCK EXECUTOR
            .real_node = try Node.init(id, storage, disk, fba, // Pass any valid pointer as context (unused)
                mockExecutor),
            .sys_alloc = sys_alloc,
        };
    }

    pub fn deinit(self: *NodeWrapper, alloc: std.mem.Allocator) void {
        // FIX: Cleanup heap allocations
        alloc.destroy(self.fba);
        alloc.free(self.mem);
        alloc.free(self.disk);
    }
};

test "compressed digest packs more than raw entries and round-trips" {
    var payload: [952]u8 = undefined;
    var entries: [120]Entry = undefined;
    for (entries, 0..) |_, idx| {
        entries[idx] = .{ .id = idx + 1, .version = (idx + 1) * 2 };
    }

    const used_bytes: u16 = node_impl.codec.encodeDigest(entries[0..], payload[0..]);
    const encoded_len: usize = @intCast(used_bytes);

    var decoded: [120]Entry = undefined;
    const decoded_len = node_impl.codec.decodeDigest(payload[0..encoded_len], decoded[0..]);

    try std.testing.expectEqual(entries.len, decoded_len);
    for (entries, 0..) |expected, i| {
        try std.testing.expectEqual(expected.id, decoded[i].id);
        try std.testing.expectEqual(expected.version, decoded[i].version);
    }

    const raw_size = entries.len * @sizeOf(Entry);
    try std.testing.expect(encoded_len < raw_size);
}

test "Phase 5: CRDT Anti-Entropy Convergence" {
    const alloc = std.testing.allocator;
    var clock = myco.sim.time.Clock{};
    var network = try net.NetworkSimulator.init(alloc, 111, 0.0, &clock, 0, 0, 50_000 * @sizeOf(myco.Packet), false);
    defer network.deinit();

    var alice = try NodeWrapper.init(0, alloc);
    defer alice.deinit(alloc);
    try network.register(0);

    var bob = try NodeWrapper.init(1, alloc);
    defer bob.deinit(alloc);
    try network.register(1);

    // 1. INJECT SERVICE INTO ALICE
    const service_id = 999;
    const service_version = Hlc.init(1).pack();
    _ = try alice.real_node.store.update(service_id, service_version);
    var service: Service = undefined;
    @memset(std.mem.asBytes(&service), 0);
    service.id = service_id;
    try alice.real_node.putService(service);
    alice.real_node.last_deployed_id = service_id;

    try std.testing.expectEqual(@as(u64, 0), bob.real_node.store.getVersion(service_id));

    // 2. RUN TICKS (Sync Process)
    std.debug.print("\n[MycoSync] Starting Convergence Loop...\n", .{});

    var converged = false;
    for (0..1000) |i| {
        // Alice Tick
        {
            var inbox = std.ArrayList(Packet){};
            defer inbox.deinit(alloc);
            while (network.recv(0)) |p| try inbox.append(alloc, p);
            try alice.real_node.tick(inbox.items);
        }

        // Bob Tick
        {
            var inbox = std.ArrayList(Packet){};
            defer inbox.deinit(alloc);
            while (network.recv(1)) |p| try inbox.append(alloc, p);
            try bob.real_node.tick(inbox.items);
        }

        // Deliver Packets
        for (alice.real_node.outbox.constSlice()) |p| {
            if (p.packet.msg_type == Headers.Sync) std.debug.print("[{d}] Alice -> SYNC\n", .{i});
            if (p.packet.msg_type == Headers.Deploy) std.debug.print("[{d}] Alice -> DEPLOY (Push/Reply)\n", .{i});
            _ = try network.send(0, 1, p.packet);
        }
        for (bob.real_node.outbox.constSlice()) |p| {
            if (p.packet.msg_type == Headers.Request) std.debug.print("[{d}] Bob -> REQUEST (Pull)\n", .{i});
            _ = try network.send(1, 0, p.packet);
        }

        if (bob.real_node.store.getVersion(service_id) == service_version) {
            std.debug.print("[{d}] Bob Acquired Service!\n", .{i});
            converged = true;
            break;
        }
    }

    if (!converged) return error.CRDT_DidNotSync;

    std.debug.print("[MycoSync] Success: Bob learned Service {d} from Alice.\n", .{service_id});
}
