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
    menu_select: struct { index: i32 },
    menu_show: struct {
        items: []const Line,
        anchor: Coord,
        selected_item_face: Face,
        menu_face: Face,
        style: enum { prompt, search, @"inline" },
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

    pub fn jsonParseFromValue(
        arena: std.mem.Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) !UiMethod {
        if (value != .object) return error.UnexpectedToken;
        const msg = value.object;

        const version = msg.get("jsonrpc") orelse return error.MissingField;
        if (version != .string) return error.UnexpectedToken;
        if (!std.mem.eql(u8, version.string, "2.0")) return error.InvalidEnumTag;

        const method_value = msg.get("method") orelse return error.MissingField;
        if (method_value != .string) return error.UnexpectedToken;
        const method_tag = std.meta.stringToEnum(std.meta.Tag(UiMethod), method_value.string) orelse {
            return error.InvalidEnumTag;
        };

        const params_value = msg.get("params") orelse return error.MissingField;
        if (params_value != .array) return error.UnexpectedToken;
        const params = params_value.array.items;

        switch (method_tag) {
            inline else => |method| {
                const Params = @FieldType(UiMethod, @tagName(method));
                return @unionInit(
                    UiMethod,
                    @tagName(method),
                    try parseParams(Params, arena, params, options),
                );
            },
        }
    }

    fn parseParams(
        comptime Params: type,
        arena: std.mem.Allocator,
        params_json: []const std.json.Value,
        options: std.json.ParseOptions,
    ) !Params {
        switch (@typeInfo(Params)) {
            .@"struct" => |info| {
                var params: Params = undefined;
                if (params_json.len != info.fields.len) return error.LengthMismatch;
                inline for (info.fields, params_json) |field, param| {
                    @field(params, field.name) = try std.json.parseFromValueLeaky(field.type, arena, param, options);
                }
                return params;
            },
            .void => return,
            else => @compileError("Invalid params type " ++ @typeName(Params)),
        }
    }
};

/// Methods Kakoune implements, called by us
pub const KakMethod = union(enum) {
    // keep-sorted start block=yes
    keys: []const input.KeyOrText,
    menu_select: struct { index: i32 },
    mouse_move: struct {
        line: u32,
        column: u32,
    },
    mouse_press: struct {
        button: Button,
        line: u32,
        column: u32,
    },
    mouse_release: struct {
        button: Button,
        line: u32,
        column: u32,
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

    pub const Button = enum { left, middle, right };

    pub fn jsonStringify(call: KakMethod, s: *std.json.Stringify) !void {
        try s.beginObject();

        try s.objectField("jsonrpc");
        try s.write("2.0");

        try s.objectField("method");
        try s.write(std.meta.activeTag(call));

        try s.objectField("params");
        switch (call) {
            .keys => |keys| try s.write(keys),
            inline else => |params| {
                try s.beginArray();
                inline for (@typeInfo(@TypeOf(params)).@"struct".fields) |field| {
                    try s.write(@field(params, field.name));
                }
                try s.endArray();
            },
        }

        try s.endObject();
    }
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

pub const Color = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,

    const Name = enum {
        default,
        black,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,
        @"bright-black",
        @"bright-red",
        @"bright-green",
        @"bright-yellow",
        @"bright-blue",
        @"bright-magenta",
        @"bright-cyan",
        @"bright-white",
    };
    pub fn named(name: Name) Color {
        return switch (name) {
            .default => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .black => .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .red => .{ .r = 205, .g = 0, .b = 0, .a = 255 },
            .green => .{ .r = 0, .g = 205, .b = 0, .a = 255 },
            .yellow => .{ .r = 205, .g = 205, .b = 0, .a = 255 },
            .blue => .{ .r = 0, .g = 0, .b = 238, .a = 255 },
            .magenta => .{ .r = 205, .g = 0, .b = 205, .a = 255 },
            .cyan => .{ .r = 0, .g = 205, .b = 205, .a = 255 },
            .white => .{ .r = 229, .g = 229, .b = 229, .a = 255 },
            .@"bright-black" => .{ .r = 127, .g = 127, .b = 127, .a = 255 },
            .@"bright-red" => .{ .r = 255, .g = 0, .b = 0, .a = 255 },
            .@"bright-green" => .{ .r = 0, .g = 255, .b = 0, .a = 255 },
            .@"bright-yellow" => .{ .r = 255, .g = 255, .b = 0, .a = 255 },
            .@"bright-blue" => .{ .r = 92, .g = 92, .b = 255, .a = 255 },
            .@"bright-magenta" => .{ .r = 255, .g = 0, .b = 255, .a = 255 },
            .@"bright-cyan" => .{ .r = 0, .g = 255, .b = 255, .a = 255 },
            .@"bright-white" => .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        };
    }

    pub fn blend(src: Color, dst: Color) Color {
        return .{
            .r = lerp(src.r, dst.r, src.a),
            .g = lerp(src.g, dst.g, src.a),
            .b = lerp(src.b, dst.b, src.a),
            .a = dst.a,
        };
    }
    fn lerp(src: u8, dst: u8, fac: u8) u8 {
        const src_mix: u8 = @intCast(@as(u16, src) * fac / 255);
        const dst_mix: u8 = @intCast(@as(u16, dst) * (255 - fac) / 255);
        return src_mix + dst_mix;
    }

    pub fn jsonParseFromValue(
        arena: std.mem.Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) !Color {
        _ = arena;
        _ = options;

        if (value != .string) return error.UnexpectedToken;
        if (stripAnyPrefix(value.string, &.{ "#", "rgb:", "rgba:" })) |hex| {
            const parsed = try std.fmt.parseInt(u32, hex, 16);
            const bits: u32 = switch (hex.len) {
                3 => duplicateNibbles(parsed << 4 | 0xf),
                4 => duplicateNibbles(parsed),
                6 => parsed << 8 | 0xff,
                8 => parsed,
                else => return error.InvalidEnumTag,
            };
            return @bitCast(bits);
        } else if (std.meta.stringToEnum(Name, value.string)) |name| {
            return .named(name);
        } else {
            return error.InvalidEnumTag;
        }
    }

    // Turns an integer 0xABCD into 0xAABBCCDD
    fn duplicateNibbles(x: u32) u32 {
        return 0x11 * spreadNibbles(x);
    }
    fn spreadNibbles(x: u32) u32 {
        if (builtin.zig_backend == .stage2_llvm and builtin.cpu.has(.x86, .bmi)) {
            return @"llvm.x86.bmi.pdep.32"(x, 0xF0F0F0F);
        }

        const spread_bytes = (x & 0xFF00) << 8 | (x & 0xFF);
        return (spread_bytes & 0xF000F0) << 4 | (spread_bytes & 0xF000F);
    }
    extern fn @"llvm.x86.bmi.pdep.32"(x: u32, mask: u32) u32;
};

fn stripAnyPrefix(str: []const u8, prefixes: []const []const u8) ?[]const u8 {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, str, prefix)) {
            return str[prefix.len..];
        }
    }
    return null;
}

pub const Coord = struct {
    line: u32,
    column: u32,
};

pub const Face = struct {
    fg: Color,
    bg: Color,
    attributes: []const Attribute,
    underline: Color = .named(.default),
};

pub const Line = []const Atom;
// keep-sorted end

pub fn send(call: KakMethod, writer: *std.Io.Writer) !void {
    const fmt = std.json.fmt(call, .{});
    std.log.scoped(.rpc_send).debug("-> {f}", .{fmt});
    try writer.print("{f}\n", .{fmt});
}

pub fn recv(arena: std.mem.Allocator, line: []const u8) !UiMethod {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    std.log.scoped(.rpc_recv).debug("<- {f}", .{std.json.fmt(parsed, .{})});
    return try std.json.parseFromValueLeaky(UiMethod, arena, parsed, .{});
}

const std = @import("std");
const builtin = @import("builtin");
const input = @import("input.zig");
