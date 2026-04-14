const std = @import("std");
const wal_mod = @import("myco").db.wal;

test "WAL: Snapshot + Log Recovery" {
    var log_buf: [1024]u8 = undefined;
    var snap_buf: [1024]u8 = undefined;

    var wal = wal_mod.WriteAheadLog.init(&log_buf, &snap_buf);

    // 1. Append some entries
    try wal.append(1, 100);
    try wal.append(2, 200);

    // 2. Snapshot
    // Mock snapshot data: id=1, version=100, id=2, version=200
    var snap_data: [16]u8 = .{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 1
        0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 100
    };

    try wal.compact(&snap_data);

    // 3. Append more
    try wal.append(3, 300);

    // 4. Recover
    var recovered_items = std.AutoHashMap(u64, u64).init(std.testing.allocator);
    defer recovered_items.deinit();

    const Context = struct {
        map: *std.AutoHashMap(u64, u64),
    };
    var ctx = Context{ .map = &recovered_items };

    const loader = struct {
        fn load(c: *anyopaque, id: u64, ver: u64) void {
            const ctx_ptr: *Context = @ptrCast(@alignCast(c));
            ctx_ptr.map.put(id, ver) catch unreachable;
        }
        fn loadSnap(c: *anyopaque, data: []const u8) void {
            const ctx_ptr: *Context = @ptrCast(@alignCast(c));
            var fbs = std.io.fixedBufferStream(data);
            var reader = fbs.reader();
            while (true) {
                const id = reader.readInt(u64, .little) catch break;
                const ver = reader.readInt(u64, .little) catch break;
                ctx_ptr.map.put(id, ver) catch unreachable;
            }
        }
    };

    try wal.recover(&ctx, loader.load, loader.loadSnap);

    try std.testing.expectEqual(@as(u64, 100), recovered_items.get(1).?);
    try std.testing.expectEqual(@as(u64, 300), recovered_items.get(3).?);
}
