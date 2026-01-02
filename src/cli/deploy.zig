// CLI deploy command: packages current directory into a Service payload and posts to daemon.
// This file implements the `myco deploy` CLI command, which facilitates the
// deployment of services to the local Myco daemon. It reads a `myco.json`
// configuration file, parses the service definitions (supporting both single
// and multiple services), and sends the resulting `Service` payload(s) to the
// daemon via a Unix domain socket for orchestration and execution.
//
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

fn parseDeployConfig(input: []const u8, idx: *usize, scratch: *DeployScratch) !DeployConfig {
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

    try json_noalloc.expectChar(input, idx, '{');
    while (true) {
        json_noalloc.skipWhitespace(input, idx);
        if (idx.* >= input.len) return error.UnexpectedToken;
        if (input[idx.*] == '}') {
            idx.* += 1;
            break;
        }

        var key_buf: [32]u8 = undefined;
        const key = try json_noalloc.parseString(input, idx, &key_buf);
        try json_noalloc.expectChar(input, idx, ':');

        if (std.mem.eql(u8, key, "id")) {
            cfg.id = try json_noalloc.parseU64(input, idx);
        } else if (std.mem.eql(u8, key, "name")) {
            cfg.name = try json_noalloc.parseString(input, idx, scratch.name_buf[0..]);
        } else if (std.mem.eql(u8, key, "flake_uri")) {
            cfg.flake_uri = try json_noalloc.parseString(input, idx, scratch.flake_buf[0..]);
        } else if (std.mem.eql(u8, key, "package")) {
            cfg.package = try json_noalloc.parseString(input, idx, scratch.package_buf[0..]);
        } else if (std.mem.eql(u8, key, "exec_name")) {
            cfg.exec_name = try json_noalloc.parseString(input, idx, scratch.exec_buf[0..]);
        } else {
            try json_noalloc.skipValue(input, idx);
        }

        json_noalloc.skipWhitespace(input, idx);
        if (idx.* >= input.len) return error.UnexpectedToken;
        if (input[idx.*] == ',') {
            idx.* += 1;
            continue;
        }
        if (input[idx.*] == '}') {
            idx.* += 1;
            break;
        }
        return error.UnexpectedToken;
    }

    if (cfg.name.len == 0) return error.MissingName;
    if (cfg.flake_uri.len == 0 and cfg.package.len == 0) return error.MissingFlake;
    return cfg;
}

fn sendDeploy(service: *const Service, uds_path: []const u8) !void {
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    var addr = try std.net.Address.initUnix(uds_path);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

    var header_buf: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "POST /deploy HTTP/1.0\r\nContent-Length: {d}\r\n\r\n", .{@sizeOf(Service)});
    _ = try std.posix.write(sock, header);

    const service_bytes = std.mem.asBytes(service);
    _ = try std.posix.write(sock, service_bytes);

    var buf: [1024]u8 = undefined;
    const len = try std.posix.read(sock, &buf);
    std.debug.print("✅ Daemon Response:\n{s}\n", .{buf[0..len]});
}

fn deployConfig(cfg: DeployConfig, uds_path: []const u8) !void {
    var service = Service{
        .id = cfg.id,
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };

    service.setName(cfg.name);
    const flake = if (cfg.flake_uri.len > 0) cfg.flake_uri else cfg.package;
    service.setFlake(flake);

    @memset(&service.exec_name, 0);
    const exec_len = @min(cfg.exec_name.len, service.exec_name.len);
    @memcpy(service.exec_name[0..exec_len], cfg.exec_name[0..exec_len]);

    try sendDeploy(&service, uds_path);
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
    const input = config_buf[0..read_len];

    // 2. Determine UDS path (respect env to match daemon socket location)
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const uds_path = if (uds_env) |v| v else "/tmp/myco.sock";

    // 3. Parse config (single object or array) and deploy.
    var idx: usize = 0;
    json_noalloc.skipWhitespace(input, &idx);
    if (idx >= input.len) return error.UnexpectedToken;

    if (input[idx] == '[') {
        idx += 1;
        json_noalloc.skipWhitespace(input, &idx);
        if (idx < input.len and input[idx] == ']') return;
        var count: usize = 0;
        while (true) {
            if (count >= limits.MAX_SERVICES) return error.TooManyServices;
            var scratch = DeployScratch{};
            const parsed = parseDeployConfig(input, &idx, &scratch) catch |err| {
                std.debug.print("Error: Could not parse myco.json: {s}\n", .{@errorName(err)});
                return err;
            };
            try deployConfig(parsed, uds_path);
            count += 1;

            json_noalloc.skipWhitespace(input, &idx);
            if (idx >= input.len) return error.UnexpectedToken;
            if (input[idx] == ',') {
                idx += 1;
                continue;
            }
            if (input[idx] == ']') {
                idx += 1;
                break;
            }
            return error.UnexpectedToken;
        }
        json_noalloc.skipWhitespace(input, &idx);
        if (idx != input.len) return error.UnexpectedToken;
        return;
    }

    var scratch = DeployScratch{};
    const parsed = parseDeployConfig(input, &idx, &scratch) catch |err| {
        std.debug.print("Error: Could not parse myco.json: {s}\n", .{@errorName(err)});
        return err;
    };
    json_noalloc.skipWhitespace(input, &idx);
    if (idx != input.len) return error.UnexpectedToken;
    try deployConfig(parsed, uds_path);
}
