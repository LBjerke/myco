// Minimal API surface used in simulations to inspect node state and trigger deployments.
const std = @import("std");
const Node = @import("../node.zig").Node;
const Service = @import("../schema/service.zig").Service;
const Config = @import("../core/config.zig");

pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    node: *Node,
    packet_mac_failures: *std.atomic.Value(u64),
    auth_token: ?[]const u8 = null,
    auth_token_prev: ?[]const u8 = null,
    debug: bool = false,

    /// Create an API wrapper around a node.
    pub fn init(allocator: std.mem.Allocator, node: *Node, packet_mac_failures: *std.atomic.Value(u64), auth_token: ?[]const u8, auth_token_prev: ?[]const u8, debug: bool) ApiServer {
        return .{
            .allocator = allocator,
            .node = node,
            .packet_mac_failures = packet_mac_failures,
            .auth_token = auth_token,
            .auth_token_prev = auth_token_prev,
            .debug = debug,
        };
    }

    fn authorized(self: *ApiServer, raw_req: []const u8) bool {
        if (self.auth_token == null and self.auth_token_prev == null) return true;
        const header_prefix = "Authorization: Bearer ";
        if (std.mem.indexOf(u8, raw_req, header_prefix)) |idx| {
            const start = idx + header_prefix.len;
            const end_pos = std.mem.indexOfScalarPos(u8, raw_req, start, '\n') orelse raw_req.len;
            const token = raw_req[start..end_pos];
            if (self.auth_token) |t| {
                if (std.mem.eql(u8, token, t)) return true;
            }
            if (self.auth_token_prev) |t| {
                if (std.mem.eql(u8, token, t)) return true;
            }
        }
        return false;
    }

    /// Handle a very small HTTP-like request surface for metrics and deploy using caller-provided buffer.
    pub fn handleRequestBuf(self: *ApiServer, raw_req: []const u8, buf: []u8) ![]u8 {
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();

        if (self.debug) {
            std.debug.print("[api] recv bytes={d}\n", .{raw_req.len});
        }

        if (!self.authorized(raw_req)) {
            try w.writeAll("HTTP/1.0 401 Unauthorized\r\n\r\n");
            return stream.getWritten();
        }

        // --- GET /metrics ---
        if (std.mem.indexOf(u8, raw_req, "GET /metrics") != null) {
            if (self.debug) {
                std.debug.print("[api] metrics request\n", .{});
            }
            try w.print(
                \\HTTP/1.0 200 OK
                \\
                \\node_id {d}
                \\knowledge_height {d}
                \\services_known {d}
                \\last_deployed {d}
                \\packet_mac_failures {d}
            , .{
                self.node.id,
                self.node.knowledge,
                self.node.storeCount(),
                self.node.last_deployed_id,
                self.packet_mac_failures.load(.seq_cst),
            });
            return stream.getWritten();
        }

        // --- POST /deploy ---
        if (std.mem.indexOf(u8, raw_req, "POST /deploy") != null) {
            if (self.debug) {
                std.debug.print("[api] deploy request\n", .{});
            }
            // 1. Find Body (Double newline separates headers from body)
            const split_idx = std.mem.indexOf(u8, raw_req, "\r\n\r\n");
            if (split_idx) |idx| {
                const body = raw_req[idx + 4 ..];
                if (self.debug) {
                    std.debug.print("[api] deploy body bytes={d}\n", .{body.len});
                }

                // 2. Cast Body to Service Struct
                // Safety: In a real http server we'd check Content-Length
                if (body.len == @sizeOf(Service)) {
                    // We use @alignCast inside a safe block logic
                    // For simplicity, we just copy to a stack struct to ensure alignment
                    var service: Service = undefined;
                    @memcpy(std.mem.asBytes(&service), body);

                    // 3. Inject
                    const updated = try self.node.injectService(service);
                    const version = self.node.store.getVersion(service.id);

                    // Persist a JSON config so gossip summaries have something to advertise.
                    const exec_slice = std.mem.sliceTo(&service.exec_name, 0);
                    const cmd_field: ?[]const u8 = if (exec_slice.len > 0) exec_slice else null;
                    const cfg = Config.ServiceConfig{
                        .id = service.id,
                        .name = service.getName(),
                        .package = service.getFlake(),
                        .cmd = cmd_field,
                        .version = version,
                    };
                    Config.ConfigLoader.save(self.allocator, cfg) catch {};

                    if (updated) {
                        if (self.debug) {
                            std.debug.print("[api] deploy accepted id={d}\n", .{service.id});
                        }
                        try w.print("HTTP/1.0 200 OK\r\n\r\nDeployed ID {d}", .{service.id});
                    } else {
                        if (self.debug) {
                            std.debug.print("[api] deploy no-op id={d}\n", .{service.id});
                        }
                        try w.writeAll("HTTP/1.0 200 OK\r\n\r\nAlready up to date");
                    }
                    return stream.getWritten();
                } else {
                    if (self.debug) {
                        std.debug.print("[api] deploy bad body expected={d} got={d}\n", .{ @sizeOf(Service), body.len });
                    }
                    try w.print("HTTP/1.0 400 Bad Request\r\n\r\nBody size mismatch. Expected {d}, got {d}", .{ @sizeOf(Service), body.len });
                    return stream.getWritten();
                }
            }
        }

        try w.writeAll("HTTP/1.0 404 Not Found\r\n\r\nUnknown Endpoint");
        return stream.getWritten();
    }

    /// Heap-allocating compatibility wrapper for callers not yet migrated to fixed buffers.
    pub fn handleRequest(self: *ApiServer, raw_req: []const u8) ![]u8 {
        // Conservative buffer for small responses.
        var buf: [1024]u8 = undefined;
        const written = self.handleRequestBuf(raw_req, &buf) catch |err| {
            // Fallback to heap on overflow or unexpected errors.
            if (err == error.NoSpaceLeft) {
                return std.fmt.allocPrint(self.allocator, "HTTP/1.0 500 Internal Server Error\r\n\r\nBuffer too small", .{});
            }
            return err;
        };
        return self.allocator.dupe(u8, written);
    }
};
