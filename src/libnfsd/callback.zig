//! Calls to programs on client hosts, found through each host's portmapper:
//! NLM's `_RES` and `GRANTED_MSG` callbacks, and NSM's SM_NOTIFY.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const portmap = @import("portmap.zig");

pub const Error = error{ NoPortmapper, NotRegistered, NoReply, BadReply, TooLong } || net.IpAddress.BindError || net.Socket.SendError;

/// The largest arguments a callback carries; GRANTED_MSG's can reach about
/// 4 KiB.
pub const max_args = 8192;

/// Sends `proc` of `prog` to `host` over UDP once, expecting no reply.
pub fn send(io: Io, host: net.IpAddress, prog: u32, vers: u32, proc: u32, args: []const u8) Error!void {
    const target = try locate(io, host, prog, vers);
    const socket = try bind(io, host);
    defer socket.close(io);
    var buf: [max_args + 256]u8 = undefined;
    try socket.send(io, &target, (try encode(io, &buf, prog, vers, proc, args)).message);
}

/// Calls `proc` of `prog` on `host` over UDP, waiting for its reply, and
/// returns its results in `reply`. Only replies from where it was sent count.
pub fn call(io: Io, host: net.IpAddress, prog: u32, vers: u32, proc: u32, args: []const u8, reply: []u8) Error![]const u8 {
    const target = try locate(io, host, prog, vers);
    const socket = try bind(io, host);
    defer socket.close(io);
    var buf: [max_args + 256]u8 = undefined;
    const encoded = try encode(io, &buf, prog, vers, proc, args);
    for (0..3) |_| {
        try socket.send(io, &target, encoded.message);
        while (true) {
            const in = socket.receiveTimeout(io, reply, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => break,
            };
            if (!in.from.eql(&target)) continue;
            if (in.data.len < 24 or std.mem.readInt(u32, in.data[0..4], .big) != encoded.xid) continue;
            const accepted_success: [20]u8 = .{ 0, 0, 0, 1 } ++ @as([16]u8, @splat(0));
            if (!std.mem.eql(u8, in.data[4..24], &accepted_success)) return error.BadReply;
            return in.data[24..];
        }
    }
    return error.NoReply;
}

/// Where `host` serves `prog`, asked of its portmapper.
fn locate(io: Io, host: net.IpAddress, prog: u32, vers: u32) Error!net.IpAddress {
    var pmap_address = host;
    pmap_address.setPort(portmap.port);
    var pmap = portmap.Client.init(io, pmap_address, .{ .raw = .fromSeconds(2), .clock = .awake }) catch |err| return err;
    defer pmap.deinit();
    const port = pmap.getport(prog, vers, .udp) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.NoPortmapper,
    };
    if (port == 0 or port > std.math.maxInt(u16)) return error.NotRegistered;
    var target = host;
    target.setPort(@intCast(port));
    return target;
}

fn bind(io: Io, host: net.IpAddress) net.IpAddress.BindError!net.Socket {
    const local: net.IpAddress = switch (host) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    return local.bind(io, .{ .mode = .dgram, .protocol = .udp });
}

const Encoded = struct { xid: u32, message: []const u8 };

/// Encodes a call, with AUTH_SYS as root, as lock managers call each other.
fn encode(io: Io, buf: []u8, prog: u32, vers: u32, proc: u32, args: []const u8) error{TooLong}!Encoded {
    if (args.len > max_args) return error.TooLong;
    var cred_buf: [64]u8 = undefined;
    var cw: Io.Writer = .fixed(&cred_buf);
    const auth: rpc.AuthSys = .{ .stamp = 0, .machine_name = "znfsd", .uid = 0, .gid = 0 };
    auth.encode(.init(&cw)) catch unreachable;

    const xid: u32 = @truncate(@as(u64, @bitCast(@as(i64, @truncate(Io.Clock.real.now(io).nanoseconds)))));
    var mw: Io.Writer = .fixed(buf);
    const message: rpc.Call = .{
        .xid = xid,
        .prog = prog,
        .vers = vers,
        .proc = proc,
        .cred = .{ .flavor = .sys, .body = cw.buffered() },
        .verf = .none,
        .args = args,
    };
    message.encode(.init(&mw)) catch return error.TooLong;
    return .{ .xid = xid, .message = mw.buffered() };
}

const testing = std.testing;
const server = @import("server.zig");

test "call a program registered with a host's portmapper" {
    // Needs a portmapper on port 111 of this host; skip without one.
    const io = testing.io;
    const loopback: net.IpAddress = .{ .ip4 = .loopback(portmap.port) };
    var probe = try portmap.Client.init(io, loopback, .{ .raw = .fromMilliseconds(200), .clock = .awake });
    defer probe.deinit();
    probe.ping() catch return error.SkipZigTest;

    const Echo = struct {
        fn handle(ptr: *anyopaque, ctx: server.Context, c: rpc.Call, results: *Io.Writer) rpc.Reply {
            _ = .{ ptr, ctx };
            results.writeAll(c.args) catch return .system_err;
            return .success;
        }
    };
    var dummy: u8 = 0;
    const programs = [_]server.Program{.{ .prog = 0x20000777, .low = 1, .high = 1, .ptr = &dummy, .handle = Echo.handle }};
    const udp = try net.IpAddress.bind(&.{ .ip4 = .loopback(0) }, io, .{ .mode = .dgram, .protocol = .udp });
    defer udp.close(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, server.serveUdp, .{ io, testing.allocator, &programs, udp, null });

    const mapping: portmap.Mapping = .{ .prog = 0x20000777, .vers = 1, .prot = .udp, .port = udp.address.getPort() };
    if (!try probe.set(mapping)) return error.SkipZigTest;
    defer _ = probe.unset(0x20000777, 1) catch {};

    var reply: [128]u8 = undefined;
    try testing.expectEqualStrings("hal\x00", try call(io, loopback, 0x20000777, 1, 1, "hal\x00", &reply));
    try send(io, loopback, 0x20000777, 1, 1, "art\x00");
    try testing.expectError(error.NotRegistered, call(io, loopback, 0x20000778, 1, 1, "", &reply));
    // GRANTED_MSG's largest arguments fit; more than `max_args` don't.
    const big: [4200]u8 = @splat(0);
    try send(io, loopback, 0x20000777, 1, 1, &big);
    const too_big: [max_args + 4]u8 = @splat(0);
    try testing.expectError(error.TooLong, send(io, loopback, 0x20000777, 1, 1, &too_big));
}
