const Editor = @This();

mode: Mode,
size: [2]u32,
kak: Kakoune,
buffer: Text,
status_line: Text,
mode_line: Text,

const Text = struct {
    buf: std.ArrayList(u8),
    atoms: std.ArrayList(Atom),

    const Atom = struct {
        start: u32,
        len: u32,
        fg: dvui.Color,
        bg: dvui.Color,
        underline: dvui.Color,
        flags: Flags,
    };
    const Flags = packed struct {
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
    };

    pub const empty: Text = .{
        .buf = .empty,
        .atoms = .empty,
    };

    pub fn set(text: *Text, gpa: std.mem.Allocator, lines: []const rpc.Line, default_face: rpc.Face) !void {
        text.buf.clearRetainingCapacity();
        text.atoms.clearRetainingCapacity();

        const default_fg = parseColor(default_face.fg, dvui.themeGet().text);
        const default_bg = parseColor(default_face.bg, dvui.Color.transparent);
        const default_underline = parseColor(default_face.underline, dvui.themeGet().text);

        for (lines) |line| {
            for (line) |atom| {
                var flags: Flags = .{};
                for (atom.face.attributes) |attr| {
                    switch (attr) {
                        inline else => |a| @field(flags, @tagName(a)) = true,
                    }
                }

                try text.atoms.append(gpa, .{
                    .start = std.math.cast(u32, text.buf.items.len) orelse return error.Overflow,
                    .len = std.math.cast(u32, atom.contents.len) orelse return error.Overflow,

                    .fg = parseColor(atom.face.fg, default_fg),
                    .bg = parseColor(atom.face.bg, default_bg),
                    .underline = parseColor(atom.face.underline, default_underline),
                    .flags = flags,
                });
                try text.buf.appendSlice(gpa, atom.contents);
            }
        }
    }

    fn parseColor(c: []const u8, default: dvui.Color) dvui.Color {
        // TODO: hex colors
        if (std.mem.eql(u8, c, "default")) return default;
        return colors.get(c) orelse default;
    }

    pub fn deinit(text: *Text, gpa: std.mem.Allocator) void {
        text.buf.deinit(gpa);
        text.atoms.deinit(gpa);
    }

    pub fn draw(text: Text, src: std.builtin.SourceLocation, options: dvui.Options) !void {
        const layout = dvui.textLayout(src, .{ .break_lines = false }, options);
        defer layout.deinit();

        for (text.atoms.items) |atom| {
            const str = text.buf.items[atom.start .. atom.start + atom.len];
            layout.addText(str, .{
                .color_text = atom.fg,
                .color_fill = atom.bg,
                // ...
            });
        }
        layout.addTextDone(options);
    }
};

pub fn init(editor: *Editor, gpa: std.mem.Allocator, win: *dvui.Window) !void {
    editor.* = .{
        .mode = .normal,
        .size = .{ 0, 0 },
        .kak = undefined,
        .buffer = .empty,
        .status_line = .empty,
        .mode_line = .empty,
    };
    try editor.kak.init(gpa, win);
}
pub fn deinit(editor: *Editor, gpa: std.mem.Allocator) void {
    editor.kak.deinit();
    editor.buffer.deinit(gpa);
    editor.status_line.deinit(gpa);
    editor.mode_line.deinit(gpa);
}

pub fn frame(editor: *Editor, gpa: std.mem.Allocator) !dvui.App.Result {
    const box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    dvui.focusWidget(box.wd.id, null, null);

    try editor.processEvents(box.data());
    editor.processUiCalls(gpa) catch |err| switch (err) {
        error.EndOfStream => return .close,
        else => |e| return e,
    };

    try editor.buffer.draw(@src(), .{ .expand = .both });
    {
        const status_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer status_box.deinit();
        try editor.status_line.draw(@src(), .{ .gravity_x = 0 });
        try editor.mode_line.draw(@src(), .{ .gravity_x = 1 });
    }

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

fn pixelsToGrid(editor: Editor, p: dvui.Point.Physical) [2]u32 {
    // TODO: compute based on font size
    _ = editor;
    return .{
        @intFromFloat(p.x / 16),
        @intFromFloat(p.y / 10),
    };
}

const Mode = enum { normal, insert };

fn processEvents(editor: *Editor, wd: *dvui.WidgetData) !void {
    const writer = &editor.kak.stdin.interface;

    // Detect resize
    {
        const rect = dvui.windowRectPixels();
        const lc = editor.pixelsToGrid(.{ .x = rect.w, .y = rect.h });
        if (editor.size[0] != lc[0] or editor.size[1] != lc[1]) {
            editor.size = lc;
            try rpc.send(.{ .resize = .{ .rows = lc[0], .columns = lc[1] } }, writer);
        }
    }

    // TODO: deduplicate scroll events
    var update_pos = false;
    dvui.wantTextInput(wd.borderRectScale().r.toNatural()); // TODO: provide more useful rect
    for (dvui.events()) |*ev| {
        if (!dvui.eventMatchSimple(ev, wd)) continue;
        switch (ev.evt) {
            .key => |k| if (k.action != .up) {
                const key = input.KeyOrText.fromKey(k) orelse continue;
                try rpc.send(.{ .keys = &.{key} }, writer);
            },
            .text => |t| {
                const text: input.KeyOrText = .{ .text = t.txt };
                try rpc.send(.{ .keys = &.{text} }, writer);
            },
            .mouse => |m| switch (m.action) {
                .press => {
                    const btn = input.button(m.button) orelse continue;
                    const line, const col = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .mouse_press = .{
                        .button = btn,
                        .line = line,
                        .column = col,
                    } }, writer);
                },
                .release => {
                    const btn = input.button(m.button) orelse continue;
                    const line, const col = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .mouse_release = .{
                        .button = btn,
                        .line = line,
                        .column = col,
                    } }, writer);
                },
                .position => if (update_pos) {
                    const line, const col = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .mouse_move = .{
                        .line = line,
                        .column = col,
                    } }, writer);
                },
                .wheel_x => continue,
                .wheel_y => |amount| {
                    const line, const col = editor.pixelsToGrid(m.p);
                    try rpc.send(.{ .scroll = .{
                        .amount = @intFromFloat(amount),
                        .line = line,
                        .column = col,
                    } }, writer);
                },
                .motion => update_pos = true,
                .focus => continue,
            },
        }
        ev.handle(@src(), wd);
    }
    try writer.flush();
}

fn processUiCalls(editor: *Editor, gpa: std.mem.Allocator) !void {
    const calls = try editor.kak.acquireUiCalls();
    defer editor.kak.releaseUiCalls();

    for (calls) |call| {
        switch (call) {
            .draw => |args| try editor.buffer.set(gpa, args.lines, args.default_face),
            .draw_status => |args| {
                try editor.status_line.set(gpa, &.{args.status_line}, args.default_face);
                try editor.mode_line.set(gpa, &.{args.mode_line}, args.default_face);
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

const std = @import("std");
const dvui = @import("dvui");

// keep-sorted start
const Kakoune = @import("Kakoune.zig");
const input = @import("input.zig");
const rpc = @import("rpc.zig");
// keep-sorted end
