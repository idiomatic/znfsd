//! NLM, the network lock manager (lockd), version 4 (RFC 1813, appendix II;
//! X/Open XNFS for the rest).
//!
//! Synchronous procedures reply directly, as Linux clients use them. The
//! asynchronous `_MSG` procedures, as macOS clients use them, get no reply;
//! their results go back as `_RES` calls to the client's lock manager.
//! Blocked requests wait in a queue and are granted with `GRANTED_MSG`.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");
const server = @import("server.zig");
const fh = @import("fh.zig");
const locks_ = @import("locks.zig");
const Locks = locks_.Locks;
const Nfs = @import("nfs.zig").Nfs;
const nsm_ = @import("nsm.zig");
const callback = @import("callback.zig");

const log = std.log.scoped(.libnfsd);

pub const prog: u32 = 100021;
pub const vers: u32 = 4;
pub const max_string = 1024;
pub const max_netobj = 1024;

/// How long after a restart only reclaims are granted.
pub const grace_seconds = 90;

pub const Proc = enum(u32) {
    null = 0,
    @"test" = 1,
    lock = 2,
    cancel = 3,
    unlock = 4,
    granted = 5,
    test_msg = 6,
    lock_msg = 7,
    cancel_msg = 8,
    unlock_msg = 9,
    granted_msg = 10,
    test_res = 11,
    lock_res = 12,
    cancel_res = 13,
    unlock_res = 14,
    granted_res = 15,
    share = 20,
    unshare = 21,
    nm_lock = 22,
    free_all = 23,
    _,
};

pub const Stat = enum(u32) {
    granted = 0,
    denied = 1,
    denied_nolocks = 2,
    blocked = 3,
    denied_grace_period = 4,
    deadlck = 5,
    rofs = 6,
    stale_fh = 7,
    fbig = 8,
    failed = 9,
};

/// nlm4_lock.
const LockArgs = struct {
    caller_name: []const u8,
    fh: []const u8,
    oh: []const u8,
    svid: i32,
    offset: u64,
    len: u64,

    fn decode(d: *xdr.Decoder) xdr.DecodeError!LockArgs {
        return .{
            .caller_name = try d.string(max_string),
            .fh = try d.opaque_(max_netobj),
            .oh = try d.opaque_(max_netobj),
            .svid = try d.i32_(),
            .offset = try d.u64_(),
            .len = try d.u64_(),
        };
    }

    fn encode(l: LockArgs, e: xdr.Encoder) Io.Writer.Error!void {
        try e.string(l.caller_name);
        try e.opaque_(l.fh);
        try e.opaque_(l.oh);
        try e.i32_(l.svid);
        try e.u64_(l.offset);
        try e.u64_(l.len);
    }

    /// The lock's owner, calling from `address` (`nsm.addressText`).
    fn owner(l: LockArgs, address: []const u8) locks_.Owner {
        return .{ .host = l.caller_name, .address = address, .svid = l.svid, .oh = l.oh };
    }

    fn range(l: LockArgs) locks_.Range {
        return .fromLength(l.offset, l.len);
    }
};

/// A blocked request, waiting for a conflicting lock to go.
const Waiter = struct {
    file: locks_.File,
    exclusive: bool,
    cookie: []u8,
    /// The request's nlm4_lock, owned.
    lock: LockArgs,
    address: net.IpAddress,

    fn owner(w: *const Waiter, buf: []u8) locks_.Owner {
        return w.lock.owner(nsm_.addressText(w.address, buf));
    }
};

pub const Nlm = struct {
    gpa: std.mem.Allocator,
    nfs: *Nfs,
    locks: *Locks,
    nsm: *nsm_.Nsm,
    /// While set and not yet reached, only reclaims are granted.
    grace_end: ?Io.Clock.Timestamp = null,
    mutex: Io.Mutex = .init,
    waiters: std.ArrayList(Waiter) = .empty,
    /// GRANTED_MSG callbacks in flight, so replies needn't wait for them.
    callbacks: Io.Group = .init,

    pub fn init(gpa: std.mem.Allocator, nfs: *Nfs, locks: *Locks, nsm: *nsm_.Nsm) Nlm {
        return .{ .gpa = gpa, .nfs = nfs, .locks = locks, .nsm = nsm };
    }

    pub fn deinit(n: *Nlm, io: Io) void {
        n.callbacks.cancel(io);
        for (n.waiters.items) |w| n.freeWaiter(w);
        n.waiters.deinit(n.gpa);
    }

    pub fn program(n: *Nlm) server.Program {
        return .{ .prog = prog, .low = vers, .high = vers, .ptr = n, .handle = handle };
    }

    /// Starts the grace period after a restart, for clients to reclaim.
    pub fn startGrace(n: *Nlm, io: Io) void {
        n.grace_end = .fromNow(io, .{ .raw = .fromSeconds(grace_seconds), .clock = .awake });
    }

    fn inGrace(n: *Nlm, io: Io) bool {
        const end = n.grace_end orelse return false;
        return end.durationFromNow(io).raw.nanoseconds > 0;
    }

    /// For NSM: a client host restarted, so its locks and waits go.
    pub fn rebooted(n: *Nlm) nsm_.Rebooted {
        const S = struct {
            fn call(ptr: *anyopaque, io: Io, name: []const u8, address: []const u8) void {
                const self: *Nlm = @ptrCast(@alignCast(ptr));
                _ = self.releaseHostAt(io, name, address) catch {};
            }
        };
        return .{ .ptr = n, .call = S.call };
    }

    /// Releases `host`'s locks and waits, on `file` or everywhere, then
    /// grants what waited on them. Returns how many locks went.
    pub fn releaseHost(n: *Nlm, io: Io, host: []const u8, file: ?locks_.File) !usize {
        const released = try n.locks.releaseHost(io, host, file);
        {
            try n.mutex.lock(io);
            defer n.mutex.unlock(io);
            var i: usize = 0;
            while (i < n.waiters.items.len) {
                const w = n.waiters.items[i];
                if (std.mem.eql(u8, w.lock.caller_name, host) and (file == null or std.meta.eql(w.file, file.?))) {
                    n.freeWaiter(n.waiters.orderedRemove(i));
                } else i += 1;
            }
        }
        return n.afterRelease(io, host, released);
    }

    /// Releases the locks and waits `host` holds from `address`, as when it
    /// says it restarted, then grants what waited on them. Returns how many
    /// locks went.
    fn releaseHostAt(n: *Nlm, io: Io, host: []const u8, address: []const u8) !usize {
        const released = try n.locks.releaseHostAt(io, host, address);
        {
            try n.mutex.lock(io);
            defer n.mutex.unlock(io);
            var i: usize = 0;
            while (i < n.waiters.items.len) {
                const w = n.waiters.items[i];
                var buf: [64]u8 = undefined;
                if (w.owner(&buf).of(host, address)) {
                    n.freeWaiter(n.waiters.orderedRemove(i));
                } else i += 1;
            }
        }
        return n.afterRelease(io, host, released);
    }

    /// Unmonitors `host` if it holds no more locks, and grants what can be.
    fn afterRelease(n: *Nlm, io: Io, host: []const u8, count: usize) !usize {
        if (!try n.locks.hostHolds(io, host)) n.nsm.unmonitor(io, host) catch {};
        try n.wake(io);
        return count;
    }

    /// Monitors `host` at `address`, unless it still holds locks from where
    /// it's monitored now: a caller can't move another host's restart
    /// notices, or its FREE_ALL, to itself by giving its name.
    fn monitor(n: *Nlm, io: Io, host: []const u8, address: net.IpAddress) void {
        var buf: [64]u8 = undefined;
        var at_buf: [64]u8 = undefined;
        if (n.nsm.addressOf(io, host, &at_buf)) |at| {
            if (!std.mem.eql(u8, at, nsm_.addressText(address, &buf)) and
                (n.locks.hostHoldsAt(io, host, at) catch true)) return;
        }
        n.nsm.monitor(io, host, address) catch {};
    }

    fn handle(ptr: *anyopaque, ctx: server.Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
        const n: *Nlm = @ptrCast(@alignCast(ptr));
        return n.handleCall(ctx, call, results) catch |err| switch (err) {
            error.Truncated, error.TooLong, error.Invalid => .garbage_args,
            error.WriteFailed, error.OutOfMemory, error.Canceled => .system_err,
        };
    }

    fn handleCall(n: *Nlm, ctx: server.Context, call: rpc.Call, results: *Io.Writer) !rpc.Reply {
        const proc: Proc = @fromBackingInt(@intCast(call.proc));
        var d: xdr.Decoder = .init(call.args);
        switch (proc) {
            .null => return .success,
            .@"test", .lock, .cancel, .unlock, .nm_lock => {
                try n.answer(ctx, proc, &d, .init(results));
                return .success;
            },
            .test_msg, .lock_msg, .cancel_msg, .unlock_msg => {
                // Answer with the matching `_RES` call; send no reply. Calls
                // from hosts no export covers get nothing, so a spoofed
                // source can't aim our callbacks at others.
                if (!n.nfs.admits(ctx.from)) return .none;
                const sync: Proc = @fromBackingInt(@intCast(call.proc - 5));
                var buf: [max_netobj * 2 + 64]u8 = undefined;
                var w: Io.Writer = .fixed(&buf);
                try n.answer(ctx, sync, &d, .init(&w));
                _ = callback.call(ctx.io, ctx.from, prog, vers, call.proc + 5, w.buffered(), null) catch |err|
                    log.warn("nlm: {t} result to {f}: {t}", .{ proc, ctx.from, err });
                return .none;
            },
            // Clients' answers to our GRANTED_MSG, and other results: nothing to do.
            .test_res, .lock_res, .cancel_res, .unlock_res, .granted_res, .granted_msg => return .none,
            .granted => {
                const e: xdr.Encoder = .init(results);
                try e.opaque_(try d.opaque_(max_netobj));
                try e.enumeration(Stat.granted);
                return .success;
            },
            .share, .unshare => {
                // DOS share reservations: granted, and not enforced.
                const e: xdr.Encoder = .init(results);
                try e.opaque_(try d.opaque_(max_netobj));
                try e.enumeration(Stat.granted);
                try e.i32_(0);
                return .success;
            },
            .free_all => {
                const name = try d.string(max_string + 1);
                _ = try d.i32_();
                // A host frees its own locks, from where it holds them.
                var buf: [64]u8 = undefined;
                if (n.nsm.monitoredAt(ctx.io, name, ctx.from)) _ = try n.releaseHostAt(ctx.io, name, nsm_.addressText(ctx.from, &buf));
                return .success;
            },
            _ => return .proc_unavail,
        }
    }

    /// Decodes and performs TEST, LOCK, CANCEL, UNLOCK, or NM_LOCK, and
    /// encodes its result.
    fn answer(n: *Nlm, ctx: server.Context, proc: Proc, d: *xdr.Decoder, e: xdr.Encoder) !void {
        const cookie = try d.opaque_(max_netobj);
        try e.opaque_(cookie);
        var from_buf: [64]u8 = undefined;
        const from = nsm_.addressText(ctx.from, &from_buf);
        switch (proc) {
            .@"test" => {
                const exclusive = try d.boolean();
                const lock: LockArgs = try .decode(d);
                if (n.inGrace(ctx.io)) return e.enumeration(Stat.denied_grace_period);
                var located: Nfs.Located = undefined;
                if (!n.nfs.locate(ctx.io, lock.fh, ctx.from, &located)) return e.enumeration(Stat.stale_fh);
                var arena_state: std.heap.ArenaAllocator = .init(n.gpa);
                defer arena_state.deinit();
                const holder = try n.locks.conflict(ctx.io, arena_state.allocator(), located.file, lock.owner(from), exclusive, lock.range()) orelse
                    return e.enumeration(Stat.granted);
                try e.enumeration(Stat.denied);
                try e.boolean(holder.exclusive);
                try e.i32_(holder.owner.svid);
                try e.opaque_(holder.owner.oh);
                try e.u64_(holder.range.start);
                try e.u64_(holder.range.length());
            },
            .lock, .nm_lock => {
                const block = try d.boolean();
                const exclusive = try d.boolean();
                const lock: LockArgs = try .decode(d);
                const reclaim = try d.boolean();
                _ = try d.i32_(); // the client's NSM state
                if (n.inGrace(ctx.io) and !reclaim) return e.enumeration(Stat.denied_grace_period);
                var located: Nfs.Located = undefined;
                if (!n.nfs.locate(ctx.io, lock.fh, ctx.from, &located)) return e.enumeration(Stat.stale_fh);
                if (try n.locks.acquire(ctx.io, located.file, lock.owner(from), exclusive, lock.range())) {
                    if (proc == .lock) n.monitor(ctx.io, lock.caller_name, ctx.from);
                    return e.enumeration(Stat.granted);
                }
                if (!block) return e.enumeration(Stat.denied);
                try n.wait(ctx.io, located.file, exclusive, cookie, lock, ctx.from);
                try e.enumeration(Stat.blocked);
            },
            .cancel => {
                _ = try d.boolean(); // block
                _ = try d.boolean(); // exclusive
                const lock: LockArgs = try .decode(d);
                if (!n.nfs.admits(ctx.from)) return e.enumeration(Stat.denied);
                const h = fh.Handle.decode(lock.fh) catch return e.enumeration(Stat.stale_fh);
                n.cancel(ctx.io, .{ .fsid = h.fsid, .inode = h.inode }, lock.owner(from), lock) catch {};
                try e.enumeration(Stat.granted);
            },
            .unlock => {
                const lock: LockArgs = try .decode(d);
                if (!n.nfs.admits(ctx.from)) return e.enumeration(Stat.denied);
                const h = fh.Handle.decode(lock.fh) catch return e.enumeration(Stat.stale_fh);
                try n.locks.release(ctx.io, .{ .fsid = h.fsid, .inode = h.inode }, lock.owner(from), lock.range());
                if (!try n.locks.hostHolds(ctx.io, lock.caller_name)) n.nsm.unmonitor(ctx.io, lock.caller_name) catch {};
                try e.enumeration(Stat.granted);
                try n.wake(ctx.io);
            },
            else => unreachable,
        }
    }

    /// Queues a blocked request, unless the client is just repeating one.
    fn wait(n: *Nlm, io: Io, file: locks_.File, exclusive: bool, cookie: []const u8, lock: LockArgs, address: net.IpAddress) !void {
        try n.mutex.lock(io);
        defer n.mutex.unlock(io);
        for (n.waiters.items) |*w| {
            var buf: [64]u8 = undefined;
            var from_buf: [64]u8 = undefined;
            if (std.meta.eql(w.file, file) and w.owner(&buf).eql(lock.owner(nsm_.addressText(address, &from_buf))) and std.meta.eql(w.lock.range(), lock.range())) return;
        }
        var owned: Waiter = .{
            .file = file,
            .exclusive = exclusive,
            .cookie = try n.gpa.dupe(u8, cookie),
            .lock = lock,
            .address = address,
        };
        errdefer n.gpa.free(owned.cookie);
        owned.lock.caller_name = try n.gpa.dupe(u8, lock.caller_name);
        owned.lock.fh = try n.gpa.dupe(u8, lock.fh);
        owned.lock.oh = try n.gpa.dupe(u8, lock.oh);
        try n.waiters.append(n.gpa, owned);
    }

    fn cancel(n: *Nlm, io: Io, file: locks_.File, owner: locks_.Owner, lock: LockArgs) !void {
        try n.mutex.lock(io);
        defer n.mutex.unlock(io);
        for (n.waiters.items, 0..) |*w, i| {
            var buf: [64]u8 = undefined;
            if (std.meta.eql(w.file, file) and w.owner(&buf).eql(owner) and std.meta.eql(w.lock.range(), lock.range())) {
                n.freeWaiter(n.waiters.orderedRemove(i));
                return;
            }
        }
    }

    /// Grants what waiting requests can now have, in order, and tells
    /// their clients with GRANTED_MSG.
    fn wake(n: *Nlm, io: Io) !void {
        var granted: std.ArrayList(Waiter) = .empty;
        defer granted.deinit(n.gpa);
        {
            try n.mutex.lock(io);
            defer n.mutex.unlock(io);
            var i: usize = 0;
            while (i < n.waiters.items.len) {
                const w = &n.waiters.items[i];
                var buf: [64]u8 = undefined;
                if (try n.locks.acquire(io, w.file, w.owner(&buf), w.exclusive, w.lock.range())) {
                    try granted.append(n.gpa, n.waiters.orderedRemove(i));
                } else i += 1;
            }
        }
        for (granted.items) |w| {
            n.monitor(io, w.lock.caller_name, w.address);
            // The task owns the waiter from here.
            n.callbacks.concurrent(io, grant, .{ n, io, w }) catch grant(n, io, w);
        }
    }

    /// Tells a client its blocked request was granted: GRANTED_MSG, with
    /// nlm4_testargs (cookie, exclusive, and the original lock).
    fn grant(n: *Nlm, io: Io, w: Waiter) void {
        defer n.freeWaiter(w);
        var buf: [max_netobj * 4 + 64]u8 = undefined;
        var bw: Io.Writer = .fixed(&buf);
        const e: xdr.Encoder = .init(&bw);
        e.opaque_(w.cookie) catch return;
        e.boolean(w.exclusive) catch return;
        w.lock.encode(e) catch return;
        _ = callback.call(io, w.address, prog, vers, @backingInt(Proc.granted_msg), bw.buffered(), null) catch |err| {
            if (err != error.Canceled) log.warn("nlm: granting to {s}: {t}", .{ w.lock.caller_name, err });
        };
    }

    fn freeWaiter(n: *Nlm, w: Waiter) void {
        n.gpa.free(w.cookie);
        n.gpa.free(w.lock.caller_name);
        n.gpa.free(w.lock.fh);
        n.gpa.free(w.lock.oh);
    }
};

const testing = std.testing;

test "lock, test, block, unlock, and grace" {
    const io = testing.io;
    const exports = @import("exports.zig");
    const Files = @import("files.zig").Files;
    const sys = @import("sys.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hal", .data = "9000" });
    var buf: [sys.max_path]u8 = undefined;
    const root = try std.fmt.allocPrint(testing.allocator, "{s}", .{buf[0..try tmp.dir.realPath(io, &buf)]});
    defer testing.allocator.free(root);
    const hal_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/hal", .{root}, 0);
    defer testing.allocator.free(hal_path);

    const rules = [_]exports.Rule{.{ .path = root, .client = .any, .options = .{} }};
    const table: exports.Table = .{ .rules = &rules };
    var files: Files = .init(testing.allocator);
    defer files.deinit();
    var nfs: Nfs = .init(testing.allocator, &table, &files, @splat(0));
    var attr: sys.Attr = undefined;
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat(hal_path, &attr));
    const h: fh.Handle = .fromAttr(@import("mount.zig").exportId(root), attr);
    try files.remember(io, h, hal_path);
    const handle_bytes = h.encode();

    var locks: Locks = .init(testing.allocator);
    defer locks.deinit();
    var status: nsm_.Nsm = .init(testing.allocator, 1);
    defer status.deinit();
    var nlm: Nlm = .init(testing.allocator, &nfs, &locks, &status);
    defer nlm.deinit(io);
    const programs = [_]server.Program{nlm.program()};
    // An address whose portmapper nobody answers, so GRANTED_MSG goes nowhere.
    const ctx: server.Context = .{ .io = io, .from = try .parse("127.0.0.1", 9), .protocol = .tcp };

    const Call = struct {
        fn run(p: []const server.Program, c: server.Context, proc: Proc, args: []const u8, out: []u8) !Stat {
            var b: [512]u8 = undefined;
            var w: Io.Writer = .fixed(&b);
            const m: rpc.Call = .{ .xid = 1, .prog = prog, .vers = vers, .proc = @backingInt(proc), .cred = .none, .verf = .none, .args = args };
            try m.encode(.init(&w));
            const reply = server.dispatch(p, c, w.buffered(), out).?;
            var d: xdr.Decoder = .init(reply[24..]);
            _ = try d.opaque_(max_netobj);
            return d.enumeration(Stat);
        }
    };
    const Args = struct {
        fn lockArgs(b: []u8, who: []const u8, svid: i32, block: bool, exclusive: bool, fh_bytes: []const u8, reclaim: bool) []const u8 {
            var w: Io.Writer = .fixed(b);
            const e: xdr.Encoder = .init(&w);
            e.opaque_("c") catch unreachable;
            e.boolean(block) catch unreachable;
            e.boolean(exclusive) catch unreachable;
            (LockArgs{ .caller_name = who, .fh = fh_bytes, .oh = who, .svid = svid, .offset = 0, .len = 0 }).encode(e) catch unreachable;
            e.boolean(reclaim) catch unreachable;
            e.i32_(1) catch unreachable;
            return w.buffered();
        }
        fn unlockArgs(b: []u8, who: []const u8, svid: i32, fh_bytes: []const u8) []const u8 {
            var w: Io.Writer = .fixed(b);
            const e: xdr.Encoder = .init(&w);
            e.opaque_("c") catch unreachable;
            (LockArgs{ .caller_name = who, .fh = fh_bytes, .oh = who, .svid = svid, .offset = 0, .len = 0 }).encode(e) catch unreachable;
            return w.buffered();
        }
    };
    var a: [512]u8 = undefined;
    var out: [512]u8 = undefined;

    try testing.expectEqual(Stat.granted, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "art", 1, false, true, &handle_bytes, false), &out));
    try testing.expect(status.hosts.contains("art"));

    // Another address giving art's name and process can't unlock art's
    // lock, nor, by locking another range as art, take over art's monitor
    // and free art's locks with FREE_ALL.
    const skynet: server.Context = .{ .io = io, .from = try .parse("127.0.0.66", 9), .protocol = .tcp };
    try testing.expectEqual(Stat.granted, try Call.run(&programs, skynet, .unlock, Args.unlockArgs(&a, "art", 1, &handle_bytes), &out));
    try testing.expectEqual(1, locks.held.items.len);
    try testing.expectEqualStrings("127.0.0.1", status.hosts.get("art").?);
    var free_all: [64]u8 = undefined;
    var fw: Io.Writer = .fixed(&free_all);
    try xdr.Encoder.init(&fw).string("art");
    try xdr.Encoder.init(&fw).i32_(3);
    var b: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&b);
    const m: rpc.Call = .{ .xid = 1, .prog = prog, .vers = vers, .proc = @backingInt(Proc.free_all), .cred = .none, .verf = .none, .args = fw.buffered() };
    try m.encode(.init(&w));
    _ = server.dispatch(&programs, skynet, w.buffered(), &out);
    try testing.expectEqual(1, locks.held.items.len);

    try testing.expectEqual(Stat.denied, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "hal", 2, false, true, &handle_bytes, false), &out));
    try testing.expectEqual(Stat.blocked, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "hal", 2, true, true, &handle_bytes, false), &out));
    try testing.expectEqual(Stat.blocked, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "hal", 2, true, true, &handle_bytes, false), &out));
    try testing.expectEqual(1, nlm.waiters.items.len);

    // Unlocking grants the waiter its lock.
    try testing.expectEqual(Stat.granted, try Call.run(&programs, ctx, .unlock, Args.unlockArgs(&a, "art", 1, &handle_bytes), &out));
    try testing.expectEqual(0, nlm.waiters.items.len);
    try testing.expect(!status.hosts.contains("art"));
    try testing.expect(status.hosts.contains("hal"));
    try testing.expectEqual(Stat.denied, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "art", 1, false, false, &handle_bytes, false), &out));

    // A stale handle, and the grace period after a restart.
    var stale = handle_bytes;
    stale[31] ^= 0xff;
    try testing.expectEqual(Stat.stale_fh, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "art", 1, false, true, &stale, false), &out));
    try testing.expectEqual(1, try nlm.releaseHost(io, "hal", null));
    nlm.startGrace(io);
    try testing.expectEqual(Stat.denied_grace_period, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "art", 1, false, true, &handle_bytes, false), &out));
    try testing.expectEqual(Stat.granted, try Call.run(&programs, ctx, .lock, Args.lockArgs(&a, "art", 1, false, true, &handle_bytes, true), &out));
}
