// CLI deploy command: packages current directory into a Service payload and posts to daemon.
const std = @import("std");
const Service = @import("../schema/service.zig").Service;

/// Deploy the current workspace by sending a Service struct to the local daemon.
pub fn run(allocator: std.mem.Allocator) !void {
    // 1. Read myco.json
    const cwd = std.fs.cwd();
    const config_file = cwd.openFile("myco.json", .{}) catch |err| {
        std.debug.print("Error: Could not open myco.json. Run 'myco init' first.\n", .{});
        return err;
    };
    defer config_file.close();

    const config_bytes = try config_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(config_bytes);

    const Config = struct {
        id: u64,
        name: []const u8,
        flake_uri: []const u8,
        exec_name: []const u8,
    };

    var parsed = std.json.parseFromSlice(Config, allocator, config_bytes, .{}) catch |err| {
        std.debug.print("Error: Could not parse myco.json: {s}\n", .{@errorName(err)});
        return err;
    };
    defer parsed.deinit();

    // 2. Determine UDS path (respect env to match daemon socket location)
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const uds_path = if (uds_env) |v| v else "/tmp/myco.sock";

    // 3. Prepare Service Struct
    var service = Service{
        .id = parsed.value.id,
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };

    service.setName(parsed.value.name);
    service.setFlake(parsed.value.flake_uri);

    @memset(&service.exec_name, 0);
    const exec_src = parsed.value.exec_name;
    const exec_len = @min(exec_src.len, service.exec_name.len);
    @memcpy(service.exec_name[0..exec_len], exec_src[0..exec_len]);

    // 4. Send to Daemon via UDS
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    var addr = try std.net.Address.initUnix(uds_path);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Construct POST Request
    // Header
    const header = try std.fmt.allocPrint(allocator, "POST /deploy HTTP/1.0\r\nContent-Length: {d}\r\n\r\n", .{@sizeOf(Service)});
    defer allocator.free(header);

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
