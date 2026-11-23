//! NSM, the status monitor (statd), version 1: records which client hosts
//! hold locks, tells them when the server restarts, and hears when they do.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");
const server = @import("server.zig");
const callback = @import("callback.zig");

pub const prog: u32 = 100024;
pub const vers: u32 = 1;
pub const max_name = 1024;

pub const Proc = enum(u32) {
    null = 0,
    stat = 1,
    mon = 2,
    unmon = 3,
    unmon_all = 4,
    simu_crash = 5,
    notify = 6,
    _,
};

const stat_succ: u32 = 0;
const stat_fail: u32 = 1;

/// A host holding locks, as recorded across restarts.
pub const Host = struct {
    name: []const u8,
    address: []const u8,
};

/// Where an embedder keeps the monitored hosts.
pub const Store = struct {
    ptr: *anyopaque,
    monitor: *const fn (ptr: *anyopaque, host: Host) void,
    unmonitor: *const fn (ptr: *anyopaque, name: []const u8) void,
};

/// Called when a client host reports it restarted, so its locks go.
pub const Rebooted = struct {
    ptr: *anyopaque,
    /// `address`: where it called from, as `addressText` writes it.
    call: *const fn (ptr: *anyopaque, io: Io, name: []const u8, address: []const u8) void,
};

/// How many hosts may be monitored, as each is kept in the store too.
pub const Limits = struct {
    /// Names monitored at any one address.
    per_address: usize = 16,
    /// In all.
    total: usize = 16384,
};

pub const Nsm = struct {
    gpa: std.mem.Allocator,
    limits: Limits = .{},
    /// This server's state number: odd while up, advanced at each start.
    state: u32,
    store: ?Store = null,
    rebooted: ?Rebooted = null,
    mutex: Io.Mutex = .init,
    /// Monitored hosts: name to address text.
    hosts: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, state: u32) Nsm {
        return .{ .gpa = gpa, .state = state };
    }

    pub fn deinit(n: *Nsm) void {
        var it = n.hosts.iterator();
        while (it.next()) |e| {
            n.gpa.free(e.key_ptr.*);
            n.gpa.free(e.value_ptr.*);
        }
        n.hosts.deinit(n.gpa);
    }

    pub fn program(n: *Nsm) server.Program {
        return .{ .prog = prog, .low = vers, .high = vers, .ptr = n, .handle = handle };
    }

    /// Records that `name`, at `address`, holds locks. Fails with
    /// `TooManyHosts` past the limits.
    pub fn monitor(n: *Nsm, io: Io, name: []const u8, address: net.IpAddress) !void {
        var buf: [64]u8 = undefined;
        const text = addressText(address, &buf);
        try n.mutex.lock(io);
        defer n.mutex.unlock(io);
        if (n.hosts.get(name)) |existing| if (std.mem.eql(u8, existing, text)) return;
        if (!n.fitsLocked(name, text)) return error.TooManyHosts;
        const gop = try n.hosts.getOrPut(n.gpa, name);
        if (gop.found_existing) {
            n.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = n.gpa.dupe(u8, name) catch |err| {
                n.hosts.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = try n.gpa.dupe(u8, text);
        if (n.store) |s| s.monitor(s.ptr, .{ .name = name, .address = text });
    }

    /// Whether monitoring `name` at `address` stays within the limits.
    pub fn fits(n: *Nsm, io: Io, name: []const u8, address: net.IpAddress) bool {
        var buf: [64]u8 = undefined;
        const text = addressText(address, &buf);
        n.mutex.lock(io) catch return false;
        defer n.mutex.unlock(io);
        return n.fitsLocked(name, text);
    }

    fn fitsLocked(n: *const Nsm, name: []const u8, address: []const u8) bool {
        const existing = n.hosts.get(name);
        if (existing) |at| if (std.mem.eql(u8, at, address)) return true;
        if (existing == null and n.hosts.count() >= n.limits.total) return false;
        var at_address: usize = 0;
        var it = n.hosts.valueIterator();
        while (it.next()) |at| {
            if (std.mem.eql(u8, at.*, address)) at_address += 1;
        }
        return at_address < n.limits.per_address;
    }

    /// Whether `name` is monitored at `address`, the only place requests
    /// to release its locks are accepted from.
    pub fn monitoredAt(n: *Nsm, io: Io, name: []const u8, address: net.IpAddress) bool {
        var buf: [64]u8 = undefined;
        const text = addressText(address, &buf);
        n.mutex.lock(io) catch return false;
        defer n.mutex.unlock(io);
        const at = n.hosts.get(name) orelse return false;
        return std.mem.eql(u8, at, text);
    }

    /// Where `name` is monitored, copied into `buf`.
    pub fn addressOf(n: *Nsm, io: Io, name: []const u8, buf: []u8) ?[]const u8 {
        n.mutex.lock(io) catch return null;
        defer n.mutex.unlock(io);
        const at = n.hosts.get(name) orelse return null;
        if (at.len > buf.len) return null;
        @memcpy(buf[0..at.len], at);
        return buf[0..at.len];
    }

    /// Stops monitoring `name`, which holds no more locks.
    pub fn unmonitor(n: *Nsm, io: Io, name: []const u8) !void {
        try n.mutex.lock(io);
        defer n.mutex.unlock(io);
        if (n.hosts.fetchRemove(name)) |kv| {
            n.gpa.free(kv.key);
            n.gpa.free(kv.value);
        }
        if (n.store) |s| s.unmonitor(s.ptr, name);
    }

    /// Stops monitoring hosts named `key`, or at address `key`, as when an
    /// administrator forgets a client.
    pub fn forget(n: *Nsm, io: Io, key: []const u8) !void {
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |x| n.gpa.free(x);
            names.deinit(n.gpa);
        }
        {
            try n.mutex.lock(io);
            defer n.mutex.unlock(io);
            var it = n.hosts.iterator();
            while (it.next()) |h| {
                if (std.mem.eql(u8, h.key_ptr.*, key) or std.mem.eql(u8, h.value_ptr.*, key)) {
                    try names.append(n.gpa, try n.gpa.dupe(u8, h.key_ptr.*));
                }
            }
        }
        if (names.items.len == 0) {
            if (n.store) |s| s.unmonitor(s.ptr, key);
        }
        for (names.items) |name| try n.unmonitor(io, name);
    }

    fn handle(ptr: *anyopaque, ctx: server.Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
        const n: *Nsm = @ptrCast(@alignCast(ptr));
        return n.handleCall(ctx, call, results) catch |err| switch (err) {
            error.Truncated, error.TooLong, error.Invalid => .garbage_args,
            error.WriteFailed, error.OutOfMemory, error.Canceled => .system_err,
        };
    }

    fn handleCall(n: *Nsm, ctx: server.Context, call: rpc.Call, results: *Io.Writer) !rpc.Reply {
        const e: xdr.Encoder = .init(results);
        var d: xdr.Decoder = .init(call.args);
        switch (@as(Proc, @fromBackingInt(@intCast(call.proc)))) {
            .null, .simu_crash => {},
            .stat => {
                _ = try d.string(max_name);
                try e.u32_(stat_succ);
                try e.u32_(n.state);
            },
            // Lock managers ask their own host's statd to monitor; ours is
            // built in, so others are refused.
            .mon => {
                try e.u32_(stat_fail);
                try e.u32_(n.state);
            },
            .unmon, .unmon_all => try e.u32_(n.state),
            .notify => {
                _ = try d.string(max_name);
                _ = try d.u32_();
                // Only the host's own address can say it restarted, whatever
                // name it gives; others' locks are theirs to keep.
                var buf: [64]u8 = undefined;
                const from = addressText(ctx.from, &buf);
                var names: std.ArrayList([]u8) = .empty;
                defer {
                    for (names.items) |x| n.gpa.free(x);
                    names.deinit(n.gpa);
                }
                {
                    try n.mutex.lock(ctx.io);
                    defer n.mutex.unlock(ctx.io);
                    var it = n.hosts.iterator();
                    while (it.next()) |h| {
                        if (std.mem.eql(u8, h.value_ptr.*, from)) {
                            try names.append(n.gpa, try n.gpa.dupe(u8, h.key_ptr.*));
                        }
                    }
                }
                for (names.items) |host| {
                    if (n.rebooted) |r| r.call(r.ptr, ctx.io, host, from);
                    try n.unmonitor(ctx.io, host);
                }
            },
            _ => return .proc_unavail,
        }
        return .success;
    }
};

/// Tells each host this server restarted, with SM_NOTIFY to its statd, so
/// it reclaims its locks. Returns how many were told.
pub fn notify(io: Io, hosts: []const Host, state: u32) usize {
    var name_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const me = std.posix.gethostname(&name_buf) catch "znfsd";
    var args_buf: [max_name + 16]u8 = undefined;
    var w: Io.Writer = .fixed(&args_buf);
    const e: xdr.Encoder = .init(&w);
    e.string(me) catch return 0;
    e.u32_(state) catch return 0;
    var caller: callback.Caller = .{};
    var told: usize = 0;
    for (hosts) |h| {
        const address = net.IpAddress.parse(h.address, 0) catch continue;
        var reply: [64]u8 = undefined;
        _ = caller.call(io, address, prog, vers, @backingInt(Proc.notify), w.buffered(), &reply) catch continue;
        told += 1;
    }
    return told;
}

/// The next state number after `previous`: odd, as statd's are while up.
pub fn nextState(previous: u32) u32 {
    return if (previous % 2 == 0) previous +% 1 else previous +% 2;
}

/// An address as text, without its port, IPv4-mapped addresses as IPv4.
pub fn addressText(address: net.IpAddress, buf: []u8) []const u8 {
    const plain = switch (address) {
        .ip4 => address,
        .ip6 => |a| if (net.Ip4Address.fromIp6(a)) |v4| net.IpAddress{ .ip4 = v4 } else address,
    };
    var w: Io.Writer = .fixed(buf);
    switch (plain) {
        .ip4 => |a| w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch {},
        .ip6 => |a| {
            var tmp: [64]u8 = undefined;
            var tw: Io.Writer = .fixed(&tmp);
            a.format(&tw) catch {};
            const text = tw.buffered();
            const end = std.mem.lastIndexOfScalar(u8, text, ']') orelse text.len;
            w.writeAll(std.mem.trimStart(u8, text[0..end], "[")) catch {};
        },
    }
    return w.buffered();
}

const testing = std.testing;

test "state numbers stay odd" {
    try testing.expectEqual(1, nextState(0));
    try testing.expectEqual(3, nextState(1));
    try testing.expectEqual(5, nextState(4));
}

test "monitor, and release a host that reports a restart" {
    const io = testing.io;
    var n: Nsm = .init(testing.allocator, 3);
    defer n.deinit();
    const Seen = struct {
        last: [32]u8 = undefined,
        last_len: usize = 0,
        count: usize = 0,
        fn call(ptr: *anyopaque, _: Io, name: []const u8, _: []const u8) void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            @memcpy(s.last[0..name.len], name);
            s.last_len = name.len;
            s.count += 1;
        }
    };
    var seen: Seen = .{};
    n.rebooted = .{ .ptr = &seen, .call = Seen.call };
    try n.monitor(io, "art", try .parse("192.168.213.11", 0));
    try n.monitor(io, "hal", try .parse("192.168.213.12", 0));

    // SM_NOTIFY naming another name, from art's address.
    var args: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&args);
    try xdr.Encoder.init(&w).string("art.example.com");
    try xdr.Encoder.init(&w).u32_(5);
    var out: [64]u8 = undefined;
    var results: Io.Writer = .fixed(&out);
    const ctx: server.Context = .{ .io = io, .from = try .parse("::ffff:192.168.213.11", 800), .protocol = .udp };
    const c: rpc.Call = .{ .xid = 1, .prog = prog, .vers = vers, .proc = @backingInt(Proc.notify), .cred = .none, .verf = .none, .args = w.buffered() };
    try testing.expectEqual(rpc.Reply.success, n.handleCall(ctx, c, &results));
    try testing.expectEqual(1, seen.count);
    try testing.expectEqualStrings("art", seen.last[0..seen.last_len]);
    try testing.expect(!n.hosts.contains("art"));
    try testing.expect(n.hosts.contains("hal"));
}

test "monitor only so many hosts" {
    const io = testing.io;
    var n: Nsm = .init(testing.allocator, 3);
    defer n.deinit();
    n.limits = .{ .per_address = 2, .total = 3 };
    const skynet: net.IpAddress = try .parse("192.168.213.66", 0);
    try n.monitor(io, "skynet1", skynet);
    try n.monitor(io, "skynet2", skynet);
    try testing.expect(!n.fits(io, "skynet3", skynet));
    try testing.expectError(error.TooManyHosts, n.monitor(io, "skynet3", skynet));
    try n.monitor(io, "skynet2", skynet);
    try n.monitor(io, "hal", try .parse("192.168.213.12", 0));
    try testing.expectError(error.TooManyHosts, n.monitor(io, "art", try .parse("192.168.213.11", 0)));
    try n.unmonitor(io, "skynet1");
    try n.monitor(io, "art", try .parse("192.168.213.11", 0));
}
