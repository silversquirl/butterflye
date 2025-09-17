const Editor = @This();

kak: Kakoune,
bg: rpc.Color,
buffer: Text,
status_line: Text,
mode_line: Text,

fonts: Fonts,

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

const Fonts = struct {
    engine: *c.TTF_TextEngine,
    line_height: u31,
    array: [1 << @bitSizeOf(Style)]*c.TTF_Font,

    pub const Style = packed struct {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
    };
    const StyleInt = @typeInfo(Style).@"struct".backing_integer.?;

    pub fn init(ren: *c.SDL_Renderer, font_size: f32) !Fonts {
        // TODO: error handling

        const base_font = try loadFallbackFont(font_size);

        var fonts: Fonts = .{
            .engine = c.TTF_CreateRendererTextEngine(ren) orelse {
                std.process.fatal("failed to create text engine: {s}", .{c.SDL_GetError()});
            },
            .line_height = @intCast(c.TTF_GetFontLineSkip(base_font)),
            .array = undefined,
        };

        for (&fonts.array, 0..) |*font, i| {
            const bits: StyleInt = @intCast(i);
            const style: Style = @bitCast(bits);
            font.* = try fontWith(base_font, style);
        }

        return fonts;
    }

    pub fn deinit(fonts: Fonts) void {
        for (fonts.array) |font| {
            c.TTF_CloseFont(font);
        }
        c.SDL_DestroyRendererTextEngine(fonts.engine);
    }

    pub fn get(fonts: Fonts, style: Style) *c.TTF_Font {
        const idx: StyleInt = @bitCast(style);
        return fonts.array[idx];
    }

    fn loadFallbackFont(ptsize: f32) !*c.TTF_Font {
        if (!build_options.bundle_font) {
            return error.Unavailable;
        }
        const data = @embedFile("default_font.ttf");
        const stream = c.SDL_IOFromConstMem(data.ptr, data.len) orelse {
            return error.FontLoadingFailed;
        };
        const font = c.TTF_OpenFontIO(stream, true, ptsize) orelse {
            return error.FontLoadingFailed;
        };
        return font;
    }

    fn fontWith(base: *c.TTF_Font, style: Style) !*c.TTF_Font {
        const sdl_style =
            @as(u32, c.TTF_STYLE_BOLD) * @intFromBool(style.bold) |
            @as(u32, c.TTF_STYLE_ITALIC) * @intFromBool(style.italic) |
            @as(u32, c.TTF_STYLE_UNDERLINE) * @intFromBool(style.underline);
        if (sdl_style == c.TTF_STYLE_NORMAL) {
            return base;
        }
        const new = c.TTF_CopyFont(base) orelse {
            return error.FontLoadingFailed;
        };
        c.TTF_SetFontStyle(new, sdl_style);
        return new;
    }
};

const Text = struct {
    atoms: std.MultiArrayList(Atom),
    width: i32,

    const Atom = struct {
        text: *c.TTF_Text,
        width: Width,
        bg: rpc.Color,
        // TODO: underline coloring - currently it's part of the font so it'll always be the fg color
        underline: rpc.Color,
        flags: Flags,

        const Width = enum(u8) {
            too_long = 254,
            end_of_line,
            _,

            pub fn fromInt(i: i32) Width {
                if (i < 0 or i >= @intFromEnum(Width.too_long)) {
                    return .too_long;
                }
                return @enumFromInt(i);
            }
        };

        const Flags = packed struct {
            curly_underline: bool = false,
            double_underline: bool = false,
            blink: bool = false,
            dim: bool = false,
        };
    };

    pub const empty: Text = .{ .atoms = .empty, .width = 0 };

    pub const SetOptions = struct {
        gpa: std.mem.Allocator,
        fonts: *const Fonts,
        lines: []const rpc.Line,
        default_face: rpc.Face,
    };

    pub fn set(text: *Text, opts: SetOptions) !void {
        // TODO: reuse text objects
        for (text.atoms.items(.text)) |atom_text| {
            c.TTF_DestroyText(atom_text);
        }
        text.atoms.clearRetainingCapacity();

        const default_fg = opts.default_face.fg.blend(.named(.white));
        const default_bg = opts.default_face.bg.blend(.named(.black));
        const default_underline = opts.default_face.underline.blend(default_fg);

        text.width = 0;
        var x: i32 = 0;
        for (opts.lines) |line| {
            for (line) |atom| {
                if (atom.contents.len == 0) continue;

                // TODO: default face flags/style
                var flags: Atom.Flags = .{};
                var style: Fonts.Style = .{};
                var reverse: bool = false;
                for (atom.face.attributes) |attr| {
                    switch (attr) {
                        .bold => style.bold = true,
                        .italic => style.italic = true,
                        .underline => style.underline = true,

                        .curly_underline => flags.curly_underline = true,
                        .double_underline => flags.double_underline = true,
                        .blink => flags.blink = true,
                        .dim => flags.dim = true,

                        .reverse => reverse = true,

                        // TODO: finality
                        .final_fg => {},
                        .final_bg => {},
                        .final_attr => {},
                    }
                }

                const fg0 = atom.face.fg.blend(default_fg);
                const bg0 = atom.face.bg.blend(default_bg);
                const fg = if (reverse) bg0 else fg0;
                const bg = if (reverse) fg0 else bg0;

                const font = opts.fonts.get(style);
                const atom_text = c.TTF_CreateText(
                    opts.fonts.engine,
                    font,
                    atom.contents.ptr,
                    atom.contents.len,
                ) orelse return error.CreateTextFailed;
                _ = c.TTF_SetTextColor(atom_text, fg.r, fg.g, fg.b, fg.a);

                // _ = c.TTF_SetTextPosition(atom_text, x, y);

                var w: c_int = undefined;
                if (!c.TTF_GetTextSize(atom_text, &w, null)) {
                    return error.GetTextSizeFailed;
                }
                x += w;
                text.width = @max(text.width, x);

                try text.atoms.append(opts.gpa, .{
                    .text = atom_text,
                    .width = .fromInt(w),
                    .bg = bg,
                    .underline = atom.face.underline.blend(default_underline),
                    .flags = flags,
                });
            }

            if (text.atoms.len > 0) {
                text.atoms.items(.width)[text.atoms.len - 1] = .end_of_line;
            }
            x = 0;
        }
    }

    pub fn deinit(text: *Text, gpa: std.mem.Allocator) void {
        text.atoms.deinit(gpa);
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
        .fonts = undefined,
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
        std.fmt.comptimePrint("{f}", .{build_options.version}),
        "dev.squirl.butterflye",
    );

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.process.fatal("failed to initialize SDL: {s}", .{c.SDL_GetError()});
    }
    if (!c.TTF_Init()) {
        std.process.fatal("failed to initialize SDL_ttf: {s}", .{c.SDL_GetError()});
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

    editor.fonts = Fonts.init(editor.ren, 13.0) catch {
        std.process.fatal("failed to load fonts: {s}", .{c.SDL_GetError()});
    };

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

    var w: c_int = undefined;
    var h: c_int = undefined;
    if (!c.SDL_GetCurrentRenderOutputSize(editor.ren, &w, &h)) {
        return error.GetSizeFailed;
    }

    editor.drawText(editor.buffer, 0, 0);
    editor.drawText(editor.status_line, 0, h - editor.fonts.line_height);
    editor.drawText(editor.mode_line, w - editor.mode_line.width, h - editor.fonts.line_height);

    _ = c.SDL_RenderPresent(editor.ren);
}

fn setDrawColor(editor: *Editor, color: rpc.Color) void {
    _ = c.SDL_SetRenderDrawColor(editor.ren, color.r, color.g, color.b, color.a);
}

fn drawText(editor: *Editor, text: Text, anchor_x: i32, anchor_y: i32) void {
    var x: i32 = 0;
    var y: i32 = 0;
    const a = text.atoms.slice();
    for (a.items(.text), a.items(.width)) |atom_text, width| {
        _ = c.TTF_DrawRendererText(atom_text, @floatFromInt(x + anchor_x), @floatFromInt(y + anchor_y));
        // TODO: flags

        switch (width) {
            _ => |w| x += @intFromEnum(w),
            .too_long => {
                var w: c_int = undefined;
                _ = c.TTF_GetTextSize(atom_text, &w, null);
                x += w;
            },
            .end_of_line => {
                x = 0;
                y += editor.fonts.line_height;
            },
        }
    }
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
                try editor.buffer.set(.{
                    .gpa = gpa,
                    .fonts = &editor.fonts,
                    .lines = args.lines,
                    .default_face = args.default_face,
                });
            },
            .draw_status => |args| {
                try editor.status_line.set(.{
                    .gpa = gpa,
                    .fonts = &editor.fonts,
                    .lines = &.{args.status_line},
                    .default_face = args.default_face,
                });
                try editor.mode_line.set(.{
                    .gpa = gpa,
                    .fonts = &editor.fonts,
                    .lines = &.{args.mode_line},
                    .default_face = args.default_face,
                });
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
const build_options = @import("build_options");
const c = @import("c.zig").c;

// keep-sorted start
const Kakoune = @import("Kakoune.zig");
const input = @import("input.zig");
const rpc = @import("rpc.zig");
// keep-sorted end
