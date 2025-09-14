/// Methods we implement, called by Kakoune
pub const UiMethod = union(enum) {
    // keep-sorted start block=yes
    draw: struct {
        lines: []const Line,
        default_face: Face,
        padding_face: Face,
    },
    draw_status: struct {
        status_line: Line,
        mode_line: Line,
        default_face: Face,
    },
    info_hide: void,
    info_show: struct {
        title: Line,
        content: []const Line,
        anchor: Coord,
        face: Face,
        style: enum { prompt, @"inline", inlineAbove, inlineBelow, menuDoc, modal },
    },
    menu_hide: void,
    menu_show: struct {
        items: []const Line,
        anchor: Coord,
        selected_item_face: Face,
        menu_face: Face,
        style: enum { prompt, @"inline" },
    },
    refresh: struct { force: bool },
    set_cursor: struct {
        mode: enum { prompt, buffer },
        coord: Coord,
    },
    set_ui_options: struct {
        options: std.json.Value,
    },
    // keep-sorted end
};

/// Methods Kakoune implements, called by us
pub const KakMethod = union(enum) {
    // keep-sorted start block=yes
    keys: []const []const u8,
    menu_select: struct { index: u32 },
    mouse_move: struct {
        line: u32,
        column: u32,
    },
    mouse_press: struct {
        button: enum { left, middle, right },
        line: u32,
        column: u32,
    },
    mouse_release: struct {
        button: enum { left, middle, right },
        line: u32,
        columm: u32,
    },
    resize: struct {
        rows: u32,
        columns: u32,
    },
    scroll: struct {
        amount: i32,
        line: u32,
        column: u32,
    },
    // keep-sorted end
};

// keep-sorted start block=yes newline_separated=yes
pub const Atom = struct {
    face: Face,
    contents: []const u8,
};

pub const Attribute = enum {
    underline,
    curly_underline,
    double_underline,
    reverse,
    blink,
    bold,
    dim,
    italic,
    final_fg,
    final_bg,
    final_attr,
};

pub const Color = []const u8;

pub const Coord = struct {
    line: u32,
    column: u32,
};

pub const Face = struct {
    fg: Color,
    bg: Color,
    attributes: []const Attribute,
    underline: Color = "default",
};

pub const Line = []const Atom;
// keep-sorted end

pub fn send(writer: *std.Io.Writer, call: KakMethod) !void {
    var s: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try s.beginObject();

    try s.objectField("jsonrpc");
    try s.write("2.0");

    try s.objectField("method");
    try s.write(std.meta.activeTag(call));

    try s.objectField("params");
    try s.beginArray();
    switch (call) {
        inline else => |params| {
            inline for (@typeInfo(params).@"struct".fields) |field| {
                try s.write(@field(params, field.name));
            }
            try s.write(call);
        },
    }
    try s.endArray();

    try s.endObject();
}

pub fn recv(arena: std.mem.Allocator, reader: *std.Io.Reader) !UiMethod {
    var line_buffer: [1024]u8 = undefined;
    var line_reader: DelimitedReader = .init(reader, '\n', &line_buffer);
    var json_reader: std.json.Reader = .init(arena, &line_reader.interface);
    const parsed = try std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &json_reader, .{});

    log.debug("<- {f}", .{std.json.fmt(parsed, .{})});

    if (parsed != .object) return error.InvalidRequest;
    const msg = parsed.object;

    const version = msg.get("jsonrpc") orelse return error.InvalidRequest;
    if (version != .string) return error.InvalidRequest;
    if (!std.mem.eql(u8, version.string, "2.0")) return error.InvalidRequest;

    const method_value = msg.get("method") orelse return error.InvalidRequest;
    if (method_value != .string) return error.InvalidRequest;
    const method_tag = std.meta.stringToEnum(std.meta.Tag(UiMethod), method_value.string) orelse {
        return error.InvalidRequest;
    };

    const params_value = msg.get("params") orelse return error.InvalidRequest;
    if (params_value != .array) return error.InvalidRequest;
    const params = params_value.array.items;

    switch (method_tag) {
        inline else => |method| {
            const Params = @FieldType(UiMethod, @tagName(method));
            return @unionInit(
                UiMethod,
                @tagName(method),
                try parseParams(Params, arena, params),
            );
        },
    }
}

fn parseParams(comptime Params: type, arena: std.mem.Allocator, params_json: []const std.json.Value) !Params {
    switch (@typeInfo(Params)) {
        .@"struct" => |info| {
            var params: Params = undefined;
            if (params_json.len != info.fields.len) return error.InvalidRequest;
            inline for (info.fields, params_json) |field, param| {
                @field(params, field.name) = try std.json.parseFromValueLeaky(field.type, arena, param, .{});
            }
            return params;
        },
        .void => return,
        else => @compileError("Invalid params type " ++ @typeName(Params)),
    }
}

const DelimitedReader = struct {
    backing: *std.Io.Reader,
    delimiter: u8,
    interface: std.Io.Reader,

    pub fn init(backing: *std.Io.Reader, delimiter: u8, buffer: []u8) DelimitedReader {
        return .{
            .backing = backing,
            .delimiter = delimiter,
            .interface = .{
                .vtable = comptime &.{
                    .stream = stream,
                    .discard = discard,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const d: *DelimitedReader = @fieldParentPtr("interface", r);
        const n = d.backing.streamDelimiterLimit(w, d.delimiter, limit) catch |err| switch (err) {
            error.StreamTooLong => return limit.toInt().?,
            else => |e| return e,
        };
        if (n == 0) {
            if (try d.backing.peekByte() == d.delimiter) {
                d.backing.toss(1);
                return error.EndOfStream;
            }
        }
        return n;
    }
    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const d: *DelimitedReader = @fieldParentPtr("interface", r);
        const n = d.backing.discardDelimiterLimit(d.delimiter, limit) catch |err| switch (err) {
            error.StreamTooLong => return limit.toInt().?,
            else => |e| return e,
        };
        if (n == 0) {
            if (try d.backing.peekByte() == d.delimiter) {
                d.backing.toss(1);
                return error.EndOfStream;
            }
        }
        return n;
    }
};

const std = @import("std");
const log = std.log.scoped(.rpc);
