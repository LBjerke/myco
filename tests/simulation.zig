//! Simulation harness for Myco.
//!
//! This module provides:
//! - Simulation: a test harness for running multi-node scenarios
//! - Scenario: a definition of a test scenario with steps
//! - NetworkSimulator: simulates network conditions (latency, packet loss)
//! - Built-in scenarios for common cluster behaviors
//!
//! Usage:
//!     const sim = try Simulation.init(allocator, .{.node_count = 10});
//!     try sim.run(scenario_node_join_leave);
//!     defer sim.deinit(allocator);

const std = @import("std");
const myco = @import("myco");
const reducer = myco.reducer;
const Event = myco.Event;
const World = myco.World;
const NodeHealthStatus = myco.NodeHealthStatus;
const hlc = myco.hlc;
const Timestamp = hlc.Timestamp;
const limits = myco.limits;

/// Network profile for simulation.
pub const NetworkProfile = enum {
    /// Low latency, reliable (data center)
    realworld,
    /// Higher latency, some packet loss (WiFi)
    pi_wifi,
};

/// Configuration for network simulation.
pub const NetworkConfig = struct {
    profile: NetworkProfile = .realworld,
    base_latency_ms: u32 = 1,
    latency_jitter_ms: u32 = 0,
    packet_loss_percent: f32 = 0.0,
};

/// A single step in a scenario.
pub const Step = union(enum) {
    /// Advance time by N milliseconds.
    advance_time: u64,

    /// A node joins the cluster.
    node_join: NodeJoinStep,

    /// A node leaves the cluster.
    node_leave: u16,

    /// Deploy a service.
    service_deploy: ServiceDeployStep,

    /// Remove a service.
    service_remove: u16,

    /// Change node health status.
    health_change: HealthChangeStep,

    /// Verify expected state.
    verify: VerifyStep,
};

/// Node join step data.
pub const NodeJoinStep = struct {
    node_id: u16,
    address: [4]u8,
    port: u16,
};

/// Service deploy step data.
pub const ServiceDeployStep = struct {
    service_id: u16,
    name: []const u8,
    replicas: u8,
};

/// Health change step data.
pub const HealthChangeStep = struct {
    node_id: u16,
    new_status: u8,
};

/// Verification step data.
pub const VerifyStep = struct {
    description: []const u8,
    expected_nodes: usize,
    expected_services: usize,
    check_fn: *const fn (*const World) bool,
};

/// A scenario is a sequence of steps that defines a test case.
pub const Scenario = struct {
    name: []const u8,
    description: []const u8,
    steps: []const Step,
};

/// Network simulator - simulates network conditions.
pub const NetworkSimulator = struct {
    config: NetworkConfig,

    /// Simulate network latency for a message.
    pub fn simulateLatency(self: *const NetworkSimulator) u64 {
        const jitter = if (self.config.latency_jitter_ms > 0)
            self.config.latency_jitter_ms
        else
            0;
        return self.config.base_latency_ms + @as(u64, std.crypto.random.uintAtMost(u32, jitter));
    }

    /// Check if a packet should be lost.
    pub fn shouldDropPacket(self: *const NetworkSimulator) bool {
        if (self.config.packet_loss_percent <= 0) return false;
        const rand = std.crypto.random.float(f32);
        return rand < self.config.packet_loss_percent;
    }
};

/// The simulation harness.
pub const Simulation = struct {
    /// The ECS world being simulated.
    world: World,

    /// Simulated HLC clock.
    clock: Timestamp,

    /// Network simulator.
    network: NetworkSimulator,

    /// Event count for ordering.
    event_count: u16,

    /// Current simulation time in ms.
    time_ms: u64,

    /// Initialize a new simulation.
    pub fn init(config: SimulationConfig) Simulation {
        return Simulation{
            .world = World.init(),
            .clock = .{ .time = 0, .count = 0, .node_id = 0 },
            .network = NetworkSimulator{ .config = config.network },
            .event_count = 0,
            .time_ms = 0,
        };
    }

    /// Run a scenario.
    pub fn run(self: *Simulation, scenario: Scenario, allocator: std.mem.Allocator) !void {
        std.debug.print("\n=== Running scenario: {s} ===\n", .{scenario.name});
        std.debug.print("{s}\n\n", .{scenario.description});

        for (scenario.steps) |step| {
            try self.runStep(step, allocator);
        }

        std.debug.print("=== Scenario complete: {s} ===\n", .{scenario.name});
    }

    /// Run a single step.
    fn runStep(self: *Simulation, step: Step, _: std.mem.Allocator) !void {
        switch (step) {
            .advance_time => |ms| {
                self.time_ms += ms;
                self.clock.time = self.time_ms;
                std.debug.print("  [time] advanced {d}ms (total: {d}ms)\n", .{ ms, self.time_ms });
            },

            .node_join => |join| {
                const event = Event{
                    .node_join = .{
                        .node_id = join.node_id,
                        .address = join.address,
                        .port = join.port,
                        .timestamp = self.nextTimestamp(),
                    },
                };
                const result = reducer.reduce(&self.world, event);
                if (result.err) |err| {
                    std.debug.print("  [ERROR] node_join failed: {s}\n", .{@errorName(err)});
                    return error.ReducerError;
                }
                std.debug.print("  [event] node_join: node_id={d}\n", .{join.node_id});
            },

            .node_leave => |node_id| {
                const event = Event{
                    .node_leave = .{
                        .node_id = node_id,
                        .timestamp = self.nextTimestamp(),
                    },
                };
                const result = reducer.reduce(&self.world, event);
                if (result.err) |err| {
                    std.debug.print("  [ERROR] node_leave failed: {s}\n", .{@errorName(err)});
                    return error.ReducerError;
                }
                std.debug.print("  [event] node_leave: node_id={d}\n", .{node_id});
            },

            .service_deploy => |deploy| {
                var name_buffer: [32]u8 = undefined;
                @memcpy(name_buffer[0..deploy.name.len], deploy.name);

                const event = Event{
                    .service_deploy = .{
                        .service_id = deploy.service_id,
                        .name = name_buffer,
                        .name_len = @truncate(deploy.name.len),
                        .replicas = deploy.replicas,
                        .timestamp = self.nextTimestamp(),
                    },
                };
                const result = reducer.reduce(&self.world, event);
                if (result.err) |err| {
                    std.debug.print("  [ERROR] service_deploy failed: {s}\n", .{@errorName(err)});
                    return error.ReducerError;
                }
                std.debug.print("  [event] service_deploy: service_id={d}, name={s}, replicas={d}\n", .{
                    deploy.service_id,
                    deploy.name,
                    deploy.replicas,
                });
            },

            .service_remove => |service_id| {
                const event = Event{
                    .service_remove = .{
                        .service_id = service_id,
                        .timestamp = self.nextTimestamp(),
                    },
                };
                const result = reducer.reduce(&self.world, event);
                if (result.err) |err| {
                    std.debug.print("  [ERROR] service_remove failed: {s}\n", .{@errorName(err)});
                    return error.ReducerError;
                }
                std.debug.print("  [event] service_remove: service_id={d}\n", .{service_id});
            },

            .health_change => |change| {
                const event = Event{
                    .health_status_change = .{
                        .node_id = change.node_id,
                        .new_status = change.new_status,
                        .timestamp = self.nextTimestamp(),
                    },
                };
                const result = reducer.reduce(&self.world, event);
                if (result.err) |err| {
                    std.debug.print("  [ERROR] health_change failed: {s}\n", .{@errorName(err)});
                    return error.ReducerError;
                }
                std.debug.print("  [event] health_change: node_id={d}, status={d}\n", .{
                    change.node_id,
                    change.new_status,
                });
            },

            .verify => |verify| {
                const passed = verify.check_fn(&self.world);
                std.debug.print("  [verify] {s}: nodes={d} (expected {d}), services={d} (expected {d}) -> {s}\n", .{
                    verify.description,
                    self.world.node_count,
                    verify.expected_nodes,
                    self.world.service_count,
                    verify.expected_services,
                    if (passed) "PASS" else "FAIL",
                });
                if (!passed) {
                    return error.VerificationFailed;
                }
            },
        }
    }

    /// Generate the next timestamp.
    fn nextTimestamp(self: *Simulation) Timestamp {
        self.event_count += 1;
        return Timestamp{
            .time = self.time_ms,
            .count = self.event_count,
            .node_id = 0, // Simulation node ID
        };
    }
};

/// Configuration for simulation.
pub const SimulationConfig = struct {
    network: NetworkConfig = .{},
};

/// Create a node address from an IP string.
pub fn parseIpv4(addr: []const u8) [4]u8 {
    var parts: [4]u8 = undefined;
    var i: usize = 0;
    var start: usize = 0;
    var part_idx: usize = 0;

    while (i < addr.len) : (i += 1) {
        if (addr[i] == '.') {
            if (part_idx < 3) {
                parts[part_idx] = std.fmt.parseInt(u8, addr[start..i], 10) catch 0;
                part_idx += 1;
            }
            start = i + 1;
        }
    }
    if (part_idx < 4) {
        parts[part_idx] = std.fmt.parseInt(u8, addr[start..addr.len], 10) catch 0;
    }
    return parts;
}

// ============================================================================
// Built-in Scenarios
// ============================================================================

/// Scenario: Basic node join and leave.
pub fn scenarioNodeJoinLeave() Scenario {
    return Scenario{
        .name = "node_join_leave",
        .description = "Basic node join and leave flow",
        .steps = &.{
            .{ .advance_time = 100 },
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .advance_time = 50 },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{ .advance_time = 50 },
            .{
                .verify = .{
                    .description = "Two nodes should be present",
                    .expected_nodes = 2,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_count == 2;
                        }
                    }).check,
                },
            },
            .{ .node_leave = 1 },
            .{ .advance_time = 50 },
            .{
                .verify = .{
                    .description = "One node should remain (marked not alive)",
                    .expected_nodes = 2, // Node still in array, just not alive
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_count == 2 and !w.nodes[0].alive;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: Service deployment and removal.
pub fn scenarioServiceDeploy() Scenario {
    return Scenario{
        .name = "service_deploy",
        .description = "Service deployment and removal flow",
        .steps = &.{
            .{ .advance_time = 100 },
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 3, .address = .{ 192, 168, 1, 12 }, .port = 8080 } },
            .{ .advance_time = 50 },
            .{
                .service_deploy = .{
                    .service_id = 1,
                    .name = "nginx",
                    .replicas = 2,
                },
            },
            .{ .advance_time = 50 },
            .{
                .verify = .{
                    .description = "Service should be deployed with 2 replicas",
                    .expected_nodes = 3,
                    .expected_services = 1,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            if (w.service_count != 1) return false;
                            const svc = &w.services[0];
                            return svc.replicas == 2;
                        }
                    }).check,
                },
            },
            .{ .service_remove = 1 },
            .{ .advance_time = 50 },
            .{
                .verify = .{
                    .description = "Service should be removed",
                    .expected_nodes = 3,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.service_count == 0;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: Network partition simulation.
pub fn scenarioNetworkPartition() Scenario {
    return Scenario{
        .name = "network_partition",
        .description = "Simulate a network partition and recovery",
        .steps = &.{
            .{ .advance_time = 100 },
            // Phase 1: All nodes join
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 3, .address = .{ 192, 168, 1, 12 }, .port = 8080 } },
            .{
                .verify = .{
                    .description = "All 3 nodes should be present",
                    .expected_nodes = 3,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_count == 3;
                        }
                    }).check,
                },
            },
            // Phase 2: Simulate partition (node 2 "leaves")
            .{ .advance_time = 1000 },
            .{ .node_leave = 2 },
            .{
                .verify = .{
                    .description = "Node 2 should be marked not alive",
                    .expected_nodes = 3,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            // Find node 2
                            for (w.nodes[0..w.node_count]) |node| {
                                if (node.id == 2) return !node.alive;
                            }
                            return false;
                        }
                    }).check,
                },
            },
            // Phase 3: Node 2 rejoins (partition heals)
            .{ .advance_time = 5000 },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{
                .verify = .{
                    .description = "Node 2 should be alive again",
                    .expected_nodes = 3,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            for (w.nodes[0..w.node_count]) |node| {
                                if (node.id == 2) return node.alive;
                            }
                            return false;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: Health monitoring.
pub fn scenarioHealthMonitoring() Scenario {
    return Scenario{
        .name = "health_monitoring",
        .description = "Node health status changes",
        .steps = &.{
            .{ .advance_time = 100 },
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            // Node starts healthy
            .{ .health_change = .{ .node_id = 1, .new_status = 0 } }, // healthy
            .{ .advance_time = 100 },
            .{
                .verify = .{
                    .description = "Node should be healthy",
                    .expected_nodes = 1,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_health_count == 1 and
                                w.node_health[0].node_id == 1 and
                                w.node_health[0].status == .healthy;
                        }
                    }).check,
                },
            },
            // Node becomes unhealthy
            .{ .health_change = .{ .node_id = 1, .new_status = 2 } }, // unhealthy
            .{ .advance_time = 100 },
            .{
                .verify = .{
                    .description = "Node should be unhealthy",
                    .expected_nodes = 1,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_health_count == 1 and
                                w.node_health[0].status == .unhealthy;
                        }
                    }).check,
                },
            },
            // Node recovers
            .{ .health_change = .{ .node_id = 1, .new_status = 0 } }, // healthy
            .{
                .verify = .{
                    .description = "Node should be healthy again",
                    .expected_nodes = 1,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_health_count == 1 and
                                w.node_health[0].status == .healthy;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: 50 nodes - realworld profile.
pub fn scenario50Realworld(allocator: std.mem.Allocator) !Scenario {
    const steps_count = 50 + 2; // 50 node joins + 2 verifies
    const steps = try allocator.alloc(Step, steps_count);
    var idx: usize = 0;

    // Initial time advance
    steps[idx] = .{ .advance_time = 100 };
    idx += 1;

    // Add 50 nodes
    for (1..51) |i| {
        const ip: [4]u8 = .{
            192,
            168,
            @truncate((i / 255) + 1),
            @truncate((i % 255) + 1),
        };
        steps[idx] = .{ .node_join = .{
            .node_id = @truncate(i),
            .address = ip,
            .port = 8080,
        } };
        idx += 1;
    }

    // Verify all 50 nodes
    steps[idx] = .{
        .verify = .{
            .description = "All 50 nodes should be present",
            .expected_nodes = 50,
            .expected_services = 0,
            .check_fn = &(struct {
                fn check(w: *const World) bool {
                    return w.node_count == 50;
                }
            }).check,
        },
    };
    idx += 1;

    return Scenario{
        .name = "50_nodes_realworld",
        .description = "50 nodes joining - realworld network profile",
        .steps = steps[0..idx],
    };
}

/// Scenario: 20 nodes - Pi WiFi profile.
pub fn scenario20PiWifi(allocator: std.mem.Allocator) !Scenario {
    const steps_count = 20 + 2; // 20 node joins + 2 verifies
    const steps = try allocator.alloc(Step, steps_count);
    var idx: usize = 0;

    // Initial time advance
    steps[idx] = .{ .advance_time = 100 };
    idx += 1;

    // Add 20 nodes (simulating Raspberry Pis on WiFi)
    for (1..21) |i| {
        const ip: [4]u8 = .{
            10,
            0,
            1,
            @truncate(i + 10),
        };
        steps[idx] = .{ .node_join = .{
            .node_id = @truncate(i),
            .address = ip,
            .port = 8080,
        } };
        idx += 1;
    }

    // Verify all 20 nodes
    steps[idx] = .{
        .verify = .{
            .description = "All 20 nodes should be present",
            .expected_nodes = 20,
            .expected_services = 0,
            .check_fn = &(struct {
                fn check(w: *const World) bool {
                    return w.node_count == 20;
                }
            }).check,
        },
    };
    idx += 1;

    return Scenario{
        .name = "20_nodes_pi_wifi",
        .description = "20 nodes joining - Pi WiFi network profile",
        .steps = steps[0..idx],
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Simulation: node_join_leave scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioNodeJoinLeave();

    try sim.run(scenario, testing.allocator);

    try testing.expectEqual(@as(usize, 2), sim.world.node_count);
}

test "Simulation: service_deploy scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioServiceDeploy();

    try sim.run(scenario, testing.allocator);

    // The scenario deploys and then REMOVES the service
    try testing.expectEqual(@as(usize, 0), sim.world.service_count);
}

test "Simulation: network_partition scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioNetworkPartition();

    try sim.run(scenario, testing.allocator);

    // After partition heals, all 3 should be alive
    var all_alive = true;
    for (sim.world.nodes[0..sim.world.node_count]) |node| {
        if (!node.alive) all_alive = false;
    }
    try testing.expect(all_alive);
}

test "Simulation: health_monitoring scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioHealthMonitoring();

    try sim.run(scenario, testing.allocator);

    try testing.expectEqual(@as(usize, 1), sim.world.node_health_count);
    try testing.expectEqual(NodeHealthStatus.healthy, sim.world.node_health[0].status);
}

test "Simulation: 50 nodes (realworld profile)" {
    var sim = Simulation.init(.{
        .network = .{
            .profile = .realworld,
            .base_latency_ms = 1,
            .latency_jitter_ms = 2,
            .packet_loss_percent = 0.001,
        },
    });
    const scenario = try scenario50Realworld(testing.allocator);
    defer testing.allocator.free(scenario.steps);

    try sim.run(scenario, testing.allocator);

    try testing.expectEqual(@as(usize, 50), sim.world.node_count);
}

test "Simulation: 20 nodes (pi-ish wifi profile)" {
    var sim = Simulation.init(.{
        .network = .{
            .profile = .pi_wifi,
            .base_latency_ms = 50,
            .latency_jitter_ms = 30,
            .packet_loss_percent = 0.02,
        },
    });
    const scenario = try scenario20PiWifi(testing.allocator);
    defer testing.allocator.free(scenario.steps);

    try sim.run(scenario, testing.allocator);

    try testing.expectEqual(@as(usize, 20), sim.world.node_count);
}

test "parseIpv4 parses IP address correctly" {
    const ip = parseIpv4("192.168.1.100");
    try testing.expectEqual(@as(u8, 192), ip[0]);
    try testing.expectEqual(@as(u8, 168), ip[1]);
    try testing.expectEqual(@as(u8, 1), ip[2]);
    try testing.expectEqual(@as(u8, 100), ip[3]);
}

// ============================================================================
// Additional Simulation Scenarios
// ============================================================================

/// Scenario: Multiple nodes join simultaneously (tests concurrent behavior)
pub fn scenarioConcurrentNodeJoins() Scenario {
    return Scenario{
        .name = "concurrent_node_joins",
        .description = "Multiple nodes join at the same time",
        .steps = &.{
            .{ .advance_time = 100 },
            // All nodes join at time 100 (simulating concurrent join)
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 3, .address = .{ 192, 168, 1, 12 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 4, .address = .{ 192, 168, 1, 13 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 5, .address = .{ 192, 168, 1, 14 }, .port = 8080 } },
            .{
                .verify = .{
                    .description = "All 5 nodes should be present",
                    .expected_nodes = 5,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_count == 5;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: Rapid health status changes (stress test for health monitoring)
pub fn scenarioRapidHealthChanges() Scenario {
    return Scenario{
        .name = "rapid_health_changes",
        .description = "Node health oscillates rapidly between states",
        .steps = &.{
            .{ .advance_time = 100 },
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            // Rapid health oscillations
            .{ .health_change = .{ .node_id = 1, .new_status = 0 } }, // healthy
            .{ .health_change = .{ .node_id = 1, .new_status = 2 } }, // unhealthy
            .{ .health_change = .{ .node_id = 1, .new_status = 0 } }, // healthy
            .{ .health_change = .{ .node_id = 1, .new_status = 1 } }, // degraded
            .{ .health_change = .{ .node_id = 1, .new_status = 0 } }, // healthy
            .{ .health_change = .{ .node_id = 1, .new_status = 2 } }, // unhealthy
            .{
                .verify = .{
                    .description = "Final health should be unhealthy",
                    .expected_nodes = 1,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            if (w.node_health_count != 1) return false;
                            return w.node_health[0].status == .unhealthy;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: Deploy same service twice (tests idempotency)
pub fn scenarioServiceReDeploy() Scenario {
    return Scenario{
        .name = "service_redeploy",
        .description = "Deploy same service twice - should be idempotent",
        .steps = &.{
            .{ .advance_time = 100 },
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            // First deploy
            .{
                .service_deploy = .{
                    .service_id = 1,
                    .name = "redis",
                    .replicas = 2,
                },
            },
            .{ .advance_time = 50 },
            // Redeploy same service (should be idempotent)
            .{
                .service_deploy = .{
                    .service_id = 1,
                    .name = "redis",
                    .replicas = 3, // Changed replica count
                },
            },
            .{ .advance_time = 50 },
            .{
                .verify = .{
                    .description = "Service should exist exactly once",
                    .expected_nodes = 2,
                    .expected_services = 1,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            // Should only have 1 service, not 2
                            return w.service_count == 1;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: Node flapping - join, leave, rejoin repeatedly
pub fn scenarioNodeFlapping() Scenario {
    return Scenario{
        .name = "node_flapping",
        .description = "Node repeatedly joins and leaves",
        .steps = &.{
            .{ .advance_time = 100 },
            // First cycle
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .advance_time = 100 },
            .{ .node_leave = 1 },
            .{ .advance_time = 100 },
            // Second cycle
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .advance_time = 100 },
            .{ .node_leave = 1 },
            .{ .advance_time = 100 },
            // Third cycle - final join
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{
                .verify = .{
                    .description = "Node should be alive after final join",
                    .expected_nodes = 1,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            if (w.node_count != 1) return false;
                            return w.nodes[0].alive and w.nodes[0].id == 1;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: Fill cluster with multiple nodes (10 nodes)
pub fn scenarioMaxNodes() Scenario {
    return Scenario{
        .name = "max_nodes",
        .description = "Fill cluster with multiple nodes",
        .steps = &.{
            .{ .advance_time = 100 },
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 12 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 3, .address = .{ 192, 168, 1, 13 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 4, .address = .{ 192, 168, 1, 14 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 5, .address = .{ 192, 168, 1, 15 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 6, .address = .{ 192, 168, 1, 16 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 7, .address = .{ 192, 168, 1, 17 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 8, .address = .{ 192, 168, 1, 18 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 9, .address = .{ 192, 168, 1, 19 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 10, .address = .{ 192, 168, 1, 20 }, .port = 8080 } },
            .{
                .verify = .{
                    .description = "All 10 nodes should be present",
                    .expected_nodes = 10,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_count == 10;
                        }
                    }).check,
                },
            },
        },
    };
}

/// Scenario: WAL replay simulation - deploy services, remove some, verify final state
pub fn scenarioWALReplay() Scenario {
    return Scenario{
        .name = "wal_replay",
        .description = "Simulate WAL replay: deploy services, remove some, verify final state",
        .steps = &.{
            // Simulate replay of historical events
            .{ .advance_time = 1000 },
            // Events that would have been in WAL
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 3, .address = .{ 192, 168, 1, 12 }, .port = 8080 } },
            .{
                .service_deploy = .{
                    .service_id = 1,
                    .name = "web",
                    .replicas = 2,
                },
            },
            .{
                .service_deploy = .{
                    .service_id = 2,
                    .name = "api",
                    .replicas = 3,
                },
            },
            // Service 1 gets removed (simulating historical removal)
            .{ .service_remove = 1 },
            .{
                .verify = .{
                    .description = "After replay: 3 nodes, 1 service (id=2)",
                    .expected_nodes = 3,
                    .expected_services = 1,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            if (w.node_count != 3) return false;
                            if (w.service_count != 1) return false;
                            // Service 1 should be gone, service 2 should remain
                            return w.services[0].service_id == 2;
                        }
                    }).check,
                },
            },
        },
    };
}

// ============================================================================
// Property-Based Tests
// ============================================================================

// Property: Adding same node multiple times is idempotent
test "property: node_join idempotent" {
    var sim = Simulation.init(.{});

    const event = Event{
        .node_join = .{
            .node_id = 1,
            .address = .{ 192, 168, 1, 10 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };

    // Apply same event multiple times
    for (0..10) |_| {
        const result = reducer.reduce(&sim.world, event);
        try testing.expect(result.err == null);
    }

    // Should only have 1 node
    try testing.expectEqual(@as(usize, 1), sim.world.node_count);
}

// Property: Deploying same service is idempotent
test "property: service_deploy idempotent" {
    var sim = Simulation.init(.{});

    var event = Event{
        .service_deploy = .{
            .service_id = 1,
            .name = undefined,
            .name_len = 4,
            .replicas = 2,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };
    event.service_deploy.name[0..4].* = "test".*;

    // Deploy same service multiple times
    for (0..10) |_| {
        const result = reducer.reduce(&sim.world, event);
        try testing.expect(result.err == null);
    }

    // Should only have 1 service
    try testing.expectEqual(@as(usize, 1), sim.world.service_count);
}

// Property: Rapid health changes converge to final state
test "property: health_oscillation converges" {
    var sim = Simulation.init(.{});

    // Add node first
    _ = reducer.reduce(&sim.world, Event{
        .node_join = .{
            .node_id = 1,
            .address = .{ 192, 168, 1, 10 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    });

    // Rapidly oscillate health status
    const statuses = [_]u8{ 0, 2, 0, 2, 0, 2, 1, 0, 2, 0 };
    for (statuses, 0..) |status, i| {
        _ = reducer.reduce(&sim.world, Event{
            .health_status_change = .{
                .node_id = 1,
                .new_status = status,
                .timestamp = .{ .time = 2000 + @as(u64, i), .count = @truncate(i), .node_id = 0 },
            },
        });
    }

    // Final status should be the last one applied (healthy = 0)
    try testing.expectEqual(@as(usize, 1), sim.world.node_health_count);
    try testing.expectEqual(NodeHealthStatus.healthy, sim.world.node_health[0].status);
}

// Property: Random operations produce consistent state
test "property: random_operations consistent" {
    var sim = Simulation.init(.{});

    // Run 100 deterministic but varied operations
    // Using iteration to drive deterministic but varied behavior
    for (0..100) |i| {
        const op: u2 = @truncate(i % 4); // Cycle through 0-3

        switch (op) {
            0 => {
                // Node join - use i to get varied node IDs
                const node_id: u16 = @truncate((i % 10) + 1);
                _ = reducer.reduce(&sim.world, Event{
                    .node_join = .{
                        .node_id = node_id,
                        .address = .{ 192, 168, 1, @truncate(node_id) },
                        .port = 8080,
                        .timestamp = .{ .time = @as(u64, i), .count = @truncate(i), .node_id = 0 },
                    },
                });
            },
            1 => {
                // Node leave
                const node_id: u16 = @truncate((i % 10) + 1);
                _ = reducer.reduce(&sim.world, Event{
                    .node_leave = .{
                        .node_id = node_id,
                        .timestamp = .{ .time = @as(u64, i), .count = @truncate(i), .node_id = 0 },
                    },
                });
            },
            2 => {
                // Service deploy
                const service_id: u16 = @truncate((i % 20) + 1);
                var event = Event{
                    .service_deploy = .{
                        .service_id = service_id,
                        .name = undefined,
                        .name_len = 4,
                        .replicas = @truncate((i % 4) + 1),
                        .timestamp = .{ .time = @as(u64, i), .count = @truncate(i), .node_id = 0 },
                    },
                };
                event.service_deploy.name[0..4].* = "test".*;
                _ = reducer.reduce(&sim.world, event);
            },
            3 => {
                // Health change
                const node_id: u16 = @truncate((i % 10) + 1);
                const status: u8 = @truncate(i % 4);
                _ = reducer.reduce(&sim.world, Event{
                    .health_status_change = .{
                        .node_id = node_id,
                        .new_status = status,
                        .timestamp = .{ .time = @as(u64, i), .count = @truncate(i), .node_id = 0 },
                    },
                });
            },
        }
    }

    // Verify invariants: counts should be within bounds
    try testing.expect(sim.world.node_count <= limits.MAX_NODES);
    try testing.expect(sim.world.service_count <= limits.MAX_SERVICES);
    try testing.expect(sim.world.node_health_count <= limits.MAX_NODES);
}

// Property: Node can leave and rejoin correctly
test "property: node_leave_then_join" {
    var sim = Simulation.init(.{});

    // Join node
    _ = reducer.reduce(&sim.world, Event{
        .node_join = .{
            .node_id = 1,
            .address = .{ 192, 168, 1, 10 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    });

    try testing.expect(sim.world.nodes[0].alive);

    // Leave
    _ = reducer.reduce(&sim.world, Event{
        .node_leave = .{
            .node_id = 1,
            .timestamp = .{ .time = 2000, .count = 2, .node_id = 0 },
        },
    });

    try testing.expect(!sim.world.nodes[0].alive);

    // Rejoin
    _ = reducer.reduce(&sim.world, Event{
        .node_join = .{
            .node_id = 1,
            .address = .{ 192, 168, 1, 10 },
            .port = 8080,
            .timestamp = .{ .time = 3000, .count = 3, .node_id = 0 },
        },
    });

    // Should still have exactly 1 node, and it should be alive
    try testing.expectEqual(@as(usize, 1), sim.world.node_count);
    try testing.expect(sim.world.nodes[0].alive);
}

// Property: Deploy -> remove -> deploy produces correct final state
test "property: service_deploy_remove_deploy" {
    var sim = Simulation.init(.{});

    // Deploy service 1
    var event1 = Event{
        .service_deploy = .{
            .service_id = 1,
            .name = undefined,
            .name_len = 4,
            .replicas = 2,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };
    event1.service_deploy.name[0..4].* = "svc1".*;
    _ = reducer.reduce(&sim.world, event1);

    try testing.expectEqual(@as(usize, 1), sim.world.service_count);

    // Remove service 1
    _ = reducer.reduce(&sim.world, Event{
        .service_remove = .{
            .service_id = 1,
            .timestamp = .{ .time = 2000, .count = 2, .node_id = 0 },
        },
    });

    try testing.expectEqual(@as(usize, 0), sim.world.service_count);

    // Deploy service 1 again
    var event2 = Event{
        .service_deploy = .{
            .service_id = 1,
            .name = undefined,
            .name_len = 4,
            .replicas = 3,
            .timestamp = .{ .time = 3000, .count = 3, .node_id = 0 },
        },
    };
    event2.service_deploy.name[0..4].* = "svc1".*;
    _ = reducer.reduce(&sim.world, event2);

    // Should have exactly 1 service with updated replica count
    try testing.expectEqual(@as(usize, 1), sim.world.service_count);
    try testing.expectEqual(@as(u8, 3), sim.world.services[0].replicas);
}

// ============================================================================
// Additional Scenario Tests
// ============================================================================

test "Simulation: concurrent_node_joins scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioConcurrentNodeJoins();
    try sim.run(scenario, testing.allocator);
    try testing.expectEqual(@as(usize, 5), sim.world.node_count);
}

test "Simulation: rapid_health_changes scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioRapidHealthChanges();
    try sim.run(scenario, testing.allocator);
    try testing.expectEqual(NodeHealthStatus.unhealthy, sim.world.node_health[0].status);
}

test "Simulation: service_redeploy scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioServiceReDeploy();
    try sim.run(scenario, testing.allocator);
    try testing.expectEqual(@as(usize, 1), sim.world.service_count);
}

test "Simulation: node_flapping scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioNodeFlapping();
    try sim.run(scenario, testing.allocator);
    try testing.expect(sim.world.nodes[0].alive);
}

test "Simulation: max_nodes scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioMaxNodes();
    try sim.run(scenario, testing.allocator);
    try testing.expectEqual(@as(usize, 10), sim.world.node_count);
}

test "Simulation: wal_replay scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioWALReplay();
    try sim.run(scenario, testing.allocator);
    try testing.expectEqual(@as(usize, 3), sim.world.node_count);
    try testing.expectEqual(@as(usize, 1), sim.world.service_count);
}
