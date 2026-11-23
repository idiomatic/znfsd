//! The control socket: commands sent to a running daemon.
//!
//! A request is a command's words: a count, then each word's length and
//! bytes. A reply is the exit status, then the output and the error text,
//! each with its length. Integers are big-endian u32s; one request per
//! connection.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const sys = @import("libnfsd").sys;

const log = std.log.scoped(.znfsd);

/// The largest request or reply part.
const max_part = 16 * 1024 * 1024;

/// How long a peer has to send its request, and then to take the reply,
/// so a silent one can't hold up every other command.
const deadline: Io.Duration = .fromSeconds(5);

/// The default socket path: per the user unless root, per the OS.
pub fn defaultPath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map, root: bool) error{ OutOfMemory, NoRuntimeDir }![]const u8 {
    if (root) return "/var/run/znfsd.sock";
    const dir = if (builtin.os.tag.isDarwin()) environ.get("TMPDIR") else environ.get("XDG_RUNTIME_DIR");
    const d = dir orelse return error.NoRuntimeDir;
    return std.fmt.allocPrint(arena, "{s}/znfsd.sock", .{std.mem.trimEnd(u8, d, "/")});
}

pub const Reply = struct {
    status: u8,
    out: []const u8,
    err: []const u8,
};

/// Sends `words` to the daemon at `path`; null when no daemon answers.
pub fn send(io: Io, arena: std.mem.Allocator, path: []const u8, words: []const []const u8) !?Reply {
    const address = net.UnixAddress.init(path) catch return null;
    var z: [net.UnixAddress.max_len + 1]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    if (kindAt(z[0..path.len :0]) != .socket) return null;
    const stream = address.connect(io) catch return null;
    defer stream.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;
    try w.writeInt(u32, @intCast(words.len), .big);
    for (words) |word| {
        try w.writeInt(u32, @intCast(word.len), .big);
        try w.writeAll(word);
    }
    try w.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;
    const status = try r.takeInt(u32, .big);
    return .{ .status = @intCast(@min(status, 255)), .out = try readPart(r, arena), .err = try readPart(r, arena) };
}

/// What is at a socket path. Connecting to anything but a socket is
/// refused, and on macOS fails as a bug in `std.Io.Threaded`.
fn kindAt(path: [:0]const u8) enum { absent, socket, other } {
    var attr: sys.Attr = undefined;
    if (sys.lstat(path, &attr) != .SUCCESS) return .absent;
    return if (attr.mode & std.c.S.IFMT == std.c.S.IFSOCK) .socket else .other;
}

fn readPart(r: *Io.Reader, arena: std.mem.Allocator) ![]const u8 {
    const len = try r.takeInt(u32, .big);
    if (len > max_part) return error.TooLong;
    const buf = try arena.alloc(u8, len);
    try r.readSliceAll(buf);
    return buf;
}

/// Runs one command for the daemon, writing to `out` and `err`.
pub const Handler = struct {
    ptr: *anyopaque,
    handle: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, words: []const []const u8, out: *Io.Writer, err: *Io.Writer) u8,
};

pub const ListenError = error{ InUse, SocketPath, NotSocket } || net.UnixAddress.ListenError;

/// Listens at `path`, replacing a stale socket but not a live daemon's,
/// nor anything else there, with mode 0600.
pub fn listen(io: Io, path: []const u8) ListenError!net.Server {
    const address = net.UnixAddress.init(path) catch return error.SocketPath;
    var z: [net.UnixAddress.max_len + 1]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    switch (kindAt(z[0..path.len :0])) {
        .absent => {},
        .other => return error.NotSocket,
        .socket => {
            if (address.connect(io)) |stream| {
                stream.close(io);
                return error.InUse;
            } else |_| {}
            _ = std.c.unlink(z[0..path.len :0]);
        },
    }
    // Only the owner may connect, from the moment the socket exists.
    const old = std.c.umask(0o177);
    defer _ = std.c.umask(old);
    return address.listen(io, .{});
}

/// Removes the socket file when the daemon stops.
pub fn remove(path: []const u8) void {
    var z: [net.UnixAddress.max_len + 1]u8 = undefined;
    if (path.len > net.UnixAddress.max_len) return;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    _ = std.c.unlink(z[0..path.len :0]);
}

/// Answers requests on `server`, one at a time, until canceled.
pub fn serve(io: Io, gpa: std.mem.Allocator, server: *net.Server, handler: Handler) Io.Cancelable!void {
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("control accept: {t}", .{err});
                continue;
            },
        };
        defer stream.close(io);
        // A connection closed without a request is another daemon's
        // check for this one, not an error.
        answer(io, gpa, stream, handler) catch |err| if (err != error.EndOfStream) log.warn("control request: {t}", .{err});
    }
}

fn answer(io: Io, gpa: std.mem.Allocator, stream: net.Stream, handler: Handler) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const words = words: {
        var timer = try io.concurrent(watchdog, .{ io, stream });
        defer timer.cancel(io) catch {};
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        const r = &reader.interface;
        const count = try r.takeInt(u32, .big);
        if (count > 4096) return error.TooLong;
        const words = try arena.alloc([]const u8, count);
        for (words) |*word| word.* = try readPart(r, arena);
        break :words words;
    };

    var out: Io.Writer.Allocating = .init(arena);
    var err: Io.Writer.Allocating = .init(arena);
    const status = handler.handle(handler.ptr, arena, words, &out.writer, &err.writer);

    var timer = try io.concurrent(watchdog, .{ io, stream });
    defer timer.cancel(io) catch {};
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;
    try w.writeInt(u32, status, .big);
    for ([_][]const u8{ out.written(), err.written() }) |part| {
        try w.writeInt(u32, @intCast(part.len), .big);
        try w.writeAll(part);
    }
    try w.flush();
}

/// Shuts `stream` down once `deadline` passes, unless canceled first,
/// ending any read or write waiting on it.
fn watchdog(io: Io, stream: net.Stream) Io.Cancelable!void {
    try io.sleep(deadline, .awake);
    stream.shutdown(io, .both) catch {};
}

const testing = std.testing;

test "send a command to a listening daemon" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var path_buf: [300]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/c.sock", .{dir});

    const Echo = struct {
        fn handle(ptr: *anyopaque, arena: std.mem.Allocator, words: []const []const u8, out: *Io.Writer, err: *Io.Writer) u8 {
            _ = .{ ptr, arena };
            for (words) |word| out.print("{s};", .{word}) catch {};
            err.writeAll("hal") catch {};
            return 3;
        }
    };
    var dummy: u8 = 0;
    var server = try listen(io, path);
    defer server.deinit(io);
    try testing.expectError(error.InUse, listen(io, path));
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serve, .{ io, testing.allocator, &server, Handler{ .ptr = &dummy, .handle = Echo.handle } });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const reply = (try send(io, arena_state.allocator(), path, &.{ "export", "list" })).?;
    try testing.expectEqual(3, reply.status);
    try testing.expectEqualStrings("export;list;", reply.out);
    try testing.expectEqualStrings("hal", reply.err);

    try testing.expectEqual(null, try send(io, arena_state.allocator(), "/nonexistent/skynet.sock", &.{"stop"}));

    // A peer that never sends a request is dropped, and others answered.
    const address = try net.UnixAddress.init(path);
    const silent = try address.connect(io);
    defer silent.close(io);
    const again = (try send(io, arena_state.allocator(), path, &.{"stop"})).?;
    try testing.expectEqualStrings("stop;", again.out);
}

test "listen replaces only a socket" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var path_buf: [300]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/c.sock", .{dir});
    try tmp.dir.writeFile(io, .{ .sub_path = "c.sock", .data = "hal" });
    try testing.expectError(error.NotSocket, listen(io, path));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(null, try send(io, arena_state.allocator(), path, &.{"stop"}));
    try tmp.dir.deleteFile(io, "c.sock");

    // A stale socket, nobody answering on it, is replaced.
    var stale = try listen(io, path);
    stale.deinit(io);
    var server = try listen(io, path);
    server.deinit(io);
}
