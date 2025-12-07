
const std = @import("std");
const Config = @import("config.zig");

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = try child.spawnAndWait();
}

pub fn showLogs(allocator: std.mem.Allocator, name: []const u8) !void {
    const svc_name = try std.fmt.allocPrint(allocator, "myco-{s}", .{name});
    defer allocator.free(svc_name);

    // Arguments:
    // -u : Filter by unit name
    // -f : Follow (stream new logs)
    // -n 20 : Show the last 20 lines immediately
    // --no-pager : Don't invoke 'less', just print to stdout
    const argv = &[_][]const u8{ "journalctl", "-u", svc_name, "-f", "-n", "20", "--no-pager" };

    // Reuse the existing 'run' helper which uses Inherit for stdout/stderr
    try run(allocator, argv);
}
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

pub fn apply(allocator: std.mem.Allocator, config: Config.ServiceConfig, store_path: []const u8) !void {
    // 1. Resolve Command
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

    // 2. Construct Execution String
    var exec_cmd: []u8 = undefined;
    if (std.mem.eql(u8, config.name, "caddy")) {
        const port = config.port orelse 8080;
        exec_cmd = try std.fmt.allocPrint(allocator, "{s}/bin/{s} file-server --listen :{d} --root /var/lib/myco/{s}", .{store_path, binary_name, port, config.name});
    } 
    else if (std.mem.eql(u8, config.name, "redis")) {
        const port = config.port orelse 6379;
        exec_cmd = try std.fmt.allocPrint(allocator, "{s}/bin/{s} --port {d} --dir /var/lib/myco/{s}", .{store_path, binary_name, port, config.name});
    }
    else if (std.mem.eql(u8, config.name, "minio")) {
        const port = config.port orelse 9000;
        exec_cmd = try std.fmt.allocPrint(allocator, "{s}/bin/{s} server /var/lib/myco/{s}/data --address :{d} --console-address :9001", .{store_path, binary_name, config.name, port});
    }
    else {
        exec_cmd = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{store_path, binary_name});
    }
    defer allocator.free(exec_cmd);

    // 3. Generate Unit Content
    var env_section = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer env_section.deinit(allocator);
    
    const home_env = try std.fmt.allocPrint(allocator, "Environment=\"HOME=/var/lib/myco/{s}\"\n", .{config.name});
    try env_section.appendSlice(allocator, home_env);
    allocator.free(home_env);

    if (std.mem.eql(u8, config.name, "minio")) {
        const minio_conf = try std.fmt.allocPrint(allocator, "Environment=\"MINIO_CONFIG_DIR=/var/lib/myco/{s}/.minio\"\n", .{config.name});
        try env_section.appendSlice(allocator, minio_conf);
        allocator.free(minio_conf);
    }

    if (config.env) |envs| {
        for (envs) |e| {
            if (std.mem.indexOf(u8, e, "=$")) |idx| {
                const key = e[0..idx];
                const host_var_name = e[idx+2..];
                if (std.posix.getenv(host_var_name)) |val| {
                    const line = try std.fmt.allocPrint(allocator, "Environment=\"{s}={s}\"\n", .{key, val});
                    defer allocator.free(line);
                    try env_section.appendSlice(allocator, line);
                }
            } else {
                const line = try std.fmt.allocPrint(allocator, "Environment=\"{s}\"\n", .{e});
                defer allocator.free(line);
                try env_section.appendSlice(allocator, line);
            }
        }
    }

    const unit = try std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=Myco Service: {s}
        \\After=network.target
        \\
        \\[Service]
        \\DynamicUser=yes
        \\StateDirectory=myco/{s}
        \\WorkingDirectory=/var/lib/myco/{s}
        \\ProtectSystem=strict
        \\{s}
        \\ExecStart={s}
        \\Restart=always
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{ config.name, config.name, config.name, env_section.items, exec_cmd });
    defer allocator.free(unit);

    // 4. Write to /run/systemd/system (Using Raw POSIX Write)
    const filename = try std.fmt.allocPrint(allocator, "myco-{s}.service", .{config.name});
    defer allocator.free(filename);
    
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ "/run/systemd/system", filename });
    defer allocator.free(full_path);

    // FIX: Clean up zombie file if it exists (handles 0-byte files too)
    std.fs.deleteFileAbsolute(full_path) catch {};

    const file = try std.fs.createFileAbsolute(full_path, .{});
    
    // FIX: Use raw POSIX write to bypass buffering issues. 
    // This ensures data hits the file descriptor immediately.
    _ = try std.posix.write(file.handle, unit);
    
    file.close();

    // 5. Reload and Start
    const svc_name = try std.fmt.allocPrint(allocator, "myco-{s}", .{config.name});
    defer allocator.free(svc_name);

    // Unmask just in case Systemd still thinks it's masked
    _ = run(allocator, &[_][]const u8{ "systemctl", "unmask", svc_name }) catch {};
    
    try run(allocator, &[_][]const u8{ "systemctl", "daemon-reload" });
    try run(allocator, &[_][]const u8{ "systemctl", "restart", svc_name });
}
