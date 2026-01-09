const std = @import("std");
const myco = @import("myco"); // Import myco module for limits, PacketCrypto

const Limits = myco.limits;

pub const DaemonConfig = struct {
    udp_port: u16,
    skip_udp: bool,
    uds_path: []const u8,
    packet_force_plain: bool,
    packet_allow_plain: bool,
    poll_timeout_ms: i32,
    state_dir: []const u8,
    node_id: u16,
};

pub fn loadDaemonConfig() !DaemonConfig {
    const default_port: u16 = 7777;
    const port_env = std.posix.getenv("MYCO_PORT");
    const udp_port = if (port_env) |p|
        std.fmt.parseUnsigned(u16, p, 10) catch default_port
    else
        default_port;

    const skip_udp = std.posix.getenv("MYCO_SKIP_UDP") != null;
    const uds_env = std.posix.getenv("MYCO_UDS_PATH");
    const uds_path = if (uds_env) |v| v else "/tmp/myco.sock";

    const packet_force_plain = std.posix.getenv("MYCO_PACKET_PLAINTEXT") != null;
    const packet_allow_plain = packet_force_plain or (std.posix.getenv("MYCO_PACKET_ALLOW_PLAINTEXT") != null);

    const default_poll_ms: u32 = 100;
    const poll_ms_raw = if (std.posix.getenv("MYCO_POLL_MS")) |v|
        std.fmt.parseInt(u32, v, 10) catch default_poll_ms
    else
        default_poll_ms;
    const poll_timeout_ms: i32 = @intCast(@min(poll_ms_raw, @as(u32, std.math.maxInt(i32))));

    const state_dir = std.posix.getenv("MYCO_STATE_DIR") orelse "/var/lib/myco";

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const node_id_env = std.posix.getenv("MYCO_NODE_ID");
    const node_id: u16 = if (node_id_env) |v|
        std.fmt.parseUnsigned(u16, v, 10) catch prng.random().int(u16)
    else
        prng.random().int(u16);

    return DaemonConfig{
        .udp_port = udp_port,
        .skip_udp = skip_udp,
        .uds_path = uds_path,
        .packet_force_plain = packet_force_plain,
        .packet_allow_plain = packet_allow_plain,
        .poll_timeout_ms = poll_timeout_ms,
        .state_dir = state_dir,
        .node_id = node_id,
    };
}

pub fn makePathAbsolute(path: []const u8) !void {
    if (path.len <= 1 or path[0] != '/') return error.BadPathName;
    var root = try std.fs.openDirAbsolute("/", .{});
    defer root.close();
    try root.makePath(path[1..]);
}

pub fn ensureStateDirs(state_dir: []const u8) !void {
    if (std.fs.path.isAbsolute(state_dir)) {
        try makePathAbsolute(state_dir);
    } else {
        try std.fs.cwd().makePath(state_dir);
    }

    var services_buf: [Limits.PATH_MAX]u8 = undefined;
    const services_dir = try std.fmt.bufPrint(&services_buf, "{s}/services", .{state_dir});
    if (std.fs.path.isAbsolute(services_dir)) {
        try makePathAbsolute(services_dir);
    } else {
        try std.fs.cwd().makePath(services_dir);
    }
}

pub fn initUdpSocket(port: u16) !std.posix.socket_t {
    const udp_addr = try std.net.Address.resolveIp("0.0.0.0", port);
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
        std.debug.print("[ERR] udp socket create failed: {any}\n", .{err});
        return err;
    };
    std.posix.bind(sock, &udp_addr.any, udp_addr.getOsSockLen()) catch |err| {
        std.debug.print("[ERR] udp bind failed: {any}\n", .{err});
        return err;
    };
    return sock;
}

pub fn initUdsSocket(path: []const u8) !std.posix.socket_t {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    var addr = try std.net.Address.initUnix(path);
    try std.posix.bind(sock, &addr.any, addr.getOsSockLen());
    try std.posix.listen(sock, 10);
    _ = std.posix.fchmod(sock, 0o666) catch {};
    return sock;
}
