const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("arrowz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run native Zig tests").dependOn(&b.addRunArtifact(tests).step);
    const fixture = b.addLibrary(.{
        .name = "arrowz_fixture",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "arrowz", .module = module }},
        }),
    });
    b.step("interop", "Build test-only C ABI fixture").dependOn(&b.addInstallArtifact(fixture, .{}).step);
    const example = b.addExecutable(.{
        .name = "native-array",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/native_array.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "arrowz", .module = module }},
        }),
    });
    b.step("example", "Run native array example").dependOn(&b.addRunArtifact(example).step);
}
