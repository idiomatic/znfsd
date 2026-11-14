const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libnfsd = b.addModule("libnfsd", .{
        .root_source_file = b.path("src/libnfsd/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const znfsd = b.addExecutable(.{
        .name = "znfsd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/znfsd/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libnfsd", .module = libnfsd },
            },
        }),
    });
    znfsd.root_module.link_libc = true;
    znfsd.root_module.addIncludePath(b.path("vendor/sqlite"));
    znfsd.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-fno-sanitize=undefined",
        },
    });
    b.installArtifact(znfsd);

    const run = b.addRunArtifact(znfsd);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run znfsd").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests");
    const filters = b.option([]const []const u8, "test-filter", "Run only tests whose names contain this (repeatable)") orelse &.{};
    for ([_]*std.Build.Module{ libnfsd, znfsd.root_module }) |module| {
        const tests = b.addTest(.{ .root_module = module, .filters = filters });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
