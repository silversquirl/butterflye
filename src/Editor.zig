const Editor = @This();

kak: Kakoune,
bg: rpc.Color,
buffer: Text,
status_line: Text,
mode_line: Text,

event_dedup: struct {
    size: RowCol,
    mouse_pos: RowCol,
},

win: *c.SDL_Window,
ren: *c.SDL_Renderer,

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

    pub fn fromSdl(x: f32, y: f32, font_scale: [2]f32) RowCol {
        return .{
            .col = @intFromFloat(x / font_scale[0]),
            .row = @intFromFloat(y / font_scale[1]),
        };
    }

    pub fn toSdl(p: RowCol, font_scale: [2]f32) [2]f32 {
        return .{
            @as(f32, @floatFromInt(p.col)) * font_scale[0],
            @as(f32, @floatFromInt(p.row)) * font_scale[1],
        };
    }

    pub fn fromPixels(x: i32, y: i32, font_scale: [2]f32) RowCol {
        return .fromSdl(@floatFromInt(x), @floatFromInt(y), font_scale);
    }
};

const Text = struct {
    buf: std.ArrayList(u8),
    atoms: std.ArrayList(Atom),

    const Atom = struct {
        start: u32,
        len: u32,
        fg: rpc.Color,
        bg: rpc.Color,
        underline: rpc.Color,
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

        const default_fg = default_face.fg.blend(.named(.white));
        const default_bg = default_face.bg.blend(.named(.black));
        const default_underline = default_face.underline.blend(default_fg);

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

                    .fg = atom.face.fg.blend(default_fg),
                    .bg = atom.face.bg.blend(default_bg),
                    .underline = atom.face.underline.blend(default_underline),
                    .flags = flags,
                });
            }
        }
    }

    pub fn deinit(text: *Text, gpa: std.mem.Allocator) void {
        text.buf.deinit(gpa);
        text.atoms.deinit(gpa);
    }

    pub fn draw(text: Text, ren: *c.SDL_Renderer) void {
        for (text.atoms.items) |atom| {
            const str = text.buf.items[atom.start..][0..atom.len];
            // TODO: draw text
            _ = ren;
            _ = str;
            // TODO: flags
        }
    }
};

pub fn init(editor: *Editor, gpa: std.mem.Allocator) !void {
    editor.* = .{
        .kak = undefined,
        .bg = .named(.black),
        .buffer = .empty,
        .status_line = .empty,
        .mode_line = .empty,
        .event_dedup = .{
            .size = .invalid,
            .mouse_pos = .invalid,
        },
        .win = undefined,
        .ren = undefined,
    };

    const hints: []const [2][*:0]const u8 = &.{
        .{ c.SDL_HINT_MAIN_CALLBACK_RATE, "waitevent" },
        .{ c.SDL_HINT_VIDEO_ALLOW_SCREENSAVER, "1" },
        .{ c.SDL_HINT_RENDER_GPU_LOW_POWER, "1" },
        .{ c.SDL_HINT_RENDER_VSYNC, "1" }, // TODO: Maybe?
        .{ c.SDL_HINT_VIDEO_DOUBLE_BUFFER, "1" },
    };
    for (hints) |hint| {
        const name, const value = hint;
        if (!c.SDL_SetHint(name, value)) {
            std.process.fatal("failed to set SDL hints: {s}", .{c.SDL_GetError()});
        }
    }

    _ = c.SDL_SetAppMetadata(
        "Butterflye",
        "0.0.1-dev", // TODO: provide via build options
        "dev.squirl.butterflye",
    );

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.process.fatal("failed to initialize SDL: {s}", .{c.SDL_GetError()});
    }

    // TODO: title
    // TODO: window properties (eg. app id)
    if (!c.SDL_CreateWindowAndRenderer(
        "Butterflye",
        800,
        600,
        c.SDL_WINDOW_RESIZABLE,
        @ptrCast(&editor.win),
        @ptrCast(&editor.ren),
    )) {
        std.process.fatal("failed to create window and/or renderer: {s}", .{c.SDL_GetError()});
    }

    try editor.kak.init(gpa);
}
pub fn deinit(editor: *Editor, gpa: std.mem.Allocator) void {
    editor.kak.deinit();
    editor.buffer.deinit(gpa);
    editor.status_line.deinit(gpa);
    editor.mode_line.deinit(gpa);
}

pub fn frame(editor: *Editor) !void {
    editor.setDrawColor(editor.bg);
    _ = c.SDL_RenderClear(editor.ren);

    editor.buffer.draw(editor.ren);
    editor.status_line.draw(editor.ren);
    editor.mode_line.draw(editor.ren);

    _ = c.SDL_RenderPresent(editor.ren);
}

fn setDrawColor(editor: *Editor, color: rpc.Color) void {
    _ = c.SDL_SetRenderDrawColor(editor.ren, color.r, color.g, color.b, color.a);
}

pub fn event(editor: *Editor, gpa: std.mem.Allocator, ev: *c.SDL_Event) !void {
    const font_scale: [2]f32 = .{ 16, 16 };
    switch (ev.type) {
        c.SDL_EVENT_QUIT => return error.Exit,

        c.SDL_EVENT_WINDOW_RESIZED => {
            const size: RowCol = .fromPixels(ev.window.data1, ev.window.data2, font_scale);
            if (size != editor.event_dedup.size) {
                editor.event_dedup.size = size;
                try editor.kak.call(.{ .resize = .{
                    .columns = size.col,
                    .rows = size.row,
                } });
            }
        },
        c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
            // TODO: may need to update renderer scale? unsure if sdl handles this for us or not
        },

        c.SDL_EVENT_KEY_DOWN => {
            // TODO: ignore caps lock in normal mode?
            if (input.KeyOrText.fromKey(ev.key)) |key| {
                try editor.kak.call(.{ .keys = &.{key} });
            }
        },

        // TODO: enable text input when in insert or command mode
        // c.SDL_EVENT_TEXT_INPUT => {
        //     const text: input.KeyOrText = .{ .text = std.mem.span(ev.text.text) };
        //     try editor.kak.call(.{ .keys = &.{text} });
        // },

        c.SDL_EVENT_MOUSE_MOTION => {
            const pos: RowCol = .fromSdl(ev.motion.x, ev.motion.y, font_scale);
            if (pos != editor.event_dedup.mouse_pos) {
                editor.event_dedup.mouse_pos = pos;
                try editor.kak.call(.{ .mouse_move = .{
                    .column = pos.col,
                    .line = pos.row,
                } });
            }
        },

        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (input.button(ev.button.button)) |btn| {
                const pos: RowCol = .fromSdl(ev.button.x, ev.button.y, font_scale);
                try editor.kak.call(.{ .mouse_press = .{
                    .button = btn,
                    .column = pos.col,
                    .line = pos.row,
                } });
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (input.button(ev.button.button)) |btn| {
                const pos: RowCol = .fromSdl(ev.button.x, ev.button.y, font_scale);
                try editor.kak.call(.{ .mouse_release = .{
                    .button = btn,
                    .column = pos.col,
                    .line = pos.row,
                } });
            }
        },

        c.SDL_EVENT_MOUSE_WHEEL => {
            // TODO: deduplicate scroll events
            const pos: RowCol = .fromSdl(ev.wheel.mouse_x, ev.wheel.mouse_y, font_scale);
            try editor.kak.call(.{
                .scroll = .{
                    .amount = ev.wheel.integer_y, // TODO: pixel scrolling
                    .column = pos.col,
                    .line = pos.row,
                },
            });
        },

        // TODO: touch screen input. Probably want SDL_HINT_TOUCH_MOUSE_EVENTS=0

        // TODO: use an event per ui call, instead of one refresh event and a separate queue
        else => if (ev.type == editor.kak.recv.sdl_event_id) {
            editor.processUiCalls(gpa) catch |err| switch (err) {
                error.EndOfStream => return error.Exit,
                else => |e| return e,
            };
        },
    }
}

fn processUiCalls(editor: *Editor, gpa: std.mem.Allocator) !void {
    const calls = try editor.kak.acquireUiCalls();
    defer editor.kak.releaseUiCalls();

    for (calls) |call| {
        switch (call) {
            .draw => |args| {
                editor.bg = args.default_face.bg.blend(.named(.black));
                try editor.buffer.set(gpa, args.lines, args.default_face);
            },
            .draw_status => |args| {
                try editor.status_line.set(gpa, &.{args.status_line}, args.default_face);
                try editor.mode_line.set(gpa, &.{args.mode_line}, args.default_face);
            },
            .info_hide => {},
            .info_show => {},
            .menu_hide => {},
            .menu_select => {},
            .menu_show => {},
            .refresh, .set_cursor => {},
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
const c = @import("c.zig").c;

// keep-sorted start
const Kakoune = @import("Kakoune.zig");
const input = @import("input.zig");
const rpc = @import("rpc.zig");
// keep-sorted end
