const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const unicorn = b.addModule("unicorn", .{
        .root_source_file = b.path("src/unicorn.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unicorn.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unicorn", .module = unicorn }},
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
