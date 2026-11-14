//! What the server has been doing, for the activity monitor: calls by
//! procedure and by client, and the latest calls.

const std = @import("std");
const Io = std.Io;
const libnfsd = @import("libnfsd");
const server = libnfsd.server;

pub const recent_max = 200;

const Key = struct { prog: u32, proc: u32 };

const ProcStat = struct {
    calls: u64 = 0,
    errors: u64 = 0,
    nanoseconds: u64 = 0,
    bytes: u64 = 0,
};

const ClientStat = struct {
    calls: u64 = 0,
    bytes: u64 = 0,
    last_ms: i64 = 0,
};

const Recent = struct {
    time_ms: i64,
    client: [64]u8,
    client_len: u8,
    prog: u32,
    proc: u32,
    reply: std.meta.Tag(libnfsd.rpc.Reply),
    bytes: usize,
    nanoseconds: u64,
};

pub const Activity = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    started_ms: i64,
    total: u64 = 0,
    procs: std.AutoHashMapUnmanaged(Key, ProcStat) = .empty,
    clients: std.StringHashMapUnmanaged(ClientStat) = .empty,
    recent: [recent_max]Recent = undefined,
    recent_len: usize = 0,
    recent_next: usize = 0,
    observer_value: server.Observer = undefined,

    pub fn init(gpa: std.mem.Allocator, io: Io) Activity {
        return .{ .gpa = gpa, .started_ms = nowMs(io) };
    }

    pub fn deinit(a: *Activity) void {
        var it = a.clients.keyIterator();
        while (it.next()) |k| a.gpa.free(k.*);
        a.clients.deinit(a.gpa);
        a.procs.deinit(a.gpa);
    }

    /// The observer to give libnfsd's service; `a` must not move after.
    pub fn observer(a: *Activity) *const server.Observer {
        a.observer_value = .{ .ptr = a, .observe = observe };
        return &a.observer_value;
    }

    fn observe(ptr: *anyopaque, io: Io, call: server.Observed) void {
        const a: *Activity = @ptrCast(@alignCast(ptr));
        var buf: [64]u8 = undefined;
        const client = libnfsd.nsm.addressText(call.from, &buf);
        const now = nowMs(io);
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        a.total += 1;
        if (a.procs.getOrPut(a.gpa, .{ .prog = call.prog, .proc = call.proc })) |gop| {
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.calls += 1;
            if (call.reply != .success and call.reply != .none) gop.value_ptr.errors += 1;
            gop.value_ptr.nanoseconds += call.nanoseconds;
            gop.value_ptr.bytes += call.bytes;
        } else |_| {}
        if (a.clients.getPtr(client)) |c| {
            c.calls += 1;
            c.bytes += call.bytes;
            c.last_ms = now;
        } else if (a.gpa.dupe(u8, client)) |key| {
            a.clients.put(a.gpa, key, .{ .calls = 1, .bytes = call.bytes, .last_ms = now }) catch a.gpa.free(key);
        } else |_| {}
        var r: Recent = .{
            .time_ms = now,
            .client = undefined,
            .client_len = @intCast(client.len),
            .prog = call.prog,
            .proc = call.proc,
            .reply = call.reply,
            .bytes = call.bytes,
            .nanoseconds = call.nanoseconds,
        };
        @memcpy(r.client[0..client.len], client);
        a.recent[a.recent_next] = r;
        a.recent_next = (a.recent_next + 1) % recent_max;
        a.recent_len = @min(a.recent_len + 1, recent_max);
    }

    pub const ProcRow = struct {
        program: []const u8,
        procedure: []const u8,
        calls: u64,
        errors: u64,
        average_us: u64,
        bytes: u64,
    };

    pub const ClientRow = struct {
        address: []const u8,
        calls: u64,
        bytes: u64,
        last_ms: i64,
    };

    pub const RecentRow = struct {
        time_ms: i64,
        client: []const u8,
        program: []const u8,
        procedure: []const u8,
        outcome: []const u8,
        bytes: usize,
        us: u64,
    };

    pub const Snapshot = struct {
        now_ms: i64,
        started_ms: i64,
        total_calls: u64,
        procedures: []ProcRow,
        clients: []ClientRow,
        /// Newest first.
        recent: []RecentRow,
    };

    /// A copy of the activity so far, in `arena`.
    pub fn snapshot(a: *Activity, io: Io, arena: std.mem.Allocator) !Snapshot {
        try a.mutex.lock(io);
        defer a.mutex.unlock(io);
        var procs: std.ArrayList(ProcRow) = .empty;
        var pit = a.procs.iterator();
        while (pit.next()) |e| try procs.append(arena, .{
            .program = programName(e.key_ptr.prog),
            .procedure = procedureName(e.key_ptr.prog, e.key_ptr.proc),
            .calls = e.value_ptr.calls,
            .errors = e.value_ptr.errors,
            .average_us = e.value_ptr.nanoseconds / @max(1, e.value_ptr.calls) / 1000,
            .bytes = e.value_ptr.bytes,
        });
        std.mem.sort(ProcRow, procs.items, {}, struct {
            fn more(_: void, x: ProcRow, y: ProcRow) bool {
                return x.calls > y.calls;
            }
        }.more);
        var clients: std.ArrayList(ClientRow) = .empty;
        var cit = a.clients.iterator();
        while (cit.next()) |e| try clients.append(arena, .{
            .address = try arena.dupe(u8, e.key_ptr.*),
            .calls = e.value_ptr.calls,
            .bytes = e.value_ptr.bytes,
            .last_ms = e.value_ptr.last_ms,
        });
        std.mem.sort(ClientRow, clients.items, {}, struct {
            fn later(_: void, x: ClientRow, y: ClientRow) bool {
                return x.last_ms > y.last_ms;
            }
        }.later);
        const recent = try arena.alloc(RecentRow, a.recent_len);
        for (recent, 0..) |*row, i| {
            const r = &a.recent[(a.recent_next + recent_max - 1 - i) % recent_max];
            row.* = .{
                .time_ms = r.time_ms,
                .client = try arena.dupe(u8, r.client[0..r.client_len]),
                .program = programName(r.prog),
                .procedure = procedureName(r.prog, r.proc),
                .outcome = @tagName(r.reply),
                .bytes = r.bytes,
                .us = r.nanoseconds / 1000,
            };
        }
        return .{
            .now_ms = nowMs(io),
            .started_ms = a.started_ms,
            .total_calls = a.total,
            .procedures = procs.items,
            .clients = clients.items,
            .recent = recent,
        };
    }
};

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

pub fn programName(prog: u32) []const u8 {
    return switch (prog) {
        libnfsd.portmap.prog => "portmap",
        libnfsd.nfs.prog => "nfs",
        libnfsd.mount.prog => "mount",
        libnfsd.nlm.prog => "nlm",
        libnfsd.nsm.prog => "nsm",
        else => "other",
    };
}

pub fn procedureName(prog: u32, proc: u32) []const u8 {
    const names: []const []const u8 = switch (prog) {
        libnfsd.portmap.prog => &.{ "NULL", "SET", "UNSET", "GETPORT", "DUMP", "CALLIT" },
        libnfsd.nfs.prog => &.{
            "NULL",  "GETATTR", "SETATTR", "LOOKUP", "ACCESS", "READLINK", "READ",        "WRITE",  "CREATE", "MKDIR",    "SYMLINK",
            "MKNOD", "REMOVE",  "RMDIR",   "RENAME", "LINK",   "READDIR",  "READDIRPLUS", "FSSTAT", "FSINFO", "PATHCONF", "COMMIT",
        },
        libnfsd.mount.prog => &.{ "NULL", "MNT", "DUMP", "UMNT", "UMNTALL", "EXPORT" },
        libnfsd.nlm.prog => &.{
            "NULL",       "TEST",       "LOCK",        "CANCEL",   "UNLOCK",   "GRANTED",    "TEST_MSG",   "LOCK_MSG",
            "CANCEL_MSG", "UNLOCK_MSG", "GRANTED_MSG", "TEST_RES", "LOCK_RES", "CANCEL_RES", "UNLOCK_RES", "GRANTED_RES",
            "16",         "17",         "18",          "19",       "SHARE",    "UNSHARE",    "NM_LOCK",    "FREE_ALL",
        },
        libnfsd.nsm.prog => &.{ "NULL", "STAT", "MON", "UNMON", "UNMON_ALL", "SIMU_CRASH", "NOTIFY" },
        else => &.{},
    };
    return if (proc < names.len) names[proc] else "?";
}

const testing = std.testing;

test "record calls, by procedure and client, newest first" {
    const io = testing.io;
    var a: Activity = .init(testing.allocator, io);
    defer a.deinit();
    const o = a.observer();
    const art: std.Io.net.IpAddress = try .parse("192.168.213.11", 900);
    o.observe(o.ptr, io, .{ .from = art, .protocol = .tcp, .prog = 100003, .vers = 3, .proc = 6, .reply = .success, .bytes = 4200, .nanoseconds = 30_000 });
    o.observe(o.ptr, io, .{ .from = art, .protocol = .tcp, .prog = 100003, .vers = 3, .proc = 6, .reply = .success, .bytes = 4200, .nanoseconds = 10_000 });
    o.observe(o.ptr, io, .{ .from = try .parse("::ffff:192.168.213.2", 1), .protocol = .udp, .prog = 100021, .vers = 4, .proc = 7, .reply = .none, .bytes = 0, .nanoseconds = 5_000 });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try a.snapshot(io, arena_state.allocator());
    try testing.expectEqual(3, s.total_calls);
    try testing.expectEqualStrings("READ", s.procedures[0].procedure);
    try testing.expectEqual(20, s.procedures[0].average_us);
    try testing.expectEqual(2, s.clients.len);
    try testing.expectEqualStrings("LOCK_MSG", s.recent[0].procedure);
    try testing.expectEqualStrings("192.168.213.2", s.recent[0].client);
    try testing.expectEqualStrings("nlm", s.recent[0].program);

    var json: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try std.json.Stringify.value(s, .{}, &json.writer);
    try testing.expect(std.mem.indexOf(u8, json.written(), "\"procedure\":\"READ\"") != null);
}
