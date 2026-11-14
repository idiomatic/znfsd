//! RPC serving: dispatch calls to programs, over UDP datagrams and TCP
//! record-marked streams.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");

const log = std.log.scoped(.libnfsd);

/// Largest UDP datagram.
pub const max_datagram = 65535;

/// Where a call came from.
pub const Context = struct {
    io: Io,
    from: net.IpAddress,
    protocol: net.Protocol,
    /// Told of every call answered, as for an activity monitor.
    observer: ?*const Observer = null,
};

/// One answered call, for an observer.
pub const Observed = struct {
    from: net.IpAddress,
    protocol: net.Protocol,
    prog: u32,
    vers: u32,
    proc: u32,
    reply: std.meta.Tag(rpc.Reply),
    /// Bytes of results.
    bytes: usize,
    nanoseconds: u64,
};

pub const Observer = struct {
    ptr: *anyopaque,
    observe: *const fn (ptr: *anyopaque, io: Io, call: Observed) void,
};

/// An RPC program: its number, supported versions, and handler.
pub const Program = struct {
    prog: u32,
    low: u32,
    high: u32,
    ptr: *anyopaque,
    /// Writes the results of a successful call to `results` and returns
    /// `.success`, or returns another status and writes nothing.
    handle: *const fn (ptr: *anyopaque, ctx: Context, call: rpc.Call, results: *Io.Writer) rpc.Reply,
};

/// Size of a success header: xid, REPLY, MSG_ACCEPTED, AUTH_NONE verifier,
/// and SUCCESS. Results are written after it, so they needn't be copied.
const success_header = 24;

/// Answers `message`, writing the reply into `out`. Returns the reply, or
/// null when the message gets none.
pub fn dispatch(programs: []const Program, ctx: Context, message: []const u8, out: []u8) ?[]const u8 {
    std.debug.assert(out.len >= success_header);
    const call, const reply: rpc.Reply = switch (rpc.decodeCall(message)) {
        .ignore => return null,
        .reject => |r| return encodeStatus(out, r.xid, r.reply),
        .call => |call| .{ call, status: {
            const program = for (programs) |*p| {
                if (p.prog == call.prog) break p;
            } else break :status .prog_unavail;
            if (call.vers < program.low or call.vers > program.high) {
                break :status .{ .prog_mismatch = .{ .low = program.low, .high = program.high } };
            }
            var results: Io.Writer = .fixed(out[success_header..]);
            log.debug("{f} {t}: prog {d} vers {d} proc {d}: arrived", .{ ctx.from, ctx.protocol, call.prog, call.vers, call.proc });
            const started = if (ctx.observer != null) Io.Clock.awake.now(ctx.io) else undefined;
            const reply = program.handle(program.ptr, ctx, call, &results);
            if (ctx.observer) |o| o.observe(o.ptr, ctx.io, .{
                .from = ctx.from,
                .protocol = ctx.protocol,
                .prog = call.prog,
                .vers = call.vers,
                .proc = call.proc,
                .reply = reply,
                .bytes = results.end,
                .nanoseconds = @intCast(@max(0, started.durationTo(Io.Clock.awake.now(ctx.io)).nanoseconds)),
            });
            log.debug("{f} {t}: prog {d} vers {d} proc {d}: {t}, {d} bytes", .{
                ctx.from, ctx.protocol, call.prog, call.vers, call.proc, reply, results.end,
            });
            if (reply == .none) return null;
            if (reply == .success) {
                var header: Io.Writer = .fixed(out[0..success_header]);
                rpc.Reply.encode(.success, .init(&header), call.xid) catch unreachable;
                std.debug.assert(header.end == success_header);
                return out[0 .. success_header + results.end];
            }
            break :status reply;
        } },
    };
    return encodeStatus(out, call.xid, reply);
}

fn encodeStatus(out: []u8, xid: u32, reply: rpc.Reply) []const u8 {
    var w: Io.Writer = .fixed(out);
    reply.encode(.init(&w), xid) catch unreachable; // a status header fits in `success_header` bytes plus a range
    return w.buffered();
}

/// Serves RPC over UDP on `socket` until canceled.
pub fn serveUdp(io: Io, gpa: std.mem.Allocator, programs: []const Program, socket: net.Socket, observer: ?*const Observer) Io.Cancelable!void {
    const buf = gpa.alloc(u8, 2 * max_datagram) catch {
        log.err("udp: out of memory", .{});
        return;
    };
    defer gpa.free(buf);
    const in = buf[0..max_datagram];
    const out = buf[max_datagram..];
    while (true) {
        const message = socket.receive(io, in) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("udp receive: {t}", .{err});
                continue;
            },
        };
        if (message.flags.trunc) continue;
        const ctx: Context = .{ .io = io, .from = message.from, .protocol = .udp, .observer = observer };
        const reply = dispatch(programs, ctx, message.data, out) orelse continue;
        socket.send(io, &message.from, reply) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => log.warn("udp send: {t}", .{err}),
        };
    }
}

/// How TCP connections, accepted or adopted, are served.
pub const ConnectionOptions = struct {
    /// Largest record accepted.
    max_record: usize = 1024 * 1024 + 4096,
    /// Calls answered at once on one connection; their replies may go out
    /// in any order, matched by XID. Each can hold two records' worth of
    /// buffers.
    max_calls: usize = 16,
    /// Told of every call answered.
    observer: ?*const Observer = null,
};

/// Serves RPC over TCP on `listener` until canceled, one task per connection.
pub fn serveTcp(
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    listener: *net.Server,
    options: ConnectionOptions,
) Io.Cancelable!void {
    var connections: Io.Group = .init;
    defer connections.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("tcp accept: {t}", .{err});
                continue;
            },
        };
        connections.concurrent(io, serveConnection, .{ io, gpa, programs, stream, options }) catch |err| {
            log.warn("tcp connection: {t}", .{err});
            stream.close(io);
        };
    }
}

/// A call's buffers: its record, and room for its reply.
const Slot = struct {
    busy: std.atomic.Value(bool) = .init(false),
    message: std.ArrayList(u8) = .empty,
    out: []u8 = &.{},

    /// Allocates both buffers whole, so reading a record never allocates.
    /// An allocator may wait on a cancelable lock and drop the cancelation
    /// (`DebugAllocator`'s stack traces do, on macOS), which would leave
    /// the next read deaf to it, so cancelation is blocked meanwhile.
    fn allocate(slot: *Slot, io: Io, gpa: std.mem.Allocator, size: usize) std.mem.Allocator.Error!void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        try slot.message.ensureTotalCapacityPrecise(gpa, size);
        slot.out = try gpa.alloc(u8, size);
    }
};

/// One connection's state, shared by its reader and its calls.
const Connection = struct {
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    ctx: Context,
    stream: net.Stream,
    writer: *Io.Writer,
    /// Keeps replies whole.
    write_lock: Io.Mutex = .init,
    /// Slots not busy.
    free: Io.Semaphore,
    slots: []Slot,

    /// Answers the call in `slot`, then frees the slot.
    fn answer(c: *Connection, slot: *Slot) Io.Cancelable!void {
        defer {
            slot.busy.store(false, .release);
            c.free.post(c.io);
        }
        const reply = dispatch(c.programs, c.ctx, slot.message.items, slot.out) orelse return;
        try c.write_lock.lock(c.io);
        defer c.write_lock.unlock(c.io);
        rpc.record.write(c.writer, reply) catch return c.broken();
        c.writer.flush() catch return c.broken();
    }

    /// A reply can't be sent, so stop reading calls too.
    fn broken(c: *Connection) void {
        c.stream.shutdown(c.io, .both) catch {};
    }
};

/// Serves RPC over one connected stream (TCP, a Unix socket, vsock) until
/// the peer closes it or the task is canceled, then closes it. Calls run
/// concurrently, up to `options.max_calls`. `stream.socket.address` stands
/// for the peer in export rules and logs.
pub fn serveConnection(
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    stream: net.Stream,
    options: ConnectionOptions,
) Io.Cancelable!void {
    defer stream.close(io);
    const slots = gpa.alloc(Slot, @max(1, options.max_calls)) catch return;
    @memset(slots, .{});
    defer {
        for (slots) |*s| {
            s.message.deinit(gpa);
            gpa.free(s.out);
        }
        gpa.free(slots);
    }
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var c: Connection = .{
        .io = io,
        .gpa = gpa,
        .programs = programs,
        .ctx = .{ .io = io, .from = stream.socket.address, .protocol = .tcp, .observer = options.observer },
        .stream = stream,
        .writer = &writer.interface,
        .free = .{ .permits = slots.len },
        .slots = slots,
    };
    var calls: Io.Group = .init;
    defer calls.cancel(io);

    while (true) {
        try c.free.wait(io);
        const slot = for (slots) |*s| {
            if (s.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) break s;
        } else unreachable; // a permit means a free slot
        if (slot.out.len == 0) slot.allocate(io, gpa, options.max_record) catch {
            log.warn("tcp: out of memory", .{});
            break;
        };
        rpc.record.read(&reader.interface, gpa, &slot.message, options.max_record) catch |err| {
            if (reader.err) |e| if (e == error.Canceled) return error.Canceled;
            if (err != error.EndOfStream) log.warn("tcp read: {t}", .{err});
            break;
        };
        // Without a task to spare, answer before reading on.
        calls.concurrent(io, Connection.answer, .{ &c, slot }) catch try c.answer(slot);
    }
    // The peer is gone or misbehaved; let calls already read finish.
    try calls.await(io);
}

const testing = std.testing;

const Echo = struct {
    calls: usize = 0,

    fn handle(ptr: *anyopaque, ctx: Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
        _ = ctx;
        const echo: *Echo = @ptrCast(@alignCast(ptr));
        echo.calls += 1;
        return switch (call.proc) {
            0 => .success,
            1 => {
                results.writeAll(call.args) catch return .system_err;
                return .success;
            },
            else => .proc_unavail,
        };
    }

    fn program(echo: *Echo) Program {
        return .{ .prog = 400000, .low = 1, .high = 2, .ptr = echo, .handle = handle };
    }
};

fn encodeCall(buf: []u8, prog: u32, vers: u32, proc: u32, args: []const u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    const call: rpc.Call = .{
        .xid = 9,
        .prog = prog,
        .vers = vers,
        .proc = proc,
        .cred = .none,
        .verf = .none,
        .args = args,
    };
    call.encode(.init(&w)) catch unreachable;
    return w.buffered();
}

fn acceptStat(reply: []const u8) u32 {
    return std.mem.readInt(u32, reply[20..24], .big);
}

test "dispatch to programs, versions, and procedures" {
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    const ctx: Context = .{ .io = testing.io, .from = .{ .ip4 = .loopback(0) }, .protocol = .udp };
    var call_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;

    var reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 1, "hal\x00"), &out).?;
    try testing.expectEqual(0, acceptStat(reply));
    try testing.expectEqualStrings("hal\x00", reply[24..]);

    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400001, 1, 0, ""), &out).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.prog_unavail), acceptStat(reply));

    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 3, 0, ""), &out).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.prog_mismatch), acceptStat(reply));
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x01\x00\x00\x00\x02", reply[24..32]);

    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 2, 7, ""), &out).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.proc_unavail), acceptStat(reply));

    var too_small: [26]u8 = undefined;
    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 1, "perihelion\x00\x00"), &too_small).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.system_err), acceptStat(reply));
    try testing.expectEqual(3, echo.calls);
}

test "an observer sees each answered call" {
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    const Seen = struct {
        calls: usize = 0,
        last: Observed = undefined,
        fn observe(ptr: *anyopaque, _: Io, call: Observed) void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            s.calls += 1;
            s.last = call;
        }
    };
    var seen: Seen = .{};
    const observer: Observer = .{ .ptr = &seen, .observe = Seen.observe };
    const ctx: Context = .{ .io = testing.io, .from = .{ .ip4 = .loopback(0) }, .protocol = .udp, .observer = &observer };
    var call_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    _ = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 1, "art\x00"), &out).?;
    _ = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 7, ""), &out).?;
    try testing.expectEqual(2, seen.calls);
    try testing.expectEqual(.proc_unavail, seen.last.reply);
    try testing.expectEqual(7, seen.last.proc);
    // Programs that don't exist never reach a handler, so aren't observed.
    _ = dispatch(&programs, ctx, encodeCall(&call_buf, 400001, 1, 0, ""), &out).?;
    try testing.expectEqual(2, seen.calls);
}

test "serve over UDP and TCP on loopback" {
    const io = testing.io;
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};

    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    const udp = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer udp.close(io);
    var tcp = try any.listen(io, .{ .reuse_address = true });
    defer tcp.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveUdp, .{ io, testing.allocator, &programs, udp, null });
    try group.concurrent(io, serveTcp, .{ io, testing.allocator, &programs, &tcp, .{ .max_record = 4096 } });

    var call_buf: [64]u8 = undefined;
    const call = encodeCall(&call_buf, 400000, 1, 1, "art\x00");

    const client = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer client.close(io);
    try client.send(io, &udp.address, call);
    var in: [128]u8 = undefined;
    const message = try client.receiveTimeout(io, &in, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqualStrings("art\x00", message.data[24..]);

    const stream = try tcp.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buf: [128]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try rpc.record.write(&writer.interface, call);
    try writer.interface.flush();
    var read_buf: [128]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    try testing.expectEqualStrings("art\x00", reply.items[24..]);
}

/// A connected pair of Unix stream sockets, as `Stream`s.
fn testPair() ![2]net.Stream {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    var pair: [2]net.Stream = undefined;
    for (&pair, fds) |*s, fd| s.* = .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .unspecified(0) } } };
    return pair;
}

test "a connection answers calls concurrently, replies matched by XID" {
    const io = testing.io;
    // Procedure 1 waits for procedure 2, so answering one call at a time
    // would time out.
    const Gate = struct {
        open: Io.Event = .unset,

        fn handle(ptr: *anyopaque, ctx: Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
            _ = results;
            const gate: *@This() = @ptrCast(@alignCast(ptr));
            switch (call.proc) {
                1 => gate.open.waitTimeout(ctx.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch return .system_err,
                2 => gate.open.set(ctx.io),
                else => return .proc_unavail,
            }
            return .success;
        }
    };
    var gate: Gate = .{};
    const programs = [_]Program{.{ .prog = 400000, .low = 1, .high = 1, .ptr = &gate, .handle = Gate.handle }};
    const pair = try testPair();
    defer pair[1].close(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveConnection, .{ io, testing.allocator, &programs, pair[0], .{ .max_record = 4096 } });

    var write_buf: [128]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    for ([_]u32{ 1, 2 }) |proc| {
        var call_buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&call_buf);
        const call: rpc.Call = .{ .xid = 10 + proc, .prog = 400000, .vers = 1, .proc = proc, .cred = .none, .verf = .none, .args = &.{} };
        try call.encode(.init(&w));
        try rpc.record.write(&writer.interface, w.buffered());
        try writer.interface.flush();
    }
    var read_buf: [128]u8 = undefined;
    var reader = pair[1].reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    for ([_]u32{ 12, 11 }) |xid| {
        try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
        try testing.expectEqual(xid, std.mem.readInt(u32, reply.items[0..4], .big));
        try testing.expectEqual(0, acceptStat(reply.items));
    }
}

test "a connection the embedder accepted carries MOUNT and NFS" {
    const io = testing.io;
    const exports = @import("exports.zig");
    const files_mod = @import("files.zig");
    const mount_mod = @import("mount.zig");
    const nfs_mod = @import("nfs.zig");
    const sys = @import("sys.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "share");
    var buf: [sys.max_path]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = try std.fmt.allocPrint(testing.allocator, "{s}/share", .{buf[0..n]});
    defer testing.allocator.free(root);
    const rules = [_]exports.Rule{.{ .path = root, .client = .any, .options = .{ .squash = .none } }};
    const table: exports.Table = .{ .rules = &rules };
    var mount: mount_mod.Mount = .init(testing.allocator, &table);
    defer mount.deinit();
    var files: files_mod.Files = .init(testing.allocator);
    defer files.deinit();
    var nfs: nfs_mod.Nfs = .init(testing.allocator, &table, &files, "znfsd-t\x00".*);

    const programs = [_]Program{ mount.program(), nfs.program() };
    const pair = try testPair();
    defer pair[1].close(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveConnection, .{ io, testing.allocator, &programs, pair[0], .{} });

    var cred_buf: [64]u8 = undefined;
    var cw: Io.Writer = .fixed(&cred_buf);
    const auth: rpc.AuthSys = .{ .stamp = 0, .machine_name = "perihelion", .uid = std.c.getuid(), .gid = std.c.getgid() };
    try auth.encode(.init(&cw));
    var write_buf: [1024]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    var read_buf: [1024]u8 = undefined;
    var reader = pair[1].reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    var args_buf: [sys.max_path + 8]u8 = undefined;

    // MNT, then GETATTR on the handle it returns, over the one connection.
    var aw: Io.Writer = .fixed(&args_buf);
    try xdr.Encoder.init(&aw).string(root);
    try sendCall(&writer.interface, 1, mount_mod.prog, 1, cw.buffered(), aw.buffered());
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    var d: xdr.Decoder = .init(reply.items[24..]);
    try testing.expectEqual(0, try d.u32_());
    const handle = try d.opaque_(64);

    aw = .fixed(&args_buf);
    try xdr.Encoder.init(&aw).opaque_(handle);
    try sendCall(&writer.interface, 2, nfs_mod.prog, 1, cw.buffered(), aw.buffered());
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    try testing.expectEqual(2, std.mem.readInt(u32, reply.items[0..4], .big));
    try testing.expectEqual(0, std.mem.readInt(u32, reply.items[20..24], .big));
    d = .init(reply.items[24..]);
    try testing.expectEqual(0, try d.u32_()); // NFS3_OK
    try testing.expectEqual(2, try d.u32_()); // NF3DIR
}

fn sendCall(w: *Io.Writer, xid: u32, prog: u32, proc: u32, cred: []const u8, args: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var cw: Io.Writer = .fixed(&buf);
    const call: rpc.Call = .{ .xid = xid, .prog = prog, .vers = 3, .proc = proc, .cred = .{ .flavor = .sys, .body = cred }, .verf = .none, .args = args };
    try call.encode(.init(&cw));
    try rpc.record.write(w, cw.buffered());
    try w.flush();
}
