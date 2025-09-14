pub const KeyOrText = union(enum) {
    key: dvui.Event.Key,
    text: []const u8,

    /// If this key event should be sent to kakoune, returns a KeyOrText representing it.
    /// If the key should be ignored, or if it will be processed by a corresponding text event, returns null.
    pub fn fromKey(key: dvui.Event.Key) ?KeyOrText {
        // Synchronize with stringifyKey
        return switch (key.code) {
            .kp_enter,
            .enter,
            .escape,
            .tab,
            .delete,
            .home,
            .end,
            .page_up,
            .page_down,
            .insert,
            .left,
            .right,
            .up,
            .down,
            .backspace,
            .space,
            .minus,
            => .{ .key = key },
            else => null,
        };
    }

    pub fn jsonStringify(key_or_text: KeyOrText, s: *std.json.Stringify) !void {
        switch (key_or_text) {
            .key => |key| try stringifyKey(key, s),
            .text => |text| try stringifyText(text, s),
        }
    }

    fn stringifyKey(key: dvui.Event.Key, s: *std.json.Stringify) !void {
        // Synchronize with fromKey
        const name = switch (key.code) {
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
            else => unreachable,
        };

        const mod = switch (key.mod) {
            .lshift, .rshift => "s-",
            .lalt, .ralt => "a-",
            .lcontrol, .rcontrol => "c-",
            else => "",
        };

        const angle = name.len > 1 or mod.len > 0;

        try s.beginWriteRaw();
        defer s.endWriteRaw();

        try s.writer.writeByte('"');
        if (angle) try s.writer.writeByte('<');
        try s.writer.writeAll(mod);
        try std.json.Stringify.encodeJsonStringChars(name, .{}, s.writer);
        if (angle) try s.writer.writeByte('>');
        try s.writer.writeByte('"');
    }

    fn stringifyText(text: []const u8, s: *std.json.Stringify) !void {
        try s.beginWriteRaw();
        defer s.endWriteRaw();

        try s.writer.writeByte('"');
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |next| {
            try std.json.Stringify.encodeJsonStringChars(text[pos..next], .{}, s.writer);
            try s.writer.writeAll("<lt>");
            pos = next + 1;
        }
        try std.json.Stringify.encodeJsonStringChars(text[pos..], .{}, s.writer);
        try s.writer.writeByte('"');
    }
};

pub fn button(btn: dvui.enums.Button) ?rpc.KakMethod.Button {
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
