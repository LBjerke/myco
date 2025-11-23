const std = @import("std");
const myco = @import("Myco");
const lmdb = @import("lmdb");
const zimq = @import("zimq");
const nix = @import("nix.zig").Nix;

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    //this is the zimq part

    const context: *zimq.Context = try .init();
    defer context.deinit();

    const pull: *zimq.Socket = try .init(context, .pull);
    defer pull.deinit();

    const push: *zimq.Socket = try .init(context, .push);
    defer push.deinit();

    try pull.bind("inproc://#1");
    try push.connect("inproc://#1");

    try push.sendSlice("hello", .{});

    var buffer: zimq.Message = .empty();
    _ = try pull.recvMsg(&buffer, .{});

    std.debug.print("{s}\n", .{buffer.slice()});

    // this is the lmdb part
    const env = try lmdb.Environment.init("data", .{});
    defer env.deinit();

    const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
    errdefer txn.abort();

    try txn.set("aaa", "foo");
    try txn.set("bbb", "bar");

    const x = try txn.get("aaa");
    std.debug.print("All your database {s} are belong to us.\n", .{x.?});
    try txn.commit();
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try myco.bufferedPrint();
    const new_nix = nix.init("testcwd", "test_env");
    try new_nix.nixosRebuild();
}
test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
