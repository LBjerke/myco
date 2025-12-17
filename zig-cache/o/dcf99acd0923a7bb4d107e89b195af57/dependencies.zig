pub const packages = struct {
    pub const @"N-V-__8AAMeOlQEipHjcyu0TCftdAi9AQe7EXUDJOoVe0k-t" = struct {
        pub const available = false;
    };
    pub const @"diffz-0.0.1-G2tlIQrOAQCfH15jdyaLyrMgV8eGPouFhkCeYFTmJaLk" = struct {
        pub const build_root = "zig-cache/p/diffz-0.0.1-G2tlIQrOAQCfH15jdyaLyrMgV8eGPouFhkCeYFTmJaLk";
        pub const build_zig = @import("diffz-0.0.1-G2tlIQrOAQCfH15jdyaLyrMgV8eGPouFhkCeYFTmJaLk");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"known_folders-0.0.0-Fy-PJkfRAAAVdptXWXBspIIC7EkVgLgWozU5zIk5Zgcy" = struct {
        pub const build_root = "zig-cache/p/known_folders-0.0.0-Fy-PJkfRAAAVdptXWXBspIIC7EkVgLgWozU5zIk5Zgcy";
        pub const build_zig = @import("known_folders-0.0.0-Fy-PJkfRAAAVdptXWXBspIIC7EkVgLgWozU5zIk5Zgcy");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"lsp_kit-0.1.0-bi_PL04yCgAxLsF0hH2a5sZKT84MGQaKXouw2jvCE8Nl" = struct {
        pub const build_root = "zig-cache/p/lsp_kit-0.1.0-bi_PL04yCgAxLsF0hH2a5sZKT84MGQaKXouw2jvCE8Nl";
        pub const build_zig = @import("lsp_kit-0.1.0-bi_PL04yCgAxLsF0hH2a5sZKT84MGQaKXouw2jvCE8Nl");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zlinter-0.0.1-OjQ08ZOnCwBx9meqm2cUjOkYUBeTUpKhQ3ERnVPg6ARc" = struct {
        pub const build_root = "zig-cache/p/zlinter-0.0.1-OjQ08ZOnCwBx9meqm2cUjOkYUBeTUpKhQ3ERnVPg6ARc";
        pub const build_zig = @import("zlinter-0.0.1-OjQ08ZOnCwBx9meqm2cUjOkYUBeTUpKhQ3ERnVPg6ARc");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zls", "zls-0.15.0-rmm5fkjqIwDZpmDHyKwxa9K2gcI3FPaGVFPwjYWFBM5B" },
        };
    };
    pub const @"zls-0.15.0-rmm5fkjqIwDZpmDHyKwxa9K2gcI3FPaGVFPwjYWFBM5B" = struct {
        pub const build_root = "zig-cache/p/zls-0.15.0-rmm5fkjqIwDZpmDHyKwxa9K2gcI3FPaGVFPwjYWFBM5B";
        pub const build_zig = @import("zls-0.15.0-rmm5fkjqIwDZpmDHyKwxa9K2gcI3FPaGVFPwjYWFBM5B");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "known_folders", "known_folders-0.0.0-Fy-PJkfRAAAVdptXWXBspIIC7EkVgLgWozU5zIk5Zgcy" },
            .{ "diffz", "diffz-0.0.1-G2tlIQrOAQCfH15jdyaLyrMgV8eGPouFhkCeYFTmJaLk" },
            .{ "lsp_kit", "lsp_kit-0.1.0-bi_PL04yCgAxLsF0hH2a5sZKT84MGQaKXouw2jvCE8Nl" },
            .{ "tracy", "N-V-__8AAMeOlQEipHjcyu0TCftdAi9AQe7EXUDJOoVe0k-t" },
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zlinter", "zlinter-0.0.1-OjQ08ZOnCwBx9meqm2cUjOkYUBeTUpKhQ3ERnVPg6ARc" },
};
