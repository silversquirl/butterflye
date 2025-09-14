const Kakoune = @This();

process: std.process.Child,
stdin_buf: [1024]u8,
stdin: std.fs.File.Writer,
poller: std.Io.Poller(PollEnum),
waited: bool,

pub fn init(kak: *Kakoune, gpa: std.mem.Allocator) !void {
    var process: std.process.Child = .init(&.{ "kak", "-ui", "json" }, gpa);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    try process.spawn();

    kak.* = .{
        .process = process,
        .stdin_buf = undefined,
        .stdin = process.stdin.?.writerStreaming(&kak.stdin_buf),
        .poller = std.Io.poll(gpa, PollEnum, .{ .kak_stdout = kak.process.stdout.? }),
        .waited = false,
    };
}

pub fn deinit(kak: *Kakoune) void {
    if (!kak.waited) {
        _ = kak.process.kill() catch {};
        kak.waitForExit() catch {};
    }
    kak.poller.deinit();
}

fn waitForExit(kak: *Kakoune) !void {
    std.debug.assert(!kak.waited);
    _ = try kak.process.wait();
    kak.waited = true;
}

pub fn nextUiCall(kak: *Kakoune, arena: std.mem.Allocator, timeout: u64) !?rpc.UiMethod {
    var r = kak.poller.reader(.kak_stdout);
    const line_len = std.mem.indexOfScalar(u8, r.buffered(), '\n') orelse blk: {
        if (!try kak.poller.pollTimeout(timeout)) return error.EndOfStream;
        break :blk std.mem.indexOfScalar(u8, r.buffered(), '\n') orelse return null;
    };

    const call = try rpc.recv(arena, r.buffered()[0..line_len]);
    r.toss(line_len + 1);
    return call;
}

const PollEnum = enum { kak_stdout };

const std = @import("std");
const rpc = @import("rpc.zig");
