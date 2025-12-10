const std = @import("std");

pub const BackupManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BackupManager {
        return .{ .allocator = allocator };
    }

    pub fn createSnapshot(self: *BackupManager, service_name: []const u8) !void {
        const state_dir = try std.fmt.allocPrint(self.allocator, "/var/lib/myco/{s}", .{service_name});
        defer self.allocator.free(state_dir);

        const backup_dir = "/var/lib/myco/backups";
        std.fs.makeDirAbsolute(backup_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const timestamp = std.time.timestamp();
        const tar_filename = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{d}.tar.gz", .{backup_dir, service_name, timestamp});
        defer self.allocator.free(tar_filename);

        const svc_unit = try std.fmt.allocPrint(self.allocator, "myco-{s}", .{service_name});
        defer self.allocator.free(svc_unit);

        std.debug.print("[*] Snapshotting {s} to {s}...\n", .{service_name, tar_filename});

        // 1. Stop Service
        std.debug.print("[*] Stopping service...\n", .{});
        try self.run(&[_][]const u8{"systemctl", "stop", svc_unit});

        // 2. Create Archive
        // Strategy: cd into the state_dir and archive '.'
        // cmd: tar -czf <file> -C <state_dir> .
        std.debug.print("[*] Archiving data...\n", .{});
        
        std.fs.accessAbsolute(state_dir, .{}) catch {
            std.debug.print("[!] Data directory {s} does not exist. Aborting.\n", .{state_dir});
            _ = self.run(&[_][]const u8{"systemctl", "start", svc_unit}) catch {};
            return error.DataDirectoryNotFound;
        };

        const tar_args = &[_][]const u8{
            "tar",
            "-czf", tar_filename,
            "-C", state_dir,     // Change to specific service directory
            "."                  // Archive everything inside it
        };
        
        const tar_result = self.run(tar_args);

        // 3. Start Service
        std.debug.print("[*] Restarting service...\n", .{});
        try self.run(&[_][]const u8{"systemctl", "start", svc_unit});

        try tar_result;
        std.debug.print("[+] Snapshot Complete: {s}\n", .{tar_filename});
    }

    pub fn restoreSnapshot(self: *BackupManager, service_name: []const u8, snapshot_path: []const u8) !void {
        // --- PRE-FLIGHT CHECKS (CRITICAL) ---
        // Verify the backup file exists BEFORE we stop services or wipe data
        std.fs.cwd().access(snapshot_path, .{}) catch |err| {
            std.debug.print("[!] Backup file not found: {s}\n", .{snapshot_path});
            return err; // Abort immediately
        };

        const state_dir = try std.fmt.allocPrint(self.allocator, "/var/lib/myco/{s}", .{service_name});
        defer self.allocator.free(state_dir);

        const svc_unit = try std.fmt.allocPrint(self.allocator, "myco-{s}", .{service_name});
        defer self.allocator.free(svc_unit);

        std.debug.print("[!] RESTORING {s} from {s}\n", .{service_name, snapshot_path});
        
        // 1. Stop Service
        std.debug.print("[*] Stopping service...\n", .{});
        try self.run(&[_][]const u8{"systemctl", "stop", svc_unit});

        // 2. Wipe Current Data
        std.debug.print("[*] Wiping current data...\n", .{});
        std.fs.deleteTreeAbsolute(state_dir) catch |err| {
            if (err != error.FileNotFound) {
                std.debug.print("[!] Failed to wipe data: {}\n", .{err});
                // Attempt restart before failing
                _ = self.run(&[_][]const u8{"systemctl", "start", svc_unit}) catch {};
                return err;
            }
        };

        // 3. Recreate Directory
        std.debug.print("[*] Recreating directory structure...\n", .{});
        try std.fs.makeDirAbsolute(state_dir);

        // 4. Extract Archive
        std.debug.print("[*] Extracting archive...\n", .{});
        
        const tar_args = &[_][]const u8{
            "tar",
            "-xzf", snapshot_path,
            "-C", state_dir 
        };

        const tar_result = self.run(tar_args);

        // 5. Start Service
        std.debug.print("[*] Restarting service...\n", .{});
        try self.run(&[_][]const u8{"systemctl", "start", svc_unit});

        try tar_result;
        std.debug.print("[+] Restore Complete.\n", .{});
    }

    fn run(self: *BackupManager, argv: []const []const u8) !void {
        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        const term = try child.spawnAndWait();
        if (term != .Exited or term.Exited != 0) return error.CommandFailed;
    }
};
