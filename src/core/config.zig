const std = @import("std");

pub const ServiceConfig = struct {
    name: []const u8,
    package: []const u8,
    cmd: ?[]const u8 = null,
    port: ?u16 = null,
    env: ?[][]const u8 = null,
};

pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) ConfigLoader {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *ConfigLoader) void {
        self.arena.deinit();
    }

    /// Atomic Save: Write to tmp, then rename to target.
    /// This prevents corrupted config files on crash/power-loss.
    pub fn save(allocator: std.mem.Allocator, config: ServiceConfig) !void {
        // 1. Ensure dir exists
        std.fs.cwd().makeDir("services") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // 2. Prepare paths
        const filename = try std.fmt.allocPrint(allocator, "services/{s}.json", .{config.name});
        defer allocator.free(filename);

        const tmp_filename = try std.fmt.allocPrint(allocator, "services/{s}.json.tmp", .{config.name});
        defer allocator.free(tmp_filename);

        // 3. Serialize JSON to string (Robust method)
        const json_str = try std.fmt.allocPrint(allocator, "{f}", .{
            std.json.fmt(config, .{ .whitespace = .indent_4 })
        });
        defer allocator.free(json_str);

        // 4. Write to .tmp file
        {
            const file = try std.fs.cwd().createFile(tmp_filename, .{});
            defer file.close();
            _ = try std.posix.write(file.handle, json_str);
            // Sync to ensure bytes hit physical disk
            try std.posix.fsync(file.handle); 
        }

        // 5. Atomic Rename (Overwrite)
        try std.fs.cwd().rename(tmp_filename, filename);
    }

    pub fn loadAll(self: *ConfigLoader, dir_path: []const u8) ![]ServiceConfig {
        const arena_alloc = self.arena.allocator();
        
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return &[_]ServiceConfig{};
            return err;
        };
        defer dir.close();

        var list = try std.ArrayList(ServiceConfig).initCapacity(arena_alloc, 0);

        var walker = dir.iterate();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const file = try dir.openFile(entry.name, .{});
            defer file.close();
            
            const max_size = 1024 * 1024; 
            const content = try file.readToEndAlloc(arena_alloc, max_size);

            const parsed = try std.json.parseFromSlice(
                ServiceConfig, 
                arena_alloc, 
                content, 
                .{ .ignore_unknown_fields = true }
            );
            
            try list.append(arena_alloc, parsed.value);
        }

        return list.toOwnedSlice(arena_alloc);
    }
};
test "Config: Atomic Save and Load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    
    // FIX: Capture the allocated path so we can free it
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    
    try std.process.changeCurDir(tmp_path);
    defer std.process.changeCurDir(cwd) catch {};

    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    const svc = ServiceConfig{
        .name = "test-service",
        .package = "nixpkgs#hello",
        .port = 8080,
    };

    try ConfigLoader.save(allocator, svc);

    // Verify file exists
    const file = try std.fs.cwd().openFile("services/test-service.json", .{});
    file.close();

    const list = try loader.loadAll("services");
    
    try std.testing.expectEqual(1, list.len);
    try std.testing.expectEqualStrings("test-service", list[0].name);
    try std.testing.expectEqualStrings("nixpkgs#hello", list[0].package);
    try std.testing.expectEqual(@as(?u16, 8080), list[0].port);
}
