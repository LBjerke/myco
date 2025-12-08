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

    pub fn loadAll(self: *ConfigLoader, dir_path: []const u8) ![]ServiceConfig {
        const arena_alloc = self.arena.allocator();

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return &[_]ServiceConfig{};
            return err;
        };
        defer dir.close();

        // 1. Init: Use initCapacity.
        var list = try std.ArrayList(ServiceConfig).initCapacity(arena_alloc, 0);
        // Note: Since this ArrayList doesn't store the allocator (based on the error),
        // we generally don't defer deinit() here because we call toOwnedSlice() at the end.

        var walker = dir.iterate();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const file = try dir.openFile(entry.name, .{});
            defer file.close();

            const max_size = 1024 * 1024; // 1MB max config

            // FIX: Create a 4KB stack buffer for the syscalls
            var sys_buf: [4096]u8 = undefined;
            // Create the Reader interface using that buffer
            var file_reader = file.reader(&sys_buf);

            // Read using the Reader interface
            const content = try file_reader.file.readToEndAlloc(arena_alloc, max_size);
            // FIX: Explicitly pass allocator to readToEndAlloc if required (usually File.readToEndAlloc takes it)

            const parsed = try std.json.parseFromSlice(ServiceConfig, arena_alloc, content, .{ .ignore_unknown_fields = true });

            // FIX: Pass 'arena_alloc' to append()
            // The compiler error said append expects (allocator, item)
            try list.append(arena_alloc, parsed.value);
        }

        // FIX: Pass 'arena_alloc' to toOwnedSlice()
        // If append needs it, toOwnedSlice definitely needs it to resize/detach the buffer.
        return list.toOwnedSlice(arena_alloc);
    }
};
