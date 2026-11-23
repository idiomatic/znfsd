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

pub const Locks = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    /// Every lock, owning its owner's strings.
    held: std.ArrayList(Lock) = .empty,

    pub fn init(gpa: std.mem.Allocator) Locks {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Locks) void {
        for (l.held.items) |lock| l.free(lock);
        l.held.deinit(l.gpa);
    }

    fn free(l: *Locks, lock: Lock) void {
        l.gpa.free(lock.owner.host);
        l.gpa.free(lock.owner.address);
        l.gpa.free(lock.owner.oh);
    }

    /// The first lock another owner holds that conflicts with this request.
    /// The result's strings are valid until the next change.
    fn conflictLocked(l: *const Locks, file: File, owner: Owner, exclusive: bool, range: Range) ?Lock {
        for (l.held.items) |h| {
            if (!std.meta.eql(h.file, file) or h.owner.eql(owner) or !h.range.overlaps(range)) continue;
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
    /// was taken. The owner's own locks over the range are replaced.
    pub fn acquire(l: *Locks, io: Io, file: File, owner: Owner, exclusive: bool, range: Range) !bool {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        if (l.conflictLocked(file, owner, exclusive, range) != null) return false;
        try l.removeLocked(file, owner, range);
        const lock: Lock = .{
            .file = file,
            .owner = try owner.dupe(l.gpa),
            .exclusive = exclusive,
            .range = range,
        };
        errdefer l.free(lock);
        try l.held.append(l.gpa, lock);
        l.coalesceLocked(file, owner);
        return true;
    }

    /// Releases the owner's locks over `range`, splitting any that extend
    /// beyond it.
    pub fn release(l: *Locks, io: Io, file: File, owner: Owner, range: Range) !void {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        try l.removeLocked(file, owner, range);
    }

    fn removeLocked(l: *Locks, file: File, owner: Owner, range: Range) !void {
        var i: usize = 0;
        while (i < l.held.items.len) {
            const h = l.held.items[i];
            if (!std.meta.eql(h.file, file) or !h.owner.eql(owner) or !h.range.overlaps(range)) {
                i += 1;
                continue;
            }
            const before = h.range.start < range.start;
            const after = h.range.end > range.end;
            if (before and after) {
                // Split: keep the part before here, add the part after.
                var tail = h;
                tail.range.start = range.end;
                tail.owner = try h.owner.dupe(l.gpa);
                l.held.items[i].range.end = range.start;
                l.held.append(l.gpa, tail) catch |err| {
                    l.free(tail);
                    return err;
                };
                i += 1;
            } else if (before) {
                l.held.items[i].range.end = range.start;
                i += 1;
            } else if (after) {
                l.held.items[i].range.start = range.end;
                i += 1;
            } else {
                l.free(l.held.swapRemove(i));
            }
        }
    }

    /// Joins the owner's adjacent or overlapping locks of the same kind.
    fn coalesceLocked(l: *Locks, file: File, owner: Owner) void {
        var changed = true;
        while (changed) {
            changed = false;
            outer: for (l.held.items, 0..) |a, i| {
                if (!std.meta.eql(a.file, file) or !a.owner.eql(owner)) continue;
                for (l.held.items[i + 1 ..], i + 1..) |b, j| {
                    if (!std.meta.eql(b.file, file) or !b.owner.eql(owner) or a.exclusive != b.exclusive) continue;
                    if (a.range.end < b.range.start or b.range.end < a.range.start) continue;
                    l.held.items[i].range = .{ .start = @min(a.range.start, b.range.start), .end = @max(a.range.end, b.range.end) };
                    l.free(l.held.swapRemove(j));
                    changed = true;
                    break :outer;
                }
            }
        }
    }

    /// Releases every lock `host` holds, or only those on `file`; returns
    /// how many.
    pub fn releaseHost(l: *Locks, io: Io, host: []const u8, file: ?File) !usize {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        var n: usize = 0;
        var i: usize = 0;
        while (i < l.held.items.len) {
            const h = l.held.items[i];
            if (std.mem.eql(u8, h.owner.host, host) and (file == null or std.meta.eql(h.file, file.?))) {
                l.free(l.held.swapRemove(i));
                n += 1;
            } else i += 1;
        }
        return n;
    }

    /// Releases every lock `host` holds from `address`; returns how many.
    pub fn releaseHostAt(l: *Locks, io: Io, host: []const u8, address: []const u8) !usize {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        var n: usize = 0;
        var i: usize = 0;
        while (i < l.held.items.len) {
            if (l.held.items[i].owner.of(host, address)) {
                l.free(l.held.swapRemove(i));
                n += 1;
            } else i += 1;
        }
        return n;
    }

    /// Whether `host` holds any lock.
    pub fn hostHolds(l: *Locks, io: Io, host: []const u8) !bool {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        for (l.held.items) |h| if (std.mem.eql(u8, h.owner.host, host)) return true;
        return false;
    }

    /// Whether `host` holds any lock from `address`.
    pub fn hostHoldsAt(l: *Locks, io: Io, host: []const u8, address: []const u8) !bool {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        for (l.held.items) |h| if (h.owner.of(host, address)) return true;
        return false;
    }

    /// A copy of every lock, in `arena`.
    pub fn snapshot(l: *Locks, io: Io, arena: std.mem.Allocator) ![]Lock {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const out = try arena.alloc(Lock, l.held.items.len);
        for (l.held.items, out) |h, *o| {
            o.* = h;
            o.owner = try h.owner.dupe(arena);
        }
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
    try testing.expectEqual(3, l.held.items.len);
    try testing.expect(try l.acquire(io, file_a, art, false, .fromLength(45, 10)));
    try testing.expect(!try l.acquire(io, file_a, art, false, .fromLength(30, 20)));

    try l.release(io, file_a, hal, .fromLength(0, 0));
    try testing.expectEqual(1, l.held.items.len);
    try testing.expect(try l.acquire(io, file_a, art, false, .fromLength(55, 10)));
    try testing.expectEqual(1, l.held.items.len); // merged with 45-55
    try testing.expectEqual(Range{ .start = 45, .end = 65 }, l.held.items[0].range);
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
    try testing.expectEqual(1, l.held.items.len);
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
    try testing.expectEqual(0, l.held.items.len);
}

test "ranges from offsets and lengths" {
    try testing.expectEqual(Range{ .start = 5, .end = Range.eof }, Range.fromLength(5, 0));
    try testing.expectEqual(Range.eof, Range.fromLength(10, std.math.maxInt(u64)).end);
    try testing.expectEqual(0, Range.fromLength(5, 0).length());
}
