const std = @import("std");
const Config = @import("config.zig");

pub const Registry = struct {
    
    /// Scans {store_path}/bin to find the executable (Fallback logic)
    fn detectBinary(allocator: std.mem.Allocator, store_path: []const u8, service_name: []const u8) ![]const u8 {
        const bin_path = try std.fs.path.join(allocator, &[_][]const u8{ store_path, "bin" });
        defer allocator.free(bin_path);

        var dir = std.fs.openDirAbsolute(bin_path, .{ .iterate = true }) catch return error.BinaryNotFound;
        defer dir.close();

        var walker = dir.iterate();
        var candidates = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit(allocator);
        }

        while (try walker.next()) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                try candidates.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }

        if (candidates.items.len == 0) return error.NoBinariesFound;
        if (candidates.items.len == 1) return try allocator.dupe(u8, candidates.items[0]);

        for (candidates.items) |c| {
            if (std.mem.eql(u8, c, service_name)) return try allocator.dupe(u8, c);
        }
        
        return try allocator.dupe(u8, candidates.items[0]);
    }

    /// Determines the ExecStart string for a service
    /// Returns an allocated string (caller must free)
    pub fn getCommand(allocator: std.mem.Allocator, config: Config.ServiceConfig, store_path: []const u8) ![]u8 {
        // 1. Resolve Binary Name
        var binary_name: []const u8 = undefined;
        var needs_free = false;

        if (config.cmd) |cmd| {
            binary_name = cmd;
        } 
        else if (std.mem.eql(u8, config.name, "redis")) { binary_name = "redis-server"; }
        else if (std.mem.eql(u8, config.name, "caddy")) { binary_name = "caddy"; }
        else if (std.mem.eql(u8, config.name, "minio")) { binary_name = "minio"; }
        else {
            binary_name = try detectBinary(allocator, store_path, config.name);
            needs_free = true;
        }
        defer if (needs_free) allocator.free(binary_name);

        // 2. Generate Command String based on Service Type
        if (std.mem.eql(u8, config.name, "caddy")) {
            const port = config.port orelse 8080;
            return std.fmt.allocPrint(allocator, 
                "{s}/bin/{s} file-server --listen :{d} --root /var/lib/myco/{s}", 
                .{store_path, binary_name, port, config.name});
        } 
        else if (std.mem.eql(u8, config.name, "redis")) {
            const port = config.port orelse 6379;
            return std.fmt.allocPrint(allocator, 
                "{s}/bin/{s} --port {d} --dir /var/lib/myco/{s}", 
                .{store_path, binary_name, port, config.name});
        }
        else if (std.mem.eql(u8, config.name, "minio")) {
            const port = config.port orelse 9000;
            return std.fmt.allocPrint(allocator, 
                "{s}/bin/{s} server /var/lib/myco/{s}/data --address :{d} --console-address :9001", 
                .{store_path, binary_name, config.name, port});
        }
        
        // Default / Fallback
        return std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{store_path, binary_name});
    }
};
