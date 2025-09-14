const Editor = @This();

mode: Mode,
size: [2]u32,
kak: Kakoune,

pub fn init(editor: *Editor, gpa: std.mem.Allocator) !void {
    editor.* = .{
        .mode = .normal,
        .size = .{ 0, 0 },
        .kak = undefined,
    };
    try editor.kak.init(gpa);
}
pub fn deinit(editor: *Editor) void {
    editor.kak.deinit();
}

pub fn frame(editor: *Editor) !dvui.App.Result {
    const writer = &editor.kak.stdin.interface;

    const text_layout = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .expand = .both });
    defer text_layout.deinit();

    // Get the current window size
    const rect = dvui.windowRectPixels();
    {
        const lc = editor.pixelsToGrid(.{ .x = rect.w, .y = rect.h });
        if (editor.size[0] != lc[0] or editor.size[1] != lc[1]) {
            editor.size = lc;
            try rpc.send(.{ .resize = .{ .rows = lc[0], .columns = lc[1] } }, writer);
        }
    }

    // Get input
    // TODO: deduplicate scroll events
    for (dvui.events()) |*ev| {
        if (!dvui.eventMatchSimple(ev, &text_layout.wd)) continue;
        switch (ev.evt) {
            .key => |k| if (editor.mode == .normal) {
                const key = Key.init(k) orelse continue;
                try rpc.send(.{ .keys = &.{.{ .key = key }} }, writer);
            },
            .text => |t| if (editor.mode != .normal) {
                try rpc.send(.{ .keys = &.{.{ .text = t.txt }} }, writer);
            },
            .mouse => |m| switch (m.action) {
                .press => {
                    const btn = Key.getButton(m.button) orelse continue;
                    const lc = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .mouse_press = .{
                        .button = btn,
                        .line = lc[0],
                        .column = lc[1],
                    } }, writer);
                },
                .release => {
                    const btn = Key.getButton(m.button) orelse continue;
                    const lc = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .mouse_release = .{
                        .button = btn,
                        .line = lc[0],
                        .column = lc[1],
                    } }, writer);
                },
                .position => {
                    const lc = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .mouse_move = .{
                        .line = lc[0],
                        .column = lc[1],
                    } }, writer);
                },
                .wheel_x => continue,
                .wheel_y => |amount| {
                    const lc = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .scroll = .{
                        .amount = @intFromFloat(amount),
                        .line = lc[0],
                        .column = lc[1],
                    } }, writer);
                },
                .motion => continue,
                .focus => continue,
            },
        }
        ev.handle(@src(), &text_layout.wd);
    }
    try writer.flush();

    editor.processUiCalls(10 * std.time.ns_per_ms) catch |err| switch (err) {
        error.EndOfStream => return .close,
        else => |e| return e,
    };

    return .ok;
}

fn pixelsToGrid(editor: Editor, p: dvui.Point.Physical) [2]u32 {
    // TODO: compute based on font size
    _ = editor;
    return .{
        @intFromFloat(p.x / 16),
        @intFromFloat(p.y / 10),
    };
}

const Mode = enum { normal, insert };

fn processUiCalls(editor: *Editor, timeout: u64) !void {
    const arena = dvui.currentWindow().arena();
    var timer: std.time.Timer = try .start();
    var time_taken: u64 = 0;
    while (try editor.kak.nextUiCall(arena, timeout - time_taken)) |call| : ({
        time_taken = timer.read();
        if (time_taken >= timeout) break;
    }) {
        switch (call) {
            .draw => {},
            .draw_status => {},
            .info_hide => {},
            .info_show => {},
            .menu_hide => {},
            .menu_show => {},
            .refresh => {},
            .set_cursor => {},
            .set_ui_options => |opts| {
                std.log.debug("set_ui_options", .{});
                if (opts.options != .object) return error.InvalidRequest;
                for (opts.options.object.keys(), opts.options.object.values()) |key, value| {
                    std.log.debug("{s}: {f}", .{ key, std.json.fmt(value, .{}) });
                }
            },
        }
    }
}

const std = @import("std");
const dvui = @import("dvui");

// keep-sorted start
const Kakoune = @import("Kakoune.zig");
const Key = @import("Key.zig");
const rpc = @import("rpc.zig");
// keep-sorted end
