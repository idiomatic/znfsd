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

/// Callbacks sent at once; more are dropped, as lost datagrams would be.
pub const max_callbacks = 64;

/// GRANTED_MSG sends before an unconfirmed grant is released.
pub const grant_sends = 5;

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

/// A granted request its client hasn't confirmed with GRANTED_RES.
const Grant = struct {
    waiter: Waiter,
    /// GRANTED_MSG's arguments, owned.
    args: []u8,
    /// GRANTED_MSGs sent so far.
    sent: u8,
    /// When to send again, or, after the last send, to give up.
    due: Io.Clock.Timestamp,
};

pub const Nlm = struct {
    gpa: std.mem.Allocator,
    nfs: *Nfs,
    locks: *Locks,
    nsm: *nsm_.Nsm,
    /// While set and not yet reached, only reclaims are granted.
    grace_end: ?Io.Clock.Timestamp = null,
    /// Held while taking locks and monitoring their hosts, and while
    /// unmonitoring hosts that hold none, so no host holding a lock goes
    /// unmonitored. Taken before `mutex`.
    monitoring: Io.Mutex = .init,
    mutex: Io.Mutex = .init,
    waiters: std.ArrayList(Waiter) = .empty,
    /// Grants resent until confirmed, and after `grant_sends` released.
    grants: std.ArrayList(Grant) = .empty,
    /// Whether a task is resending grants.
    resending: bool = false,
    /// The wait before a grant is first resent, doubling after each send.
    grant_interval: Io.Clock.Duration = .{ .raw = .fromSeconds(1), .clock = .awake },
    /// Callbacks in flight, so replies, and UDP's one loop, needn't wait
    /// for clients' portmappers.
    callbacks: Io.Group = .init,
    /// How many, at most `max_callbacks`.
    in_flight: std.atomic.Value(usize) = .init(0),
    caller: callback.Caller = .{},

    pub fn init(gpa: std.mem.Allocator, nfs: *Nfs, locks: *Locks, nsm: *nsm_.Nsm) Nlm {
        return .{ .gpa = gpa, .nfs = nfs, .locks = locks, .nsm = nsm };
    }

    pub fn deinit(n: *Nlm, io: Io) void {
        n.callbacks.cancel(io);
        for (n.waiters.items) |w| n.freeWaiter(w);
        n.waiters.deinit(n.gpa);
        for (n.grants.items) |g| n.freeGrant(g);
        n.grants.deinit(n.gpa);
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
            i = 0;
            while (i < n.grants.items.len) {
                const w = n.grants.items[i].waiter;
                if (std.mem.eql(u8, w.lock.caller_name, host) and (file == null or std.meta.eql(w.file, file.?))) {
                    n.freeGrant(n.grants.orderedRemove(i));
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
            i = 0;
            while (i < n.grants.items.len) {
                var buf: [64]u8 = undefined;
                if (n.grants.items[i].waiter.owner(&buf).of(host, address)) {
                    n.freeGrant(n.grants.orderedRemove(i));
                } else i += 1;
            }
        }
        return n.afterRelease(io, host, released);
    }

    /// Unmonitors `host` if it holds no more locks, and grants what can be.
    fn afterRelease(n: *Nlm, io: Io, host: []const u8, count: usize) !usize {
        try n.unmonitorIdle(io, host);
        try n.wake(io);
        return count;
    }

    /// Unmonitors `host` if it holds no locks.
    fn unmonitorIdle(n: *Nlm, io: Io, host: []const u8) !void {
        try n.monitoring.lock(io);
        defer n.monitoring.unlock(io);
        if (!try n.locks.hostHolds(io, host)) n.nsm.unmonitor(io, host) catch {};
    }

    /// Takes a lock for LOCK, monitoring its host; returns whether it was
    /// taken.
    fn lockMonitored(n: *Nlm, io: Io, file: locks_.File, lock: LockArgs, exclusive: bool, address: net.IpAddress) !bool {
        var buf: [64]u8 = undefined;
        try n.monitoring.lock(io);
        defer n.monitoring.unlock(io);
        if (!try n.locks.acquire(io, file, lock.owner(nsm_.addressText(address, &buf)), exclusive, lock.range())) return false;
        n.monitor(io, lock.caller_name, address);
        return true;
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
                n.sendLater(ctx.io, ctx.from, @fromBackingInt(call.proc + 5), w.buffered());
                return .none;
            },
            .granted_res => {
                const cookie = try d.opaque_(max_netobj);
                const stat = d.enumeration(Stat) catch Stat.failed;
                try n.confirm(ctx.io, cookie, ctx.from, stat);
                return .none;
            },
            // Other results: nothing to do.
            .test_res, .lock_res, .cancel_res, .unlock_res, .granted_msg => return .none,
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
                const name = try d.string(max_string);
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
                const taken = switch (proc) {
                    .lock => try n.lockMonitored(ctx.io, located.file, lock, exclusive, ctx.from),
                    else => try n.locks.acquire(ctx.io, located.file, lock.owner(from), exclusive, lock.range()),
                };
                if (taken) {
                    // A client repeating a request it was granted knows now.
                    if (n.takeGrant(ctx.io, located.file, lock.owner(from), lock.range())) |g| n.freeGrant(g);
                    try e.enumeration(Stat.granted);
                    // A downgrade or a shrink may free what others wait for.
                    return n.wake(ctx.io);
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
                try n.cancel(ctx.io, .{ .fsid = h.fsid, .inode = h.inode }, lock.owner(from), lock);
                try e.enumeration(Stat.granted);
            },
            .unlock => {
                const lock: LockArgs = try .decode(d);
                if (!n.nfs.admits(ctx.from)) return e.enumeration(Stat.denied);
                const h = fh.Handle.decode(lock.fh) catch return e.enumeration(Stat.stale_fh);
                const file: locks_.File = .{ .fsid = h.fsid, .inode = h.inode };
                try n.locks.release(ctx.io, file, lock.owner(from), lock.range());
                try n.dropGrants(ctx.io, file, lock.owner(from), lock.range());
                try n.unmonitorIdle(ctx.io, lock.caller_name);
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

    /// Stops a request waiting; if it was granted unbeknownst to its
    /// client, releases the lock.
    fn cancel(n: *Nlm, io: Io, file: locks_.File, owner: locks_.Owner, lock: LockArgs) !void {
        {
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
        const g = n.takeGrant(io, file, owner, lock.range()) orelse return;
        defer n.freeGrant(g);
        try n.releaseGranted(io, g);
    }

    /// Removes and returns the grant of `range` to `owner`, if pending.
    fn takeGrant(n: *Nlm, io: Io, file: locks_.File, owner: locks_.Owner, range: locks_.Range) ?Grant {
        n.mutex.lockUncancelable(io);
        defer n.mutex.unlock(io);
        for (n.grants.items, 0..) |*g, i| {
            var buf: [64]u8 = undefined;
            if (std.meta.eql(g.waiter.file, file) and g.waiter.owner(&buf).eql(owner) and std.meta.eql(g.waiter.lock.range(), range)) {
                return n.grants.orderedRemove(i);
            }
        }
        return null;
    }

    /// Forgets grants to `owner` overlapping `range`, as it unlocked them.
    fn dropGrants(n: *Nlm, io: Io, file: locks_.File, owner: locks_.Owner, range: locks_.Range) !void {
        try n.mutex.lock(io);
        defer n.mutex.unlock(io);
        var i: usize = 0;
        while (i < n.grants.items.len) {
            const w = &n.grants.items[i].waiter;
            var buf: [64]u8 = undefined;
            const r = w.lock.range();
            if (std.meta.eql(w.file, file) and w.owner(&buf).eql(owner) and r.start < range.end and range.start < r.end) {
                n.freeGrant(n.grants.orderedRemove(i));
            } else i += 1;
        }
    }

    /// Handles GRANTED_RES from `from`: a confirmed grant is done; a
    /// refused one is released; one refused in the client's grace period
    /// is sent again.
    fn confirm(n: *Nlm, io: Io, cookie: []const u8, from: net.IpAddress, stat: Stat) !void {
        var from_buf: [64]u8 = undefined;
        const text = nsm_.addressText(from, &from_buf);
        const g = found: {
            try n.mutex.lock(io);
            defer n.mutex.unlock(io);
            for (n.grants.items, 0..) |*g, i| {
                var buf: [64]u8 = undefined;
                if (!std.mem.eql(u8, g.waiter.cookie, cookie) or !std.mem.eql(u8, nsm_.addressText(g.waiter.address, &buf), text)) continue;
                if (stat == .denied_grace_period) return;
                break :found n.grants.orderedRemove(i);
            }
            return;
        };
        defer n.freeGrant(g);
        if (stat != .granted) try n.releaseGranted(io, g);
    }

    /// Releases a grant's lock, which its client doesn't hold, and grants
    /// what can be.
    fn releaseGranted(n: *Nlm, io: Io, g: Grant) !void {
        var buf: [64]u8 = undefined;
        try n.locks.release(io, g.waiter.file, g.waiter.owner(&buf), g.waiter.lock.range());
        try n.unmonitorIdle(io, g.waiter.lock.caller_name);
        try n.wake(io);
    }

    /// Grants what waiting requests can now have, in order, and tells
    /// their clients with GRANTED_MSG. A failure leaves the rest waiting.
    fn wake(n: *Nlm, io: Io) !void {
        var granted: std.ArrayList(Waiter) = .empty;
        defer granted.deinit(n.gpa);
        {
            try n.monitoring.lock(io);
            defer n.monitoring.unlock(io);
            {
                try n.mutex.lock(io);
                defer n.mutex.unlock(io);
                var i: usize = 0;
                while (i < n.waiters.items.len) {
                    const w = &n.waiters.items[i];
                    var buf: [64]u8 = undefined;
                    granted.ensureUnusedCapacity(n.gpa, 1) catch break;
                    const taken = n.locks.acquire(io, w.file, w.owner(&buf), w.exclusive, w.lock.range()) catch break;
                    if (taken) {
                        granted.appendAssumeCapacity(n.waiters.orderedRemove(i));
                    } else i += 1;
                }
            }
            for (granted.items) |w| n.monitor(io, w.lock.caller_name, w.address);
        }
        for (granted.items) |w| n.grant(io, w);
    }

    /// Tells a client its blocked request was granted: GRANTED_MSG, with
    /// nlm4_testargs (cookie, exclusive, and the original lock), sent again
    /// until the client confirms it.
    fn grant(n: *Nlm, io: Io, w: Waiter) void {
        var buf: [max_netobj * 4 + 64]u8 = undefined;
        var bw: Io.Writer = .fixed(&buf);
        const e: xdr.Encoder = .init(&bw);
        e.opaque_(w.cookie) catch unreachable;
        e.boolean(w.exclusive) catch unreachable;
        w.lock.encode(e) catch unreachable;
        n.sendLater(io, w.address, .granted_msg, bw.buffered());
        n.track(io, w, bw.buffered()) catch {
            log.warn("nlm: granting to {s}: out of memory; not resending", .{w.lock.caller_name});
            n.freeWaiter(w);
        };
    }

    /// Keeps a grant, owning `w`, for `resend`, which it starts if need be.
    fn track(n: *Nlm, io: Io, w: Waiter, args: []const u8) !void {
        const owned = try n.gpa.dupe(u8, args);
        errdefer n.gpa.free(owned);
        n.mutex.lockUncancelable(io);
        defer n.mutex.unlock(io);
        try n.grants.append(n.gpa, .{ .waiter = w, .args = owned, .sent = 1, .due = .fromNow(io, n.grant_interval) });
        if (n.resending) return;
        // Without a task, the grant waits for the next one.
        n.callbacks.concurrent(io, resend, .{ n, io }) catch return;
        n.resending = true;
    }

    /// Resends grants as they come due, doubling the wait after each send,
    /// and releases those still unconfirmed after `grant_sends`. Ends when
    /// none are left.
    fn resend(n: *Nlm, io: Io) Io.Cancelable!void {
        while (true) {
            try io.sleep(n.grant_interval.raw, n.grant_interval.clock);
            var expired: std.ArrayList(Grant) = .empty;
            defer expired.deinit(n.gpa);
            const done = done: {
                try n.mutex.lock(io);
                defer n.mutex.unlock(io);
                var i: usize = 0;
                while (i < n.grants.items.len) {
                    const g = &n.grants.items[i];
                    if (g.due.durationFromNow(io).raw.nanoseconds > 0) {
                        i += 1;
                    } else if (g.sent < grant_sends) {
                        const interval: Io.Clock.Duration = .{
                            .raw = .fromNanoseconds(n.grant_interval.raw.nanoseconds << @intCast(g.sent)),
                            .clock = n.grant_interval.clock,
                        };
                        g.sent += 1;
                        g.due = .fromNow(io, interval);
                        n.sendLater(io, g.waiter.address, .granted_msg, g.args);
                        i += 1;
                    } else if (expired.ensureUnusedCapacity(n.gpa, 1)) {
                        expired.appendAssumeCapacity(n.grants.orderedRemove(i));
                    } else |_| i += 1;
                }
                if (n.grants.items.len == 0) n.resending = false;
                break :done n.grants.items.len == 0;
            };
            for (expired.items) |g| {
                log.warn("nlm: {s} didn't confirm its lock; releasing it", .{g.waiter.lock.caller_name});
                n.releaseGranted(io, g) catch |err| if (err == error.Canceled) {
                    for (expired.items) |x| n.freeGrant(x);
                    return error.Canceled;
                };
            }
            for (expired.items) |g| n.freeGrant(g);
            if (done) return;
        }
    }

    /// Sends a callback in the background, with a copy of `args`, unless
    /// `max_callbacks` are already in flight.
    fn sendLater(n: *Nlm, io: Io, host: net.IpAddress, proc: Proc, args: []const u8) void {
        if (n.in_flight.fetchAdd(1, .monotonic) >= max_callbacks) {
            _ = n.in_flight.fetchSub(1, .monotonic);
            log.warn("nlm: {t} to {f}: too many callbacks in flight", .{ proc, host });
            return;
        }
        const owned = n.gpa.dupe(u8, args) catch {
            _ = n.in_flight.fetchSub(1, .monotonic);
            log.warn("nlm: {t} to {f}: out of memory", .{ proc, host });
            return;
        };
        // The task owns the copy from here.
        n.callbacks.concurrent(io, send, .{ n, io, host, proc, owned }) catch |err| {
            n.gpa.free(owned);
            _ = n.in_flight.fetchSub(1, .monotonic);
            log.warn("nlm: {t} to {f}: {t}", .{ proc, host, err });
        };
    }

    fn send(n: *Nlm, io: Io, host: net.IpAddress, proc: Proc, args: []u8) void {
        defer {
            n.gpa.free(args);
            _ = n.in_flight.fetchSub(1, .monotonic);
        }
        n.caller.send(io, host, prog, vers, @backingInt(proc), args) catch |err| {
            if (err != error.Canceled) log.warn("nlm: {t} to {f}: {t}", .{ proc, host, err });
        };
    }

    fn freeGrant(n: *Nlm, g: Grant) void {
        n.gpa.free(g.args);
        n.freeWaiter(g.waiter);
    }

    fn freeWaiter(n: *Nlm, w: Waiter) void {
        n.gpa.free(w.cookie);
        n.gpa.free(w.lock.caller_name);
        n.gpa.free(w.lock.fh);
        n.gpa.free(w.lock.oh);
    }
};

const testing = std.testing;
const exports = @import("exports.zig");
const Files = @import("files.zig").Files;
const sys = @import("sys.zig");

/// A server exporting a directory that holds the file `hal`, for NLM's tests.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    rules: [1]exports.Rule,
    table: exports.Table,
    files: Files,
    nfs: Nfs,
    locks: Locks,
    status: nsm_.Nsm,
    nlm: Nlm,
    programs: [1]server.Program,
    /// `hal`'s handle.
    handle: [fh.size]u8,

    fn init(f: *Fixture) !void {
        const io = testing.io;
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        try f.tmp.dir.writeFile(io, .{ .sub_path = "hal", .data = "9000" });
        var buf: [sys.max_path]u8 = undefined;
        f.root = try testing.allocator.dupe(u8, buf[0..try f.tmp.dir.realPath(io, &buf)]);
        errdefer testing.allocator.free(f.root);
        const hal_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/hal", .{f.root}, 0);
        defer testing.allocator.free(hal_path);

        f.rules = .{.{ .path = f.root, .client = .any, .options = .{} }};
        f.table = .{ .rules = &f.rules };
        f.files = .init(testing.allocator);
        errdefer f.files.deinit();
        f.nfs = .init(testing.allocator, &f.table, &f.files, @splat(0));
        var attr: sys.Attr = undefined;
        try testing.expectEqual(sys.E.SUCCESS, sys.lstat(hal_path, &attr));
        const h: fh.Handle = .fromAttr(@import("mount.zig").exportId(f.root), attr);
        try f.files.remember(io, h, hal_path);
        f.handle = h.encode();
        f.locks = .init(testing.allocator);
        f.status = .init(testing.allocator, 1);
        f.nlm = .init(testing.allocator, &f.nfs, &f.locks, &f.status);
        f.programs = .{f.nlm.program()};
    }

    fn deinit(f: *Fixture) void {
        f.nlm.deinit(testing.io);
        f.status.deinit();
        f.locks.deinit();
        f.files.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// Dispatches `proc` from `from`; returns the reply, or null for none.
    fn dispatch(f: *Fixture, from: server.Context, proc: Proc, args: []const u8, out: []u8) !?[]const u8 {
        var b: [max_string + 512]u8 = undefined;
        var w: Io.Writer = .fixed(&b);
        const m: rpc.Call = .{ .xid = 1, .prog = prog, .vers = vers, .proc = @backingInt(proc), .cred = .none, .verf = .none, .args = args };
        try m.encode(.init(&w));
        return server.dispatch(&f.programs, from, w.buffered(), out);
    }

    /// Calls a synchronous procedure from `from`; returns its status.
    fn run(f: *Fixture, from: server.Context, proc: Proc, args: []const u8) !Stat {
        var out: [512]u8 = undefined;
        const reply = (try f.dispatch(from, proc, args, &out)).?;
        var d: xdr.Decoder = .init(reply[24..]);
        _ = try d.opaque_(max_netobj);
        return d.enumeration(Stat);
    }
};

/// A request's lock, as a test sends it.
const Request = struct {
    cookie: []const u8 = "c",
    who: []const u8,
    svid: i32,
    block: bool = false,
    exclusive: bool = true,
    reclaim: bool = false,
    offset: u64 = 0,
    len: u64 = 0,

    fn lockArgs(r: Request, b: []u8, fh_bytes: []const u8) []const u8 {
        var w: Io.Writer = .fixed(b);
        const e: xdr.Encoder = .init(&w);
        e.opaque_(r.cookie) catch unreachable;
        e.boolean(r.block) catch unreachable;
        e.boolean(r.exclusive) catch unreachable;
        r.lock(fh_bytes).encode(e) catch unreachable;
        e.boolean(r.reclaim) catch unreachable;
        e.i32_(1) catch unreachable;
        return w.buffered();
    }

    /// CANCEL's arguments, as LOCK's but for the reclaim and state.
    fn cancelArgs(r: Request, b: []u8, fh_bytes: []const u8) []const u8 {
        var w: Io.Writer = .fixed(b);
        const e: xdr.Encoder = .init(&w);
        e.opaque_(r.cookie) catch unreachable;
        e.boolean(r.block) catch unreachable;
        e.boolean(r.exclusive) catch unreachable;
        r.lock(fh_bytes).encode(e) catch unreachable;
        return w.buffered();
    }

    fn testArgs(r: Request, b: []u8, fh_bytes: []const u8) []const u8 {
        var w: Io.Writer = .fixed(b);
        const e: xdr.Encoder = .init(&w);
        e.opaque_(r.cookie) catch unreachable;
        e.boolean(r.exclusive) catch unreachable;
        r.lock(fh_bytes).encode(e) catch unreachable;
        return w.buffered();
    }

    fn unlockArgs(r: Request, b: []u8, fh_bytes: []const u8) []const u8 {
        var w: Io.Writer = .fixed(b);
        const e: xdr.Encoder = .init(&w);
        e.opaque_(r.cookie) catch unreachable;
        r.lock(fh_bytes).encode(e) catch unreachable;
        return w.buffered();
    }

    fn lock(r: Request, fh_bytes: []const u8) LockArgs {
        return .{ .caller_name = r.who, .fh = fh_bytes, .oh = r.who, .svid = r.svid, .offset = r.offset, .len = r.len };
    }
};

test "lock, test, block, unlock, and grace" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const h = &f.handle;
    // An address whose portmapper nobody answers, so GRANTED_MSG goes nowhere.
    const ctx: server.Context = .{ .io = io, .from = try .parse("127.0.0.1", 9), .protocol = .tcp };
    var a: [512]u8 = undefined;

    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, h)));
    try testing.expect(f.status.hosts.contains("art"));

    // Another address giving art's name and process can't unlock art's
    // lock, nor, by locking another range as art, take over art's monitor
    // and free art's locks with FREE_ALL.
    const skynet: server.Context = .{ .io = io, .from = try .parse("127.0.0.66", 9), .protocol = .tcp };
    try testing.expectEqual(Stat.granted, try f.run(skynet, .unlock, (Request{ .who = "art", .svid = 1 }).unlockArgs(&a, h)));
    try testing.expectEqual(1, f.locks.held.items.len);
    try testing.expectEqualStrings("127.0.0.1", f.status.hosts.get("art").?);
    var free_all: [max_string + 16]u8 = undefined;
    var fw: Io.Writer = .fixed(&free_all);
    try xdr.Encoder.init(&fw).string("art");
    try xdr.Encoder.init(&fw).i32_(3);
    var out: [512]u8 = undefined;
    _ = try f.dispatch(skynet, .free_all, fw.buffered(), &out);
    try testing.expectEqual(1, f.locks.held.items.len);

    // FREE_ALL names are limited as other calls' are.
    fw = .fixed(&free_all);
    try xdr.Encoder.init(&fw).string(&@as([max_string + 1]u8, @splat('a')));
    try xdr.Encoder.init(&fw).i32_(3);
    try testing.expectEqual(4, std.mem.readInt(u32, (try f.dispatch(ctx, .free_all, fw.buffered(), &out)).?[20..24], .big)); // GARBAGE_ARGS

    try testing.expectEqual(Stat.denied, try f.run(ctx, .lock, (Request{ .who = "hal", .svid = 2 }).lockArgs(&a, h)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, (Request{ .who = "hal", .svid = 2, .block = true }).lockArgs(&a, h)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, (Request{ .who = "hal", .svid = 2, .block = true }).lockArgs(&a, h)));
    try testing.expectEqual(1, f.nlm.waiters.items.len);

    // Unlocking grants the waiter its lock.
    try testing.expectEqual(Stat.granted, try f.run(ctx, .unlock, (Request{ .who = "art", .svid = 1 }).unlockArgs(&a, h)));
    try testing.expectEqual(0, f.nlm.waiters.items.len);
    try testing.expect(!f.status.hosts.contains("art"));
    try testing.expect(f.status.hosts.contains("hal"));
    try testing.expectEqual(Stat.denied, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1, .exclusive = false }).lockArgs(&a, h)));

    // A stale handle, and the grace period after a restart.
    // Flipping the inode's top bit, not its low byte: that could make
    // the export root's, one less than hal's, which is always found.
    var stale = f.handle;
    stale[24] ^= 0x80;
    try testing.expectEqual(Stat.stale_fh, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, &stale)));
    try testing.expectEqual(1, try f.nlm.releaseHost(io, "hal", null));
    f.nlm.startGrace(io);
    try testing.expectEqual(Stat.denied_grace_period, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, h)));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1, .reclaim = true }).lockArgs(&a, h)));
}

/// A client's lock manager on loopback, whose port NLM remembers.
const Client = struct {
    socket: net.Socket,

    fn init(n: *Nlm) !Client {
        const io = testing.io;
        const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
        const socket = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
        n.caller.remember(io, loopback, prog, vers, socket.address.getPort());
        return .{ .socket = socket };
    }

    fn deinit(c: Client) void {
        c.socket.close(testing.io);
    }

    /// The next callback: its procedure and arguments, in `buf`.
    fn next(c: Client, buf: []u8) !struct { Proc, []const u8 } {
        return c.nextWithin(buf, .fromSeconds(2));
    }

    fn nextWithin(c: Client, buf: []u8, timeout: Io.Duration) !struct { Proc, []const u8 } {
        const in = try c.socket.receiveTimeout(testing.io, buf, .{ .duration = .{ .raw = timeout, .clock = .awake } });
        const call = switch (rpc.decodeCall(in.data)) {
            .call => |c_| c_,
            else => return error.NotACall,
        };
        return .{ @fromBackingInt(call.proc), call.args };
    }
};

test "_MSG results go back in the background" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const client: Client = try .init(&f.nlm);
    defer client.deinit();
    const ctx: server.Context = .{ .io = io, .from = .{ .ip4 = .loopback(800) }, .protocol = .udp };
    var a: [512]u8 = undefined;
    var out: [512]u8 = undefined;

    // An address that answers nothing: its portmapper's silence doesn't
    // hold up the reply.
    const silent: server.Context = .{ .io = io, .from = try .parse("192.0.2.1", 800), .protocol = .udp };
    const started: Io.Clock.Timestamp = .now(io, .awake);
    try testing.expectEqual(null, try f.dispatch(silent, .test_msg, (Request{ .who = "art", .svid = 1 }).testArgs(&a, &f.handle), &out));
    try testing.expect(started.untilNow(io).raw.toMilliseconds() < 1000);

    try testing.expectEqual(null, try f.dispatch(ctx, .lock_msg, (Request{ .who = "art", .svid = 1, .cookie = "art1" }).lockArgs(&a, &f.handle), &out));
    var buf: [512]u8 = undefined;
    const proc, const args = try client.next(&buf);
    try testing.expectEqual(Proc.lock_res, proc);
    var d: xdr.Decoder = .init(args);
    try testing.expectEqualStrings("art1", try d.opaque_(max_netobj));
    try testing.expectEqual(Stat.granted, try d.enumeration(Stat));
}

test "a holder's downgrade grants what waits" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ctx: server.Context = .{ .io = io, .from = try .parse("127.0.0.1", 9), .protocol = .tcp };
    var a: [512]u8 = undefined;
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, (Request{ .who = "hal", .svid = 2, .block = true, .exclusive = false }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1, .exclusive = false }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(0, f.nlm.waiters.items.len);
    try testing.expectEqual(2, f.locks.held.items.len);
}

test "a failure granting leaves waiters waiting" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ctx: server.Context = .{ .io = io, .from = try .parse("127.0.0.1", 9), .protocol = .tcp };
    var a: [512]u8 = undefined;
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, (Request{ .who = "hal", .svid = 2, .block = true }).lockArgs(&a, &f.handle)));

    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    f.nlm.gpa = failing.allocator();
    try testing.expectEqual(Stat.granted, try f.run(ctx, .unlock, (Request{ .who = "art", .svid = 1 }).unlockArgs(&a, &f.handle)));
    try testing.expectEqual(1, f.nlm.waiters.items.len);
    try testing.expectEqual(0, f.locks.held.items.len);

    f.nlm.gpa = testing.allocator;
    try f.nlm.wake(io);
    try testing.expectEqual(0, f.nlm.waiters.items.len);
    try testing.expectEqual(1, f.locks.held.items.len);
}

test "GRANTED_MSG goes again until confirmed, and its lock goes if never" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.nlm.grant_interval = .{ .raw = .fromMilliseconds(10), .clock = .awake };
    const client: Client = try .init(&f.nlm);
    defer client.deinit();
    const ctx: server.Context = .{ .io = io, .from = .{ .ip4 = .loopback(800) }, .protocol = .udp };
    var a: [512]u8 = undefined;
    var buf: [512]u8 = undefined;
    const hal: Request = .{ .who = "hal", .svid = 2, .block = true, .cookie = "hal1" };

    // Unconfirmed, it's sent `grant_sends` times, then released.
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, hal.lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .unlock, (Request{ .who = "art", .svid = 1 }).unlockArgs(&a, &f.handle)));
    for (0..grant_sends) |_| {
        const proc, const args = try client.next(&buf);
        try testing.expectEqual(Proc.granted_msg, proc);
        var d: xdr.Decoder = .init(args);
        try testing.expectEqualStrings("hal1", try d.opaque_(max_netobj));
    }
    for (0..200) |_| {
        if (!try f.locks.hostHolds(io, "hal")) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.TestUnexpectedResult;
    try testing.expect(!f.status.hosts.contains("hal"));

    // Confirmed, it's sent no more, and kept.
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, hal.lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .unlock, (Request{ .who = "art", .svid = 1 }).unlockArgs(&a, &f.handle)));
    _ = try client.next(&buf);
    var res: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&res);
    try xdr.Encoder.init(&w).opaque_("hal1");
    try xdr.Encoder.init(&w).enumeration(Stat.granted);
    var out: [512]u8 = undefined;
    // From elsewhere, it doesn't count.
    const skynet: server.Context = .{ .io = io, .from = try .parse("127.0.0.66", 800), .protocol = .udp };
    try testing.expectEqual(null, try f.dispatch(skynet, .granted_res, w.buffered(), &out));
    try testing.expectEqual(1, f.nlm.grants.items.len);
    try testing.expectEqual(null, try f.dispatch(ctx, .granted_res, w.buffered(), &out));
    try testing.expectEqual(0, f.nlm.grants.items.len);
    // At most one resend could have been on its way.
    _ = client.nextWithin(&buf, .fromMilliseconds(100)) catch {};
    try testing.expectError(error.Timeout, client.nextWithin(&buf, .fromMilliseconds(500)));
    try testing.expect(try f.locks.hostHolds(io, "hal"));

    // A refused grant is released.
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1, .block = true, .cookie = "art1" }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .unlock, hal.unlockArgs(&a, &f.handle)));
    _ = try client.next(&buf);
    w = .fixed(&res);
    try xdr.Encoder.init(&w).opaque_("art1");
    try xdr.Encoder.init(&w).enumeration(Stat.denied);
    try testing.expectEqual(null, try f.dispatch(ctx, .granted_res, w.buffered(), &out));
    try testing.expect(!try f.locks.hostHolds(io, "art"));
}

test "a client cancelling a grant it never heard of releases it" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ctx: server.Context = .{ .io = io, .from = try .parse("127.0.0.1", 9), .protocol = .tcp };
    var a: [512]u8 = undefined;
    const hal: Request = .{ .who = "hal", .svid = 2, .block = true };
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, hal.lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .unlock, (Request{ .who = "art", .svid = 1 }).unlockArgs(&a, &f.handle)));
    try testing.expect(try f.locks.hostHolds(io, "hal"));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .cancel, hal.cancelArgs(&a, &f.handle)));
    try testing.expect(!try f.locks.hostHolds(io, "hal"));
    try testing.expectEqual(0, f.nlm.grants.items.len);

    // Asking again for a lock it was granted confirms it.
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, (Request{ .who = "art", .svid = 1 }).lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.blocked, try f.run(ctx, .lock, hal.lockArgs(&a, &f.handle)));
    try testing.expectEqual(Stat.granted, try f.run(ctx, .unlock, (Request{ .who = "art", .svid = 1 }).unlockArgs(&a, &f.handle)));
    try testing.expectEqual(1, f.nlm.grants.items.len);
    try testing.expectEqual(Stat.granted, try f.run(ctx, .lock, hal.lockArgs(&a, &f.handle)));
    try testing.expectEqual(0, f.nlm.grants.items.len);
}
