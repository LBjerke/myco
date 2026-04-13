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
const assert = @import("util/assert.zig");

const version = "0.1.0";

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    // Initialize frozen allocator with a properly aligned buffer for init-phase allocations
    // The buffer is aligned to 16 bytes to satisfy dir.walk() and similar functions
    const BufferType = [allocator_mod.init_allocator_size]u8;
    var buffer: BufferType align(allocator_mod.init_allocator_align) = undefined;
    var frozen_allocator = allocator_mod.FrozenAllocator.init(&buffer);
    const init_alloc = frozen_allocator.allocator();

    // Parse command line arguments
    const args = try parseArgs();

    // Handle help/version flags first
    if (args.show_help) {
        try printUsage();
        return;
    }

    if (args.show_version) {
        try printVersion();
        return;
    }

    // Validate unimplemented features
    if (args.config_path != null) {
        std.debug.print("error: --config is not implemented yet\n", .{});
        return error.Unimplemented;
    }

    if (args.command) |cmd| {
        std.debug.print("error: command '{s}' is not implemented yet\n", .{cmd});
        return error.Unimplemented;
    }

    const data_dir = args.data_dir;

    std.debug.print("Myco (greenfield) starting...\n", .{});

    // =========================================================================
    // INIT PHASE: Use allocator for dynamic structures
    // =========================================================================

    // Initialize world (creates data dir, acquires lock, initializes WAL,
    // replays events, applies example event, freezes allocator)
    const world = try initWorld(init_alloc, data_dir, &frozen_allocator);

    std.debug.print("World ready. {} nodes, {} services. Entering tick loop...\n", .{
        world.node_count,
        world.service_count,
    });

    // Main tick loop - runs indefinitely until interrupted
    // WARNING: No heap allocations allowed in this loop!
    tickLoop();
}

// ============================================================================
// Helper Functions
// ============================================================================

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
    try out.print("myco {s}\n", .{version});
}

/// Parsed command line arguments.
const ParsedArgs = struct {
    data_dir: []const u8,
    show_help: bool,
    show_version: bool,
    config_path: ?[]const u8,
    command: ?[]const u8,
};

/// Parses command line arguments and returns parsed values.
/// Returns error.InvalidArgs for missing flag values or unknown arguments.
fn parseArgs() !ParsedArgs {
    const parsed = try parseFlags();
    return try validateArgs(parsed);
}

/// Raw parsed flags before validation.
const RawParsed = struct {
    data_dir: []const u8,
    show_help: bool,
    show_version: bool,
    config_path: ?[]const u8,
    command: ?[]const u8,
    unknown_arg: ?[]const u8,
    missing_value_for: ?[]const u8,
};

/// Parse command line flags into raw structure.
fn parseFlags() !RawParsed {
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

    return .{
        .data_dir = data_dir,
        .show_help = show_help,
        .show_version = show_version,
        .config_path = config_path,
        .command = command,
        .unknown_arg = unknown_arg,
        .missing_value_for = missing_value_for,
    };
}

/// Validate parsed arguments and convert to final form.
fn validateArgs(raw: RawParsed) !ParsedArgs {
    if (raw.missing_value_for) |flag| {
        std.debug.print("error: missing value for {s}\n", .{flag});
        return error.InvalidArgs;
    }

    if (raw.unknown_arg) |arg| {
        std.debug.print("error: unknown argument '{s}'\n", .{arg});
        return error.InvalidArgs;
    }

    return .{
        .data_dir = raw.data_dir,
        .show_help = raw.show_help,
        .show_version = raw.show_version,
        .config_path = raw.config_path,
        .command = raw.command,
    };
}

/// Test that the allocator works before we rely on it.
fn testAllocator(allocator: std.mem.Allocator) !void {
    const test_mem = try allocator.alloc(u8, 16);
    defer allocator.free(test_mem);
    test_mem[0] = 0xAB; // verify write works
}

/// Create data directory and acquire exclusive lock.
fn createDataDirectory(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    // NASA Power of 10 Rule 5: Assert valid inputs
    assert.assert(data_dir.len > 0, "createDataDirectory: data_dir must not be empty");

    // Ensure data directory exists
    std.fs.cwd().makePath(data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/myco.lock", .{data_dir});

    var lock_file = try std.fs.cwd().createFile(lock_path, .{ .read = true, .truncate = false });
    defer lock_file.close();
    const got_lock = try lock_file.tryLock(.exclusive);
    if (!got_lock) {
        std.debug.print("error: another myco instance is already running\n", .{});
        return error.AlreadyRunning;
    }
}

/// Initialize WAL and replay events into world.
fn initWalAndReplay(allocator: std.mem.Allocator, data_dir: []const u8, world: *World) !void {
    // NASA Power of 10 Rule 5: Assert valid inputs
    assert.assert(data_dir.len > 0, "initWalAndReplay: data_dir must not be empty");

    const wal_dir = try std.fmt.allocPrint(allocator, "{s}/wal", .{data_dir});

    var wal = try Wal.init(allocator, wal_dir);
    defer wal.deinit();
    const events = try wal.getTotalEventCount();
    std.debug.print("WAL initialized with {} events\n", .{events});

    // Replay WAL events - fail fast on any error
    wal.replay(world, reduceReplay) catch |err| {
        std.debug.print("FATAL: WAL replay failed: {}\n", .{err});
        return err;
    };
    std.debug.print("Replayed WAL: {} nodes, {} services in world\n", .{
        world.node_count,
        world.service_count,
    });

    // Validate world state after replay
    world.validate() catch |err| {
        std.debug.print("FATAL: World validation failed after replay: {}\n", .{err});
        return error.WorldValidationFailed;
    };
    std.debug.print("World state validated successfully\n", .{});
}

/// Apply example node join event to world.
fn applyExampleEvent(world: *World) void {
    // NASA Power of 10 Rule 5: Assert world is valid
    assert.assert(world.node_count <= world.nodes.len, "applyExampleEvent: world node_count invalid");
    assert.assert(world.service_count <= world.services.len, "applyExampleEvent: world service_count invalid");

    const new_node_event = makeNodeJoinEvent(1, .{ 192, 168, 1, 100 }, 8080);
    const result = reduce(world, WalEvent.create(new_node_event).event);

    if (result.err) |err| {
        std.debug.print("Warning: reduce error: {}\n", .{err});
    } else {
        std.debug.print("Applied node_join event\n", .{});
        switch (result.effect) {
            .node_joined => |e| {
                std.debug.print("  -> Effect: node {} joined at {d}.{d}.{d}.{d}:{}\n", .{
                    e.node_id, e.address[0], e.address[1], e.address[2], e.address[3], e.port,
                });
            },
            .node_left => |e| {
                std.debug.print("  -> Effect: node {} left\n", .{e.node_id});
            },
            .service_deployed => |e| {
                std.debug.print(
                    "  -> Effect: service {} deployed ({} replicas)\n",
                    .{ e.service_id, e.replicas },
                );
            },
            .service_removed => |e| {
                std.debug.print("  -> Effect: service {} removed\n", .{e.service_id});
            },
            .health_changed => |e| {
                std.debug.print(
                    "  -> Effect: node {} health changed to {}\n",
                    .{ e.node_id, e.new_status },
                );
            },
            .none => {},
        }
    }
}

/// Freeze the allocator and report memory usage.
fn freezeAllocator(frozen_allocator: *allocator_mod.FrozenAllocator) void {
    // NASA Power of 10 Rule 5: Assert allocator is not already frozen
    assert.assert(!frozen_allocator.isFrozen(), "freezeAllocator: allocator already frozen");

    const used_memory = allocator_mod.init_allocator_size - frozen_allocator.remaining();
    std.debug.print("Init complete. Used {} bytes of {} (max).\n", .{
        used_memory,
        allocator_mod.init_allocator_size,
    });

    frozen_allocator.freeze();
    std.debug.print("Allocator frozen. Zero-allocation runtime active.\n", .{});
}

/// Initializes the world: creates data directory, acquires lock, initializes WAL,
/// replays events, applies example event, and freezes the allocator.
/// After this function returns, no more heap allocations can be made.
fn initWorld(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    frozen_allocator: *allocator_mod.FrozenAllocator,
) !World {
    // Test allocator works before init
    try testAllocator(allocator);

    // Create data directory and acquire lock
    try createDataDirectory(allocator, data_dir);

    var world = World.init();

    // Initialize WAL and replay events
    try initWalAndReplay(allocator, data_dir, &world);

    // Apply example event
    applyExampleEvent(&world);

    // Freeze allocator
    freezeAllocator(frozen_allocator);

    return world;
}

/// Main tick loop - processes events in each tick.
/// WARNING: No heap allocations allowed in this loop!
fn tickLoop() noreturn {
    while (true) {
        std.Thread.sleep(limits.tick_interval_ms * std.time.ns_per_ms);
        // TODO: gather inputs (timers, packets, API commands)
        // TODO: decode inputs into events
        // TODO: reduce(event) to get new state + effects
        // TODO: execute effects (gossip, systemd, etc.)
        // NOTE: All state must be pre-allocated or use stack-only operations!
    }
}

test {
    std.testing.refAllDecls(@This());
}
