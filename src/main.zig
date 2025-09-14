pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    var kak_process: std.process.Child = .init(&.{ "kak", "-ui", "json" }, arena.allocator());
    kak_process.stdin_behavior = .Pipe;
    kak_process.stdout_behavior = .Pipe;
    try kak_process.spawn();
    defer _ = kak_process.kill() catch {};

    var kak_stdin_buf: [1024]u8 = undefined;
    var kak_stdin = kak_process.stdin.?.writerStreaming(&kak_stdin_buf);

    var poller = std.Io.poll(gpa, PollEnum, .{ .kak_stdout = kak_process.stdout.? });
    defer poller.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);
        processRpcRequests(arena.allocator(), &poller, 100 * std.time.ns_per_ms) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        std.log.debug("sending quit message", .{});
        try rpc.send(&kak_stdin.interface, .{
            .keys = &.{":q<ret>"},
        });
        try kak_stdin.interface.flush();
    }

    _ = try kak_process.wait();
}

fn processRpcRequests(arena: std.mem.Allocator, poller: *std.Io.Poller(PollEnum), timeout: u64) !void {
    var timer: std.time.Timer = try .start();
    while (true) {
        const used = timer.read();
        if (used >= timeout) break;
        if (!try poller.pollTimeout(timeout - used)) return error.EndOfStream;

        var r = poller.reader(.kak_stdout);
        while (std.mem.indexOfScalar(u8, r.buffered(), '\n')) |line_len| {
            const call = try rpc.recv(arena, r.buffered()[0..line_len]);
            r.toss(line_len + 1);
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
}

const PollEnum = enum { kak_stdout };

const std = @import("std");
const rpc = @import("rpc.zig");
