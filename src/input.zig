pub const KeyOrText = union(enum) {
    key: Key,
    text: []const u8,

    const Key = struct {
        name: [9]u8,
        flags: Flags,
        const Flags = packed struct(u3) {
            ctrl: bool = false,
            alt: bool = false,
            shift: bool = false,

            const none: Flags = .{};

            pub fn format(flags: Flags, writer: *std.Io.Writer) !void {
                if (flags.ctrl) {
                    try writer.writeAll("c-");
                }
                if (flags.alt) {
                    try writer.writeAll("a-");
                }
                if (flags.shift) {
                    try writer.writeAll("s-");
                }
            }
        };
    };

    /// If this key event should be sent to kakoune, returns a KeyOrText representing it.
    /// Returns null if the key should be ignored. If `mode == .text_enabled`, null will also
    /// be returned when the key is expected to be included in a corresponding text event.
    pub fn fromKey(ev: c.SDL_KeyboardEvent) ?KeyOrText {
        const shift: u16 = @intCast(ev.mod & c.SDL_KMOD_SHIFT);
        const key = c.SDL_GetKeyFromScancode(ev.scancode, shift, false);

        var name: [9:0]u8 = @splat(0);
        if (key == '<') {
            name[0..2].* = "lt".*;
        } else if (' ' <= key and key <= '~') {
            name[0] = @intCast(key);
        } else {
            const key_name = switch (key) {
                // keep-sorted start
                c.SDLK_BACKSPACE => "backspace",
                c.SDLK_DELETE => "del",
                c.SDLK_DOWN => "down",
                c.SDLK_END => "end",
                c.SDLK_ESCAPE => "esc",
                c.SDLK_HOME => "home",
                c.SDLK_INSERT => "ins",
                c.SDLK_LEFT => "left",
                c.SDLK_PAGEDOWN => "pagedown",
                c.SDLK_PAGEUP => "pageup",
                c.SDLK_RETURN => "ret",
                c.SDLK_RIGHT => "right",
                c.SDLK_TAB => "tab",
                c.SDLK_UP => "up",
                // keep-sorted end

                // keep-sorted start numeric=true
                c.SDLK_F1 => "F1",
                c.SDLK_F2 => "F2",
                c.SDLK_F3 => "F3",
                c.SDLK_F4 => "F4",
                c.SDLK_F5 => "F5",
                c.SDLK_F6 => "F6",
                c.SDLK_F7 => "F7",
                c.SDLK_F8 => "F8",
                c.SDLK_F9 => "F9",
                c.SDLK_F10 => "F10",
                c.SDLK_F11 => "F11",
                c.SDLK_F12 => "F12",
                // keep-sorted end

                else => return null,
            };
            @memcpy(name[0..key_name.len], key_name);
        }

        const flags: Key.Flags = .{
            .ctrl = ev.mod & c.SDL_KMOD_CTRL != 0,
            .alt = ev.mod & c.SDL_KMOD_ALT != 0,
            // Only pass shit to kak if it didn't modify the keycode
            .shift = key == ev.key and shift != 0,
        };

        return .{ .key = .{ .name = name, .flags = flags } };
    }

    pub fn jsonStringify(key_or_text: KeyOrText, s: *std.json.Stringify) !void {
        switch (key_or_text) {
            .key => |key| try stringifyKey(key, s),
            .text => |text| try stringifyText(text, s),
        }
    }

    fn stringifyKey(key: Key, s: *std.json.Stringify) !void {
        const name = std.mem.sliceTo(&key.name, 0);
        std.debug.assert(name.len > 0);
        if (name.len == 1 and key.flags == Key.Flags.none) {
            try s.write(name);
        } else {
            var buf: [32]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "<{f}{s}>", .{ key.flags, name }) catch unreachable;
            try s.write(out);
        }
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

pub fn button(btn: u8) ?rpc.KakMethod.Button {
    return switch (btn) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => null,
    };
}

const std = @import("std");
const c = @import("c.zig").c;
const rpc = @import("rpc.zig");
