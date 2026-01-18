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
    // Mock snapshot data: simply a sequence of u64s
    var snap_data = std.ArrayList(u8).init(std.testing.allocator);
    defer snap_data.deinit();
    try snap_data.writer().writeInt(u64, 1, .little);
    try snap_data.writer().writeInt(u64, 100, .little);
    try snap_data.writer().writeInt(u64, 2, .little);
    try snap_data.writer().writeInt(u64, 200, .little);

    try wal.compact(snap_data.items);

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
        fn load(c: *Context, id: u64, ver: u64) void {
            c.map.put(id, ver) catch unreachable;
        }
        fn loadSnap(c: *Context, data: []const u8) void {
            var fbs = std.io.fixedBufferStream(data);
            var reader = fbs.reader();
            while (true) {
                const id = reader.readInt(u64, .little) catch break;
                const ver = reader.readInt(u64, .little) catch break;
                c.map.put(id, ver) catch unreachable;
            }
        }
    };

    try wal.recover(&ctx, loader.load, loader.loadSnap);

    try std.testing.expectEqual(@as(u64, 100), recovered_items.get(1).?);
    try std.testing.expectEqual(@as(u64, 200), recovered_items.get(2).?);
    try std.testing.expectEqual(@as(u64, 300), recovered_items.get(3).?);
}
