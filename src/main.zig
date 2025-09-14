fn init() dvui.App.StartOptions {
    return .{
        .size = .{ .w = 800, .h = 600 },
        .title = "window",
    };
}

fn initWindow(win: *dvui.Window) !void {
    win.theme = switch (win.backend.preferredColorScheme() orelse .dark) {
        .dark => dvui.Theme.builtin.adwaita_dark,
        .light => dvui.Theme.builtin.adwaita_light,
    };
    try kakoune.init(win.gpa);
}

fn deinit() void {
    kakoune.deinit();
}

fn frame() !dvui.App.Result {
    kakoune.processRpcRequests(dvui.currentWindow().arena(), 10 * std.time.ns_per_ms) catch |err| switch (err) {
        error.EndOfStream => return .close,
        else => |e| return e,
    };

    return .ok;
}

var kakoune: Kakoune = undefined;
const Kakoune = struct {
    process: std.process.Child,
    stdin_buf: [1024]u8,
    stdin: std.fs.File.Writer,
    poller: std.Io.Poller(PollEnum),
    waited: bool,

    fn init(kak: *Kakoune, gpa: std.mem.Allocator) !void {
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

    fn deinit(kak: *Kakoune) void {
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

    fn processRpcRequests(kak: *Kakoune, arena: std.mem.Allocator, timeout: u64) !void {
        var timer: std.time.Timer = try .start();
        while (true) {
            const used = timer.read();
            if (used >= timeout) break;
            if (!try kak.poller.pollTimeout(timeout - used)) return error.EndOfStream;

            var r = kak.poller.reader(.kak_stdout);
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
};

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = init },
    .initFn = initWindow,
    .deinitFn = deinit,
    .frameFn = frame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;

const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const std = @import("std");
const dvui = @import("dvui");

const rpc = @import("rpc.zig");
