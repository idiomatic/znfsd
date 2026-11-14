//! Portmapper version 2 (RFC 1833, section 3): a server for hosts without
//! one, and a client for probing and registering with an existing one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");
const server = @import("server.zig");

pub const prog: u32 = 100000;
pub const vers: u32 = 2;
pub const port: u16 = 111;

/// Where launchd listens to start macOS's on-demand `rpcbind`.
pub const macos_tickle_socket = "/var/run/portmap.socket";

pub const Proc = enum(u32) {
    null = 0,
    set = 1,
    unset = 2,
    getport = 3,
    dump = 4,
    callit = 5,
    _,
};

/// IPPROTO_TCP and IPPROTO_UDP.
pub const Prot = enum(u32) {
    tcp = 6,
    udp = 17,
    _,
};

pub const Mapping = struct {
    prog: u32,
    vers: u32,
    prot: Prot,
    port: u32,

    pub fn decode(d: *xdr.Decoder) xdr.DecodeError!Mapping {
        return .{
            .prog = try d.u32_(),
            .vers = try d.u32_(),
            .prot = try d.enumeration(Prot),
            .port = try d.u32_(),
        };
    }

    pub fn encode(m: Mapping, e: xdr.Encoder) xdr.Encoder.Error!void {
        try e.u32_(m.prog);
        try e.u32_(m.vers);
        try e.enumeration(m.prot);
        try e.u32_(m.port);
    }
};

/// The portmapper's table and RPC program.
pub const Server = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    mappings: std.ArrayList(Mapping) = .empty,

    pub fn init(gpa: std.mem.Allocator) Server {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Server) void {
        s.mappings.deinit(s.gpa);
    }

    pub fn program(s: *Server) server.Program {
        return .{ .prog = prog, .low = vers, .high = vers, .ptr = s, .handle = handle };
    }

    /// Adds a mapping unless one for its program, version, and protocol
    /// exists; returns whether it was added.
    pub fn set(s: *Server, io: Io, m: Mapping) error{ OutOfMemory, Canceled }!bool {
        try s.mutex.lock(io);
        defer s.mutex.unlock(io);
        for (s.mappings.items) |existing| {
            if (existing.prog == m.prog and existing.vers == m.vers and existing.prot == m.prot) return false;
        }
        try s.mappings.append(s.gpa, m);
        return true;
    }

    /// Removes every mapping for a program and version; returns whether any was.
    pub fn unset(s: *Server, io: Io, program_: u32, version: u32) Io.Cancelable!bool {
        try s.mutex.lock(io);
        defer s.mutex.unlock(io);
        var removed = false;
        var i: usize = 0;
        while (i < s.mappings.items.len) {
            const m = s.mappings.items[i];
            if (m.prog == program_ and m.vers == version) {
                _ = s.mappings.swapRemove(i);
                removed = true;
            } else i += 1;
        }
        return removed;
    }

    /// The port for a program, version, and protocol, or 0.
    pub fn getport(s: *Server, io: Io, program_: u32, version: u32, prot: Prot) Io.Cancelable!u32 {
        try s.mutex.lock(io);
        defer s.mutex.unlock(io);
        for (s.mappings.items) |m| {
            if (m.prog == program_ and m.vers == version and m.prot == prot) return m.port;
        }
        return 0;
    }

    fn handle(ptr: *anyopaque, ctx: server.Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
        const s: *Server = @ptrCast(@alignCast(ptr));
        return s.handleCall(ctx, call, results) catch |err| switch (err) {
            error.Truncated, error.TooLong, error.Invalid => .garbage_args,
            error.WriteFailed, error.OutOfMemory, error.Canceled => .system_err,
        };
    }

    fn handleCall(s: *Server, ctx: server.Context, call: rpc.Call, results: *Io.Writer) !rpc.Reply {
        const e: xdr.Encoder = .init(results);
        var d: xdr.Decoder = .init(call.args);
        switch (@as(Proc, @fromBackingInt(@intCast(call.proc)))) {
            .null => {},
            .set => {
                const m: Mapping = try .decode(&d);
                try e.boolean(isLocal(ctx.from) and try s.set(ctx.io, m));
            },
            .unset => {
                const m: Mapping = try .decode(&d);
                try e.boolean(isLocal(ctx.from) and try s.unset(ctx.io, m.prog, m.vers));
            },
            .getport => {
                const m: Mapping = try .decode(&d);
                try e.u32_(try s.getport(ctx.io, m.prog, m.vers, m.prot));
            },
            .dump => {
                try s.mutex.lock(ctx.io);
                defer s.mutex.unlock(ctx.io);
                for (s.mappings.items) |m| {
                    try e.boolean(true);
                    try m.encode(e);
                }
                try e.boolean(false);
            },
            .callit, _ => return .proc_unavail,
        }
        return .success;
    }
};

/// Only local callers may change the table.
fn isLocal(address: net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| a.isLoopBack() or if (net.Ip4Address.fromIp6(a)) |v4| v4.bytes[0] == 127 else false,
    };
}

/// A client of a portmapper, over UDP.
pub const Client = struct {
    io: Io,
    socket: net.Socket,
    address: net.IpAddress,
    timeout: Io.Clock.Duration,
    xid: u32 = 1,

    pub const Error = net.IpAddress.BindError || net.Socket.SendError || error{ NoPortmapper, BadReply };

    /// Opens a client of the portmapper at `address`, usually the local one.
    pub fn init(io: Io, address: net.IpAddress, timeout: Io.Clock.Duration) net.IpAddress.BindError!Client {
        const local: net.IpAddress = switch (address) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        return .{
            .io = io,
            .socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp }),
            .address = address,
            .timeout = timeout,
        };
    }

    pub fn deinit(c: *Client) void {
        c.socket.close(c.io);
    }

    /// Whether a portmapper answers.
    pub fn ping(c: *Client) Error!void {
        var reply: [64]u8 = undefined;
        _ = try c.call(.null, null, &reply);
    }

    pub fn set(c: *Client, m: Mapping) Error!bool {
        return c.boolCall(.set, m);
    }

    pub fn unset(c: *Client, program_: u32, version: u32) Error!bool {
        return c.boolCall(.unset, .{ .prog = program_, .vers = version, .prot = .tcp, .port = 0 });
    }

    pub fn getport(c: *Client, program_: u32, version: u32, prot: Prot) Error!u32 {
        var reply: [64]u8 = undefined;
        var d: xdr.Decoder = .init(try c.call(.getport, .{ .prog = program_, .vers = version, .prot = prot, .port = 0 }, &reply));
        return d.u32_() catch error.BadReply;
    }

    fn boolCall(c: *Client, proc: Proc, m: Mapping) Error!bool {
        var reply: [64]u8 = undefined;
        var d: xdr.Decoder = .init(try c.call(proc, m, &reply));
        return d.boolean() catch error.BadReply;
    }

    /// Sends a call and returns its results, retrying once on timeout.
    fn call(c: *Client, proc: Proc, args: ?Mapping, reply_buf: []u8) Error![]const u8 {
        c.xid +%= 1;
        var args_buf: [16]u8 = undefined;
        var args_w: Io.Writer = .fixed(&args_buf);
        if (args) |m| m.encode(.init(&args_w)) catch unreachable;
        var call_buf: [64]u8 = undefined;
        var call_w: Io.Writer = .fixed(&call_buf);
        const message: rpc.Call = .{
            .xid = c.xid,
            .prog = prog,
            .vers = vers,
            .proc = @backingInt(proc),
            .cred = .none,
            .verf = .none,
            .args = args_w.buffered(),
        };
        message.encode(.init(&call_w)) catch unreachable;

        for (0..2) |_| {
            try c.socket.send(c.io, &c.address, call_w.buffered());
            while (true) {
                const in = c.socket.receiveTimeout(c.io, reply_buf, .{ .duration = c.timeout }) catch |err| switch (err) {
                    error.Timeout => break,
                    error.Canceled => return error.Canceled,
                    else => return error.NoPortmapper,
                };
                if (in.data.len < 24 or std.mem.readInt(u32, in.data[0..4], .big) != c.xid) continue;
                // REPLY, MSG_ACCEPTED, AUTH_NONE verifier, SUCCESS
                const accepted_success: [20]u8 = .{ 0, 0, 0, 1 } ++ @as([16]u8, @splat(0));
                if (!std.mem.eql(u8, in.data[4..24], &accepted_success)) return error.BadReply;
                return in.data[24..];
            }
        }
        return error.NoPortmapper;
    }
};

/// Asks launchd to start macOS's on-demand `rpcbind`; returns whether it
/// was asked. A no-op elsewhere.
pub fn wakeMacos(io: Io) bool {
    if (builtin.os.tag != .macos) return false;
    const address = net.UnixAddress.init(macos_tickle_socket) catch return false;
    const stream = address.connect(io) catch return false;
    stream.close(io);
    return true;
}

const testing = std.testing;

test "serve and use a portmapper on loopback" {
    const io = testing.io;
    var pmap: Server = .init(testing.allocator);
    defer pmap.deinit();
    const programs = [_]server.Program{pmap.program()};

    const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
    const udp = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer udp.close(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, server.serveUdp, .{ io, testing.allocator, &programs, udp, null });

    var client: Client = try .init(io, udp.address, .{ .raw = .fromSeconds(2), .clock = .awake });
    defer client.deinit();
    try client.ping();

    const nfs: Mapping = .{ .prog = 100003, .vers = 3, .prot = .tcp, .port = 2049 };
    try testing.expect(try client.set(nfs));
    try testing.expect(!try client.set(nfs));
    try testing.expect(try client.set(.{ .prog = 100003, .vers = 3, .prot = .udp, .port = 2049 }));
    try testing.expectEqual(2049, try client.getport(100003, 3, .tcp));
    try testing.expectEqual(0, try client.getport(100005, 3, .tcp));
    try testing.expect(try client.unset(100003, 3));
    try testing.expectEqual(0, try client.getport(100003, 3, .udp));
    try testing.expect(!try client.unset(100003, 3));
}

test "only local callers change the table" {
    try testing.expect(isLocal(.{ .ip4 = .loopback(0) }));
    try testing.expect(isLocal(.{ .ip6 = .loopback(0) }));
    try testing.expect(isLocal(.{ .ip6 = .fromIp4(.loopback(0)) }));
    try testing.expect(!isLocal(try .parse("192.168.64.4", 0)));
    try testing.expect(!isLocal(try .parse("fd00::1", 0)));
}

test "no portmapper times out" {
    const io = testing.io;
    const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
    // A bound socket that never answers.
    const silent = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer silent.close(io);
    var client: Client = try .init(io, silent.address, .{ .raw = .fromMilliseconds(50), .clock = .awake });
    defer client.deinit();
    try testing.expectError(error.NoPortmapper, client.ping());
}
