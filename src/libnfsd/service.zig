//! A running set of RPC programs: their listeners, and their portmapper
//! registrations or the portmapper itself.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const server = @import("server.zig");
const portmap = @import("portmap.zig");

const log = std.log.scoped(.libnfsd);

pub const Ports = struct {
    nfs: u16 = 2049,
    mount: u16 = 20048,
    stat: u16 = 32765,
    lock: u16 = 32803,
};

pub const Service = enum { nfs, mount, stat, lock };

/// A program and the service whose port it listens on.
pub const Registration = struct {
    program: server.Program,
    service: Service,
};

pub const Config = struct {
    /// Addresses to listen on; their ports are ignored.
    binds: []const net.IpAddress,
    ports: Ports = .{},
    /// `.off` neither registers nor starts a portmapper.
    portmap: enum { auto, off } = .auto,
    /// Where to look for an existing portmapper.
    portmap_address: net.IpAddress = .{ .ip4 = .loopback(portmap.port) },
    /// Port for a portmapper of our own.
    portmap_port: u16 = portmap.port,
    /// Largest TCP record accepted.
    max_record: usize = 1024 * 1024 + 4096,
    /// Runs once every port is bound and registered, before any request is
    /// served, as for dropping root.
    after_bind: ?AfterBind = null,
};

pub const AfterBind = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, diag: *Diagnostic) bool,
};

pub const Error = error{
    /// A port is taken, e.g., by the host's own NFS services.
    PortInUse,
    /// A program is already registered with the portmapper.
    AlreadyRegistered,
    /// No portmapper answers, and we can't start one without root.
    NoPortmapper,
    /// The portmapper refused a registration.
    RegistrationRefused,
    /// `Config.after_bind` failed, and said why in the diagnostic.
    AfterBindFailed,
} || net.IpAddress.BindError || net.IpAddress.ListenError || Io.ConcurrentError || std.mem.Allocator.Error;

/// Why `run` failed, for its caller to show.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    pub fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const written: []u8 = std.fmt.bufPrint(&d.buf, fmt, args) catch &d.buf;
        d.len = written.len;
    }
};

const Listener = struct {
    udp: net.Socket,
    tcp: net.Server,
    programs: []const server.Program,
    /// The bound port, for registration.
    port: u16,
};

/// Binds, registers, and serves `registrations` until canceled.
pub fn run(io: Io, gpa: std.mem.Allocator, config: Config, registrations: []const Registration, diag: *Diagnostic) (Error || Io.Cancelable)!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const binds = try effectiveBinds(arena, config.binds);
    var listeners: std.ArrayList(Listener) = .empty;
    defer for (listeners.items) |*l| {
        l.udp.close(io);
        l.tcp.deinit(io);
    };
    inline for (@typeInfo(Service).@"enum".field_names) |name| {
        const service = @field(Service, name);
        var programs: std.ArrayList(server.Program) = .empty;
        for (registrations) |r| if (r.service == service) try programs.append(arena, r.program);
        if (programs.items.len > 0) {
            for (binds) |bind| {
                try listeners.append(arena, try listen(io, bind, @field(config.ports, name), programs.items, name, diag));
            }
        }
    }

    // A portmapper of our own, or registrations with an existing one.
    var own: ?portmap.Server = null;
    defer if (own) |*o| o.deinit();
    var registered = false;
    defer if (registered) unregister(io, config, registrations);
    if (config.portmap == .auto) {
        if (probe(io, config.portmap_address)) {
            try register(io, config, registrations, listeners.items, diag);
            registered = true;
        } else if (isRoot()) {
            own = .init(gpa);
            const pmap = &own.?;
            const programs = try arena.dupe(server.Program, &.{pmap.program()});
            for (binds) |bind| {
                try listeners.append(arena, try listen(io, bind, config.portmap_port, programs, "portmap", diag));
            }
            for (listeners.items) |l| for (l.programs) |p| {
                var v = p.low;
                while (v <= p.high) : (v += 1) {
                    _ = pmap.set(io, .{ .prog = p.prog, .vers = v, .prot = .udp, .port = l.port }) catch |err| return mapSetError(err);
                    _ = pmap.set(io, .{ .prog = p.prog, .vers = v, .prot = .tcp, .port = l.port }) catch |err| return mapSetError(err);
                }
            };
            log.info("started a portmapper on port {d}", .{config.portmap_port});
        } else {
            diag.set("no portmapper answers at {f}, and starting one needs root; use --no-portmap to run without", .{config.portmap_address});
            return error.NoPortmapper;
        }
    }

    if (config.after_bind) |hook| if (!hook.call(hook.ptr, diag)) return error.AfterBindFailed;

    var group: Io.Group = .init;
    defer group.cancel(io);
    for (listeners.items) |*l| {
        try group.concurrent(io, server.serveUdp, .{ io, gpa, l.programs, l.udp });
        try group.concurrent(io, server.serveTcp, .{ io, gpa, l.programs, &l.tcp, config.max_record });
    }
    try group.await(io);
}

fn mapSetError(err: anytype) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.RegistrationRefused,
    };
}

/// Both unspecified addresses become one dual-stack `::`, since a TCP
/// listener can't be made IPv6-only, and `::` then serves IPv4 too.
fn effectiveBinds(arena: std.mem.Allocator, binds: []const net.IpAddress) std.mem.Allocator.Error![]const net.IpAddress {
    var any4 = false;
    var any6 = false;
    for (binds) |b| switch (b) {
        .ip4 => |a| any4 = any4 or std.mem.allEqual(u8, &a.bytes, 0),
        .ip6 => |a| any6 = any6 or std.mem.allEqual(u8, &a.bytes, 0),
    };
    if (!(any4 and any6)) return binds;
    var out: std.ArrayList(net.IpAddress) = .empty;
    for (binds) |b| switch (b) {
        .ip4 => |a| if (!std.mem.allEqual(u8, &a.bytes, 0)) try out.append(arena, b),
        .ip6 => try out.append(arena, b),
    };
    return out.items;
}

fn isAny6(address: net.IpAddress) bool {
    return address == .ip6 and std.mem.allEqual(u8, &address.ip6.bytes, 0);
}

fn listen(io: Io, bind: net.IpAddress, port: u16, programs: []const server.Program, name: []const u8, diag: *Diagnostic) Error!Listener {
    var address = bind;
    address.setPort(port);
    const ip6_only: ?bool = if (isAny6(address)) false else null;
    const udp = address.bind(io, .{ .mode = .dgram, .protocol = .udp, .ip6_only = ip6_only }) catch |err| return inUse(err, name, address, diag);
    errdefer udp.close(io);
    // With an ephemeral port, TCP takes the port UDP got.
    address.setPort(udp.address.getPort());
    const tcp = address.listen(io, .{ .reuse_address = true }) catch |err| return inUse(err, name, address, diag);
    return .{ .udp = udp, .tcp = tcp, .programs = programs, .port = udp.address.getPort() };
}

fn inUse(err: anytype, name: []const u8, address: net.IpAddress, diag: *Diagnostic) Error {
    if (err == error.AddressInUse) {
        diag.set("{s}: {f} is in use", .{ name, address });
        return error.PortInUse;
    }
    return err;
}

/// Whether a portmapper answers at `address`, first waking macOS's
/// on-demand `rpcbind`, which can take a few seconds to answer.
fn probe(io: Io, address: net.IpAddress) bool {
    // Only the system's own portmapper, on port 111, is woken.
    const woke = address.getPort() == portmap.port and portmap.wakeMacos(io);
    var client = portmap.Client.init(io, address, .{ .raw = .fromMilliseconds(300), .clock = .awake }) catch return false;
    defer client.deinit();
    // Until `rpcbind` binds its port, a ping can fail at once (connection
    // refused), so retry until a deadline rather than a number of times.
    // launchd won't relaunch a daemon within 10 s of its last launch, and
    // `rpcbind` exits when idle, so a wake can take that long.
    const patience: Io.Clock.Duration = .{ .raw = .fromSeconds(if (woke) 15 else 1), .clock = .awake };
    const deadline: Io.Clock.Timestamp = .fromNow(io, patience);
    while (true) {
        client.ping() catch |err| {
            if (err == error.Canceled) return false;
            if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return false;
            io.sleep(.fromMilliseconds(200), .awake) catch return false;
            continue;
        };
        return true;
    }
}

fn register(io: Io, config: Config, registrations: []const Registration, listeners: []const Listener, diag: *Diagnostic) Error!void {
    var client = portmap.Client.init(io, config.portmap_address, .{ .raw = .fromSeconds(1), .clock = .awake }) catch return error.NoPortmapper;
    defer client.deinit();
    for (registrations) |r| {
        var v = r.program.low;
        while (v <= r.program.high) : (v += 1) {
            for ([_]portmap.Prot{ .udp, .tcp }) |prot| {
                const existing = client.getport(r.program.prog, v, prot) catch return error.NoPortmapper;
                if (existing != 0) {
                    diag.set("program {d} version {d} is already registered, on port {d}", .{ r.program.prog, v, existing });
                    return error.AlreadyRegistered;
                }
            }
        }
    }
    for (listeners) |l| for (l.programs) |p| {
        var v = p.low;
        while (v <= p.high) : (v += 1) {
            for ([_]portmap.Prot{ .udp, .tcp }) |prot| {
                const ok = client.set(.{ .prog = p.prog, .vers = v, .prot = prot, .port = l.port }) catch return error.NoPortmapper;
                // Several bind addresses share a port, so repeats are expected.
                if (!ok and (client.getport(p.prog, v, prot) catch 0) != l.port) {
                    diag.set("the portmapper refused program {d} version {d}", .{ p.prog, v });
                    return error.RegistrationRefused;
                }
            }
        }
    };
}

fn unregister(io: Io, config: Config, registrations: []const Registration) void {
    var client = portmap.Client.init(io, config.portmap_address, .{ .raw = .fromSeconds(1), .clock = .awake }) catch return;
    defer client.deinit();
    for (registrations) |r| {
        var v = r.program.low;
        while (v <= r.program.high) : (v += 1) _ = client.unset(r.program.prog, v) catch {};
    }
}

fn isRoot() bool {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.geteuid() == 0,
        else => std.c.geteuid() == 0,
    };
}

const testing = std.testing;
const rpc = @import("rpc.zig");

fn nullHandler(ptr: *anyopaque, ctx: server.Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
    _ = .{ ptr, ctx, results };
    return if (call.proc == 0) .success else .proc_unavail;
}

test "register with an existing portmapper, serve, and unregister" {
    const io = testing.io;

    // A stand-in for the system's portmapper, on an ephemeral port.
    var pmap: portmap.Server = .init(testing.allocator);
    defer pmap.deinit();
    const pmap_programs = [_]server.Program{pmap.program()};
    const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
    const pmap_udp = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer pmap_udp.close(io);
    var pmap_group: Io.Group = .init;
    defer pmap_group.cancel(io);
    try pmap_group.concurrent(io, server.serveUdp, .{ io, testing.allocator, &pmap_programs, pmap_udp });

    var dummy: u8 = 0;
    const registrations = [_]Registration{.{
        .program = .{ .prog = 100005, .low = 1, .high = 3, .ptr = &dummy, .handle = nullHandler },
        .service = .mount,
    }};
    const config: Config = .{
        .binds = &.{loopback},
        .ports = .{ .nfs = 0, .mount = 0, .stat = 0, .lock = 0 },
        .portmap_address = pmap_udp.address,
    };
    var diag: Diagnostic = .{};
    var service = try io.concurrent(run, .{ io, testing.allocator, config, &registrations, &diag });

    // Wait for registration, then call the program through its registered port.
    var client: portmap.Client = try .init(io, pmap_udp.address, .{ .raw = .fromSeconds(1), .clock = .awake });
    defer client.deinit();
    const port = for (0..100) |_| {
        const p = try client.getport(100005, 3, .udp);
        if (p != 0) break p;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.NotRegistered;
    try testing.expectEqual(port, try client.getport(100005, 1, .tcp));

    var address = loopback;
    address.setPort(@intCast(port));
    const sock = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);
    var call_buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&call_buf);
    const call: rpc.Call = .{ .xid = 5, .prog = 100005, .vers = 3, .proc = 0, .cred = .none, .verf = .none, .args = &.{} };
    try call.encode(.init(&w));
    try sock.send(io, &address, w.buffered());
    var in: [64]u8 = undefined;
    const reply = try sock.receiveTimeout(io, &in, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try testing.expectEqual(24, reply.data.len);

    // A second service collides with the first's registration.
    var diag2: Diagnostic = .{};
    try testing.expectError(error.AlreadyRegistered, run(io, testing.allocator, config, &registrations, &diag2));
    try testing.expectStringStartsWith(diag2.message(), "program 100005 version 1 is already registered");

    _ = service.cancel(io) catch {};
    try testing.expectEqual(0, try client.getport(100005, 3, .udp));
}

test "both unspecified addresses become one dual-stack address" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const any4: net.IpAddress = .{ .ip4 = .unspecified(0) };
    const any6: net.IpAddress = .{ .ip6 = .unspecified(0) };
    const lo: net.IpAddress = .{ .ip4 = .loopback(0) };
    const both = try effectiveBinds(arena.allocator(), &.{ any4, any6, lo });
    try testing.expectEqual(2, both.len);
    try testing.expect(isAny6(both[0]));
    try testing.expectEqual(1, (try effectiveBinds(arena.allocator(), &.{any4})).len);
}

test "no portmapper without root fails, unless off" {
    if (isRoot()) return error.SkipZigTest;
    const io = testing.io;
    const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
    const silent = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer silent.close(io);
    var dummy: u8 = 0;
    const registrations = [_]Registration{.{
        .program = .{ .prog = 100005, .low = 3, .high = 3, .ptr = &dummy, .handle = nullHandler },
        .service = .mount,
    }};
    const config: Config = .{
        .binds = &.{loopback},
        .ports = .{ .nfs = 0, .mount = 0, .stat = 0, .lock = 0 },
        .portmap_address = silent.address,
    };
    var diag: Diagnostic = .{};
    try testing.expectError(error.NoPortmapper, run(io, testing.allocator, config, &registrations, &diag));
    try testing.expectStringStartsWith(diag.message(), "no portmapper answers");

    var off = config;
    off.portmap = .off;
    var service = try io.concurrent(run, .{ io, testing.allocator, off, &registrations, &diag });
    try io.sleep(.fromMilliseconds(20), .awake);
    _ = service.cancel(io) catch {};
}
