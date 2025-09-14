pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    var stdin_buf: [1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buf);
    while (true) {
        defer _ = arena.reset(.retain_capacity);
        const call = try rpc.recv(arena.allocator(), &stdin.interface);
        switch (call) {
            .draw => {},
            .draw_status => {},
            .info_hide => {},
            .info_show => {},
            .menu_hide => {},
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
const rpc = @import("rpc.zig");
