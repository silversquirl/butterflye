const Editor = @This();

mode: Mode,
kak: Kakoune,
buffer: Text,
status_line: Text,
mode_line: Text,
cursor: union(enum) {
    prompt: u32,
    buffer: RowCol,
},

event_dedup: struct {
    size: RowCol,
    mouse_pos: RowCol,
},
const RowCol = packed struct(u64) {
    col: u32,
    row: u32,

    pub const invalid: RowCol = .{
        .col = std.math.maxInt(u32),
        .row = std.math.maxInt(u32),
    };

    pub fn fromRpc(p: rpc.Coord) RowCol {
        return .{
            .col = p.column,
            .row = p.line,
        };
    }

    pub fn fromDvui(p: dvui.Point.Physical, font_size_physical: dvui.Size.Physical) RowCol {
        return .{
            .col = @intFromFloat(p.x / font_size_physical.w),
            .row = @intFromFloat(p.y / font_size_physical.h),
        };
    }

    pub fn toDvui(p: RowCol, font_size_physical: dvui.Size.Physical) dvui.Point.Physical {
        return .{
            .x = @as(f32, @floatFromInt(p.col)) * font_size_physical.w,
            .y = @as(f32, @floatFromInt(p.row)) * font_size_physical.h,
        };
    }
};

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

        // TODO: alpha blend
        const default_fg = parseColor(default_face.fg, dvui.themeGet().text);
        const default_bg = parseColor(default_face.bg, .transparent);
        const default_underline = parseColor(default_face.underline, dvui.themeGet().text);

        for (lines) |line| {
            for (line) |atom| {
                // TODO: default face flags; finality
                var flags: Flags = .{};
                for (atom.face.attributes) |attr| {
                    switch (attr) {
                        inline else => |a| @field(flags, @tagName(a)) = true,
                    }
                }

                const start = text.buf.items.len;
                var newlines: usize = 0;
                var pos: usize = 0;
                while (std.mem.indexOfScalarPos(u8, atom.contents, pos, '\n')) |nl| {
                    try text.buf.appendSlice(gpa, atom.contents[pos..nl]);
                    // Insert fake space at end of each line, for selection/cursor highlighting
                    try text.buf.appendSlice(gpa, " \n");
                    newlines += 1;
                    pos = nl + 1;
                }
                try text.buf.appendSlice(gpa, atom.contents[pos..]);

                try text.atoms.append(gpa, .{
                    .start = std.math.cast(u32, start) orelse return error.Overflow,
                    .len = std.math.cast(u32, atom.contents.len +| newlines) orelse return error.Overflow,

                    .fg = parseColor(atom.face.fg, default_fg),
                    .bg = parseColor(atom.face.bg, default_bg),
                    .underline = parseColor(atom.face.underline, default_underline),
                    .flags = flags,
                });
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

    pub fn draw(text: Text, src: std.builtin.SourceLocation, options: dvui.Options) *dvui.TextLayoutWidget {
        const text_layout = dvui.textLayout(src, .{ .break_lines = false }, options);

        for (text.atoms.items) |atom| {
            const str = text.buf.items[atom.start..][0..atom.len];
            text_layout.addText(str, .{
                .color_text = atom.fg,
                .color_fill = atom.bg,
            });
            // TODO: flags
        }
        text_layout.addTextDone(options);

        return text_layout;
    }
};

pub fn init(editor: *Editor, gpa: std.mem.Allocator, win: *dvui.Window) !void {
    editor.* = .{
        .mode = .normal,
        .kak = undefined,
        .buffer = .empty,
        .status_line = .empty,
        .mode_line = .empty,
        .cursor = .{ .buffer = .{ .col = 0, .row = 0 } },
        .event_dedup = .{
            .size = .invalid,
            .mouse_pos = .invalid,
        },
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

    {
        const text_layout = editor.buffer.draw(@src(), .{ .expand = .both });
        defer text_layout.deinit();
        switch (editor.cursor) {
            .buffer => |pos| drawCursor(text_layout.data(), pos),
            else => {},
        }
    }

    {
        const status_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer status_box.deinit();

        {
            const text_layout = editor.status_line.draw(@src(), .{ .gravity_x = 0 });
            defer text_layout.deinit();
            switch (editor.cursor) {
                .prompt => |col| drawCursor(text_layout.data(), .{ .col = col, .row = 0 }),
                else => {},
            }
        }

        {
            const text_layout = editor.mode_line.draw(@src(), .{ .gravity_x = 1 });
            defer text_layout.deinit();
        }
    }

    return .ok;
}

fn drawCursor(wd: *dvui.WidgetData, pos: RowCol) void {
    const rs = wd.contentRectScale();
    const font_size = wd.options.fontGet().sizeM(1, 1);
    const point = pos.toDvui(font_size.scale(rs.s, dvui.Size.Physical));
    const rect = rs.rectToRectScale(.{ .x = point.x - 1, .y = point.y, .w = 1, .h = font_size.h });
    rect.r.fill(.{}, .{ .color = .white });
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

const Mode = enum { normal, insert };

fn processEvents(editor: *Editor, wd: *dvui.WidgetData) !void {
    const writer = &editor.kak.stdin.interface;
    const font_scale = wd.options.fontGet().sizeM(1, 1).scale(wd.contentRectScale().s, dvui.Size.Physical);

    // Detect resize
    {
        const rect = dvui.windowRectPixels();
        const size: RowCol = .fromDvui(.{ .x = rect.w, .y = rect.h }, font_scale);
        if (size != editor.event_dedup.size) {
            editor.event_dedup.size = size;
            try rpc.send(.{ .resize = .{
                .columns = size.col,
                .rows = size.row,
            } }, writer);
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
                    const pos: RowCol = .fromDvui(m.p, font_scale);
                    try rpc.send(.{ .mouse_press = .{
                        .button = btn,
                        .column = pos.col,
                        .line = pos.row,
                    } }, writer);
                },
                .release => {
                    const btn = input.button(m.button) orelse continue;
                    const pos: RowCol = .fromDvui(m.p, font_scale);
                    try rpc.send(.{ .mouse_release = .{
                        .button = btn,
                        .column = pos.col,
                        .line = pos.row,
                    } }, writer);
                },
                .position => {
                    const pos: RowCol = .fromDvui(m.p, font_scale);
                    if (pos != editor.event_dedup.mouse_pos) {
                        editor.event_dedup.mouse_pos = pos;
                        try rpc.send(.{ .mouse_move = .{
                            .column = pos.col,
                            .line = pos.row,
                        } }, writer);
                    }
                },
                .wheel_x => continue,
                .wheel_y => |amount| {
                    const pos: RowCol = .fromDvui(m.p, font_scale);
                    try rpc.send(.{ .scroll = .{
                        .amount = @intFromFloat(amount),
                        .column = pos.col,
                        .line = pos.row,
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
            .set_cursor => |args| {
                editor.cursor = switch (args.mode) {
                    .prompt => .{ .prompt = args.coord.column },
                    .buffer => .{ .buffer = .fromRpc(args.coord) },
                };
            },
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
