const Kakoune = @This();

process: std.process.Child,
stdin_buf: [1024]u8,
stdin: std.fs.File.Writer,
recv: Receiver,

pub fn init(kak: *Kakoune, gpa: std.mem.Allocator) !void {
    const sdl_event_id = c.SDL_RegisterEvents(1);
    if (sdl_event_id == 0) {
        return error.OutOfMemory;
    }

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
            .lock = .{},
            .sdl_event_id = sdl_event_id,
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

pub fn call(kak: *Kakoune, method: rpc.KakMethod) !void {
    const writer = &kak.stdin.interface;
    try rpc.send(method, writer);
    try writer.flush();
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
    lock: std.Thread.Mutex,
    sdl_event_id: u32,

    // TODO: put UiMethods directly on the SDL event queue
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
        recv.yield();
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
                const msg = try rpc.recv(recv.arena.allocator(), line);
                if (msg == .refresh) {
                    recv.yield();
                } else {
                    try recv.calls.append(gpa, msg);
                }
            }
        }
    }

    /// Yield to the SDL event loop
    fn yield(recv: *Receiver) void {
        var ev: c.SDL_Event = .{ .user = .{
            .type = recv.sdl_event_id,
        } };
        if (!c.SDL_PushEvent(&ev)) {
            std.log.warn("SDL_PushEvent failed: {s}", .{c.SDL_GetError()});
        }
    }
};

const PollEnum = enum { kak_stdout };

const std = @import("std");
const c = @import("c.zig").c;

const rpc = @import("rpc.zig");
