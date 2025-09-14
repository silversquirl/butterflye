const Key = @This();

key: dvui.Event.Key,

pub fn init(key: dvui.Event.Key) ?Key {
    return switch (key.code) {
        else => .{ .key = key },
        .f1,
        .f2,
        .f3,
        .f4,
        .f5,
        .f6,
        .f7,
        .f8,
        .f9,
        .f10,
        .f11,
        .f12,
        .f13,
        .f14,
        .f15,
        .f16,
        .f17,
        .f18,
        .f19,
        .f20,
        .f21,
        .f22,
        .f23,
        .f24,
        .f25,
        .left_shift,
        .right_shift,
        .left_control,
        .right_control,
        .left_alt,
        .right_alt,
        .left_command,
        .right_command,
        .menu,
        .num_lock,
        .caps_lock,
        .print,
        .scroll_lock,
        .pause,
        => null,
    };
}

pub fn jsonStringify(k: Key, s: *std.json.Stringify) !void {
    const key = switch (k.key.code) {
        else => |printable| blk: {
            const name = @tagName(printable);
            std.debug.assert(name.len == 1);
            break :blk name;
        },
        .zero => "0",
        .one => "1",
        .two => "2",
        .three => "3",
        .four => "4",
        .five => "5",
        .six => "6",
        .seven => "7",
        .eight => "8",
        .nine => "9",

        .kp_divide => "/",
        .kp_multiply => "*",
        .kp_subtract => "minus",
        .kp_add => "plus",
        .kp_0 => "0",
        .kp_1 => "1",
        .kp_2 => "2",
        .kp_3 => "3",
        .kp_4 => "4",
        .kp_5 => "5",
        .kp_6 => "6",
        .kp_7 => "7",
        .kp_8 => "8",
        .kp_9 => "9",
        .kp_decimal => ".",
        .kp_equal => "=",
        .kp_enter => "ret",

        .enter => "ret",
        .escape => "esc",
        .tab => "tab",
        .delete => "del",
        .home => "home",
        .end => "end",
        .page_up => "pageup",
        .page_down => "pagedown",
        .insert => "ins",
        .left => "left",
        .right => "right",
        .up => "up",
        .down => "down",
        .backspace => "backspace",
        .space => "space",
        .minus => "minus",
        .equal => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => "semicolon",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .grave => "`",

        .unknown => "unknown",
    };

    const mod = switch (k.key.mod) {
        .lshift, .rshift => "s-",
        .lalt, .ralt => "a-",
        .lcontrol, .rcontrol => "c-",
        else => "",
    };

    const angle = key.len > 1 or mod.len > 0;

    try s.beginWriteRaw();
    defer s.endWriteRaw();

    try s.writer.writeByte('"');
    if (angle) try s.writer.writeByte('<');
    try s.writer.writeAll(mod);
    try std.json.Stringify.encodeJsonStringChars(key, .{}, s.writer);
    if (angle) try s.writer.writeByte('>');
    try s.writer.writeByte('"');
}

pub fn writeText(text: []const u8, s: *std.json.Stringify) !void {
    try s.beginWriteRaw();
    defer s.endWriteRaw();

    var it = std.mem.splitScalar(u8, text, '<');
    while (it.next()) |part| {
        try std.json.Stringify.encodeJsonStringChars(part, .{}, s.writer);
        if (it.rest().len > 0) try s.writer.writeAll("<lt>");
    }
}

pub fn getButton(btn: dvui.enums.Button) ?rpc.KakMethod.Button {
    return switch (btn) {
        .left => .left,
        .middle => .middle,
        .right => .right,
        else => null,
    };
}

const std = @import("std");
const dvui = @import("dvui");
const rpc = @import("rpc.zig");
