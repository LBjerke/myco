//! Myco - Sovereign Cloud Orchestrator (Greenfield Rewrite)
//! Main entry point - event loop shell.

const std = @import("std");
const limits = @import("util/limits.zig");
const world_mod = @import("ecs/world.zig");
const World = world_mod.World;
const allocator_mod = @import("util/allocator.zig");
const wal_mod = @import("db/wal.zig");
const Wal = wal_mod.Wal;
const WalEvent = wal_mod.WalEvent;
const makeNodeJoinEvent = wal_mod.makeNodeJoinEvent;
const reducer_mod = @import("core/reducer.zig");
const reduce = reducer_mod.reduce;
const reduceReplay = reducer_mod.reduceReplay;
const Effect = reducer_mod.Effect;

const VERSION = "0.1.0";

fn printUsage() !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print(
        \\Usage: myco [options] [command]
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  --version        Show version information
        \\  --data-dir PATH  Set data directory (default: data)
        \\  --config PATH    Config file (not yet implemented)
        \\
        ,
        .{},
    );
}

fn printVersion() !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("myco {s}\n", .{VERSION});
}

pub fn main() !void {
    // Initialize frozen allocator with a local buffer to ensure it stays valid
    var buffer: [allocator_mod.INIT_ALLOCATOR_SIZE]u8 = undefined;
    var allocator = allocator_mod.FrozenAllocator.init(&buffer);
    const alloc = allocator.allocator();

    var data_dir: []const u8 = "data";
    var show_help = false;
    var show_version = false;
    var config_path: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var unknown_arg: ?[]const u8 = null;
    var missing_value_for: ?[]const u8 = null;

    var args = std.process.args();
    _ = args.next(); // skip executable name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            data_dir = args.next() orelse {
                missing_value_for = "--data-dir";
                break;
            };
        } else if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            data_dir = arg["--data-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse {
                missing_value_for = "--config";
                break;
            };
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            config_path = arg["--config=".len..];
        } else if (arg.len > 0 and arg[0] == '-') {
            unknown_arg = arg;
            break;
        } else {
            command = arg;
        }
    }

    if (show_help) {
        try printUsage();
        return;
    }

    if (show_version) {
        try printVersion();
        return;
    }

    if (missing_value_for) |flag| {
        std.debug.print("error: missing value for {s}\n", .{flag});
        return error.InvalidArgs;
    }

    if (unknown_arg) |arg| {
        std.debug.print("error: unknown argument '{s}'\n", .{arg});
        return error.InvalidArgs;
    }

    if (config_path != null) {
        std.debug.print("error: --config is not implemented yet\n", .{});
        return error.Unimplemented;
    }

    if (command) |cmd| {
        std.debug.print("error: command '{s}' is not implemented yet\n", .{cmd});
        return error.Unimplemented;
    }

    std.debug.print("Myco (greenfield) starting...\n", .{});

    // =========================================================================
    // INIT PHASE: Use allocator for dynamic structures
    // =========================================================================

    // Example: allocate memory during init to verify allocator works
    const test_mem = try alloc.alloc(u8, 16);
    defer alloc.free(test_mem);
    test_mem[0] = 0xAB; // verify write works

    // TODO: Load config (parse config file into allocated structures)

    // Ensure data directory exists
    std.fs.cwd().makePath(data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const wal_dir = try std.fmt.allocPrint(alloc, "{s}/wal", .{data_dir});
    const lock_path = try std.fmt.allocPrint(alloc, "{s}/myco.lock", .{data_dir});

    var lock_file = try std.fs.cwd().createFile(lock_path, .{ .read = true, .truncate = false });
    defer lock_file.close();
    const got_lock = try lock_file.tryLock(.exclusive);
    if (!got_lock) {
        std.debug.print("error: another myco instance is already running\n", .{});
        return error.AlreadyRunning;
    }

    // Initialize WAL (allocate write buffers during init phase)
    var wal = try Wal.init(alloc, wal_dir);
    defer wal.deinit();
    const events = try wal.getTotalEventCount();
    std.debug.print("WAL initialized with {} events\n", .{events});

    // Replay WAL events using the reducer (reconstruct state)
    var world = World.init();
    try wal.replay(&world, reduceReplay);
    std.debug.print("Replayed WAL: {} nodes, {} services in world\n", .{
        world.node_count,
        world.service_count,
    });

    // Example: Apply a new event using the reducer
    // In real usage, this would come from CLI/API input
    const new_node_event = makeNodeJoinEvent(1, .{ 192, 168, 1, 100 }, 8080);
    const result = reduce(&world, WalEvent.create(new_node_event).event);

    if (result.err) |err| {
        std.debug.print("Warning: reduce error: {}\n", .{err});
    } else {
        std.debug.print("Applied node_join event\n", .{});

        // Handle the effect - in real usage, this would trigger gossip/systemd
        switch (result.effect) {
            .node_joined => |e| {
                std.debug.print("  -> Effect: node {} joined at {d}.{d}.{d}.{d}:{}\n", .{ e.node_id, e.address[0], e.address[1], e.address[2], e.address[3], e.port });
                // TODO: gossip this to peers
                // TODO: start systemd service if needed
            },
            .node_left => |e| {
                std.debug.print("  -> Effect: node {} left\n", .{e.node_id});
            },
            .service_deployed => |e| {
                std.debug.print("  -> Effect: service {s} deployed ({} replicas)\n", .{ e.name, e.replicas });
            },
            .service_removed => |e| {
                std.debug.print("  -> Effect: service {} removed\n", .{e.service_id});
            },
            .health_changed => |e| {
                std.debug.print("  -> Effect: node {} health changed to {}\n", .{ e.node_id, e.new_status });
            },
            .none => {},
        }
    }

    // Example: Append the event to WAL for durability
    // In real usage, we'd append before applying effects
    // try wal.append(WalEvent.create(new_node_event));

    // Log init memory usage
    std.debug.print("Init complete. Used {} bytes of {}.\n", .{
        allocator_mod.INIT_ALLOCATOR_SIZE - allocator.remaining(),
        allocator_mod.INIT_ALLOCATOR_SIZE,
    });

    // =========================================================================
    // FREEZE: No more allocations allowed!
    // =========================================================================
    allocator.freeze();
    std.debug.print("Allocator frozen. Zero-allocation runtime active.\n", .{});

    // World already initialized above with replayed state
    _ = &world;

    std.debug.print("World ready. {} nodes, {} services. Entering tick loop...\n", .{
        world.node_count,
        world.service_count,
    });

    // Main tick loop - all allocation attempts will panic if made here
    while (true) {
        std.Thread.sleep(limits.TICK_INTERVAL_MS * std.time.ns_per_ms);
        // TODO: gather inputs (timers, packets, API commands)
        // TODO: decode inputs into events
        // TODO: reduce(event) to get new state + effects
        // TODO: execute effects (gossip, systemd, etc.)
        // Note: No heap allocations allowed in this loop!
    }
}

test {
    std.testing.refAllDecls(@This());
}
