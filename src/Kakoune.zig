const Kakoune = @This();

process: std.process.Child,
stdin_buf: [1024]u8,
stdin: std.fs.File.Writer,
recv: Receiver,

pub fn init(kak: *Kakoune, gpa: std.mem.Allocator, win: *dvui.Window) !void {
    var process: std.process.Child = .init(&.{ "kak", "-ui", "json" }, gpa);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    try process.spawn();
    try process.waitForSpawn();

    kak.* = .{
        .process = process,
        .stdin_buf = undefined,
        .stdin = process.stdin.?.writerStreaming(&kak.stdin_buf),
        .recv = .{
            .thread = undefined,
            .main_window = win,
            .lock = .{},
            .arena = .init(gpa),
            .err = null,
            .calls = .empty,
        },
    };
    kak.recv.thread = try .spawn(.{}, Receiver.threadMain, .{ &kak.recv, kak.process.stdout.? });
}

pub fn deinit(kak: *Kakoune) void {
    _ = kak.process.kill() catch {
        // The only errors this can return are:
        // - spawn errors, which we handle in `init`
        // - permission denied, which should not be possible since we're the parent of the process and run as the same user
        // - "process already exited", which is fine
        // So, do nothing :)
    };

    _ = kak.process.wait() catch {};
    kak.recv.thread.join();
}

pub fn acquireUiCalls(kak: *Kakoune) Receiver.Error![]const rpc.UiMethod {
    kak.recv.lock.lock();
    errdefer kak.recv.lock.unlock();
    if (kak.recv.err) |err| {
        return err;
    }
    return kak.recv.calls.items;
}
pub fn releaseUiCalls(kak: *Kakoune) void {
    kak.recv.calls.clearRetainingCapacity();
    _ = kak.recv.arena.reset(.retain_capacity);
    kak.recv.lock.unlock();
}

const Receiver = struct {
    thread: std.Thread,
    main_window: *dvui.Window,
    lock: std.Thread.Mutex,
    arena: std.heap.ArenaAllocator,
    err: ?Error,
    calls: std.ArrayList(rpc.UiMethod),

    const Error =
        std.Io.Reader.Error ||
        std.fs.File.ReadError ||
        std.json.ParseError(std.json.Scanner) ||
        std.mem.Allocator.Error;

    fn threadMain(recv: *Receiver, pipe: std.fs.File) void {
        const err = recv.loop(pipe);
        if (@errorReturnTrace()) |trace| {
            std.log.err("receiver thread: {s}", .{@errorName(err)});
            std.debug.dumpStackTrace(trace.*);
        }

        recv.lock.lock();
        defer recv.lock.unlock();
        recv.err = err;
        recv.calls.deinit(recv.arena.child_allocator);
        recv.arena.deinit();
        dvui.refresh(recv.main_window, @src(), null);
    }

    fn loop(recv: *Receiver, pipe: std.fs.File) Error {
        const gpa = recv.arena.child_allocator;
        var r = pipe.readerStreaming(try gpa.alloc(u8, 1024));
        defer gpa.free(r.interface.buffer);

        while (true) {
            const line = while (true) {
                if (r.interface.takeDelimiterInclusive('\n')) |line| {
                    break line;
                } else |err| switch (err) {
                    error.StreamTooLong => {},
                    error.EndOfStream => |e| return e,
                    error.ReadFailed => |e| return r.err orelse e,
                }

                // Expand
                var array: std.ArrayList(u8) = .fromOwnedSlice(r.interface.buffer);
                defer r.interface.buffer = array.allocatedSlice();
                try array.ensureUnusedCapacity(gpa, 1);
            };

            {
                recv.lock.lock();
                defer recv.lock.unlock();
                const call = try rpc.recv(recv.arena.allocator(), line);
                if (call == .refresh) {
                    dvui.refresh(recv.main_window, @src(), null);
                } else {
                    try recv.calls.append(gpa, call);
                }
            }
        }
    }
};

const PollEnum = enum { kak_stdout };

const std = @import("std");
const dvui = @import("dvui");

const rpc = @import("rpc.zig");
