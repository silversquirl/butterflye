const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_emit = b.option(bool, "no-emit", "Check for compile errors without emitting any code") orelse false;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
        .link_libc = true,
    });
    mod.linkSystemLibrary("sdl3", .{});
    mod.linkSystemLibrary("sdl3-ttf", .{});
    mod.linkSystemLibrary("fontconfig", .{});

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
