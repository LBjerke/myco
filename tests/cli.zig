// CLI scaffolder tests: ensure template generation works and is idempotently safe.
// This file contains unit tests for the `myco init` CLI command's scaffolding
// functionality. It verifies that the command correctly generates initial
// project configuration files (`flake.nix` and `myco.json`) within a
// sandboxed environment. A crucial aspect of these tests is to ensure that
// the scaffolding process is idempotently safe, meaning that attempting to
// generate files a second time will gracefully fail with a
// `PathAlreadyExists` error, thereby preventing accidental overwrites
// of existing project files.
//
const std = @import("std");
const myco = @import("myco");
const Scaffolder = myco.cli.init.Scaffolder;

test "Phase 4: Scaffolder Generation & Safety" {
    // FIX: Added the missing dot '.' before {}
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sandbox_dir = tmp.dir;

    // 2. Initialize Logic with Sandbox
    const scaffolder = Scaffolder.init(sandbox_dir);

    // 3. EXECUTE GENERATION
    try scaffolder.generate();

    // 4. VERIFY: 'flake.nix'
    {
        const file = try sandbox_dir.openFile("flake.nix", .{});
        defer file.close();
        const stat = try file.stat();
        // It should have content
        try std.testing.expect(stat.size > 0);
    }

    // 5. VERIFY: 'myco.json'
    {
        const file = try sandbox_dir.openFile("myco.json", .{});
        defer file.close();
        const stat = try file.stat();
        try std.testing.expect(stat.size > 0);
    }

    // 6. TEST SAFETY (The "Don't Overwrite" Check)
    // Running generate() a second time MUST fail.
    const result = scaffolder.generate();

    // We expect an error, specifically PathAlreadyExists
    try std.testing.expectError(error.PathAlreadyExists, result);
}
