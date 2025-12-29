// Minimal API surface used in simulations to inspect node state and trigger deployments.
const std = @import("std");
const Node = @import("../node.zig").Node;
const Service = @import("../schema/service.zig").Service;

pub const ApiServer = struct {
    allocator: std.mem.Allocator,
    node: *Node,
    packet_mac_failures: *std.atomic.Value(u64),

    /// Create an API wrapper around a node.
    pub fn init(allocator: std.mem.Allocator, node: *Node, packet_mac_failures: *std.atomic.Value(u64)) ApiServer {
        return .{
            .allocator = allocator,
            .node = node,
            .packet_mac_failures = packet_mac_failures,
        };
    }

    /// Handle a very small HTTP-like request surface for metrics and deploy.
    pub fn handleRequest(self: *ApiServer, raw_req: []const u8) ![]u8 {
        // --- GET /metrics ---
         if (std.mem.indexOf(u8, raw_req, "GET /metrics") != null) {
            return std.fmt.allocPrint(self.allocator,
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
                // ❌ OLD: self.node.store.versions.count(),
                // ✅ NEW:
                self.node.store.count(), 
                self.node.last_deployed_id,
                self.packet_mac_failures.load(.seq_cst),
            });
        }
        // --- POST /deploy ---
        if (std.mem.indexOf(u8, raw_req, "POST /deploy") != null) {
            // 1. Find Body (Double newline separates headers from body)
            const split_idx = std.mem.indexOf(u8, raw_req, "\r\n\r\n");
            if (split_idx) |idx| {
                const body = raw_req[idx + 4 ..];

                // 2. Cast Body to Service Struct
                // Safety: In a real http server we'd check Content-Length
                if (body.len == @sizeOf(Service)) {
                    // We use @alignCast inside a safe block logic
                    // For simplicity, we just copy to a stack struct to ensure alignment
                    var service: Service = undefined;
                    @memcpy(std.mem.asBytes(&service), body);

                    // 3. Inject
                    const updated = try self.node.injectService(service);

                    if (updated) {
                        return std.fmt.allocPrint(self.allocator, "HTTP/1.0 200 OK\r\n\r\nDeployed ID {d}", .{service.id});
                    } else {
                        return std.fmt.allocPrint(self.allocator, "HTTP/1.0 200 OK\r\n\r\nAlready up to date", .{});
                    }
                } else {
                    return std.fmt.allocPrint(self.allocator, "HTTP/1.0 400 Bad Request\r\n\r\nBody size mismatch. Expected {d}, got {d}", .{ @sizeOf(Service), body.len });
                }
            }
        }

        return std.fmt.allocPrint(self.allocator, "HTTP/1.0 404 Not Found\r\n\r\nUnknown Endpoint", .{});
    }
};
