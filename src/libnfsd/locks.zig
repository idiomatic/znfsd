//! Byte-range locks with POSIX semantics, held for NFS clients.
//!
//! Locks are kept in memory and coordinate NFS clients with each other, not
//! with processes on the server.

const std = @import("std");
const Io = std.Io;

/// A file, by filesystem ID and inode.
pub const File = struct {
    fsid: [16]u8,
    inode: u64,
};

/// Who holds a lock: a client host, by the name it gives and the address
/// it calls from, and one of its processes. The address keeps a host from
/// passing for another by sending its name and process.
pub const Owner = struct {
    host: []const u8,
    /// The caller's address as text (`nsm.addressText`).
    address: []const u8,
    svid: i32,
    oh: []const u8,

    pub fn eql(a: Owner, b: Owner) bool {
        return a.svid == b.svid and std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.address, b.address) and std.mem.eql(u8, a.oh, b.oh);
    }

    /// Whether this is `host` calling from `address`.
    pub fn of(o: Owner, host: []const u8, address: []const u8) bool {
        return std.mem.eql(u8, o.host, host) and std.mem.eql(u8, o.address, address);
    }

    fn dupe(o: Owner, gpa: std.mem.Allocator) std.mem.Allocator.Error!Owner {
        const host = try gpa.dupe(u8, o.host);
        errdefer gpa.free(host);
        const address = try gpa.dupe(u8, o.address);
        errdefer gpa.free(address);
        return .{ .host = host, .address = address, .svid = o.svid, .oh = try gpa.dupe(u8, o.oh) };
    }
};

/// A byte range, `end` exclusive; `end == eof` means to the end of file.
pub const Range = struct {
    start: u64,
    end: u64,

    pub const eof = std.math.maxInt(u64);

    /// From NLM's offset and length, where length 0 means to end of file.
    pub fn fromLength(offset: u64, len: u64) Range {
        if (len == 0) return .{ .start = offset, .end = eof };
        return .{ .start = offset, .end = if (eof - offset < len) eof else offset + len };
    }

    pub fn length(r: Range) u64 {
        return if (r.end == eof) 0 else r.end - r.start;
    }

    fn overlaps(a: Range, b: Range) bool {
        return a.start < b.end and b.start < a.end;
    }
};

pub const Lock = struct {
    file: File,
    owner: Owner,
    exclusive: bool,
    range: Range,
};

/// How many locks may be held, so no client can exhaust the server's memory.
pub const Limits = struct {
    /// From any one client address.
    per_host: usize = 4096,
    /// In all.
    total: usize = 32768,
};

pub const Locks = struct {
    gpa: std.mem.Allocator,
    limits: Limits = .{},
    mutex: Io.Mutex = .init,
    /// Each file's locks, owning their owners' strings; no file's list is
    /// empty. An owner's locks on a file never overlap.
    files: std.AutoHashMapUnmanaged(File, std.ArrayList(Lock)) = .empty,
    /// How many locks are held in all, under each host name, and from each
    /// address; the maps own their keys, and hold no zeros.
    count: usize = 0,
    by_name: std.StringHashMapUnmanaged(usize) = .empty,
    by_address: std.StringHashMapUnmanaged(usize) = .empty,

    pub const Error = error{TooManyLocks} || std.mem.Allocator.Error || Io.Cancelable;

    pub fn init(gpa: std.mem.Allocator) Locks {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Locks) void {
        var it = l.files.valueIterator();
        while (it.next()) |list| {
            for (list.items) |lock| l.free(lock);
            list.deinit(l.gpa);
        }
        l.files.deinit(l.gpa);
        inline for (.{ &l.by_name, &l.by_address }) |counts| {
            var keys = counts.keyIterator();
            while (keys.next()) |k| l.gpa.free(k.*);
            counts.deinit(l.gpa);
        }
    }

    fn free(l: *Locks, lock: Lock) void {
        l.freeOwner(lock.owner);
    }

    fn freeOwner(l: *Locks, o: Owner) void {
        l.gpa.free(o.host);
        l.gpa.free(o.address);
        l.gpa.free(o.oh);
    }

    /// Makes room to count one more of `owner`'s locks.
    fn reserve(l: *Locks, owner: Owner) std.mem.Allocator.Error!void {
        try l.by_name.ensureUnusedCapacity(l.gpa, 1);
        try l.by_address.ensureUnusedCapacity(l.gpa, 1);
        const name = if (l.by_name.contains(owner.host)) null else try l.gpa.dupe(u8, owner.host);
        errdefer if (name) |x| l.gpa.free(x);
        const address = if (l.by_address.contains(owner.address)) null else try l.gpa.dupe(u8, owner.address);
        if (name) |x| l.by_name.putAssumeCapacityNoClobber(x, 0);
        if (address) |x| l.by_address.putAssumeCapacityNoClobber(x, 0);
    }

    /// Counts a lock added, after `reserve`.
    fn counted(l: *Locks, owner: Owner) void {
        l.count += 1;
        l.by_name.getPtr(owner.host).?.* += 1;
        l.by_address.getPtr(owner.address).?.* += 1;
    }

    /// Counts a lock removed, or none after `reserve`.
    fn uncounted(l: *Locks, owner: Owner, n: usize) void {
        l.count -= n;
        inline for (.{ .{ &l.by_name, owner.host }, .{ &l.by_address, owner.address } }) |pair| {
            const entry = pair[0].getEntry(pair[1]).?;
            entry.value_ptr.* -= n;
            if (entry.value_ptr.* == 0) {
                const key = entry.key_ptr.*;
                pair[0].removeByPtr(entry.key_ptr);
                l.gpa.free(key);
            }
        }
    }

    /// The first lock another owner holds that conflicts with this request.
    /// The result's strings are valid until the next change.
    fn conflictLocked(l: *const Locks, file: File, owner: Owner, exclusive: bool, range: Range) ?Lock {
        const list = l.files.get(file) orelse return null;
        for (list.items) |h| {
            if (h.owner.eql(owner) or !h.range.overlaps(range)) continue;
            if (exclusive or h.exclusive) return h;
        }
        return null;
    }

    /// Copies the conflicting lock's owner into `arena`, for replies.
    pub fn conflict(l: *Locks, io: Io, arena: std.mem.Allocator, file: File, owner: Owner, exclusive: bool, range: Range) !?Lock {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        var c = l.conflictLocked(file, owner, exclusive, range) orelse return null;
        c.owner = try c.owner.dupe(arena);
        return c;
    }

    /// Takes the lock unless another owner's conflicts; returns whether it
    /// was taken. The owner's own locks over the range are replaced. Fails
    /// with `TooManyLocks` at the owner's address's limit, or the total.
    pub fn acquire(l: *Locks, io: Io, file: File, owner: Owner, exclusive: bool, range: Range) Error!bool {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        if (l.conflictLocked(file, owner, exclusive, range) != null) return false;
        if (l.count >= l.limits.total or (l.by_address.get(owner.address) orelse 0) >= l.limits.per_host)
            return error.TooManyLocks;

        // Everything that can fail comes first: the new lock, and a spare
        // for splitting one the range falls inside.
        try l.reserve(owner);
        errdefer l.uncounted(owner, 0);
        const gop = try l.files.getOrPut(l.gpa, file);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        errdefer if (gop.value_ptr.items.len == 0) {
            gop.value_ptr.deinit(l.gpa);
            l.files.removeByPtr(gop.key_ptr);
        };
        const list = gop.value_ptr;
        try list.ensureUnusedCapacity(l.gpa, 2);
        var lock: Lock = .{
            .file = file,
            .owner = try owner.dupe(l.gpa),
            .exclusive = exclusive,
            .range = range,
        };
        errdefer l.free(lock);
        var spare: ?Owner = try owner.dupe(l.gpa);
        defer if (spare) |o| l.freeOwner(o);

        // Counted first, so removing the owner's others never drops its
        // counts to zero.
        l.counted(owner);
        l.removeLocked(list, owner, range, &spare);
        // Join neighbors of the same kind; the owner's locks don't overlap,
        // so at most one ends where this starts, and one starts where it ends.
        var i: usize = 0;
        while (i < list.items.len) {
            const h = list.items[i];
            if (h.exclusive != exclusive or !h.owner.eql(owner) or (h.range.end != lock.range.start and h.range.start != lock.range.end)) {
                i += 1;
                continue;
            }
            lock.range = .{ .start = @min(h.range.start, lock.range.start), .end = @max(h.range.end, lock.range.end) };
            l.free(list.swapRemove(i));
            l.uncounted(owner, 1);
        }
        list.appendAssumeCapacity(lock);
        return true;
    }

    /// Releases the owner's locks over `range`, splitting any that extend
    /// beyond it.
    pub fn release(l: *Locks, io: Io, file: File, owner: Owner, range: Range) !void {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const list = l.files.getPtr(file) orelse return;
        try list.ensureUnusedCapacity(l.gpa, 1);
        var spare: ?Owner = try owner.dupe(l.gpa);
        defer if (spare) |o| l.freeOwner(o);
        l.removeLocked(list, owner, range, &spare);
        if (list.items.len == 0) {
            list.deinit(l.gpa);
            _ = l.files.remove(file);
        }
    }

    /// Removes the owner's locks over `range` from a file's `list`. A lock
    /// the range falls inside splits in two, taking `spare` for the second
    /// part's owner, with room for it in `list`.
    fn removeLocked(l: *Locks, list: *std.ArrayList(Lock), owner: Owner, range: Range, spare: *?Owner) void {
        var i: usize = 0;
        while (i < list.items.len) {
            const h = list.items[i];
            if (!h.owner.eql(owner) or !h.range.overlaps(range)) {
                i += 1;
                continue;
            }
            const before = h.range.start < range.start;
            const after = h.range.end > range.end;
            if (before and after) {
                // Split: keep the part before here, add the part after.
                var tail = h;
                tail.range.start = range.end;
                tail.owner = spare.*.?;
                spare.* = null;
                list.items[i].range.end = range.start;
                list.appendAssumeCapacity(tail);
                l.counted(owner);
                // Only the owner's one lock can hold the whole range.
                return;
            } else if (before) {
                list.items[i].range.end = range.start;
                i += 1;
            } else if (after) {
                list.items[i].range.start = range.end;
                i += 1;
            } else {
                l.free(list.swapRemove(i));
                l.uncounted(owner, 1);
            }
        }
    }

    /// Releases every lock `host` holds, or only those on `file`; returns
    /// how many.
    pub fn releaseHost(l: *Locks, io: Io, host: []const u8, file: ?File) !usize {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const Match = struct {
            host: []const u8,
            fn matches(m: @This(), o: Owner) bool {
                return std.mem.eql(u8, o.host, m.host);
            }
        };
        if (file) |f| return l.releaseWhereIn(f, Match{ .host = host });
        return l.releaseWhere(Match{ .host = host });
    }

    /// Releases every lock `host` holds from `address`; returns how many.
    pub fn releaseHostAt(l: *Locks, io: Io, host: []const u8, address: []const u8) !usize {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const Match = struct {
            host: []const u8,
            address: []const u8,
            fn matches(m: @This(), o: Owner) bool {
                return o.of(m.host, m.address);
            }
        };
        return l.releaseWhere(Match{ .host = host, .address = address });
    }

    /// Releases every lock whose owner `match.matches`; returns how many.
    fn releaseWhere(l: *Locks, match: anytype) usize {
        var n: usize = 0;
        var it = l.files.iterator();
        // Removing entries leaves the iterator valid.
        while (it.next()) |e| n += l.releaseFrom(e.key_ptr, e.value_ptr, match);
        return n;
    }

    /// Releases the locks on `file` whose owner `match.matches`; returns
    /// how many.
    fn releaseWhereIn(l: *Locks, file: File, match: anytype) usize {
        const entry = l.files.getEntry(file) orelse return 0;
        return l.releaseFrom(entry.key_ptr, entry.value_ptr, match);
    }

    /// Releases from one file's `list`, forgetting the file if none are left.
    fn releaseFrom(l: *Locks, key: *File, list: *std.ArrayList(Lock), match: anytype) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < list.items.len) {
            if (match.matches(list.items[i].owner)) {
                const lock = list.swapRemove(i);
                l.uncounted(lock.owner, 1);
                l.free(lock);
                n += 1;
            } else i += 1;
        }
        if (list.items.len == 0) {
            list.deinit(l.gpa);
            l.files.removeByPtr(key);
        }
        return n;
    }

    /// Whether `host` holds any lock.
    pub fn hostHolds(l: *Locks, io: Io, host: []const u8) !bool {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        return l.by_name.contains(host);
    }

    /// Whether `host` holds any lock from `address`.
    pub fn hostHoldsAt(l: *Locks, io: Io, host: []const u8, address: []const u8) !bool {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        if (!l.by_name.contains(host) or !l.by_address.contains(address)) return false;
        var it = l.files.valueIterator();
        while (it.next()) |list| for (list.items) |h| if (h.owner.of(host, address)) return true;
        return false;
    }

    /// How many locks are held.
    pub fn len(l: *Locks, io: Io) !usize {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        return l.count;
    }

    /// A copy of every lock, in `arena`.
    pub fn snapshot(l: *Locks, io: Io, arena: std.mem.Allocator) ![]Lock {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const out = try arena.alloc(Lock, l.count);
        var n: usize = 0;
        var it = l.files.valueIterator();
        while (it.next()) |list| for (list.items) |h| {
            out[n] = h;
            out[n].owner = try h.owner.dupe(arena);
            n += 1;
        };
        return out;
    }
};

const testing = std.testing;

const file_a: File = .{ .fsid = @splat(1), .inode = 7 };
const file_b: File = .{ .fsid = @splat(1), .inode = 8 };
const hal: Owner = .{ .host = "hal", .address = "192.168.213.12", .svid = 1, .oh = "x" };
const art: Owner = .{ .host = "art", .address = "192.168.213.11", .svid = 2, .oh = "y" };

test "shared locks coexist; exclusive ones conflict" {
    const io = testing.io;
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    try testing.expect(try l.acquire(io, file_a, hal, false, .fromLength(0, 100)));
    try testing.expect(try l.acquire(io, file_a, art, false, .fromLength(50, 100)));
    try testing.expect(!try l.acquire(io, file_a, art, true, .fromLength(90, 1)));
    try testing.expect(try l.acquire(io, file_a, art, true, .fromLength(200, 0)));
    try testing.expect(try l.acquire(io, file_b, hal, true, .fromLength(0, 0)));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const c = (try l.conflict(io, arena_state.allocator(), file_a, hal, true, .fromLength(1000, 5))).?;
    try testing.expectEqualStrings("art", c.owner.host);
    try testing.expect(c.exclusive);
}

test "an owner's locks split, merge, and change kind" {
    const io = testing.io;
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    try testing.expect(try l.acquire(io, file_a, hal, true, .fromLength(0, 100)));
    // Downgrading the middle leaves exclusive 0-40 and 60-100.
    try testing.expect(try l.acquire(io, file_a, hal, false, .fromLength(40, 20)));
    try testing.expectEqual(3, l.count);
    try testing.expect(try l.acquire(io, file_a, art, false, .fromLength(45, 10)));
    try testing.expect(!try l.acquire(io, file_a, art, false, .fromLength(30, 20)));

    try l.release(io, file_a, hal, .fromLength(0, 0));
    try testing.expectEqual(1, l.count);
    try testing.expect(try l.acquire(io, file_a, art, false, .fromLength(55, 10)));
    try testing.expectEqual(1, l.count); // merged with 45-55
    try testing.expectEqual(Range{ .start = 45, .end = 65 }, l.files.get(file_a).?.items[0].range);
}

test "release a host's locks" {
    const io = testing.io;
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    try testing.expect(try l.acquire(io, file_a, hal, true, .fromLength(0, 10)));
    try testing.expect(try l.acquire(io, file_b, hal, true, .fromLength(0, 10)));
    try testing.expect(try l.acquire(io, file_b, art, true, .fromLength(20, 10)));
    try testing.expectEqual(1, try l.releaseHost(io, "hal", file_b));
    try testing.expect(try l.hostHolds(io, "hal"));
    try testing.expectEqual(1, try l.releaseHost(io, "hal", null));
    try testing.expect(!try l.hostHolds(io, "hal"));
    try testing.expectEqual(1, l.count);
}

test "only the owner's own address releases its locks" {
    const io = testing.io;
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    try testing.expect(try l.acquire(io, file_a, art, true, .fromLength(0, 10)));
    var skynet = art;
    skynet.address = "192.168.213.66";
    try l.release(io, file_a, skynet, .fromLength(0, 0));
    try testing.expect(!try l.acquire(io, file_a, skynet, true, .fromLength(0, 10)));
    try testing.expectEqual(0, try l.releaseHostAt(io, "art", skynet.address));
    try testing.expect(try l.hostHoldsAt(io, "art", art.address));
    try testing.expect(!try l.hostHoldsAt(io, "art", skynet.address));
    try testing.expectEqual(1, try l.releaseHostAt(io, "art", art.address));
    try testing.expectEqual(0, l.count);
}

test "limits, per address and in all" {
    const io = testing.io;
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    l.limits = .{ .per_host = 2, .total = 3 };
    try testing.expect(try l.acquire(io, file_a, hal, true, .fromLength(0, 10)));
    try testing.expect(try l.acquire(io, file_b, hal, true, .fromLength(0, 10)));
    try testing.expectError(error.TooManyLocks, l.acquire(io, file_a, hal, true, .fromLength(20, 10)));
    // A host at its limit can still split its locks by releasing.
    try l.release(io, file_a, hal, .fromLength(4, 2));
    try testing.expectEqual(3, l.count);
    try testing.expectError(error.TooManyLocks, l.acquire(io, file_a, art, true, .fromLength(20, 10)));
    try testing.expectEqual(3, try l.releaseHost(io, "hal", null));
    try testing.expectEqual(0, l.files.count());
    try testing.expectEqual(0, l.by_name.count());
    try testing.expectEqual(0, l.by_address.count());
    try testing.expect(try l.acquire(io, file_a, art, true, .fromLength(20, 10)));
}

test "many locks on many files stay quick" {
    const io = testing.io;
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    l.limits = .{ .per_host = 1 << 20, .total = 1 << 20 };
    // Each is its own file's; coalescing and lookups touch only that file's.
    for (0..20000) |i| {
        const f: File = .{ .fsid = @splat(1), .inode = i };
        try testing.expect(try l.acquire(io, f, hal, true, .fromLength(0, 10)));
        try testing.expect(try l.acquire(io, f, hal, true, .fromLength(10, 10)));
    }
    try testing.expectEqual(20000, l.count);
    try testing.expect(try l.hostHolds(io, "hal"));
}

test "ranges from offsets and lengths" {
    try testing.expectEqual(Range{ .start = 5, .end = Range.eof }, Range.fromLength(5, 0));
    try testing.expectEqual(Range.eof, Range.fromLength(10, std.math.maxInt(u64)).end);
    try testing.expectEqual(0, Range.fromLength(5, 0).length());
}
