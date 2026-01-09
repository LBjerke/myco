const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const max_peers = b.option(usize, "max-peers", "Max peers (node cap)") orelse 256;
    const max_services = b.option(usize, "max-services", "Max services (jobs) per node") orelse 512;

    const build_options = b.addOptions();
    build_options.addOption(usize, "max_peers", max_peers);
    build_options.addOption(usize, "max_services", max_services);

    // 1. Define the 'myco' Library Module (src/lib.zig)
    const myco_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
    });
    // Allow internal files to reference the public surface via @import("myco").
    myco_module.addImport("myco", myco_module);
    myco_module.addOptions("build_options", build_options);

    // --- TEST 1: SIMULATION ---
    const sim_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/simulation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sim_test.root_module.addOptions("build_options", build_options);
    sim_test.linkLibC();
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
        const opt_flag = if (std.mem.eql(u8, step_name, "sim-50-realworld")) "-OReleaseFast" else "-ODebug";
        const cmd = b.addSystemCommand(&.{
            zig_exe,
            "test",
            opt_flag,
            "--dep",
            "build_options",
            "--dep",
            "myco",
            "-Mroot=tests/simulation.zig",
            "-Mbuild_options=src/build_options.zig",
            "--dep",
            "build_options",
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
    engine_test.root_module.addOptions("build_options", build_options);
    engine_test.linkLibC();
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
    cli_test.root_module.addOptions("build_options", build_options);
    cli_test.linkLibC();
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
    crdt_test.root_module.addOptions("build_options", build_options);
    crdt_test.linkLibC();
    crdt_test.root_module.addImport("myco", myco_module);
    const run_crdt_test = b.addRunArtifact(crdt_test);
    const test_crdt_step = b.step("test-crdt", "Test CRDT Sync Logic");
    test_crdt_step.dependOn(&run_crdt_test.step);

    // --- TEST 5: UNIT TESTS (via lib.zig) ---
    const unit_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"), // Rooted at lib.zig
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_test.root_module.addOptions("build_options", build_options);
    unit_test.linkLibC();
    // src/lib.zig is the myco module itself, so internal files should use relative imports.
    // The myco_module import is not needed here.

    const run_unit_test = b.addRunArtifact(unit_test);
    const test_unit_step = b.step("test-units", "Run unit tests");
    test_unit_step.dependOn(&run_unit_test.step);

    // --- MAIN EXECUTABLE ---
    const exe = b.addExecutable(.{
        .name = "myco",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();
    exe.root_module.addOptions("build_options", build_options);

    // Import the library module so main.zig can do @import("myco")
    exe.root_module.addImport("myco", myco_module);

    b.installArtifact(exe);
}
