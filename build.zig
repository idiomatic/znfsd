const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libnfsd = b.addModule("libnfsd", .{
        .root_source_file = b.path("src/libnfsd/root.zig"),
        .target = target,
        .optimize = optimize,
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
    b.installArtifact(znfsd);

    const run = b.addRunArtifact(znfsd);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run znfsd").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ libnfsd, znfsd.root_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
