// End-to-end simulations of cluster convergence under lossy, jittery network conditions.
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
const PACKET_LOSS: f64 = 0.05;
const LATENCY: u64 = 10;
const JITTER: u64 = 20;

const MEMORY_LIMIT_PER_NODE: usize = 512 * 1024;
const DISK_SIZE_PER_NODE: usize = 64 * 1024;

fn mockExecutor(_: *anyopaque, service: Service) anyerror!void {
    _ = service;
}

fn parseSeedEnv(name: []const u8, default_value: u64) u64 {
    if (std.posix.getenv(name)) |bytes| {
        if (bytes.len > 2 and bytes[0] == '0' and (bytes[1] == 'x' or bytes[1] == 'X')) {
            return std.fmt.parseInt(u64, bytes[2..], 16) catch default_value;
        }
        return std.fmt.parseInt(u64, bytes, 10) catch default_value;
    }
    return default_value;
}

fn parseProbEnv(name: []const u8, default_value: f64) f64 {
    if (std.posix.getenv(name)) |bytes| {
        return std.fmt.parseFloat(f64, bytes) catch default_value;
    }
    return default_value;
}

const CrashState = struct {
    is_down: bool = false,
    revive_tick: u64 = 0,
};

const SimConfig = struct {
    packet_loss: f64 = PACKET_LOSS,
    crash_prob: f64 = 0.002,
    ticks: u64 = SIM_TICKS,
    base_seed: u64 = 0xC0FFEE1234,
    quiet: bool = false,
};

const SimResult = struct {
    converged: bool,
    converge_tick: ?u64,
};

const NodeWrapper = struct {
    real_node: Node,
    mem: []u8,
    disk: []u8,
    fba: *std.heap.FixedBufferAllocator,
    outbox: std.ArrayList(OutboundPacket),
    sys_alloc: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    api: ApiServer,

    /// Allocate buffers and construct a node wrapper for simulation.
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

    /// Free heap allocations owned by the wrapper.
    pub fn deinit(self: *NodeWrapper, sys_alloc: std.mem.Allocator) void {
        self.outbox.deinit(sys_alloc);
        self.real_node.service_data.deinit();
        sys_alloc.destroy(self.fba);
        sys_alloc.free(self.mem);
        sys_alloc.free(self.disk);
    }

    /// Execute one protocol tick for this node and send outbound packets to the simulator.
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

fn runSimulation(cfg: SimConfig) !SimResult {
    const allocator = std.testing.allocator;
    if (!cfg.quiet) std.debug.print("\n[MycoSim] Initializing Final Protocol Simulation...\n", .{});

    const base_seed = cfg.base_seed;
    var seed_rng = std.Random.DefaultPrng.init(base_seed);
    const net_seed = seed_rng.random().int(u64);
    const chaos_seed = seed_rng.random().int(u64);
    const inject_seed = seed_rng.random().int(u64);
    const crash_prob = cfg.crash_prob;

    var clock = time.Clock{};

    var network = try net.NetworkSimulator.init(allocator, net_seed, cfg.packet_loss, &clock, LATENCY, JITTER);
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

    if (!cfg.quiet) {
        std.debug.print(
            "[MycoSim] Running {d} ticks with CONTINUOUS INJECTION... seed base=0x{x}, net=0x{x}, chaos=0x{x}, inject=0x{x}, crash_prob={d:.4}, loss={d:.2}\n",
            .{ cfg.ticks, base_seed, net_seed, chaos_seed, inject_seed, crash_prob, cfg.packet_loss },
        );
    }

    var chaos_rng = std.Random.DefaultPrng.init(chaos_seed);
    var inject_rng = std.Random.DefaultPrng.init(inject_seed);
    var partition_active = false;
    var partition_end_tick: u64 = 0;
    var next_partition_tick: u64 = 2000;
    var split_a = std.ArrayList(u16){};
    var split_b = std.ArrayList(u16){};
    defer {
        split_a.deinit(allocator);
        split_b.deinit(allocator);
    }
    var crash_states = [_]CrashState{.{}} ** NODE_COUNT;

    var first_full: ?u64 = null;

    for (0..cfg.ticks) |t| {
        clock.tick();

        if (t > 0 and t % 100 == 0 and services_injected < TOTAL_SERVICES) {
            const service_id = 1000 + services_injected;
            var target_node_idx: u16 = inject_rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
            for (0..3) |_| {
                if (!crash_states[target_node_idx].is_down) break;
                target_node_idx = inject_rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
            }

            var service = Service{ .id = service_id, .name = undefined, .flake_uri = undefined, .exec_name = undefined };
            service.setName("real-service");
            service.setFlake("github:myco/service");

            _ = try nodes[target_node_idx].real_node.injectService(service);

            services_injected += 1;
        }

        if (chaos_rng.random().float(f64) < crash_prob) {
            var candidate: u16 = chaos_rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
            var tries: usize = 0;
            while (crash_states[candidate].is_down and tries < 5) {
                candidate = chaos_rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
                tries += 1;
            }

            if (!crash_states[candidate].is_down) {
                const downtime = chaos_rng.random().intRangeAtMost(u64, 100, 400);
                crash_states[candidate].is_down = true;
                crash_states[candidate].revive_tick = clock.now() + downtime;
                if (!cfg.quiet) std.debug.print("[Chaos] Crashing node {d} for ~{d} ticks\n", .{ candidate, downtime });
            }
        }

        for (nodes) |*wrapper| {
            const state = &crash_states[wrapper.real_node.id];
            if (state.is_down) {
                if (clock.now() >= state.revive_tick) {
                    state.is_down = false;
                    if (!cfg.quiet) std.debug.print("[Chaos] Node {d} recovered at tick {d}\n", .{ wrapper.real_node.id, t });
                } else {
                    continue;
                }
            }
            try wrapper.tick(&network, &key_map);
        }

        if (!partition_active and t >= next_partition_tick) {
            split_a.clearRetainingCapacity();
            split_b.clearRetainingCapacity();

            const PickSet = std.StaticBitSet(NODE_COUNT);
            var picked = PickSet.initEmpty();

            const min_size: usize = 5;
            const max_size: usize = NODE_COUNT / 2;
            const desired = chaos_rng.random().intRangeAtMost(usize, min_size, max_size);

            while (split_a.items.len < desired) {
                const idx = chaos_rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
                if (!picked.isSet(idx)) {
                    picked.set(idx);
                    try split_a.append(allocator, idx);
                }
            }

            for (0..NODE_COUNT) |i| {
                if (!picked.isSet(@intCast(i))) try split_b.append(allocator, @intCast(i));
            }

            try network.disconnectGroups(split_a.items, split_b.items);
            partition_active = true;
            partition_end_tick = t + chaos_rng.random().intRangeAtMost(u64, 200, 800);
            next_partition_tick = partition_end_tick + chaos_rng.random().intRangeAtMost(u64, 1000, 3000);
            if (!cfg.quiet) {
                std.debug.print("[Partition] Split at tick {d} for ~{d} ticks (A {d} nodes, B {d} nodes)\n", .{
                    t,
                    partition_end_tick - t,
                    split_a.items.len,
                    split_b.items.len,
                });
            }
        } else if (partition_active and t >= partition_end_tick) {
            network.healAll();
            partition_active = false;
            if (!cfg.quiet) std.debug.print("[Partition] Healed at tick {d}\n", .{t});
        }

        if (!cfg.quiet and t % 500 == 0) {
            const resp = try nodes[0].api.handleRequest("GET /metrics");
            defer allocator.free(resp);

            var iter = std.mem.splitScalar(u8, resp, '\n');
            _ = iter.next();
            _ = iter.next();
            _ = iter.next();
            _ = iter.next();
            const known_line = iter.next() orelse "???";

            std.debug.print("[Tick {d: >4}] Total Injected: {d: >2} | {s}\n", .{ t, services_injected, known_line });

            const node_count_usize = @as(usize, NODE_COUNT);
            const total_services_usize = @as(usize, TOTAL_SERVICES);
            var nodes_with_any: usize = 0;
            var nodes_with_all: usize = 0;
            var total_known: usize = 0;
            var total_missing: usize = 0;
            var max_missing: usize = 0;

            for (nodes) |*wrapper| {
                const known = wrapper.real_node.store.versions.count();
                total_known += known;
                if (known > 0) nodes_with_any += 1;
                if (known == total_services_usize) nodes_with_all += 1;

                total_missing += wrapper.real_node.missing_count;
                if (wrapper.real_node.missing_count > max_missing) {
                    max_missing = wrapper.real_node.missing_count;
                }
            }

            const avg_known = total_known / node_count_usize;
            const avg_missing = total_missing / node_count_usize;

            std.debug.print(
                "           Stats: nodes_any {d}/{d}, nodes_all {d}/{d}, avg_known {d}, avg_missing {d}, max_missing {d}\n",
                .{ nodes_with_any, NODE_COUNT, nodes_with_all, NODE_COUNT, avg_known, avg_missing, max_missing },
            );
            std.debug.print(
                "           Net: enqueued {d}, delivered {d}, drop_loss {d}, drop_cong {d}, drop_part {d}, inflight {d}\n",
                .{
                    network.sent_enqueued,
                    network.delivered,
                    network.dropped_loss,
                    network.dropped_congestion,
                    network.dropped_partition,
                    network.in_flight_packets.items.len,
                },
            );
        }

        // Check convergence every tick to capture first convergence tick.
        var perfect_nodes: usize = 0;
        for (nodes) |*wrapper| {
            const count = wrapper.real_node.store.versions.count();
            if (count == TOTAL_SERVICES) perfect_nodes += 1;
        }
        if (perfect_nodes == NODE_COUNT and first_full == null) {
            first_full = t;
        }
    }
    if (!cfg.quiet) std.debug.print("\n", .{});

    var perfect_nodes: usize = 0;
    for (nodes) |*wrapper| {
        const count = wrapper.real_node.store.versions.count();
        if (count == TOTAL_SERVICES) perfect_nodes += 1;
    }

    if (!cfg.quiet) {
        std.debug.print("[MycoSim] Final Status: {d}/{d} Nodes have all {d} services.\n", .{ perfect_nodes, NODE_COUNT, TOTAL_SERVICES });
    }

    return SimResult{ .converged = perfect_nodes == NODE_COUNT, .converge_tick = first_full };
}

test "Phase 5: The Grand Simulation (Final Protocol)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED", 0xC0FFEE1234);
    const crash_prob = parseProbEnv("MYCO_SIM_CRASH_PROB", 0.002);
    const result = runSimulation(.{
        .base_seed = base_seed,
        .crash_prob = crash_prob,
        .packet_loss = PACKET_LOSS,
        .ticks = SIM_TICKS,
        .quiet = false,
    }) catch return error.ClusterDidNotConverge;

    if (!result.converged) return error.ClusterDidNotConverge;
    std.debug.print("[MycoSim] SUCCESS: Convergence at tick {any}\n", .{result.converge_tick});
}

test "Phase 5: Fuzz Harness (multi-run)" {
    const runs = blk: {
        if (std.posix.getenv("MYCO_FUZZ_RUNS")) |bytes| {
            break :blk std.fmt.parseInt(usize, bytes, 10) catch 3;
        }
        break :blk 3;
    };
    const fuzz_ticks = blk: {
        if (std.posix.getenv("MYCO_FUZZ_TICKS")) |bytes| {
            break :blk std.fmt.parseInt(u64, bytes, 10) catch 6000;
        }
        break :blk 6000;
    };
    const loss_min = blk: {
        if (std.posix.getenv("MYCO_FUZZ_LOSS_MIN")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.02;
        break :blk 0.02;
    };
    const loss_max = blk: {
        if (std.posix.getenv("MYCO_FUZZ_LOSS_MAX")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.1;
        break :blk 0.1;
    };
    const crash_min = blk: {
        if (std.posix.getenv("MYCO_FUZZ_CRASH_MIN")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.001;
        break :blk 0.001;
    };
    const crash_max = blk: {
        if (std.posix.getenv("MYCO_FUZZ_CRASH_MAX")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.003;
        break :blk 0.003;
    };
    const base_seed = parseSeedEnv("MYCO_FUZZ_SEED", 0xF00FFACE);

    std.debug.print(
        "[Fuzz] runs={d}, ticks={d}, loss[{d:.3}-{d:.3}], crash[{d:.4}-{d:.4}], seed=0x{x}\n",
        .{ runs, fuzz_ticks, loss_min, loss_max, crash_min, crash_max, base_seed },
    );

    var rng = std.Random.DefaultPrng.init(base_seed);
    var successes: usize = 0;
    var converge_ticks = std.ArrayList(u64){};
    defer converge_ticks.deinit(std.testing.allocator);

    for (0..runs) |i| {
        const loss = rng.random().float(f64) * (loss_max - loss_min) + loss_min;
        const crash = rng.random().float(f64) * (crash_max - crash_min) + crash_min;
        const seed = rng.random().int(u64);

        const res = runSimulation(.{
            .packet_loss = loss,
            .crash_prob = crash,
            .ticks = fuzz_ticks,
            .base_seed = seed,
            .quiet = true,
        }) catch SimResult{ .converged = false, .converge_tick = null };

        if (res.converged) {
            successes += 1;
            if (res.converge_tick) |ct| try converge_ticks.append(std.testing.allocator, ct);
        }
        std.debug.print("[Fuzz] run {d}/{d}: seed=0x{x}, loss={d:.3}, crash={d:.4}, converged={any}, converge_tick={any}\n", .{
            i + 1,
            runs,
            seed,
            loss,
            crash,
            res.converged,
            res.converge_tick,
        });
    }

    if (converge_ticks.items.len > 1) {
        std.sort.pdq(u64, converge_ticks.items, {}, std.sort.asc(u64));
    }
    const median_tick = if (converge_ticks.items.len == 0) null else converge_ticks.items[converge_ticks.items.len / 2];

    std.debug.print("[Fuzz] Successes {d}/{d}, median convergence tick {any}\n", .{ successes, runs, median_tick });
}
