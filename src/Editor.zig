const Editor = @This();

mode: Mode,
size: [2]u32,
kak: Kakoune,
lines: ?struct {
    text: []const u8,
    cmds: []const Cmd,
},
status: ?struct {
    text: []const u8,
    cmds: []const Cmd,
},

const Cmd = struct {
    start: u32,
    len: u32,
    fg: dvui.Color,
    bg: dvui.Color,
    flags: packed struct {
        underline: bool = false,
        curly_underline: bool = false,
        double_underline: bool = false,
        reverse: bool = false,
        blink: bool = false,
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        final_fg: bool = false,
        final_bg: bool = false,
        final_attr: bool = false,
        end: bool = false,
    },
};

pub fn init(editor: *Editor, gpa: std.mem.Allocator) !void {
    editor.* = .{
        .mode = .normal,
        .size = .{ 0, 0 },
        .kak = undefined,
        .lines = null,
        .status = null,
    };
    try editor.kak.init(gpa);
}
pub fn deinit(editor: *Editor) void {
    editor.kak.deinit();
    if (editor.lines) |lines| {
        const cw = dvui.currentWindow();
        cw.gpa.free(lines.text);
        cw.gpa.free(lines.cmds);
    }
    if (editor.status) |status| {
        const cw = dvui.currentWindow();
        cw.gpa.free(status.text);
        cw.gpa.free(status.cmds);
    }
}

pub fn frame(editor: *Editor) !dvui.App.Result {
    const writer = &editor.kak.stdin.interface;

    // Draw main UI
    {
        const status_layout = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .expand = .horizontal, .gravity_y = 1 });
        defer status_layout.deinit();

        if (editor.status) |status| {
            for (status.cmds) |cmd| {
                const text = status.text[cmd.start .. cmd.start + cmd.len];
                status_layout.addText(text, .{
                    .color_text = cmd.fg,
                    .color_fill = cmd.bg,
                    // ...
                });
                if (cmd.flags.end) status_layout.addText("\n", .{});
            }
        }
    }

    const text_layout = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .expand = .both });
    defer text_layout.deinit();

    if (editor.lines) |lines| {
        for (lines.cmds) |cmd| {
            const text = lines.text[cmd.start .. cmd.start + cmd.len];
            text_layout.addText(text, .{
                .color_text = cmd.fg,
                .color_fill = cmd.bg,
                // ...
            });
            if (cmd.flags.end) text_layout.addText("\n", .{});
        }
    }

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
            .key => |k| if (editor.mode == .normal and k.action != .up) {
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

    std.log.debug("before rpc", .{});
    // Handle events
    editor.processUiCalls(10 * std.time.ns_per_ms) catch |err| switch (err) {
        error.EndOfStream => return .close,
        else => |e| return e,
    };

    return .ok;
}

const colors: std.StaticStringMap(dvui.Color) = .initComptime(.{
    .{ "black", dvui.Color.black },
    .{ "red", dvui.Color.red },
    .{ "green", dvui.Color.green },
    .{ "yellow", dvui.Color.yellow },
    .{ "blue", dvui.Color.blue },
    .{ "magenta", dvui.Color.magenta },
    .{ "cyan", dvui.Color.cyan },
    .{ "white", dvui.Color.white },
    .{ "bright-black", dvui.Color.gray },
    .{ "bright-red", dvui.Color.red },
    .{ "bright-green", dvui.Color.green },
    .{ "bright-yellow", dvui.Color.yellow },
    .{ "bright-blue", dvui.Color.blue },
    .{ "bright-magenta", dvui.Color.magenta },
    .{ "bright-cyan", dvui.Color.cyan },
    .{ "bright-white", dvui.Color.white },
});

fn from_color(c: []const u8, default: dvui.Color) dvui.Color {
    if (std.mem.eql(u8, c, "default")) return default;
    return colors.get(c) orelse default;
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
    const cw = dvui.currentWindow();
    var timer: std.time.Timer = try .start();
    var time_taken: u64 = 0;
    while (try editor.kak.nextUiCall(cw.arena(), timeout - time_taken)) |call| : ({
        time_taken = timer.read();
        if (time_taken >= timeout) break;
    }) {
        switch (call) {
            .draw => |draw| {
                if (editor.lines) |lines| {
                    cw.gpa.free(lines.text);
                    cw.gpa.free(lines.cmds);
                }

                var text: std.ArrayList(u8) = .empty;
                var cmds: std.ArrayList(Cmd) = .empty;
                const fg = from_color(draw.default_face.fg, dvui.Color.white);
                const bg = from_color(draw.default_face.bg, dvui.Color.black);

                for (draw.lines) |line| try processLine(cw.gpa, line, &text, &cmds, fg, bg);

                editor.lines = .{
                    .text = try text.toOwnedSlice(cw.gpa),
                    .cmds = try cmds.toOwnedSlice(cw.gpa),
                };
            },
            .draw_status => |draw_status| {
                if (editor.status) |status| {
                    cw.gpa.free(status.text);
                    cw.gpa.free(status.cmds);
                }

                var text: std.ArrayList(u8) = .empty;
                var cmds: std.ArrayList(Cmd) = .empty;
                const fg = from_color(draw_status.default_face.fg, dvui.Color.white);
                const bg = from_color(draw_status.default_face.bg, dvui.Color.black);

                try processLine(cw.gpa, draw_status.status_line, &text, &cmds, fg, bg);

                editor.status = .{
                    .text = try text.toOwnedSlice(cw.gpa),
                    .cmds = try cmds.toOwnedSlice(cw.gpa),
                };
            },
            .info_hide => {},
            .info_show => {},
            .menu_hide => {},
            .menu_select => {},
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

fn processLine(
    gpa: std.mem.Allocator,
    line: rpc.Line,
    text: *std.ArrayList(u8),
    cmds: *std.ArrayList(Cmd),
    fg: dvui.Color,
    bg: dvui.Color,
) !void {
    for (line, 0..) |atom, i| {
        // TODO: handle face underline color
        var flags: @FieldType(Cmd, "flags") = .{};
        for (atom.face.attributes) |attr| {
            switch (attr) {
                inline else => |a| @field(flags, @tagName(a)) = true,
            }
        }
        flags.end = i == line.len - 1;
        try cmds.append(gpa, .{
            .start = @intCast(text.items.len),
            .len = @intCast(atom.contents.len),
            .fg = from_color(atom.face.fg, fg),
            .bg = from_color(atom.face.bg, bg),
            .flags = flags,
        });
        try text.appendSlice(gpa, atom.contents);
    }
}

const std = @import("std");
const dvui = @import("dvui");

// keep-sorted start
const Kakoune = @import("Kakoune.zig");
const Key = @import("Key.zig");
const rpc = @import("rpc.zig");
// keep-sorted end
