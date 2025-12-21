// End-to-end simulations of cluster convergence under configurable network churn.
const std = @import("std");
const myco = @import("myco");

const Node = myco.Node;
const Packet = myco.Packet;
const node_impl = @import("myco").node; // access decodeDigest/Entry via myco.node
const Headers = struct {
    pub const Deploy: u8 = 1;
    pub const Sync: u8 = 2;
    pub const Request: u8 = 3;
    pub const Control: u8 = 4;
};
const Service = myco.schema.service.Service;
const net = myco.sim.net;
const OutboundPacket = myco.OutboundPacket;
const OutboxList = myco.node.OutboxList;
const ApiServer = myco.api.server.ApiServer;
const time = myco.sim.time;
const tui = myco.sim.tui;
const sim_events = myco.sim.events;
const Entry = myco.sync.crdt.Entry;
const PubKeyMap = std.StringHashMap(u16);

pub const Phase = struct {
    duration_ticks: u64,
    packet_loss: f64,
    crash_prob: f64,
    latency: u64,
    jitter: u64,
    enable_partitions: bool,
    max_bytes_in_flight: usize = 50_000 * @sizeOf(Packet),
    crypto_enabled: bool = true,
};

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

fn parseU64Env(name: []const u8, default_value: u64) u64 {
    if (std.posix.getenv(name)) |bytes| {
        return std.fmt.parseInt(u64, bytes, 10) catch default_value;
    }
    return default_value;
}

fn parseUsizeEnv(name: []const u8, default_value: usize) usize {
    if (std.posix.getenv(name)) |bytes| {
        return std.fmt.parseInt(usize, bytes, 10) catch default_value;
    }
    return default_value;
}

fn envOverrideBytesInFlight(default_value: usize) usize {
    if (std.posix.getenv("MYCO_MAX_BYTES_IN_FLIGHT")) |bytes| {
        return std.fmt.parseInt(usize, bytes, 10) catch default_value;
    }
    return default_value;
}

const CrashState = struct {
    is_down: bool = false,
    revive_tick: u64 = 0,
};

const SimConfig = struct {
    packet_loss: f64 = 0.0,
    crash_prob: f64 = 0.0,
    ticks: u64 = 600,
    base_seed: u64 = 0xC0FFEE1234,
    quiet: bool = true,
    latency: u64 = 1,
    jitter: u64 = 2,
    inject_interval: u64 = 5,
    inject_batch: u64 = 8,
    enable_partitions: bool = false,
    partition_min_size: usize = 3,
    partition_max_size: usize = 10,
    partition_duration_min: u64 = 50,
    partition_duration_max: u64 = 150,
    partition_cooldown_min: u64 = 500,
    partition_cooldown_max: u64 = 1000,
    surge_every: ?u64 = null,
    surge_multiplier: u64 = 2,
    phases: ?[]const Phase = null,
    restart_tick: ?u64 = null,
    restart_node: u16 = 0,
    slo_max_ticks: ?u64 = null,
    slo_max_enqueued: ?u64 = null,
    max_bytes_in_flight: usize = 50_000 * @sizeOf(Packet),
    crypto_enabled: bool = true,
    cpu_sleep_ns: u64 = 0,
    enable_tui: bool = false,
    tui_refresh_ticks: u64 = 10,
    tui_event_capacity: usize = 128,
};

const SimResult = struct {
    converged: bool,
    converge_tick: ?u64,
    sent_enqueued: u64,
    dropped_loss: u64,
    dropped_congestion: u64,
    dropped_partition: u64,
    delivered: u64,
    bytes_in_flight: usize,
};

fn runSimulationWithMetrics(comptime label: []const u8, comptime node_count: u16, cfg: SimConfig) !SimResult {
    const start_ms = std.time.milliTimestamp();
    const result = try runSimulation(node_count, cfg);
    const elapsed_raw = std.time.milliTimestamp() - start_ms;
    const elapsed_ms: u64 = if (elapsed_raw < 0) 0 else @intCast(elapsed_raw);
    std.debug.print(
        "[{s}] wall_ms={d} converge_tick={any} sent_enqueued={d} delivered={d} drop_loss={d} drop_cong={d} drop_part={d} bytes_in_flight={d}\n",
        .{
            label,
            elapsed_ms,
            result.converge_tick,
            result.sent_enqueued,
            result.delivered,
            result.dropped_loss,
            result.dropped_congestion,
            result.dropped_partition,
            result.bytes_in_flight,
        },
    );
    return result;
}

const NodeWrapper = struct {
    real_node: Node,
    mem: []u8,
    disk: []u8,
    fba: *std.heap.FixedBufferAllocator,
    outbox: OutboxList,
    inbox: std.ArrayList(Packet),
    sys_alloc: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    api: ApiServer,
    id: u16,
    packet_mac_failures: std.atomic.Value(u64),

    pub fn init(id: u16, sys_alloc: std.mem.Allocator) !NodeWrapper {
        const mem = try sys_alloc.alloc(u8, MEMORY_LIMIT_PER_NODE);
        const disk = try sys_alloc.alloc(u8, DISK_SIZE_PER_NODE);
        @memset(disk, 0);

        const fba = try sys_alloc.create(std.heap.FixedBufferAllocator);
        fba.* = std.heap.FixedBufferAllocator.init(mem);

        var wrapper = NodeWrapper{
            .mem = mem,
            .disk = disk,
            .fba = fba,
            .real_node = try Node.init(id, fba.allocator(), disk, fba, mockExecutor),
            .outbox = .{},
            .inbox = .{},
            .sys_alloc = sys_alloc,
            .rng = std.Random.DefaultPrng.init(@as(u64, id) + 0xDEADBEEF),
            .api = undefined,
            .id = id,
            .packet_mac_failures = std.atomic.Value(u64).init(0),
        };
        wrapper.api = ApiServer.init(sys_alloc, &wrapper.real_node, &wrapper.packet_mac_failures, null, null, false);
        return wrapper;
    }

    pub fn deinit(self: *NodeWrapper, sys_alloc: std.mem.Allocator) void {
        self.outbox.deinit(sys_alloc);
        self.inbox.deinit(sys_alloc);
        self.real_node.service_data.deinit();
        sys_alloc.destroy(self.fba);
        sys_alloc.free(self.mem);
        sys_alloc.free(self.disk);
    }

    pub fn restart(self: *NodeWrapper, sys_alloc: std.mem.Allocator) !void {
        // Snapshot current state so crashes don't wipe all knowledge in simulations.
        var snapshot = std.ArrayListUnmanaged(struct { id: u64, version: u64, service: Service }){};
        defer snapshot.deinit(sys_alloc);
        var it = self.real_node.storeIterator();
        while (it.next()) |kv| {
            if (self.real_node.service_data.get(kv.key_ptr.*)) |svc| {
                try snapshot.append(sys_alloc, .{ .id = kv.key_ptr.*, .version = kv.value_ptr.*, .service = svc });
            }
        }

        self.outbox.clearRetainingCapacity();
        sys_alloc.destroy(self.fba);
        const fba = try sys_alloc.create(std.heap.FixedBufferAllocator);
        fba.* = std.heap.FixedBufferAllocator.init(self.mem);
        self.fba = fba;
        self.real_node = try Node.init(self.id, fba.allocator(), self.disk, fba, mockExecutor);
        self.api = ApiServer.init(sys_alloc, &self.real_node, &self.packet_mac_failures, null, null, false);
        self.rng = std.Random.DefaultPrng.init(@as(u64, self.id) + 0xDEADBEEF);

        // Restore known services/versions so replicas catch up faster after crash.
        for (snapshot.items) |item| {
            _ = try self.real_node.store.update(item.id, item.version);
            try self.real_node.service_data.put(item.id, item.service);
        }
    }

    pub fn tick(self: *NodeWrapper, simulator: *net.NetworkSimulator, key_map: *PubKeyMap, cfg: *const SimConfig, comptime NODE_COUNT: u16) !void {
        if (cfg.cpu_sleep_ns > 0) {
            const spins: u64 = (cfg.cpu_sleep_ns / 1000) + 1;
            var i: u64 = 0;
            while (i < spins) : (i += 1) {
                std.mem.doNotOptimizeAway(i);
            }
        }
        self.inbox.clearRetainingCapacity();
        try simulator.drainReady(self.real_node.id, &self.inbox, self.sys_alloc);

        self.outbox.clearRetainingCapacity();
        try self.real_node.tick(self.inbox.items, &self.outbox, self.sys_alloc);

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

fn runSimulation(comptime NODE_COUNT: u16, cfg: SimConfig) !SimResult {
    const allocator = std.heap.page_allocator;
    if (!cfg.quiet) std.debug.print("\n[MycoSim] Initializing Protocol Simulation ({d} nodes)...\n", .{NODE_COUNT});

    const base_seed = cfg.base_seed;
    const tui_enabled = cfg.enable_tui or (std.posix.getenv("MYCO_SIM_TUI") != null);
    const tui_refresh = parseU64Env("MYCO_SIM_TUI_REFRESH", cfg.tui_refresh_ticks);
    const tui_event_cap = parseUsizeEnv("MYCO_SIM_TUI_EVENTS", cfg.tui_event_capacity);
    var seed_rng = std.Random.DefaultPrng.init(base_seed);
    const net_seed = seed_rng.random().int(u64);
    const chaos_seed = seed_rng.random().int(u64);
    const inject_seed = seed_rng.random().int(u64);
    const phases = cfg.phases;

    var clock = time.Clock{};
    var event_ring: sim_events.EventRing = undefined;
    var event_ring_ptr: ?*sim_events.EventRing = null;
    if (tui_enabled) {
        event_ring = try sim_events.EventRing.init(allocator, tui_event_cap);
        event_ring_ptr = &event_ring;
    }
    defer {
        if (tui_enabled) {
            event_ring.deinit(allocator);
        }
    }

    var network = try net.NetworkSimulator.init(allocator, net_seed, cfg.packet_loss, &clock, cfg.latency, cfg.jitter, cfg.max_bytes_in_flight, cfg.crypto_enabled, event_ring_ptr);
    defer network.deinit();

    var nodes = try allocator.alloc(NodeWrapper, NODE_COUNT);
    defer allocator.free(nodes);

    const node_count_usize = @as(usize, NODE_COUNT);

    var node_snapshots: []tui.NodeSnapshot = &[_]tui.NodeSnapshot{};
    var event_view: []sim_events.PacketEvent = &[_]sim_events.PacketEvent{};
    if (tui_enabled) {
        node_snapshots = try allocator.alloc(tui.NodeSnapshot, node_count_usize);
        event_view = try allocator.alloc(sim_events.PacketEvent, tui_event_cap);
    }
    defer {
        if (tui_enabled) {
            allocator.free(node_snapshots);
            allocator.free(event_view);
        }
    }

    var crash_states = try allocator.alloc(CrashState, NODE_COUNT);
    defer allocator.free(crash_states);
    @memset(crash_states, CrashState{});

    var key_map = PubKeyMap.init(allocator);
    defer key_map.deinit();

    var stdout_buf: [4096]u8 = undefined;
    const stdout_writer: ?std.fs.File.Writer = if (tui_enabled) std.fs.File.stdout().writerStreaming(stdout_buf[0..]) else null;

    for (nodes, 0..) |*wrapper, i| {
        wrapper.* = try NodeWrapper.init(@intCast(i), allocator);
        try network.register(@intCast(i));
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
            "[MycoSim] Running {d} ticks seed base=0x{x}, net=0x{x}, chaos=0x{x}, inject=0x{x}, crash_prob={d:.4}, loss={d:.3}\n",
            .{ cfg.ticks, base_seed, net_seed, chaos_seed, inject_seed, cfg.crash_prob, cfg.packet_loss },
        );
        std.debug.print("[MycoSim] Bandwidth cap bytes_in_flight={d}\n", .{network.max_bytes_in_flight});
    }

    var chaos_rng = std.Random.DefaultPrng.init(chaos_seed);
    var inject_rng = std.Random.DefaultPrng.init(inject_seed);
    var current_loss = cfg.packet_loss;
    var current_crash = cfg.crash_prob;
    var current_latency = cfg.latency;
    var current_jitter = cfg.jitter;
    var current_partitions = cfg.enable_partitions;
    var phase_idx: usize = 0;
    var phase_tick_remaining: u64 = if (phases) |p| p[0].duration_ticks else cfg.ticks;

    var partition_active = false;
    var partition_end_tick: u64 = 0;
    var next_partition_tick: u64 = if (current_partitions) cfg.partition_cooldown_min else cfg.ticks + 1;

    var split_a = std.ArrayList(u16){};
    var split_b = std.ArrayList(u16){};
    defer {
        split_a.deinit(allocator);
        split_b.deinit(allocator);
    }

    const max_partition_size = @max(@as(usize, 1), @min(cfg.partition_max_size, node_count_usize / 2));
    const min_partition_size = @min(cfg.partition_min_size, max_partition_size);

    var first_full: ?u64 = null;

    for (0..cfg.ticks) |t| {
        clock.tick();

        // Phase progression
        if (phase_tick_remaining == 0 and phases != null) {
            phase_idx += 1;
            if (phase_idx < phases.?.len) {
                const ph = phases.?[phase_idx];
                phase_tick_remaining = ph.duration_ticks;
                current_loss = ph.packet_loss;
                current_crash = ph.crash_prob;
                current_latency = ph.latency;
                current_jitter = ph.jitter;
                current_partitions = ph.enable_partitions;
                // Update network latency/jitter in-place.
                network.packet_loss_rate = current_loss;
                network.base_latency_ticks = current_latency;
                network.jitter_ticks = current_jitter;
                next_partition_tick = if (current_partitions) t + cfg.partition_cooldown_min else cfg.ticks + 1;
            }
        }
        if (phase_tick_remaining > 0 and phases != null) phase_tick_remaining -= 1;

        if (t > 0 and t % cfg.inject_interval == 0 and services_injected < TOTAL_SERVICES) {
            const remaining = TOTAL_SERVICES - services_injected;
            var batch: u64 = @min(cfg.inject_batch, remaining);
            if (cfg.surge_every) |se| {
                if (t % se == 0) batch = @min(batch * cfg.surge_multiplier, remaining);
            }
            var injected: u64 = 0;

            while (injected < batch) : (injected += 1) {
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
        }

        if (current_crash > 0 and chaos_rng.random().float(f64) < current_crash) {
            var candidate: u16 = chaos_rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
            var tries: usize = 0;
            while (crash_states[candidate].is_down and tries < 5) {
                candidate = chaos_rng.random().intRangeAtMost(u16, 0, NODE_COUNT - 1);
                tries += 1;
            }

            if (!crash_states[candidate].is_down) {
                const downtime = chaos_rng.random().intRangeAtMost(u64, 80, 200);
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
            try wrapper.tick(&network, &key_map, &cfg, NODE_COUNT);
        }

        if (current_partitions and !partition_active and t >= next_partition_tick) {
            split_a.clearRetainingCapacity();
            split_b.clearRetainingCapacity();

            const PickSet = std.StaticBitSet(NODE_COUNT);
            var picked = PickSet.initEmpty();

            const desired = chaos_rng.random().intRangeAtMost(usize, min_partition_size, max_partition_size);

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
            partition_end_tick = t + chaos_rng.random().intRangeAtMost(u64, cfg.partition_duration_min, cfg.partition_duration_max);
            next_partition_tick = partition_end_tick + chaos_rng.random().intRangeAtMost(u64, cfg.partition_cooldown_min, cfg.partition_cooldown_max);
            if (!cfg.quiet) {
                std.debug.print("[Partition] Split at tick {d} for ~{d} ticks (A {d} nodes, B {d} nodes)\n", .{
                    t,
                    partition_end_tick - t,
                    split_a.items.len,
                    split_b.items.len,
                });
            }
        } else if (current_partitions and partition_active and t >= partition_end_tick) {
            network.healAll();
            partition_active = false;
            if (!cfg.quiet) std.debug.print("[Partition] Healed at tick {d}\n", .{t});
        }

        if (cfg.restart_tick) |rt| {
            if (t == rt and cfg.restart_node < NODE_COUNT) {
                try nodes[cfg.restart_node].restart(allocator);
                if (!cfg.quiet) std.debug.print("[Durability] Restarted node {d} at tick {d}\n", .{ cfg.restart_node, t });
            }
        }

        var perfect_nodes: usize = 0;
        for (nodes) |*wrapper| {
            const count = wrapper.real_node.storeCount();
            if (count == TOTAL_SERVICES) perfect_nodes += 1;
        }

        const converged_now = perfect_nodes == NODE_COUNT;
        if (tui_enabled and (t % tui_refresh == 0 or converged_now or t + 1 == cfg.ticks)) {
            for (nodes) |*wrapper| {
                const id = wrapper.real_node.id;
                const idx = @as(usize, id);
                node_snapshots[idx] = .{
                    .id = id,
                    .is_down = crash_states[id].is_down,
                    .services = wrapper.real_node.storeCount(),
                    .missing = wrapper.real_node.missing_count,
                    .last_deployed = wrapper.real_node.last_deployed_id,
                    .mac_failures = wrapper.packet_mac_failures.load(.seq_cst),
                };
            }

            const events_len = event_ring.copyRecent(event_view);
            const stats = tui.NetStats{
                .sent = network.sent_enqueued,
                .delivered = network.delivered,
                .drop_loss = network.dropped_loss,
                .drop_congestion = network.dropped_congestion,
                .drop_partition = network.dropped_partition,
                .drop_crypto = network.dropped_crypto,
                .bytes_in_flight = network.bytes_in_flight,
            };
            const w = stdout_writer.?;
            var iface = w.interface;
            tui.render(&iface, clock.now(), converged_now, stats, node_snapshots[0..node_snapshots.len], event_view[0..events_len]) catch {};
            iface.flush() catch {};
        }

        if (converged_now) {
            if (first_full == null) first_full = t;
            break;
        }
    }

    var perfect_nodes: usize = 0;
    for (nodes) |*wrapper| {
        const count = wrapper.real_node.storeCount();
        if (count == TOTAL_SERVICES) perfect_nodes += 1;
    }

    if (!cfg.quiet) {
        std.debug.print(
            "[MycoSim] Converged={any}, converge_tick={any}, perfect_nodes={d}/{d}\n",
            .{ perfect_nodes == NODE_COUNT, first_full, perfect_nodes, NODE_COUNT },
        );
    }

    const convergence_tick: u64 = first_full orelse cfg.ticks;
    if (cfg.slo_max_ticks) |limit| {
        if (first_full == null or convergence_tick > limit) return error.SloConvergenceExceeded;
    }
    if (cfg.slo_max_enqueued) |limit| {
        if (network.sent_enqueued > limit) return error.SloPacketsExceeded;
    }

    return SimResult{
        .converged = perfect_nodes == NODE_COUNT,
        .converge_tick = first_full,
        .sent_enqueued = network.sent_enqueued,
        .dropped_loss = network.dropped_loss,
        .dropped_congestion = network.dropped_congestion,
        .dropped_partition = network.dropped_partition,
        .delivered = network.delivered,
        .bytes_in_flight = network.bytes_in_flight,
    };
}

fn config50() SimConfig {
    return .{
        .packet_loss = 0.03,
        .crash_prob = 0.0025,
        .ticks = 900,
        .latency = 6,
        .jitter = 12,
        .inject_interval = 5,
        .inject_batch = 6,
        .enable_partitions = true,
        .partition_min_size = 3,
        .partition_max_size = 18,
        .partition_duration_min = 60,
        .partition_duration_max = 150,
        .partition_cooldown_min = 400,
        .partition_cooldown_max = 800,
        .quiet = std.posix.getenv("MYCO_SIM_VERBOSE_50") == null,
        .max_bytes_in_flight = envOverrideBytesInFlight(50_000 * @sizeOf(Packet)),
    };
}

fn config50Heavy() SimConfig {
    return .{
        .packet_loss = 0.08,
        .crash_prob = 0.01,
        .ticks = 1500,
        .latency = 8,
        .jitter = 16,
        .inject_interval = 5,
        .inject_batch = 6,
        .enable_partitions = true,
        .partition_min_size = 5,
        .partition_max_size = 20,
        .partition_duration_min = 120,
        .partition_duration_max = 260,
        .partition_cooldown_min = 500,
        .partition_cooldown_max = 900,
        .quiet = std.posix.getenv("MYCO_SIM_VERBOSE_50_HEAVY") == null,
        .max_bytes_in_flight = envOverrideBytesInFlight(50_000 * @sizeOf(Packet)),
    };
}

fn config50Extreme() SimConfig {
    return .{
        .packet_loss = 0.30,
        .crash_prob = 0.05,
        .ticks = 5000,
        .latency = 10,
        .jitter = 20,
        .inject_interval = 5,
        .inject_batch = 6,
        .enable_partitions = true,
        .partition_min_size = 5,
        .partition_max_size = 25,
        .partition_duration_min = 120,
        .partition_duration_max = 240,
        .partition_cooldown_min = 400,
        .partition_cooldown_max = 800,
        .quiet = std.posix.getenv("MYCO_SIM_VERBOSE_50_EXTREME") == null,
        .max_bytes_in_flight = envOverrideBytesInFlight(10_000 * @sizeOf(Packet)),
    };
}
fn config100() SimConfig {
    return .{
        .packet_loss = 0.03,
        .crash_prob = 0.003,
        .ticks = 1100,
        .latency = 6,
        .jitter = 12,
        .inject_interval = 5,
        .inject_batch = 8,
        .enable_partitions = true,
        .partition_min_size = 4,
        .partition_max_size = 32,
        .partition_duration_min = 80,
        .partition_duration_max = 180,
        .partition_cooldown_min = 500,
        .partition_cooldown_max = 900,
        .quiet = true,
        .max_bytes_in_flight = envOverrideBytesInFlight(50_000 * @sizeOf(Packet)),
    };
}

fn config256() SimConfig {
    return .{
        .packet_loss = 0.0,
        .crash_prob = 0.0,
        .ticks = 2000,
        .latency = 1,
        .jitter = 2,
        .inject_interval = 5,
        .inject_batch = 12,
        .enable_partitions = false,
        .quiet = true,
        .max_bytes_in_flight = envOverrideBytesInFlight(50_000 * @sizeOf(Packet)),
        .crypto_enabled = true,
    };
}

fn config50Realworld() SimConfig {
    return .{
        .packet_loss = 0.02,
        .crash_prob = 0.005,
        .ticks = 4500,
        .latency = 30,
        .jitter = 20,
        .inject_interval = 10,
        .inject_batch = 6,
        .enable_partitions = true,
        .partition_min_size = 5,
        .partition_max_size = 20,
        .partition_duration_min = 150,
        .partition_duration_max = 350,
        .partition_cooldown_min = 600,
        .partition_cooldown_max = 1200,
        .quiet = true,
        .max_bytes_in_flight = envOverrideBytesInFlight(10_000 * @sizeOf(Packet)),
        .restart_tick = 1500,
        .restart_node = 7,
        .slo_max_ticks = null, // allow full duration to converge under churn
        .slo_max_enqueued = 200_000,
        .surge_every = 200,
        .surge_multiplier = 3,
        .crypto_enabled = true,
    };
}

fn config50Edge() SimConfig {
    return .{
        .packet_loss = 0.05,
        .crash_prob = 0.02,
        .ticks = 5000,
        .latency = 60,
        .jitter = 40,
        .inject_interval = 12,
        .inject_batch = 4,
        .enable_partitions = true,
        .partition_min_size = 8,
        .partition_max_size = 22,
        .partition_duration_min = 200,
        .partition_duration_max = 450,
        .partition_cooldown_min = 800,
        .partition_cooldown_max = 1600,
        .quiet = true,
        .max_bytes_in_flight = envOverrideBytesInFlight(3_000 * @sizeOf(Packet)),
        .restart_tick = 2000,
        .restart_node = 11,
        .slo_max_ticks = 3500,
        .slo_max_enqueued = 250_000,
        .surge_every = 250,
        .surge_multiplier = 2,
        .phases = &[_]Phase{
            .{ .duration_ticks = 1500, .packet_loss = 0.05, .crash_prob = 0.02, .latency = 60, .jitter = 40, .enable_partitions = true },
            .{ .duration_ticks = 1200, .packet_loss = 0.1, .crash_prob = 0.03, .latency = 80, .jitter = 50, .enable_partitions = true },
            .{ .duration_ticks = 2300, .packet_loss = 0.02, .crash_prob = 0.01, .latency = 40, .jitter = 20, .enable_partitions = true },
        },
        .crypto_enabled = true,
    };
}

fn config1096() SimConfig {
    return .{
        .packet_loss = 0.0,
        .crash_prob = 0.0,
        .ticks = 900,
        .latency = 1,
        .jitter = 2,
        .inject_interval = 5,
        .inject_batch = 64,
        .enable_partitions = false,
        .quiet = true,
    };
}

fn config10Durability() SimConfig {
    return .{
        .packet_loss = 0.02,
        .crash_prob = 0.0,
        .ticks = 800,
        .latency = 2,
        .jitter = 4,
        .inject_interval = 5,
        .inject_batch = 4,
        .enable_partitions = false,
        .quiet = true,
        .restart_tick = 200,
        .restart_node = 3,
        .phases = &[_]Phase{
            .{ .duration_ticks = 300, .packet_loss = 0.02, .crash_prob = 0.0, .latency = 2, .jitter = 4, .enable_partitions = false },
            .{ .duration_ticks = 200, .packet_loss = 0.08, .crash_prob = 0.0, .latency = 4, .jitter = 8, .enable_partitions = true },
            .{ .duration_ticks = 300, .packet_loss = 0.01, .crash_prob = 0.0, .latency = 1, .jitter = 2, .enable_partitions = false },
        },
        .surge_every = 50,
        .surge_multiplier = 3,
    };
}

fn configTuiDemo() SimConfig {
    return .{
        .packet_loss = 0.02,
        .crash_prob = 0.0,
        .ticks = 1800,
        .latency = 12,
        .jitter = 8,
        .inject_interval = 30,
        .inject_batch = 1,
        .enable_partitions = false,
        .quiet = false,
        .max_bytes_in_flight = envOverrideBytesInFlight(10_000 * @sizeOf(Packet)),
        .crypto_enabled = true,
        .cpu_sleep_ns = 15_000_000, // ~15ms per tick to stretch wall clock (~27s for 1800 ticks)
        .enable_tui = true,
        .tui_refresh_ticks = 10,
        .tui_event_capacity = 512,
    };
}

test "Simulation: 50 nodes (loss/crash/partitions)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_50", 0x50C0FFEE);
    const cfg = config50();
    const result = runSimulationWithMetrics("Sim50", 50, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .partition_min_size = cfg.partition_min_size,
        .partition_max_size = cfg.partition_max_size,
        .partition_duration_min = cfg.partition_duration_min,
        .partition_duration_max = cfg.partition_duration_max,
        .partition_cooldown_min = cfg.partition_cooldown_min,
        .partition_cooldown_max = cfg.partition_cooldown_max,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
}

test "Simulation: 100 nodes (loss/crash/partitions)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_100", 0x64C0FFEE);
    const cfg = config100();
    const result = runSimulationWithMetrics("Sim100", 100, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .partition_min_size = cfg.partition_min_size,
        .partition_max_size = cfg.partition_max_size,
        .partition_duration_min = cfg.partition_duration_min,
        .partition_duration_max = cfg.partition_duration_max,
        .partition_cooldown_min = cfg.partition_cooldown_min,
        .partition_cooldown_max = cfg.partition_cooldown_max,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
}

test "Simulation: 50 nodes (heavy loss/crash/partitions)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_50_HEAVY", 0x50DEADBE);
    const cfg = config50Heavy();
    const result = runSimulationWithMetrics("Sim50-heavy", 50, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .partition_min_size = cfg.partition_min_size,
        .partition_max_size = cfg.partition_max_size,
        .partition_duration_min = cfg.partition_duration_min,
        .partition_duration_max = cfg.partition_duration_max,
        .partition_cooldown_min = cfg.partition_cooldown_min,
        .partition_cooldown_max = cfg.partition_cooldown_max,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
}

test "Simulation: 50 nodes (extreme loss/crash/partitions)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_50_EXTREME", 0x50E17C0E);
    const cfg = config50Extreme();
    const result = runSimulationWithMetrics("Sim50-extreme", 50, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .partition_min_size = cfg.partition_min_size,
        .partition_max_size = cfg.partition_max_size,
        .partition_duration_min = cfg.partition_duration_min,
        .partition_duration_max = cfg.partition_duration_max,
        .partition_cooldown_min = cfg.partition_cooldown_min,
        .partition_cooldown_max = cfg.partition_cooldown_max,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
}

test "Simulation: 50 nodes (realworld profile)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_50_REAL", 0x50A11E);
    const cfg = config50Realworld();
    const result = runSimulationWithMetrics("Sim50-realworld", 50, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .partition_min_size = cfg.partition_min_size,
        .partition_max_size = cfg.partition_max_size,
        .partition_duration_min = cfg.partition_duration_min,
        .partition_duration_max = cfg.partition_duration_max,
        .partition_cooldown_min = cfg.partition_cooldown_min,
        .partition_cooldown_max = cfg.partition_cooldown_max,
        .surge_every = cfg.surge_every,
        .surge_multiplier = cfg.surge_multiplier,
        .max_bytes_in_flight = cfg.max_bytes_in_flight,
        .restart_tick = cfg.restart_tick,
        .restart_node = cfg.restart_node,
        .slo_max_ticks = cfg.slo_max_ticks,
        .slo_max_enqueued = cfg.slo_max_enqueued,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
    std.debug.print(
        "[Realworld Metrics] converge_tick={any} sent_enqueued={d} delivered={d} drop_loss={d} drop_cong={d} drop_part={d} bytes_in_flight={d}\n",
        .{
            result.converge_tick,
            result.sent_enqueued,
            result.delivered,
            result.dropped_loss,
            result.dropped_congestion,
            result.dropped_partition,
            result.bytes_in_flight,
        },
    );
}

test "Simulation: 50 nodes (edge profile)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_50_EDGE", 0x50ED9E);
    const cfg = config50Edge();
    const result = runSimulationWithMetrics("Sim50-edge", 50, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .partition_min_size = cfg.partition_min_size,
        .partition_max_size = cfg.partition_max_size,
        .partition_duration_min = cfg.partition_duration_min,
        .partition_duration_max = cfg.partition_duration_max,
        .partition_cooldown_min = cfg.partition_cooldown_min,
        .partition_cooldown_max = cfg.partition_cooldown_max,
        .surge_every = cfg.surge_every,
        .surge_multiplier = cfg.surge_multiplier,
        .max_bytes_in_flight = cfg.max_bytes_in_flight,
        .restart_tick = cfg.restart_tick,
        .restart_node = cfg.restart_node,
        .slo_max_ticks = cfg.slo_max_ticks,
        .slo_max_enqueued = cfg.slo_max_enqueued,
        .phases = cfg.phases,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
    std.debug.print(
        "[Edge Metrics] converge_tick={any} sent_enqueued={d} delivered={d} drop_loss={d} drop_cong={d} drop_part={d} bytes_in_flight={d}\n",
        .{
            result.converge_tick,
            result.sent_enqueued,
            result.delivered,
            result.dropped_loss,
            result.dropped_congestion,
            result.dropped_partition,
            result.bytes_in_flight,
        },
    );
}

test "Simulation: 5 nodes (transparent trace)" {
    const allocator = std.testing.allocator;
    const node_count: u16 = 5;

    var nodes = try allocator.alloc(NodeWrapper, node_count);
    defer allocator.free(nodes);

    var key_map = PubKeyMap.init(allocator);
    defer key_map.deinit();

    for (nodes, 0..) |*wrapper, i| {
        wrapper.* = try NodeWrapper.init(@intCast(i), allocator);
        wrapper.api = ApiServer.init(allocator, &wrapper.real_node, &wrapper.packet_mac_failures, null, null, false);
        const pk_bytes = wrapper.real_node.identity.key_pair.public_key.toBytes();
        try key_map.put(try allocator.dupe(u8, &pk_bytes), @intCast(i));
    }
    defer {
        var it = key_map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        for (nodes) |*wrapper| wrapper.deinit(allocator);
    }

    var inboxes = try allocator.alloc(std.ArrayList(Packet), node_count);
    defer {
        for (inboxes) |*q| q.deinit(allocator);
        allocator.free(inboxes);
    }
    for (inboxes) |*q| q.* = .{};

    // Inject two services into node 0 to watch them propagate.
    {
        var svc = Service{ .id = 1, .name = undefined, .flake_uri = undefined, .exec_name = undefined };
        svc.setName("svc-1");
        svc.setFlake("github:svc/one");
        _ = try nodes[0].real_node.injectService(svc);

        var svc2 = Service{ .id = 2, .name = undefined, .flake_uri = undefined, .exec_name = undefined };
        svc2.setName("svc-2");
        svc2.setFlake("github:svc/two");
        _ = try nodes[0].real_node.injectService(svc2);
    }

    const max_ticks: usize = 40;
    std.debug.print("=== Transparent 5-node trace ===\n", .{});

    var all_converged = false;
    for (0..max_ticks) |t| {
        std.debug.print("\n--- TICK {d} ---\n", .{t});

        // Clear all outboxes.
        for (nodes) |*wrapper| wrapper.outbox.clearRetainingCapacity();

        // Tick each node with its current inbox.
        for (nodes, 0..) |*wrapper, i| {
            const items = inboxes[i].items;
            try wrapper.real_node.tick(items, &wrapper.outbox, allocator);
            inboxes[i].clearRetainingCapacity();
        }

        // Deliver and log all packets produced this tick.
        for (nodes, 0..) |*wrapper, src_id| {
            for (wrapper.outbox.items) |out| {
                const dest_id_opt: ?u16 = if (out.recipient) |pk| key_map.get(&pk) else null;

                logPacket(@intCast(src_id), dest_id_opt, out.packet);

                // Delivery: targeted or broadcast.
                if (dest_id_opt) |dest_id| {
                    try inboxes[dest_id].append(allocator, out.packet);
                } else {
                    for (0..node_count) |i| {
                        if (i == src_id) continue;
                        try inboxes[i].append(allocator, out.packet);
                    }
                }
            }
        }

        // Check convergence.
        var perfect: usize = 0;
        for (nodes) |*wrapper| {
            if (wrapper.real_node.storeCount() == 2) perfect += 1;
        }
        if (perfect == node_count) {
            std.debug.print("Converged at tick {d}\n", .{t});
            all_converged = true;
            break;
        }
    }

    if (!all_converged) return error.ClusterDidNotConverge;
}

fn logPacket(src_id: u16, dest_id: ?u16, p: Packet) void {
    if (dest_id) |d| {
        std.debug.print("src={d} -> {d} type={d} len={d}\n", .{ src_id, d, p.msg_type, p.payload_len });
    } else {
        std.debug.print("src={d} -> broadcast type={d} len={d}\n", .{ src_id, p.msg_type, p.payload_len });
    }

    switch (p.msg_type) {
        Headers.Sync, Headers.Control => {
            var decoded: [64]Entry = undefined;
            const len: usize = @min(@as(usize, p.payload_len), p.payload.len);
            const used = node_impl.decodeDigest(p.payload[0..len], decoded[0..]);
            std.debug.print("  digest entries ({d}): ", .{used});
            for (decoded[0..used]) |e| {
                std.debug.print("{d}:{d} ", .{ e.id, e.version });
            }
            std.debug.print("\n", .{});
        },
        Headers.Request => {
            const req_id = p.getPayload();
            std.debug.print("  request id={d}\n", .{req_id});
        },
        Headers.Deploy => {
            if (p.payload_len >= 8 + @sizeOf(Service)) {
                const version = std.mem.readInt(u64, p.payload[0..8], .little);
                const s_bytes = p.payload[8 .. 8 + @sizeOf(Service)];
                const svc: *const Service = @ptrCast(@alignCast(s_bytes));
                std.debug.print(
                    "  deploy id={d} version={d} name=\"{s}\" flake=\"{s}\" exec=\"{s}\"\n",
                    .{
                        svc.id,
                        version,
                        svc.getName(),
                        svc.getFlake(),
                        std.mem.sliceTo(&svc.exec_name, 0),
                    },
                );
            } else {
                std.debug.print("  deploy payload too small\n", .{});
            }
        },
        else => {},
    }
}

test "Simulation: 20 nodes (pi-ish wifi profile)" {
    const node_count: u16 = 20;
    const cfg = SimConfig{
        .ticks = 1200,
        .packet_loss = 0.02,
        .latency = 20,
        .jitter = 10,
        .max_bytes_in_flight = 5_000 * @sizeOf(Packet),
        .crypto_enabled = true,
        .cpu_sleep_ns = 1_000_000, // 1ms per tick to mimic slower CPU
        .quiet = true,
    };

    const result = try runSimulationWithMetrics("Sim20-pi-wifi", node_count, cfg);
    try std.testing.expect(result.converged);
}

test "Simulation: 256 nodes (baseline converge)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_256", 0x100C0FFEE);
    const cfg = config256();
    const result = runSimulationWithMetrics("Sim256", 256, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .crypto_enabled = cfg.crypto_enabled,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
}

test "Simulation: 1096 nodes (opt-in heavy)" {
    if (std.posix.getenv("MYCO_RUN_1096") == null) {
        return error.SkipZigTest;
    }
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_1096", 0x112233445566);
    const cfg = config1096();
    const result = runSimulationWithMetrics("Sim1096", 1096, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
}

test "Simulation: 8 nodes (tui demo, opt-in)" {
    if (std.posix.getenv("MYCO_SIM_TUI_DEMO") == null) {
        return error.SkipZigTest;
    }
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_TUI", 0x71C0FFEE);
    const cfg = configTuiDemo();
    _ = try runSimulationWithMetrics("Sim8-tui-demo", 8, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .max_bytes_in_flight = cfg.max_bytes_in_flight,
        .crypto_enabled = cfg.crypto_enabled,
        .cpu_sleep_ns = cfg.cpu_sleep_ns,
        .enable_tui = cfg.enable_tui,
        .tui_refresh_ticks = cfg.tui_refresh_ticks,
        .tui_event_capacity = cfg.tui_event_capacity,
    });
}

test "Simulation: 10 nodes (durability restart + phases/surge)" {
    const base_seed = parseSeedEnv("MYCO_SIM_SEED_10_DUR", 0x10D00);
    const cfg = config10Durability();
    const result = runSimulationWithMetrics("Sim10-durability", 10, .{
        .base_seed = base_seed,
        .quiet = cfg.quiet,
        .packet_loss = cfg.packet_loss,
        .crash_prob = cfg.crash_prob,
        .ticks = cfg.ticks,
        .latency = cfg.latency,
        .jitter = cfg.jitter,
        .inject_interval = cfg.inject_interval,
        .inject_batch = cfg.inject_batch,
        .enable_partitions = cfg.enable_partitions,
        .partition_min_size = cfg.partition_min_size,
        .partition_max_size = cfg.partition_max_size,
        .partition_duration_min = cfg.partition_duration_min,
        .partition_duration_max = cfg.partition_duration_max,
        .partition_cooldown_min = cfg.partition_cooldown_min,
        .partition_cooldown_max = cfg.partition_cooldown_max,
        .surge_every = cfg.surge_every,
        .surge_multiplier = cfg.surge_multiplier,
        .phases = cfg.phases,
        .restart_tick = cfg.restart_tick,
        .restart_node = cfg.restart_node,
    }) catch return error.ClusterDidNotConverge;
    if (!result.converged) return error.ClusterDidNotConverge;
}

test "Phase 5: Fuzz Harness (multi-run, 50-node baseline)" {
    const runs = blk: {
        if (std.posix.getenv("MYCO_FUZZ_RUNS")) |bytes| {
            break :blk std.fmt.parseInt(usize, bytes, 10) catch 1;
        }
        break :blk 1;
    };
    const fuzz_ticks = blk: {
        if (std.posix.getenv("MYCO_FUZZ_TICKS")) |bytes| {
            break :blk std.fmt.parseInt(u64, bytes, 10) catch 1500;
        }
        break :blk 1500;
    };
    const loss_min = blk: {
        if (std.posix.getenv("MYCO_FUZZ_LOSS_MIN")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.0;
        break :blk 0.0;
    };
    const loss_max = blk: {
        if (std.posix.getenv("MYCO_FUZZ_LOSS_MAX")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.02;
        break :blk 0.02;
    };
    const crash_min = blk: {
        if (std.posix.getenv("MYCO_FUZZ_CRASH_MIN")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.0;
        break :blk 0.0;
    };
    const crash_max = blk: {
        if (std.posix.getenv("MYCO_FUZZ_CRASH_MAX")) |bytes| break :blk std.fmt.parseFloat(f64, bytes) catch 0.0;
        break :blk 0.0;
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

        const res = runSimulation(50, .{
            .packet_loss = loss,
            .crash_prob = crash,
            .ticks = fuzz_ticks,
            .base_seed = seed,
            .quiet = true,
            .latency = 4,
            .jitter = 8,
            .inject_interval = 5,
            .inject_batch = 6,
            .enable_partitions = false,
        }) catch SimResult{
            .converged = false,
            .converge_tick = null,
            .sent_enqueued = 0,
            .dropped_loss = 0,
            .dropped_congestion = 0,
            .dropped_partition = 0,
            .delivered = 0,
            .bytes_in_flight = 0,
        };

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
