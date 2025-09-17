var editor: Editor = undefined;

pub const _start = {}; // Instruct std.start not to generate an entrypoint
export fn SDL_AppInit(
    _: **anyopaque,
    argc: c_int,
    argv: [*:null]const ?[*:0]const u8,
) c.SDL_AppResult {
    // TODO: pass args to kak
    _ = argc;
    _ = argv;

    return appResult(editor.init(gpa));
}

export fn SDL_AppQuit(_: *anyopaque, _: c.SDL_AppResult) void {
    editor.deinit(gpa);
    if (gpa_is_debug) {
        _ = debug_allocator.deinit();
    }
}

export fn SDL_AppEvent(_: *anyopaque, event: *c.SDL_Event) c.SDL_AppResult {
    return appResult(editor.event(gpa, event));
}
export fn SDL_AppIterate(_: *anyopaque) c.SDL_AppResult {
    return appResult(editor.frame());
}

fn appResult(err_or_void: anyerror!void) c.SDL_AppResult {
    if (err_or_void) |_| {
        return c.SDL_APP_CONTINUE;
    } else |err| switch (err) {
        error.Exit => return c.SDL_APP_SUCCESS,
        else => {
            std.log.err("{s}", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            return c.SDL_APP_FAILURE;
        },
    }
}

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .rpc_recv, .level = logLevel(.info, .warn) },
        .{ .scope = .rpc_send, .level = logLevel(.info, .warn) },
    },
};
fn logLevel(debug: std.log.Level, release: std.log.Level) std.log.Level {
    return switch (@import("builtin").mode) {
        .Debug => debug,
        else => release,
    };
}

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const gpa_is_debug = switch (@import("builtin").mode) {
    .Debug => true,
    else => false,
};
const gpa = if (gpa_is_debug)
    debug_allocator.allocator()
else
    std.heap.c_allocator;

const std = @import("std");
const c = @import("c.zig").c;

const rpc = @import("rpc.zig");
const Editor = @import("Editor.zig");
