const Editor = @This();

options: UiOptions,
kak: Kakoune,
buffer: Text,
scroll: f32,
info: Info,
menu: Menu,
status_line: Text,
mode_line: Text,

events_prev: struct {
    size: RowCol,
    mouse_pos: RowCol,
    residual_scroll: f32,
},

win: *c.SDL_Window,
ren: *c.SDL_Renderer,
fonts: Fonts,

pub const UiOptions = packed struct {
    precision_scrolling: bool = true,
};

const RowCol = packed struct(u64) {
    col_invalid: bool = false,
    col: u31,
    row_invalid: bool = false,
    row: u31,

    pub const invalid: RowCol = .{
        .col_invalid = true,
        .col = std.math.maxInt(u31),
        .row_invalid = true,
        .row = std.math.maxInt(u31),
    };

    pub fn valid(coord: RowCol) bool {
        return !coord.col_invalid and !coord.row_invalid;
    }

    pub fn fromRpc(coord: rpc.Coord) RowCol {
        return .{
            .col = coord.column,
            .row = coord.line,
        };
    }

    pub fn toPixels(coord: RowCol, fonts: *const Fonts) [2]u31 {
        return .{
            coord.col * fonts.m_advance,
            coord.row * fonts.line_height,
        };
    }

    pub fn fromPixels(fonts: *const Fonts, x: u31, y: u31) RowCol {
        return .{
            .col = @divFloor(x, fonts.m_advance),
            .row = @divFloor(y, fonts.line_height),
        };
    }
};

const Fonts = struct {
    engine: *c.TTF_TextEngine,
    fc_inited: bool,
    m_advance: u31,
    line_height: u31,
    array: [1 << @bitSizeOf(Style)]*c.TTF_Font,

    pub const Style = packed struct {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
    };
    const StyleInt = @typeInfo(Style).@"struct".backing_integer.?;

    pub fn init(ren: *c.SDL_Renderer) !Fonts {
        // TODO: error handling

        var fonts: Fonts = undefined;
        fonts.engine = c.TTF_CreateRendererTextEngine(ren) orelse {
            std.process.fatal("failed to create text engine: {s}", .{c.SDL_GetError()});
        };

        fonts.fc_inited = c.FcInit() != 0;
        if (!fonts.fc_inited) {
            if (build_options.bundle_font) {
                std.log.err("failed to initialize fontconfig; falling back to built-in font", .{});
            } else {
                std.process.fatal("failed to initialize fontconfig", .{});
            }
        }

        var font_or_err: error{ Unavailable, InvalidPattern, FontLoadingFailed }!*c.TTF_Font = error.Unavailable;
        if (fonts.fc_inited) {
            font_or_err = loadFontconfig("monospace");
        }
        if (build_options.bundle_font) {
            _ = font_or_err catch {
                font_or_err = loadFallback(13);
            };
        }
        const base_font = font_or_err catch {
            std.process.fatal("failed to load startup font", .{});
        };

        try fonts.populate(base_font);

        return fonts;
    }

    pub fn deinit(fonts: Fonts) void {
        for (fonts.array) |font| {
            c.TTF_CloseFont(font);
        }
        c.SDL_DestroyRendererTextEngine(fonts.engine);
        if (!fonts.fc_inited) {
            c.FcFini();
        }
    }

    pub fn get(fonts: Fonts, style: Style) *c.TTF_Font {
        const idx: StyleInt = @bitCast(style);
        return fonts.array[idx];
    }

    pub fn set(fonts: *Fonts, pattern: [*:0]const u8) !void {
        const font = try loadFontconfig(pattern);
        for (fonts.array) |old| {
            c.TTF_CloseFont(old);
        }
        fonts.populate(font);
    }
    fn populate(fonts: *Fonts, base_font: *c.TTF_Font) !void {
        var m_advance: c_int = undefined;
        if (!c.TTF_GetGlyphMetrics(base_font, 'm', null, null, null, null, &m_advance)) {
            std.process.fatal("failed to get font metrics: {s}", .{c.SDL_GetError()});
        }

        fonts.m_advance = @intCast(m_advance);
        fonts.line_height = @intCast(c.TTF_GetFontLineSkip(base_font));

        for (&fonts.array, 0..) |*font, i| {
            const bits: StyleInt = @intCast(i);
            const style: Style = @bitCast(bits);
            font.* = try fontWith(base_font, style);
        }
    }

    fn loadFontconfig(pattern_str: [*:0]const u8) !*c.TTF_Font {
        if (c.FcInitBringUptoDate() == 0) {
            std.log.warn("failed to update fontconfig configuration", .{});
        }

        const pattern = c.FcNameParse(pattern_str) orelse {
            return error.InvalidPattern;
        };
        defer c.FcPatternDestroy(pattern);

        if (c.FcConfigSubstitute(null, pattern, c.FcMatchPattern) == 0) {
            return error.FontLoadingFailed;
        }

        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = undefined;
        const font_set: *c.FcFontSet = c.FcFontSort(null, pattern, c.FcTrue, null, &result);
        if (result != c.FcResultMatch) {
            return error.FontLoadingFailed;
        }
        defer c.FcFontSetDestroy(font_set);

        var primary_font: ?*c.TTF_Font = null;
        errdefer if (primary_font) |font| c.TTF_CloseFont(font);

        for (0..@intCast(font_set.nfont)) |i| {
            const font_pattern = c.FcFontRenderPrepare(null, pattern, font_set.fonts[i]) orelse {
                std.log.warn("failed to prepare font pattern", .{});
                continue;
            };
            defer c.FcPatternDestroy(font_pattern);

            var path: [*:0]c.FcChar8 = undefined;
            if (c.FcPatternGetString(font_pattern, c.FC_FILE, 0, @ptrCast(&path)) != c.FcResultMatch) {
                std.log.warn("font pattern has no path value", .{});
                continue;
            }

            var size: c_int = undefined;
            if (c.FcPatternGetInteger(font_pattern, c.FC_SIZE, 0, &size) != c.FcResultMatch) {
                std.log.warn("font pattern has no font size value", .{});
                continue;
            }

            const font = c.TTF_OpenFont(path, @floatFromInt(size)) orelse {
                std.log.warn("failed to load font {s}: {s}", .{ path, c.SDL_GetError() });
                continue;
            };

            if (primary_font == null) {
                std.log.debug("loaded primary font: {s}", .{path});
                primary_font = font;
            } else {
                std.log.debug("loaded fallback font: {s}", .{path});
                _ = c.TTF_AddFallbackFont(primary_font.?, font);
                c.TTF_CloseFont(font);
            }
        }
        if (primary_font == null) {
            std.log.err("no valid matches found for fontconfig pattern {s}", .{pattern_str});
            return error.FontLoadingFailed;
        }

        return primary_font.?;
    }

    fn loadFallback(ptsize: f32) !*c.TTF_Font {
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
    bg: rpc.Color,
    width: u31,
    height: u31,
    atoms: std.MultiArrayList(Atom),

    const Atom = struct {
        text: *c.TTF_Text,
        bg: rpc.Color,
        // TODO: underline coloring - currently it's part of the font so it'll always be the fg color
        underline: rpc.Color,
        flags: Flags,

        const Flags = packed struct {
            curly_underline: bool = false,
            double_underline: bool = false,
            blink: bool = false,
            dim: bool = false,
            end_of_line: bool = false,
        };

        pub fn width(atom: Atom) u31 {
            var w: c_int = undefined;
            _ = c.TTF_GetTextSize(atom.text, &w, null);
            return @intCast(w);
        }
    };

    pub const empty: Text = .{
        .bg = .transparent,
        .width = 0,
        .height = 0,
        .atoms = .empty,
    };

    pub fn deinit(text: *Text, gpa: std.mem.Allocator) void {
        text.atoms.deinit(gpa);
    }

    pub fn clear(text: *Text) void {
        // TODO: reuse text objects
        for (text.atoms.items(.text)) |atom_text| {
            c.TTF_DestroyText(atom_text);
        }
        text.atoms.clearRetainingCapacity();
        text.* = .{
            .bg = .transparent,
            .atoms = text.atoms,
            .width = 0,
            .height = 0,
        };
    }

    pub const SetOptions = struct {
        gpa: std.mem.Allocator,
        fonts: *const Fonts,
        lines: []const rpc.Line,
        default_face: rpc.Face,
    };
    pub fn set(text: *Text, opts: SetOptions) !void {
        text.clear();

        const default_fg = opts.default_face.fg.blend(.named(.white));
        text.bg = opts.default_face.bg;
        const default_underline = opts.default_face.underline.blend(default_fg);

        var width: u31 = 0;
        var x: u31 = 0;
        var y: u31 = 0;
        for (opts.lines) |line| {
            for (line) |rpc_atom| {
                if (rpc_atom.contents.len == 0) continue;

                // TODO: default face flags/style
                var flags: Atom.Flags = .{};
                var style: Fonts.Style = .{};
                var reverse: bool = false;
                for (rpc_atom.face.attributes) |attr| {
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

                const fg0 = rpc_atom.face.fg.blend(default_fg);
                const bg0 = rpc_atom.face.bg;
                const fg = if (reverse) bg0 else fg0;
                const bg = if (reverse) fg0 else bg0;

                const font = opts.fonts.get(style);
                const atom_text = c.TTF_CreateText(
                    opts.fonts.engine,
                    font,
                    rpc_atom.contents.ptr,
                    rpc_atom.contents.len,
                ) orelse return error.CreateTextFailed;
                _ = c.TTF_SetTextColor(atom_text, fg.r, fg.g, fg.b, fg.a);

                const text_atom: Atom = .{
                    .text = atom_text,
                    .bg = bg,
                    .underline = rpc_atom.face.underline.blend(default_underline),
                    .flags = flags,
                };
                try text.atoms.append(opts.gpa, text_atom);

                x += text_atom.width();
            }

            width = @max(width, x);
            x = 0;
            y += opts.fonts.line_height;
            if (text.atoms.len > 0) {
                text.atoms.items(.flags)[text.atoms.len - 1].end_of_line = true;
            }
        }

        text.width = width;
        text.height = y;
    }
};

const Info = struct {
    title: Text,
    body: Text,
    anchor: RowCol,
    style: rpc.InfoStyle,

    pub fn deinit(info: *Info, gpa: std.mem.Allocator) void {
        info.title.deinit(gpa);
        info.body.deinit(gpa);
    }
};
const Menu = struct {
    items: Text,
    anchor: RowCol,
    style: rpc.MenuStyle,

    pub fn deinit(menu: *Menu, gpa: std.mem.Allocator) void {
        menu.items.deinit(gpa);
    }
};

pub fn init(editor: *Editor, gpa: std.mem.Allocator) !void {
    editor.* = .{
        .options = .{},
        .kak = undefined,
        .buffer = .empty,
        .scroll = 0,

        .info = .{
            .title = .empty,
            .body = .empty,
            .anchor = .invalid,
            .style = undefined,
        },
        .menu = .{
            .items = .empty,
            .anchor = .invalid,
            .style = undefined,
        },

        .status_line = .empty,
        .mode_line = .empty,

        .events_prev = .{
            .size = .invalid,
            .mouse_pos = .invalid,
            .residual_scroll = 0,
        },
        .win = undefined,
        .ren = undefined,
        .fonts = undefined,
    };

    const hints: []const [2][*:0]const u8 = &.{
        .{ c.SDL_HINT_MAIN_CALLBACK_RATE, "waitevent" },
        .{ c.SDL_HINT_VIDEO_ALLOW_SCREENSAVER, "1" },
        .{ c.SDL_HINT_RENDER_GPU_LOW_POWER, "1" },
        .{ c.SDL_HINT_RENDER_VSYNC, "1" }, // TODO: Maybe?
        .{ c.SDL_HINT_VIDEO_DOUBLE_BUFFER, "1" },
        .{
            c.SDL_HINT_VIDEO_DRIVER,
            switch (@import("builtin").os.tag) {
                // SDL prioritizes X11 over Wayland when fifo-v1 isn't available, for performance.
                // However, we're not exactly a AAA game engine, so we'd rather get the UX niceties that Wayland provides :)
                .linux => "wayland,x11",
                else => "",
            },
        },
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
    if (!c.SDL_SetRenderDrawBlendMode(editor.ren, c.SDL_BLENDMODE_BLEND)) {
        std.process.fatal("failed to set blend mode", .{});
    }

    editor.fonts = Fonts.init(editor.ren) catch {
        std.process.fatal("failed to load fonts: {s}", .{c.SDL_GetError()});
    };

    try editor.kak.init(gpa);
}
pub fn deinit(editor: *Editor, gpa: std.mem.Allocator) void {
    editor.kak.deinit();
    editor.info.deinit(gpa);
    editor.menu.deinit(gpa);
    editor.buffer.deinit(gpa);
    editor.status_line.deinit(gpa);
    editor.mode_line.deinit(gpa);
}

pub fn frame(editor: *Editor) !void {
    const window_background = editor.buffer.bg.blend(.named(.black));
    editor.setDrawColor(window_background);
    _ = c.SDL_RenderClear(editor.ren);

    const window_width: u31, const window_height: u31 = blk: {
        var w: c_int = undefined;
        var h: c_int = undefined;
        if (!c.SDL_GetCurrentRenderOutputSize(editor.ren, &w, &h)) {
            return error.GetSizeFailed;
        }
        break :blk .{ @intCast(w), @intCast(h) };
    };

    { // Draw buffer
        const line_height: f32 = @floatFromInt(editor.fonts.line_height);
        const scroll_offset = -editor.scroll * line_height;
        editor.drawText(editor.buffer, .{ 0, @intFromFloat(scroll_offset) });
    }

    const status_line_y = window_height - editor.fonts.line_height;
    {
        // Draw mode line in reverse order, to align it right instead of left
        // Also draw it first, so the status line draws over it if necessary
        var x = window_width;
        const atoms = editor.mode_line.atoms.slice();
        var atom_idx: usize = atoms.len;
        while (atom_idx > 0) {
            atom_idx -= 1;
            const atom = atoms.get(atom_idx);
            x -= atom.width();
            editor.drawAtom(atom, x, status_line_y);
        }
    }

    // Draw status line
    {
        // TODO: support transparent status line (needs extra lines of context from kak)
        const bg = editor.status_line.bg.blend(window_background);
        editor.setDrawColor(bg);
        editor.drawRect(.{ 0, status_line_y }, .{ window_width, editor.fonts.line_height });

        editor.drawText(editor.status_line, .{ 0, status_line_y });
    }

    // Draw info
    // TODO: text wrapping
    if (editor.info.anchor.valid()) {
        var x: i32, var y: i32 = editor.info.anchor.toPixels(&editor.fonts);
        switch (editor.info.style) {
            .prompt => {
                x = 0;
                y = status_line_y - editor.info.body.height;
            },
            .@"inline" => {
                // TODO: choose inlineAbove or inlineBelow based on position and window size
            },
            .inlineAbove => {
                y -= editor.info.body.height;
            },
            .inlineBelow => {},
            .menuDoc => {}, // TODO
            .modal => {}, // TODO
        }
        editor.setDrawColor(editor.info.body.bg);
        editor.drawRect(.{ x, y }, .{ window_width, editor.info.body.height });
        editor.drawText(editor.info.body, .{ x, y });
    }

    // Draw menu
    if (editor.menu.anchor.valid()) {
        const x, const y = editor.menu.anchor.toPixels(&editor.fonts);
        editor.drawTextBackground(editor.menu.items, .{ x, y });
        editor.drawText(editor.menu.items, .{ x, y });
    }

    _ = c.SDL_RenderPresent(editor.ren);
}

fn setDrawColor(editor: *Editor, color: rpc.Color) void {
    _ = c.SDL_SetRenderDrawColor(editor.ren, color.r, color.g, color.b, color.a);
}

fn drawTextBackground(editor: *Editor, text: Text, top_left: [2]i32) void {
    if (text.bg.a > 0) {
        editor.setDrawColor(text.bg);
        editor.drawRect(top_left, .{ text.width, text.height });
    }
}
fn drawRect(editor: *Editor, top_left: [2]i32, dims: [2]u31) void {
    _ = c.SDL_RenderFillRect(editor.ren, &.{
        .x = @floatFromInt(top_left[0]),
        .y = @floatFromInt(top_left[1]),
        .w = @floatFromInt(dims[0]),
        .h = @floatFromInt(dims[1]),
    });
}

fn drawText(editor: *Editor, text: Text, top_left: [2]i32) void {
    var x, var y = top_left;

    const atoms = text.atoms.slice();
    for (0..atoms.len) |atom_idx| {
        const atom = atoms.get(atom_idx);
        editor.drawAtom(atom, x, y);
        if (atom.flags.end_of_line) {
            x = 0;
            y += editor.fonts.line_height;
        } else {
            x += atom.width();
        }
    }
}
fn drawAtom(editor: *Editor, atom: Text.Atom, x: i32, y: i32) void {
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);

    if (atom.bg.a > 0) {
        editor.setDrawColor(atom.bg);
        _ = c.SDL_RenderFillRect(editor.ren, &.{
            .x = xf,
            .y = yf,
            .w = @floatFromInt(atom.width()),
            .h = @floatFromInt(editor.fonts.line_height),
        });
    }

    _ = c.TTF_DrawRendererText(atom.text, xf, yf);

    // TODO: flags
}

pub fn event(editor: *Editor, gpa: std.mem.Allocator, ev: *c.SDL_Event) !void {
    switch (ev.type) {
        c.SDL_EVENT_QUIT => {
            std.log.debug("received quit event", .{});
            return error.Exit;
        },

        c.SDL_EVENT_WINDOW_RESIZED => {
            const size: RowCol = .fromPixels(
                &editor.fonts,
                @intCast(ev.window.data1),
                @intCast(ev.window.data2),
            );
            if (size != editor.events_prev.size) {
                editor.events_prev.size = size;
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
            const pos: RowCol = .fromPixels(
                &editor.fonts,
                @intFromFloat(ev.motion.x),
                @intFromFloat(ev.motion.y),
            );
            if (pos != editor.events_prev.mouse_pos) {
                editor.events_prev.mouse_pos = pos;
                try editor.kak.call(.{ .mouse_move = .{
                    .column = pos.col,
                    .line = pos.row,
                } });
            }
        },

        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (input.button(ev.button.button)) |btn| {
                const pos: RowCol = .fromPixels(
                    &editor.fonts,
                    @intFromFloat(ev.button.x),
                    @intFromFloat(ev.button.y),
                );
                try editor.kak.call(.{ .mouse_press = .{
                    .button = btn,
                    .column = pos.col,
                    .line = pos.row,
                } });
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (input.button(ev.button.button)) |btn| {
                const pos: RowCol = .fromPixels(
                    &editor.fonts,
                    @intFromFloat(ev.button.x),
                    @intFromFloat(ev.button.y),
                );
                try editor.kak.call(.{ .mouse_release = .{
                    .button = btn,
                    .column = pos.col,
                    .line = pos.row,
                } });
            }
        },

        c.SDL_EVENT_MOUSE_WHEEL => {
            const delta: i32 = blk: {
                if (editor.options.precision_scrolling) {
                    editor.scroll = std.math.clamp(editor.scroll - ev.wheel.y, 0, 1);

                    const accum = editor.events_prev.residual_scroll - ev.wheel.y;
                    const coarse: f32 = @floor(accum);
                    editor.events_prev.residual_scroll = accum - coarse;

                    break :blk @intFromFloat(coarse);
                } else {
                    editor.scroll = 0;
                    editor.events_prev.residual_scroll = 0;
                    break :blk -ev.wheel.integer_y;
                }
            };

            const pos: RowCol = .fromPixels(
                &editor.fonts,
                @intFromFloat(ev.wheel.mouse_x),
                @intFromFloat(ev.wheel.mouse_y),
            );

            if (delta != 0) {
                // TODO: coalesce scroll events for performance
                try editor.kak.call(.{
                    .scroll = .{
                        .amount = delta,
                        .column = pos.col,
                        .line = pos.row,
                    },
                });
            }
        },

        // TODO: touch screen input. Probably want SDL_HINT_TOUCH_MOUSE_EVENTS=0

        // TODO: use an event per ui call, instead of one refresh event and a separate queue
        else => if (ev.type == editor.kak.recv.sdl_event_id) {
            editor.processUiCalls(gpa) catch |err| switch (err) {
                error.EndOfStream => {
                    std.log.debug("kakoune exited", .{});
                    return error.Exit;
                },
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
                try editor.buffer.set(.{
                    .gpa = gpa,
                    .fonts = &editor.fonts,
                    .lines = args.lines,
                    .default_face = args.default_face,
                });

                // Assume kakoune has processed all scroll events we've sent it, and reset our scroll offset accordingly
                editor.scroll = editor.events_prev.residual_scroll;
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

            .info_show => |info| {
                try editor.info.title.set(.{
                    .gpa = gpa,
                    .fonts = &editor.fonts,
                    .lines = &.{info.title},
                    .default_face = info.face,
                });
                try editor.info.body.set(.{
                    .gpa = gpa,
                    .fonts = &editor.fonts,
                    .lines = info.content,
                    .default_face = info.face,
                });
                editor.info.anchor = .fromRpc(info.anchor);
                editor.info.style = info.style;
            },
            .info_hide => {
                editor.info.title.clear();
                editor.info.body.clear();
                editor.info.anchor = .invalid;
                editor.info.style = undefined;
            },

            .menu_show => |menu| {
                try editor.menu.items.set(.{
                    .gpa = gpa,
                    .fonts = &editor.fonts,
                    .lines = menu.items,
                    .default_face = menu.menu_face,
                });
                editor.menu.anchor = .fromRpc(menu.anchor);
                editor.menu.style = menu.style;
            },
            .menu_hide => {
                editor.menu.items.clear();
                editor.menu.anchor = .invalid;
                editor.menu.style = undefined;
            },
            .menu_select => {},

            .refresh, .set_cursor => {},
            .set_ui_options => |opts| {
                if (opts.options != .object) return error.InvalidRequest;
                for (opts.options.object.keys(), opts.options.object.values()) |key, value_json| {
                    const prefix = "butterflye_";
                    if (!std.mem.startsWith(u8, key, prefix)) {
                        std.log.info("ignoring UI option {f}", .{std.json.fmt(key, .{})});
                        continue;
                    }

                    const Field = std.meta.FieldEnum(UiOptions);
                    const field_enum = std.meta.stringToEnum(Field, key[prefix.len..]) orelse {
                        std.log.warn("unknown UI option {f}", .{std.json.fmt(key, .{})});
                        continue;
                    };

                    if (value_json != .string) return error.InvalidRequest;
                    const value_str = value_json.string;

                    switch (field_enum) {
                        inline .precision_scrolling => |field| {
                            const str_to_bool: std.StaticStringMap(bool) = .initComptime(.{
                                .{ "true", true },
                                .{ "false", false },
                            });
                            const value_bool = str_to_bool.get(value_str) orelse {
                                std.log.warn("invalid value for UI option {f}", .{std.json.fmt(key, .{})});
                                continue;
                            };
                            @field(editor.options, @tagName(field)) = value_bool;
                        },
                    }
                }
            },
        }
    }

    // If we've not receive a `draw` call in response to our scroll events, we're probabl at the top of the buffer.
    // In that case, this line will reset the residual scroll value to 0, to clamp scrolling to the buffer area.
    editor.events_prev.residual_scroll = editor.scroll;
}

const std = @import("std");
const build_options = @import("build_options");
const c = @import("c.zig").c;

// keep-sorted start
const Kakoune = @import("Kakoune.zig");
const input = @import("input.zig");
const rpc = @import("rpc.zig");
// keep-sorted end
