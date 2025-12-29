// CLI deploy command: packages current directory into a Service payload and posts to daemon.
const std = @import("std");
const Service = @import("../schema/service.zig").Service;
const limits = @import("../core/limits.zig");
const json_noalloc = @import("../util/json_noalloc.zig");

const DeployConfig = struct {
    id: u64 = 0,
    name: []const u8,
    flake_uri: []const u8,
    package: []const u8,
    exec_name: []const u8,
};

const DeployScratch = struct {
    name_buf: [limits.MAX_SERVICE_NAME]u8 = undefined,
    flake_buf: [limits.MAX_FLAKE_URI]u8 = undefined,
    package_buf: [limits.MAX_FLAKE_URI]u8 = undefined,
    exec_buf: [limits.MAX_EXEC_NAME]u8 = undefined,
};

fn parseDeployConfig(input: []const u8, scratch: *DeployScratch) !DeployConfig {
    if (input.len > limits.MAX_CONFIG_JSON) return error.ConfigTooLarge;
    var idx: usize = 0;
    var cfg = DeployConfig{
        .id = 0,
        .name = "",
        .flake_uri = "",
        .package = "",
        .exec_name = "",
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

        if (std.mem.eql(u8, key, "id")) {
            cfg.id = try json_noalloc.parseU64(input, &idx);
        } else if (std.mem.eql(u8, key, "name")) {
            cfg.name = try json_noalloc.parseString(input, &idx, scratch.name_buf[0..]);
        } else if (std.mem.eql(u8, key, "flake_uri")) {
            cfg.flake_uri = try json_noalloc.parseString(input, &idx, scratch.flake_buf[0..]);
        } else if (std.mem.eql(u8, key, "package")) {
            cfg.package = try json_noalloc.parseString(input, &idx, scratch.package_buf[0..]);
        } else if (std.mem.eql(u8, key, "exec_name")) {
            cfg.exec_name = try json_noalloc.parseString(input, &idx, scratch.exec_buf[0..]);
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
    if (cfg.flake_uri.len == 0 and cfg.package.len == 0) return error.MissingFlake;
    return cfg;
}

/// Deploy the current workspace by sending a Service struct to the local daemon.
pub fn run() !void {
    // 1. Read myco.json
    const cwd = std.fs.cwd();
    const config_file = cwd.openFile("myco.json", .{}) catch |err| {
        std.debug.print("Error: Could not open myco.json. Run 'myco init' first.\n", .{});
        return err;
    };
    defer config_file.close();

    var config_buf: [limits.MAX_CONFIG_JSON]u8 = undefined;
    const stat = try config_file.stat();
    if (stat.size > @as(u64, config_buf.len)) return error.ConfigTooLarge;
    const read_len = try config_file.readAll(config_buf[0..@intCast(stat.size)]);

    var scratch = DeployScratch{};
    const parsed = parseDeployConfig(config_buf[0..read_len], &scratch) catch |err| {
        std.debug.print("Error: Could not parse myco.json: {s}\n", .{@errorName(err)});
        return err;
    };

    // 2. Determine UDS path (respect env to match daemon socket location)
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const uds_path = if (uds_env) |v| v else "/tmp/myco.sock";

    // 3. Prepare Service Struct
    var service = Service{
        .id = parsed.id,
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };

    service.setName(parsed.name);
    const flake = if (parsed.flake_uri.len > 0) parsed.flake_uri else parsed.package;
    service.setFlake(flake);

    @memset(&service.exec_name, 0);
    const exec_src = parsed.exec_name;
    const exec_len = @min(exec_src.len, service.exec_name.len);
    @memcpy(service.exec_name[0..exec_len], exec_src[0..exec_len]);

    // 4. Send to Daemon via UDS
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    var addr = try std.net.Address.initUnix(uds_path);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Construct POST Request
    // Header
    var header_buf: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "POST /deploy HTTP/1.0\r\nContent-Length: {d}\r\n\r\n", .{@sizeOf(Service)});

    // Write Header
    _ = try std.posix.write(sock, header);

    // Write Body (Raw Struct Bytes)
    const service_bytes = std.mem.asBytes(&service);
    _ = try std.posix.write(sock, service_bytes);

    // Read Response
    var buf: [1024]u8 = undefined;
    const len = try std.posix.read(sock, &buf);

    std.debug.print("✅ Daemon Response:\n{s}\n", .{buf[0..len]});
}
