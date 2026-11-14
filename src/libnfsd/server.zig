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
            const reply = program.handle(program.ptr, ctx, call, &results);
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
pub fn serveUdp(io: Io, gpa: std.mem.Allocator, programs: []const Program, socket: net.Socket) Io.Cancelable!void {
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
        const ctx: Context = .{ .io = io, .from = message.from, .protocol = .udp };
        const reply = dispatch(programs, ctx, message.data, out) orelse continue;
        socket.send(io, &message.from, reply) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => log.warn("udp send: {t}", .{err}),
        };
    }
}

/// Serves RPC over TCP on `listener` until canceled, one task per connection.
pub fn serveTcp(
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    listener: *net.Server,
    max_record: usize,
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
        connections.concurrent(io, serveConnection, .{ io, gpa, programs, stream, max_record }) catch |err| {
            log.warn("tcp connection: {t}", .{err});
            stream.close(io);
        };
    }
}

fn serveConnection(
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    stream: net.Stream,
    max_record: usize,
) Io.Cancelable!void {
    defer stream.close(io);
    const out = gpa.alloc(u8, max_record) catch return;
    defer gpa.free(out);
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const ctx: Context = .{ .io = io, .from = stream.socket.address, .protocol = .tcp };

    while (true) {
        rpc.record.read(&reader.interface, gpa, &message, max_record) catch |err| {
            if (reader.err) |e| if (e == error.Canceled) return error.Canceled;
            if (err != error.EndOfStream) log.warn("tcp read: {t}", .{err});
            return;
        };
        const reply = dispatch(programs, ctx, message.items, out) orelse continue;
        rpc.record.write(&writer.interface, reply) catch return;
        writer.interface.flush() catch return;
    }
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
    try group.concurrent(io, serveUdp, .{ io, testing.allocator, &programs, udp });
    try group.concurrent(io, serveTcp, .{ io, testing.allocator, &programs, &tcp, 4096 });

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
