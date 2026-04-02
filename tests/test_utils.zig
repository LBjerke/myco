//! Test Utilities - Shared helpers for Myco tests.
//!
//! This module provides common utilities for writing tests:
//! - Event builders for creating test events
//! - World state matchers for assertions
//! - Random test data generators
//! - Common test patterns
//!
//! Usage:
//!     const test_utils = @import("test_utils");
//!     const event = test_utils.nodeJoinEvent(.{ .node_id = 1 });

const std = @import("std");
const myco = @import("myco");
const Event = myco.Event;
const World = myco.World;
const NodeHealthStatus = myco.NodeHealthStatus;
const hlc = myco.hlc;
const Timestamp = hlc.Timestamp;

// ============================================================================
// Event Builders
// ============================================================================

/// Builder for creating node join events in tests.
pub const NodeJoinBuilder = struct {
    node_id: u16 = 1,
    address: [4]u8 = .{ 192, 168, 1, 10 },
    port: u16 = 8080,
    timestamp: Timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },

    /// Build the event.
    pub fn build(self: NodeJoinBuilder) Event {
        return Event{
            .node_join = .{
                .node_id = self.node_id,
                .address = self.address,
                .port = self.port,
                .timestamp = self.timestamp,
            },
        };
    }

    /// Create a node join event with custom node ID.
    pub fn withNodeId(self: *NodeJoinBuilder, id: u16) *NodeJoinBuilder {
        self.node_id = id;
        return self;
    }

    /// Create a node join event with custom IP.
    pub fn withAddress(self: *NodeJoinBuilder, addr: [4]u8) *NodeJoinBuilder {
        self.address = addr;
        return self;
    }

    /// Create a node join event with timestamp.
    pub fn withTimestamp(self: *NodeJoinBuilder, time: u64, count: u16) *NodeJoinBuilder {
        self.timestamp = .{ .time = time, .count = count, .node_id = 0 };
        return self;
    }
};

/// Create a basic node join event.
pub fn nodeJoinEvent(params: struct {
    node_id: u16,
    address: [4]u8 = .{ 192, 168, 1, 10 },
    port: u16 = 8080,
    time: u64 = 1000,
    count: u16 = 1,
}) Event {
    return Event{
        .node_join = .{
            .node_id = params.node_id,
            .address = params.address,
            .port = params.port,
            .timestamp = .{ .time = params.time, .count = params.count, .node_id = 0 },
        },
    };
}

/// Create a basic node leave event.
pub fn nodeLeaveEvent(params: struct {
    node_id: u16,
    time: u64 = 2000,
    count: u16 = 2,
}) Event {
    return Event{
        .node_leave = .{
            .node_id = params.node_id,
            .timestamp = .{ .time = params.time, .count = params.count, .node_id = 0 },
        },
    };
}

/// Create a service deploy event.
pub fn serviceDeployEvent(params: struct {
    service_id: u16,
    name: []const u8,
    replicas: u8 = 1,
    time: u64 = 1000,
    count: u16 = 1,
}) Event {
    var name_buf: [32]u8 = undefined;
    @memcpy(name_buf[0..params.name.len], params.name);
    return Event{
        .service_deploy = .{
            .service_id = params.service_id,
            .name = name_buf,
            .name_len = @truncate(params.name.len),
            .replicas = params.replicas,
            .timestamp = .{ .time = params.time, .count = params.count, .node_id = 0 },
        },
    };
}

/// Create a service remove event.
pub fn serviceRemoveEvent(params: struct {
    service_id: u16,
    time: u64 = 2000,
    count: u16 = 2,
}) Event {
    return Event{
        .service_remove = .{
            .service_id = params.service_id,
            .timestamp = .{ .time = params.time, .count = params.count, .node_id = 0 },
        },
    };
}

/// Create a health status change event.
pub fn healthChangeEvent(params: struct {
    node_id: u16,
    status: u8,
    time: u64 = 1000,
    count: u16 = 1,
}) Event {
    return Event{
        .health_status_change = .{
            .node_id = params.node_id,
            .new_status = params.status,
            .timestamp = .{ .time = params.time, .count = params.count, .node_id = 0 },
        },
    };
}

// ============================================================================
// World State Matchers
// ============================================================================

/// Matcher for world state assertions.
pub const world_matchers = struct {
    /// Assert that world has exactly the expected number of nodes.
    pub fn nodeCount(w: *const World, expected: usize) !void {
        try std.testing.expectEqual(expected, w.node_count);
    }

    /// Assert that world has exactly the expected number of services.
    pub fn serviceCount(w: *const World, expected: usize) !void {
        try std.testing.expectEqual(expected, w.service_count);
    }

    /// Assert that a specific node exists and is alive.
    pub fn nodeAlive(w: *const World, node_id: u16) !void {
        for (w.nodes[0..w.node_count]) |node| {
            if (node.node_id == node_id) {
                try std.testing.expect(node.alive);
                return;
            }
        }
        return error.NodeNotFound;
    }

    /// Assert that a specific node exists but is not alive.
    pub fn nodeDead(w: *const World, node_id: u16) !void {
        for (w.nodes[0..w.node_count]) |node| {
            if (node.node_id == node_id) {
                try std.testing.expect(!node.alive);
                return;
            }
        }
        return error.NodeNotFound;
    }

    /// Assert that a specific node does not exist.
    pub fn nodeMissing(w: *const World, node_id: u16) !void {
        const node = w.findNode(node_id);
        try std.testing.expect(node == null);
    }

    /// Assert that a specific service exists.
    pub fn serviceExists(w: *const World, service_id: u16) !void {
        for (w.services[0..w.service_count]) |svc| {
            if (svc.service_id == service_id and svc.active) {
                return;
            }
        }
        return error.ServiceNotFound;
    }

    /// Assert that a specific service does not exist.
    pub fn serviceMissing(w: *const World, service_id: u16) !void {
        for (w.services[0..w.service_count]) |svc| {
            if (svc.service_id == service_id and svc.active) {
                return error.ServiceExists;
            }
        }
    }

    /// Assert that node health has expected status.
    pub fn healthStatus(w: *const World, node_id: u16, status: NodeHealthStatus) !void {
        for (w.node_health[0..w.node_health_count]) |h| {
            if (h.node_id == node_id) {
                try std.testing.expectEqual(status, h.status);
                return;
            }
        }
        return error.HealthNotFound;
    }
};

// ============================================================================
// Test Data Generators
// ============================================================================

/// Generator for creating test data.
pub const test_data_generator = struct {
    /// Generate a sequence of node join events.
    pub fn generateNodeJoins(start_id: u16, count: usize, allocator: std.mem.Allocator) ![]Event {
        const events = try allocator.alloc(Event, count);
        for (0..count) |i| {
            const ip: [4]u8 = .{
                192,
                168,
                1,
                @truncate((i % 254) + 1),
            };
            events[i] = nodeJoinEvent(.{
                .node_id = @truncate(start_id + i),
                .address = ip,
                .time = @truncate(1000 + i * 100),
                .count = @truncate(i + 1),
            });
        }
        return events;
    }

    /// Generate a sequence of service deploy events.
    pub fn generateServiceDeploys(start_id: u16, count: usize, allocator: std.mem.Allocator) ![]Event {
        const events = try allocator.alloc(Event, count);
        const names = [_][]const u8{ "web", "api", "db", "cache", "worker" };
        for (0..count) |i| {
            const name = names[i % names.len];
            events[i] = serviceDeployEvent(.{
                .service_id = @truncate(start_id + i),
                .name = name,
                .replicas = @truncate((i % 3) + 1),
                .time = @truncate(1000 + i * 100),
                .count = @truncate(i + 1),
            });
        }
        return events;
    }

    /// Generate IP address from node ID.
    pub fn nodeIdToIp(node_id: u16) [4]u8 {
        return .{
            192,
            168,
            @truncate(node_id / 254),
            @truncate((node_id % 254) + 1),
        };
    }
};

// ============================================================================
// Test Context
// ============================================================================

/// A test context that provides common setup/teardown patterns.
pub const TestContext = struct {
    world: World,
    allocator: std.mem.Allocator,

    /// Initialize a new test context.
    pub fn init(alloc: std.mem.Allocator) TestContext {
        return TestContext{
            .world = World.init(),
            .allocator = alloc,
        };
    }

    /// Add a node to the world.
    pub fn addNode(self: *TestContext, node_id: u16) !void {
        const event = nodeJoinEvent(.{ .node_id = node_id });
        const result = myco.reducer.reduce(&self.world, event);
        if (result.err) |e| return e;
    }

    /// Deploy a service.
    pub fn deployService(self: *TestContext, service_id: u16, name: []const u8, replicas: u8) !void {
        const event = serviceDeployEvent(.{
            .service_id = service_id,
            .name = name,
            .replicas = replicas,
        });
        const result = myco.reducer.reduce(&self.world, event);
        if (result.err) |e| return e;
    }

    /// Get the world for assertions.
    pub fn getWorld(self: *TestContext) *World {
        return &self.world;
    }
};

// ============================================================================
// Assertion Helpers
// ============================================================================

/// Convenience function to assert node count.
pub fn expectNodeCount(w: *const World, expected: usize) !void {
    try std.testing.expectEqual(expected, w.node_count);
}

/// Convenience function to assert service count.
pub fn expectServiceCount(w: *const World, expected: usize) !void {
    try std.testing.expectEqual(expected, w.service_count);
}

/// Convenience function to assert node is alive.
pub fn expectNodeAlive(w: *const World, node_id: u16) !void {
    for (w.nodes[0..w.node_count]) |node| {
        if (node.node_id == node_id) {
            try std.testing.expect(node.alive);
            return;
        }
    }
    return error.NodeNotFound;
}

/// Convenience function to assert node is dead.
pub fn expectNodeDead(w: *const World, node_id: u16) !void {
    for (w.nodes[0..w.node_count]) |node| {
        if (node.node_id == node_id) {
            try std.testing.expect(!node.alive);
            return;
        }
    }
    return error.NodeNotFound;
}

/// Convenience function to assert service exists.
pub fn expectServiceExists(w: *const World, service_id: u16) !void {
    for (w.services[0..w.service_count]) |svc| {
        if (svc.service_id == service_id and svc.active) {
            return;
        }
    }
    return error.ServiceNotFound;
}

/// Convenience function to assert service does not exist.
pub fn expectServiceMissing(w: *const World, service_id: u16) !void {
    for (w.services[0..w.service_count]) |svc| {
        if (svc.service_id == service_id and svc.active) {
            return error.ServiceExists;
        }
    }
}

// ============================================================================
// Tests for the test utilities themselves
// ============================================================================

test "nodeJoinEvent creates valid event" {
    const event = nodeJoinEvent(.{
        .node_id = 42,
        .address = .{ 10, 0, 0, 1 },
        .port = 9000,
        .time = 5000,
        .count = 10,
    });

    try std.testing.expect(event.node_join.node_id == 42);
    try std.testing.expect(event.node_join.port == 9000);
    try std.testing.expect(event.node_join.timestamp.time == 5000);
}

test "nodeLeaveEvent creates valid event" {
    const event = nodeLeaveEvent(.{
        .node_id = 5,
        .time = 3000,
        .count = 3,
    });

    try std.testing.expect(event.node_leave.node_id == 5);
}

test "serviceDeployEvent creates valid event" {
    const event = serviceDeployEvent(.{
        .service_id = 1,
        .name = "nginx",
        .replicas = 3,
    });

    try std.testing.expect(event.service_deploy.service_id == 1);
    try std.testing.expect(event.service_deploy.replicas == 3);
}

test "healthChangeEvent creates valid event" {
    const event = healthChangeEvent(.{
        .node_id = 1,
        .status = 2, // unhealthy
    });

    try std.testing.expect(event.health_status_change.node_id == 1);
    try std.testing.expect(event.health_status_change.new_status == 2);
}

test "world_matchers.nodeCount works" {
    var world = World.init();
    _ = myco.reducer.reduce(&world, nodeJoinEvent(.{ .node_id = 1 }));
    _ = myco.reducer.reduce(&world, nodeJoinEvent(.{ .node_id = 2 }));

    try world_matchers.nodeCount(&world, 2);
}

test "world_matchers.nodeAlive works" {
    var world = World.init();
    _ = myco.reducer.reduce(&world, nodeJoinEvent(.{ .node_id = 1 }));

    try world_matchers.nodeAlive(&world, 1);
}

test "world_matchers.nodeDead works" {
    var world = World.init();
    _ = myco.reducer.reduce(&world, nodeJoinEvent(.{ .node_id = 1 }));
    _ = myco.reducer.reduce(&world, nodeLeaveEvent(.{ .node_id = 1 }));

    try world_matchers.nodeDead(&world, 1);
}

test "test_data_generator.nodeIdToIp generates valid IPs" {
    const ip = test_data_generator.nodeIdToIp(1);
    try std.testing.expectEqual(@as(u8, 192), ip[0]);
    try std.testing.expectEqual(@as(u8, 168), ip[1]);
    // node_id=1: 1/254=0, 1%254+1=2
    try std.testing.expectEqual(@as(u8, 0), ip[2]);
    try std.testing.expectEqual(@as(u8, 2), ip[3]);
}

test "TestContext.addNode works" {
    var ctx = TestContext.init(std.testing.allocator);
    defer {} // No cleanup needed for this test

    try ctx.addNode(1);
    try ctx.addNode(2);

    try expectNodeCount(ctx.getWorld(), 2);
    try expectNodeAlive(ctx.getWorld(), 1);
    try expectNodeAlive(ctx.getWorld(), 2);
}

test "TestContext.deployService works" {
    var ctx = TestContext.init(std.testing.allocator);
    defer {} // No cleanup needed for this test

    try ctx.deployService(1, "web", 2);

    try expectServiceCount(ctx.getWorld(), 1);
    try expectServiceExists(ctx.getWorld(), 1);
}
