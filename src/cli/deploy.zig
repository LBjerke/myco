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

    // Simple JSON parsing to get the name
    // We use a lightweight approach: search for "name": "..."
    // (In a real app, use std.json.parseFromSlice)
    var name_buf: [32]u8 = [_]u8{0} ** 32;
    if (parseNameFromJson(config_bytes, &name_buf)) {
        // Found name
    } else {
        std.debug.print("Error: Could not parse 'name' from myco.json\n", .{});
        return error.InvalidConfig;
    }

    // 2. Prepare Service Struct
    var service = Service{
        .id = 0, // Will set below
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };

    // ID = Random for v1 (Deploying always triggers update)
    service.id = std.crypto.random.int(u64);

    service.setName(std.mem.sliceTo(&name_buf, 0));

    // For v1, we assume the Flake is the current directory
    const abs_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(abs_path);

    // Construct URI: "path:/abs/path"
    var uri_buf: [256]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "path:{s}", .{abs_path});
    service.setFlake(uri);

    const exec_binary = "run";
    @memset(&service.exec_name, 0);
    @memcpy(service.exec_name[0..exec_binary.len], exec_binary);
    // Default binary name matches the service name
    //service.exec_name = service.name; // Copy name to exec_name

    // 3. Send to Daemon via TCP (preferred when set) or UDS.
    const tcp_env = std.posix.getenv("MYCO_API_TCP_PORT");
    var sock: std.posix.socket_t = undefined;
    var is_tcp = false;
    if (tcp_env) |p| {
        const port = std.fmt.parseInt(u16, p, 10) catch return error.InvalidArgument;
        const addr = try std.net.Address.resolveIp("127.0.0.1", port);
        sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        is_tcp = true;
        try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    } else {
        const uds_env = std.posix.getenv("MYCO_UDS_PATH");
        const UDS_PATH = if (uds_env) |v| v else "/tmp/myco.sock";
        sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        var addr = try std.net.Address.initUnix(UDS_PATH);
        try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    }
    defer std.posix.close(sock);

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

/// Quick and dirty JSON string extractor for the "name" field.
fn parseNameFromJson(json: []const u8, out: []u8) bool {
    const key = "\"name\"";
    const idx = std.mem.indexOf(u8, json, key) orelse return false;

    // Look for colon
    const colon = std.mem.indexOfPos(u8, json, idx + key.len, ":") orelse return false;

    // Look for first quote
    const q1 = std.mem.indexOfPos(u8, json, colon, "\"") orelse return false;

    // Look for second quote
    const q2 = std.mem.indexOfPos(u8, json, q1 + 1, "\"") orelse return false;

    const len = q2 - (q1 + 1);
    if (len > out.len) return false;

    @memcpy(out[0..len], json[q1 + 1 .. q2]);
    return true;
}
