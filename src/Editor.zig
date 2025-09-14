mode: Mode,
size: [2]u32,

fn write(writer: *std.fs.File.Writer, method: rpc.KakMethod) !void {
    try rpc.send(&writer.interface, method);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

pub fn frame(editor: *@This()) !void {
    const w = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .expand = .both });
    defer w.deinit();

    var buf: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);

    // Get the current window size
    const rect = dvui.windowRectPixels();
    {
        const lc = editor.pos_to_line_col(.{ .x = rect.w, .y = rect.h });
        if (editor.size[0] != lc[0] or editor.size[1] != lc[1]) {
            editor.size = lc;
            try write(&writer, .{ .resize = .{ .rows = lc[0], .columns = lc[1] } });
        }
    }

    // Get input
    // TODO: deduplicate scroll events
    for (dvui.events()) |*ev| {
        if (!dvui.eventMatchSimple(ev, &w.wd)) continue;
        switch (ev.evt) {
            .key => |k| if (editor.mode == .normal) {
                const key = Key.init(k) orelse continue;
                try write(&writer, .{ .keys = &.{.{ .key = key }} });
            },
            .text => |t| if (editor.mode == .insert) {
                try write(&writer, .{ .keys = &.{.{ .text = t.txt }} });
            },
            .mouse => |m| switch (m.action) {
                .press => {
                    const btn = Key.getButton(m.button) orelse continue;
                    const lc = editor.pos_to_line_col(m.p);
                    try write(&writer, .{ .mouse_press = .{
                        .button = btn,
                        .line = lc[0],
                        .column = lc[1],
                    } });
                },
                .release => {
                    const btn = Key.getButton(m.button) orelse continue;
                    const lc = editor.pos_to_line_col(m.p);
                    try write(&writer, .{ .mouse_release = .{
                        .button = btn,
                        .line = lc[0],
                        .column = lc[1],
                    } });
                },
                .position => {
                    const lc = editor.pos_to_line_col(m.p);
                    try write(&writer, .{ .mouse_move = .{
                        .line = lc[0],
                        .column = lc[1],
                    } });
                },
                .wheel_x => continue,
                .wheel_y => |amount| {
                    const n = editor.scroll_amount_to_lines(amount);
                    const lc = editor.pos_to_line_col(m.p);
                    try write(&writer, .{ .scroll = .{
                        .amount = n,
                        .line = lc[0],
                        .column = lc[1],
                    } });
                },
                .motion => continue,
                .focus => continue,
            },
        }
        ev.handle(@src(), &w.wd);
    }
    // TODO: send events
}

fn scroll_amount_to_lines(editor: @This(), amount: f32) i32 {
    _ = editor;
    _ = amount;
    return 123;
}

fn pos_to_line_col(editor: @This(), p: dvui.Point.Physical) [2]u32 {
    _ = editor;
    _ = p;
    return .{ 123, 456 };
}

const Mode = enum { normal, insert };

const std = @import("std");
const dvui = @import("dvui");
const rpc = @import("rpc.zig");
const Key = @import("Key.zig");
