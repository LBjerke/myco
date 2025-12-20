// Service config schema and loader for on-disk deployment manifests.
const std = @import("std");

pub const ServiceConfig = struct {
    id: u64 = 0,
    name: []const u8,
    package: []const u8,
    cmd: ?[]const u8 = null,
    port: ?u16 = null,
    env: ?[][]const u8 = null,
    version: u64 = 1,
};

pub const ConfigLoader = struct {
    // Fixed-capacity config table for zero-alloc mode.
    pub const max_services = 512;
    configs: [max_services]ServiceConfig = undefined,
    len: usize = 0,

    pub fn init(_: std.mem.Allocator) ConfigLoader {
        return .{};
    }

    pub fn deinit(self: *ConfigLoader) void {
        _ = self;
    }

    /// Atomic Save: Write to tmp, then rename to target.
    /// This prevents corrupted config files on crash/power-loss.
    pub fn save(_: std.mem.Allocator, config: ServiceConfig) !void {
        // 1. Ensure dir exists
        std.fs.cwd().makeDir("services") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // 2. Prepare paths
        var filename_buf: [128]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "services/{s}.json", .{config.name});

        var tmp_buf: [128]u8 = undefined;
        const tmp_filename = try std.fmt.bufPrint(&tmp_buf, "services/{s}.json.tmp", .{config.name});

        // 3. Serialize JSON to stack buffer
        var json_buf: [4096]u8 = undefined;
        const json_len = try std.fmt.bufPrint(&json_buf, "{f}", .{std.json.fmt(config, .{ .whitespace = .indent_4 })});

        // 4. Write to .tmp file
        {
            const file = try std.fs.cwd().createFile(tmp_filename, .{});
            defer file.close();
            _ = try std.posix.write(file.handle, json_len);
            // Sync to ensure bytes hit physical disk
            try std.posix.fsync(file.handle);
        }

        // 5. Atomic Rename (Overwrite)
        try std.fs.cwd().rename(tmp_filename, filename);
    }

    pub fn loadAll(self: *ConfigLoader, dir_path: []const u8) ![]ServiceConfig {
        self.len = 0;

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return self.configs[0..0];
            return err;
        };
        defer dir.close();

        var walker = dir.iterate();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (self.len == self.configs.len) return error.TableFull;

            const file = try dir.openFile(entry.name, .{});
            defer file.close();

            var buf: [4096]u8 = undefined;
            const read_len = try file.readAll(&buf);
            const content = buf[0..read_len];

            var parse_buf: [2048]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
            const parsed = try std.json.parseFromSlice(ServiceConfig, fba.allocator(), content, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            self.configs[self.len] = parsed.value;
            self.len += 1;
        }

        return self.configs[0..self.len];
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
