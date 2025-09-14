const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_emit = b.option(bool, "no-emit", "Check for compile errors without emitting any code") orelse false;

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "but",
        .root_module = mod,
    });
    if (no_emit) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        b.step("run", "Run the app").dependOn(&run_cmd.step);
    }
}
