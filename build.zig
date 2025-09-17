pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_emit = b.option(bool, "no-emit", "Check for compile errors without emitting any code") orelse false;
    const use_llvm = b.option(bool, "llvm", "Force usage of LLVM backend");
    const strip = b.option(bool, "strip", "Strip debug info from the binary");
    const bundle_font = b.option(bool, "bundle-font", "Bundle default font (Annotation Mono) into the binary") orelse false;

    const opts = b.addOptions();
    opts.addOption(std.SemanticVersion, "version", try .parse(zon.version));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = opts.createModule() },
        },
        .link_libc = true,
        .strip = strip,
    });
    mod.linkSystemLibrary("sdl3", .{});
    mod.linkSystemLibrary("sdl3-ttf", .{});
    mod.linkSystemLibrary("fontconfig", .{});

    opts.addOption(bool, "bundle_font", bundle_font);
    if (bundle_font) {
        if (b.lazyDependency("annotation_mono", .{})) |dep| {
            mod.addAnonymousImport("default_font.ttf", .{
                .root_source_file = dep.path("dist/variable/AnnotationMono-VF.ttf"),
            });
        }
    }

    const exe = b.addExecutable(.{
        .name = "but",
        .root_module = mod,
        .use_llvm = use_llvm,
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

const std = @import("std");
const zon = @import("build.zig.zon");
