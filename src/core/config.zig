// Service config schema and loader for on-disk deployment manifests.
const std = @import("std");
const limits = @import("limits.zig");
const json_noalloc = @import("../util/json_noalloc.zig");

pub const ServiceConfig = struct {
    id: u64 = 0,
    name: []const u8,
    package: []const u8,
    flake_uri: []const u8 = "",
    exec_name: []const u8 = "run",
    cmd: ?[]const u8 = null,
    port: ?u16 = null,
    env: ?[][]const u8 = null,
    version: u64 = 1,
};

pub const ConfigScratch = struct {
    name_buf: [limits.MAX_SERVICE_NAME]u8 = undefined,
    package_buf: [limits.MAX_FLAKE_URI]u8 = undefined,
    flake_buf: [limits.MAX_FLAKE_URI]u8 = undefined,
    exec_buf: [limits.MAX_EXEC_NAME]u8 = undefined,
    cmd_buf: [limits.MAX_EXEC_NAME]u8 = undefined,
};

pub const ConfigIO = struct {
    path_buf: [limits.PATH_MAX]u8 = undefined,
    tmp_buf: [limits.PATH_MAX]u8 = undefined,
    json_buf: [limits.MAX_CONFIG_JSON]u8 = undefined,
};

pub fn parseServiceConfigJson(input: []const u8, scratch: *ConfigScratch) !ServiceConfig {
    if (input.len > limits.MAX_CONFIG_JSON) return error.ConfigTooLarge;
    var idx: usize = 0;
    var cfg = ServiceConfig{
        .id = 0,
        .name = "",
        .package = "",
        .flake_uri = "",
        .exec_name = "",
        .cmd = null,
        .port = null,
        .env = null,
        .version = 1,
    };

    // Default exec_name = "run"
    scratch.exec_buf[0] = 'r';
    scratch.exec_buf[1] = 'u';
    scratch.exec_buf[2] = 'n';
    cfg.exec_name = scratch.exec_buf[0..3];

    try json_noalloc.expectChar(input, &idx, '{');
    while (true) {
        json_noalloc.skipWhitespace(input, &idx);
        if (idx >= input.len) return error.UnexpectedToken;
        if (input[idx] == '}') {
            idx += 1;
            break;
        }

        var key_buf: [32]u8 = undefined;
        const key = try json_noalloc.parseString(input, &idx, &key_buf);
        try json_noalloc.expectChar(input, &idx, ':');

        if (std.mem.eql(u8, key, "name")) {
            const name = try json_noalloc.parseString(input, &idx, scratch.name_buf[0..]);
            cfg.name = name;
        } else if (std.mem.eql(u8, key, "package")) {
            const package = try json_noalloc.parseString(input, &idx, scratch.package_buf[0..]);
            cfg.package = package;
        } else if (std.mem.eql(u8, key, "flake_uri")) {
            const flake = try json_noalloc.parseString(input, &idx, scratch.flake_buf[0..]);
            cfg.flake_uri = flake;
        } else if (std.mem.eql(u8, key, "exec_name")) {
            const exec_name = try json_noalloc.parseString(input, &idx, scratch.exec_buf[0..]);
            cfg.exec_name = exec_name;
        } else if (std.mem.eql(u8, key, "cmd")) {
            json_noalloc.skipWhitespace(input, &idx);
            if (idx < input.len and input[idx] == 'n') {
                try json_noalloc.parseNull(input, &idx);
                cfg.cmd = null;
            } else {
                const cmd = try json_noalloc.parseString(input, &idx, scratch.cmd_buf[0..]);
                cfg.cmd = cmd;
            }
        } else if (std.mem.eql(u8, key, "version")) {
            cfg.version = try json_noalloc.parseU64(input, &idx);
        } else if (std.mem.eql(u8, key, "id")) {
            cfg.id = try json_noalloc.parseU64(input, &idx);
        } else if (std.mem.eql(u8, key, "port")) {
            json_noalloc.skipWhitespace(input, &idx);
            if (idx < input.len and input[idx] == 'n') {
                try json_noalloc.parseNull(input, &idx);
                cfg.port = null;
            } else {
                cfg.port = try json_noalloc.parseU16(input, &idx);
            }
        } else {
            try json_noalloc.skipValue(input, &idx);
        }

        json_noalloc.skipWhitespace(input, &idx);
        if (idx >= input.len) return error.UnexpectedToken;
        if (input[idx] == ',') {
            idx += 1;
            continue;
        }
        if (input[idx] == '}') {
            idx += 1;
            break;
        }
        return error.UnexpectedToken;
    }

    if (cfg.name.len == 0) return error.MissingName;
    if (cfg.package.len == 0) return error.MissingPackage;
    return cfg;
}

pub fn writeServiceConfigJson(config: ServiceConfig, out: []u8) ![]const u8 {
    var writer = std.io.Writer.fixed(out);
    var serializer = std.json.Stringify{
        .writer = &writer,
        .options = .{},
    };
    try serializer.write(config);
    return std.io.Writer.buffered(&writer);
}

pub fn fromService(service: anytype, version: u64) ServiceConfig {
    return .{
        .id = service.id,
        .name = service.getName(),
        .package = service.getFlake(),
        .flake_uri = service.getFlake(),
        .exec_name = std.mem.sliceTo(&service.exec_name, 0),
        .version = version,
    };
}

pub fn serviceConfigPathBuf(state_dir: []const u8, name: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, "{s}/services/{s}.json", .{ state_dir, name });
}

pub fn saveNoAlloc(state_dir: []const u8, config: ServiceConfig, io: *ConfigIO) !void {
    const services_dir = try std.fmt.bufPrint(io.path_buf[0..], "{s}/services", .{state_dir});
    std.fs.makeDirAbsolute(services_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const filename = try serviceConfigPathBuf(state_dir, config.name, io.path_buf[0..]);
    const tmp_filename = try std.fmt.bufPrint(io.tmp_buf[0..], "{s}.tmp", .{filename});

    const json_str = try writeServiceConfigJson(config, io.json_buf[0..]);
    const file = try std.fs.createFileAbsolute(tmp_filename, .{});
    defer file.close();
    _ = try std.posix.write(file.handle, json_str);
    try std.posix.fsync(file.handle);
    try std.fs.renameAbsolute(tmp_filename, filename);
}

fn stateDirPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("MYCO_STATE_DIR")) |env| {
        return allocator.dupe(u8, env);
    }
    return allocator.dupe(u8, "/var/lib/myco");
}

pub fn serviceConfigPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const base = try stateDirPath(allocator);
    defer allocator.free(base);

    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(filename);

    return std.fs.path.join(allocator, &[_][]const u8{ base, "services", filename });
}

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

    /// Atomic Save: Write to tmp, then rename to target (under $MYCO_STATE_DIR/services).
    /// This prevents corrupted config files on crash/power-loss.
    pub fn save(allocator: std.mem.Allocator, config: ServiceConfig) !void {
        const base = try stateDirPath(allocator);
        defer allocator.free(base);

        const services_dir = try std.fs.path.join(allocator, &[_][]const u8{ base, "services" });
        defer allocator.free(services_dir);

        std.fs.makeDirAbsolute(services_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // 2. Prepare paths
        const filename = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ services_dir, config.name });
        defer allocator.free(filename);

        const tmp_filename = try std.fmt.allocPrint(allocator, "{s}.tmp", .{filename});
        defer allocator.free(tmp_filename);

        // 3. Serialize JSON to string (Robust method)
        const json_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(config, .{ .whitespace = .indent_4 })});
        defer allocator.free(json_str);

        // 4. Write to .tmp file
        {
            const file = try std.fs.createFileAbsolute(tmp_filename, .{});
            defer file.close();
            _ = try std.posix.write(file.handle, json_str);
            // Sync to ensure bytes hit physical disk
            try std.posix.fsync(file.handle);
        }

        // 5. Atomic Rename (Overwrite)
        try std.fs.renameAbsolute(tmp_filename, filename);
    }

    pub fn loadAll(self: *ConfigLoader, dir_path: []const u8) ![]ServiceConfig {
        const arena_alloc = self.arena.allocator();

        const base = try stateDirPath(self.allocator);
        defer self.allocator.free(base);
        const full = try std.fs.path.join(self.allocator, &[_][]const u8{ base, dir_path });
        defer self.allocator.free(full);

        var dir = std.fs.openDirAbsolute(full, .{ .iterate = true }) catch |err| {
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

            const parsed = try std.json.parseFromSlice(ServiceConfig, arena_alloc, content, .{ .ignore_unknown_fields = true });

            try list.append(arena_alloc, parsed.value);
        }

        return try list.toOwnedSlice(arena_alloc);
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

    if (@import("builtin").os.tag != .windows) {
        const c = struct {
            extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
            extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        };
        const key_z = try allocator.dupeZ(u8, "MYCO_STATE_DIR");
        defer allocator.free(key_z);
        const tmp_path_z = try allocator.dupeZ(u8, tmp_path);
        defer allocator.free(tmp_path_z);
        if (c.setenv(key_z, tmp_path_z, 1) != 0) {
            return error.SetEnvFailed;
        }
        defer _ = c.unsetenv(key_z);
    }

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
    const config_path = try serviceConfigPath(allocator, "test-service");
    defer allocator.free(config_path);
    const file = try std.fs.openFileAbsolute(config_path, .{});
    file.close();

    const list = try loader.loadAll("services");

    try std.testing.expectEqual(1, list.len);
    try std.testing.expectEqualStrings("test-service", list[0].name);
    try std.testing.expectEqualStrings("nixpkgs#hello", list[0].package);
    try std.testing.expectEqual(@as(?u16, 8080), list[0].port);
}
