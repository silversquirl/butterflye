var editor: Editor = undefined;

fn init() dvui.App.StartOptions {
    return .{
        .size = .{ .w = 800, .h = 600 },
        .title = "window",
    };
}

fn initWindow(win: *dvui.Window) !void {
    win.theme = switch (win.backend.preferredColorScheme() orelse .dark) {
        .dark => dvui.Theme.builtin.adwaita_dark,
        .light => dvui.Theme.builtin.adwaita_light,
    };
    try editor.init(win.gpa);
}

fn deinit() void {
    editor.deinit();
}

fn frame() !dvui.App.Result {
    return editor.frame();
}

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = init },
    .initFn = initWindow,
    .deinitFn = deinit,
    .frameFn = frame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;

const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const std = @import("std");
const dvui = @import("dvui");

const rpc = @import("rpc.zig");
const Editor = @import("Editor.zig");
