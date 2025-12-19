const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Define the 'myco' Library Module (src/lib.zig)
    const myco_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
    });

    // --- TEST 1: SIMULATION ---
    const sim_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/simulation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sim_test.root_module.addImport("myco", myco_module);
    const run_sim_test = b.addRunArtifact(sim_test);
    const test_sim_step = b.step("test-sim", "Run all simulations");
    test_sim_step.dependOn(&run_sim_test.step);

    // Individual simulation filters (mirroring test names in tests/simulation.zig)
    const sims = [_][2][]const u8{
        .{ "sim-50", "Simulation: 50 nodes (loss/crash/partitions)" },
        .{ "sim-50-heavy", "Simulation: 50 nodes (heavy loss/crash/partitions)" },
        .{ "sim-50-extreme", "Simulation: 50 nodes (extreme loss/crash/partitions)" },
        .{ "sim-50-edge", "Simulation: 50 nodes (edge profile)" },
        .{ "sim-100", "Simulation: 100 nodes (loss/crash/partitions)" },
        .{ "sim-256", "Simulation: 256 nodes (baseline converge)" },
        .{ "sim-50-realworld", "Simulation: 50 nodes (realworld profile)" },
        .{ "sim-20-pi-wifi", "Simulation: 20 nodes (pi-ish wifi profile)" },
        .{ "sim-1096", "Simulation: 1096 nodes (opt-in heavy)" },
        .{ "sim-5-trace", "Simulation: 5 nodes (transparent trace)" },
        .{ "sim-10-durability", "Simulation: 10 nodes (durability restart + phases/surge)" },
    };

    const zig_exe = b.graph.zig_exe;

    inline for (sims) |entry| {
        const step_name = entry[0];
        const filter = entry[1];
        const t = b.step(step_name, std.fmt.comptimePrint("Run simulation \"{s}\"", .{filter}));
        const cmd = b.addSystemCommand(&.{
            zig_exe,
            "test",
            "-ODebug",
            "--dep",
            "myco",
            "-Mroot=tests/simulation.zig",
            "-Mmyco=src/lib.zig",
            "--test-filter",
            filter,
        });
        t.dependOn(&cmd.step);
    }

    // --- TEST 2: ENGINE ---
    const engine_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engine_test.root_module.addImport("myco", myco_module);
    const run_engine_test = b.addRunArtifact(engine_test);
    const test_engine_step = b.step("test-engine", "Test Systemd/Nix Engine");
    test_engine_step.dependOn(&run_engine_test.step);

    // --- TEST 3: CLI ---
    const cli_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_test.root_module.addImport("myco", myco_module);
    const run_cli_test = b.addRunArtifact(cli_test);
    const test_cli_step = b.step("test-cli", "Test CLI Scaffolding");
    test_cli_step.dependOn(&run_cli_test.step);

    // --- TEST 4: CRDT SYNC ---
    const crdt_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sync_crdt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    crdt_test.root_module.addImport("myco", myco_module);
    const run_crdt_test = b.addRunArtifact(crdt_test);
    const test_crdt_step = b.step("test-crdt", "Test CRDT Sync Logic");
    test_crdt_step.dependOn(&run_crdt_test.step);

    // --- TEST 5: UNIT TESTS FOR SUPPORTING MODULES ---
    const unit_modules = [_]struct {
        name: []const u8,
        desc: []const u8,
        path: []const u8,
    }{
        .{ .name = "test-wal", .desc = "Test WAL durability helpers", .path = "src/db/wal.zig" },
        .{ .name = "test-handshake", .desc = "Test deterministic handshake identities", .path = "src/net/handshake.zig" },
        .{ .name = "test-peers", .desc = "Test peer manager persistence", .path = "src/p2p/peers.zig" },
        .{ .name = "test-ux", .desc = "Test UX helpers", .path = "src/util/ux.zig" },
        .{ .name = "test-nix", .desc = "Test Nix builder wrapper", .path = "src/engine/nix.zig" },
    };

    const test_unit_step = b.step("test-units", "Run supporting module unit tests (sequential system commands)");
    const opt_flag = switch (optimize) {
        .Debug => "-ODebug",
        .ReleaseSafe => "-OReleaseSafe",
        .ReleaseFast => "-OReleaseFast",
        .ReleaseSmall => "-OReleaseSmall",
    };
    var prev_unit: ?*std.Build.Step = null;
    inline for (unit_modules) |u| {
        const cmd = b.addSystemCommand(&.{ zig_exe, "test", opt_flag, u.path });
        if (prev_unit) |p| cmd.step.dependOn(p);
        prev_unit = &cmd.step;
        test_unit_step.dependOn(&cmd.step);
    }

    // --- MAIN EXECUTABLE ---
    // FIX: Wrap source config in root_module
    const exe = b.addExecutable(.{
        .name = "myco",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Import the library module so main.zig can do @import("myco")
    exe.root_module.addImport("myco", myco_module);
    
    b.installArtifact(exe);
}
