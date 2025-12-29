const std = @import("std");
const FrozenAllocator = @import("util/frozen_allocator.zig").FrozenAllocator;
const Node = @import("node.zig").Node;
const Packet = @import("packet.zig").Packet;
const ApiServer = @import("api/server.zig").ApiServer;
const Service = @import("schema/service.zig").Service;
const noalloc_guard = @import("util/noalloc_guard.zig");

fn noopDeploy(ctx: *anyopaque, service: Service) anyerror!void {
    _ = ctx;
    _ = service;
}

test "runtime paths avoid allocations after freeze" {
    const sys_alloc = std.testing.allocator;
    const backing = try sys_alloc.alloc(u8, 2 * 1024 * 1024);
    defer sys_alloc.free(backing);
    var fba = std.heap.FixedBufferAllocator.init(backing);
    var frozen = FrozenAllocator.init(fba.allocator());
    const allocator = frozen.allocator();

    const tmp = try allocator.alloc(u8, 1);
    allocator.free(tmp);

    var wal_buf: [64 * 1024]u8 = undefined;
    var ctx: u8 = 0;
    var node = try Node.init(1, allocator, wal_buf[0..], &ctx, noopDeploy);
    var packet_mac_failures = std.atomic.Value(u64).init(0);
    var api = ApiServer.init(&node, &packet_mac_failures);

    frozen.freeze();
    noalloc_guard.activate(&frozen);
    defer noalloc_guard.deactivate();

    try node.tick(&[_]Packet{});

    const metrics_resp = try api.handleRequest("GET /metrics HTTP/1.0\r\n\r\n");
    try std.testing.expect(metrics_resp.len > 0);

    var service = Service{
        .id = 42,
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };
    service.setName("hello");
    service.setFlake("github:example/hello");
    @memset(&service.exec_name, 0);
    const exec = "run";
    @memcpy(service.exec_name[0..exec.len], exec);

    const header = "POST /deploy HTTP/1.0\r\n\r\n";
    var req_buf: [header.len + @sizeOf(Service)]u8 = undefined;
    @memcpy(req_buf[0..header.len], header);
    @memcpy(req_buf[header.len..][0..@sizeOf(Service)], std.mem.asBytes(&service));

    const deploy_resp = try api.handleRequest(req_buf[0..]);
    try std.testing.expect(deploy_resp.len > 0);
}
