// Minimal process spawning helpers that avoid heap allocation.
const std = @import("std");

pub fn toZ(src: []const u8, buf: []u8) ![*:0]const u8 {
    if (src.len + 1 > buf.len) return error.StringTooLong;
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf[0..src.len :0].ptr;
}

pub fn spawnAndWait(argv: [*:null]const ?[*:0]const u8) !void {
    const pid = try std.posix.fork();
    if (pid == 0) {
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);
        std.posix.execvpeZ(argv[0].?, argv, envp) catch {};
        std.posix.exit(127);
    }

    const result = std.posix.waitpid(pid, 0);
    const status = result.status;
    if (!std.posix.W.IFEXITED(status)) return error.ProcessFailed;
    if (std.posix.W.EXITSTATUS(status) != 0) return error.ProcessFailed;
}
