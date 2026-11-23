//! The last-known path of each file handed out, for resolving handles back
//! to files. A path is trusted only while its inode still matches.

const std = @import("std");
const Io = std.Io;
const fh = @import("fh.zig");
const sys = @import("sys.zig");

/// A file's path, for storing.
pub const Entry = struct {
    fsid: [16]u8,
    inode: u64,
    path: []const u8,
};

/// Where an embedder keeps paths across restarts, so handles stay valid.
pub const Store = struct {
    ptr: *anyopaque,
    remember: *const fn (ptr: *anyopaque, fsid: [16]u8, inode: u64, path: []const u8) void,
    /// Stores many at once, as in one transaction; without it, `remember`
    /// is called for each.
    rememberMany: ?*const fn (ptr: *anyopaque, entries: []const Entry) void = null,
    /// Copies the stored path into `out` and returns its length, if known.
    lookup: *const fn (ptr: *anyopaque, fsid: [16]u8, inode: u64, out: []u8) ?usize,
    renamePrefix: *const fn (ptr: *anyopaque, old: []const u8, new: []const u8) void,
};

pub const Files = struct {
    gpa: std.mem.Allocator,
    store: ?Store = null,
    mutex: Io.Mutex = .init,
    paths: std.AutoHashMapUnmanaged(Key, []u8) = .empty,

    const Key = struct { fsid: [16]u8, inode: u64 };

    pub fn init(gpa: std.mem.Allocator) Files {
        return .{ .gpa = gpa };
    }

    pub fn deinit(f: *Files) void {
        var it = f.paths.valueIterator();
        while (it.next()) |p| f.gpa.free(p.*);
        f.paths.deinit(f.gpa);
    }

    fn key(h: fh.Handle) Key {
        return .{ .fsid = h.fsid, .inode = h.inode };
    }

    /// Records `path` as where `h`'s file is.
    pub fn remember(f: *Files, io: Io, h: fh.Handle, path: []const u8) (std.mem.Allocator.Error || Io.Cancelable)!void {
        {
            // The store can be slow, so the lock isn't held across it.
            try f.mutex.lock(io);
            defer f.mutex.unlock(io);
            const gop = try f.paths.getOrPut(f.gpa, key(h));
            if (gop.found_existing) {
                if (std.mem.eql(u8, gop.value_ptr.*, path)) return;
                f.gpa.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = f.gpa.dupe(u8, path) catch |err| {
                f.paths.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        if (f.store) |s| {
            // The store is the server's own: never touched as a caller.
            const caller = sys.pause();
            defer sys.@"resume"(caller);
            s.remember(s.ptr, h.fsid, h.inode, path);
        }
    }

    /// Records many paths, storing only those new or changed, all at once.
    /// `entries` must stay valid during the call.
    pub fn rememberAll(f: *Files, io: Io, entries: []const Entry) (std.mem.Allocator.Error || Io.Cancelable)!void {
        var changed: std.ArrayList(Entry) = .empty;
        defer changed.deinit(f.gpa);
        {
            try f.mutex.lock(io);
            defer f.mutex.unlock(io);
            for (entries) |e| {
                const gop = try f.paths.getOrPut(f.gpa, .{ .fsid = e.fsid, .inode = e.inode });
                if (gop.found_existing) {
                    if (std.mem.eql(u8, gop.value_ptr.*, e.path)) continue;
                    f.gpa.free(gop.value_ptr.*);
                }
                gop.value_ptr.* = f.gpa.dupe(u8, e.path) catch |err| {
                    f.paths.removeByPtr(gop.key_ptr);
                    return err;
                };
                try changed.append(f.gpa, e);
            }
        }
        if (changed.items.len == 0) return;
        const s = f.store orelse return;
        const caller = sys.pause();
        defer sys.@"resume"(caller);
        if (s.rememberMany) |many| {
            many(s.ptr, changed.items);
        } else for (changed.items) |e| s.remember(s.ptr, e.fsid, e.inode, e.path);
    }

    pub fn forget(f: *Files, io: Io, h: fh.Handle) Io.Cancelable!void {
        try f.mutex.lock(io);
        defer f.mutex.unlock(io);
        if (f.paths.fetchRemove(key(h))) |kv| f.gpa.free(kv.value);
    }

    /// After a directory moves from `old` to `new`, moves the cached paths
    /// of everything beneath it too, forgetting those grown too long to use.
    pub fn renamePrefix(f: *Files, io: Io, old: []const u8, new: []const u8) (std.mem.Allocator.Error || Io.Cancelable)!void {
        try f.mutex.lock(io);
        defer f.mutex.unlock(io);
        var too_long: std.ArrayList(Key) = .empty;
        defer too_long.deinit(f.gpa);
        var it = f.paths.iterator();
        while (it.next()) |kv| {
            const path = kv.value_ptr.*;
            if (!std.mem.startsWith(u8, path, old) or path.len == old.len or path[old.len] != '/') continue;
            if (new.len + path.len - old.len > sys.max_path) {
                try too_long.append(f.gpa, kv.key_ptr.*);
                continue;
            }
            const moved = try std.mem.concat(f.gpa, u8, &.{ new, path[old.len..] });
            f.gpa.free(path);
            kv.value_ptr.* = moved;
        }
        for (too_long.items) |k| if (f.paths.fetchRemove(k)) |kv| f.gpa.free(kv.value);
        if (f.store) |s| {
            const caller = sys.pause();
            defer sys.@"resume"(caller);
            s.renamePrefix(s.ptr, old, new);
        }
    }

    /// The last-known path of a file, copied into `arena`.
    pub fn pathOf(f: *Files, io: Io, arena: std.mem.Allocator, fsid: [16]u8, inode: u64) !?[]const u8 {
        try f.mutex.lock(io);
        defer f.mutex.unlock(io);
        const p = f.paths.get(.{ .fsid = fsid, .inode = inode }) orelse return null;
        return try arena.dupe(u8, p);
    }

    pub const ResolveError = error{Stale} || Io.Cancelable;

    /// Copies `h`'s path into `out`, NUL-terminated, and stats it; the file
    /// there must still be `h`'s.
    pub fn resolve(f: *Files, io: Io, h: fh.Handle, out: *[sys.max_path + 1]u8, attr: *sys.Attr) ResolveError![:0]const u8 {
        const cached = cached: {
            try f.mutex.lock(io);
            defer f.mutex.unlock(io);
            const p = f.paths.get(key(h)) orelse break :cached false;
            if (p.len > sys.max_path) return error.Stale;
            @memcpy(out[0..p.len], p);
            out[p.len] = 0;
            break :cached true;
        };
        const len = if (cached)
            std.mem.indexOfScalar(u8, out, 0).?
        else if (f.store) |s| lookup: {
            const caller = sys.pause();
            defer sys.@"resume"(caller);
            break :lookup s.lookup(s.ptr, h.fsid, h.inode, out[0..sys.max_path]) orelse return error.Stale;
        } else return error.Stale;
        out[len] = 0;
        const path = out[0..len :0];
        if (sys.lstat(path, attr) != .SUCCESS) return error.Stale;
        if (attr.ino != h.inode or !h.eql(fh.Handle.fromAttr(h.export_id, attr.*))) return error.Stale;
        if (!cached) f.remember(io, h, path) catch {};
        return path;
    }
};

const testing = std.testing;

test "remember many at once, storing only what changed" {
    const io = testing.io;
    const Counting = struct {
        singles: usize = 0,
        batches: usize = 0,
        stored: usize = 0,
        fn remember(ptr: *anyopaque, _: [16]u8, _: u64, _: []const u8) void {
            const c: *@This() = @ptrCast(@alignCast(ptr));
            c.singles += 1;
        }
        fn many(ptr: *anyopaque, entries: []const Entry) void {
            const c: *@This() = @ptrCast(@alignCast(ptr));
            c.batches += 1;
            c.stored += entries.len;
        }
        fn lookup(_: *anyopaque, _: [16]u8, _: u64, _: []u8) ?usize {
            return null;
        }
        fn rename(_: *anyopaque, _: []const u8, _: []const u8) void {}
    };
    var counting: Counting = .{};
    var files: Files = .init(testing.allocator);
    defer files.deinit();
    files.store = .{ .ptr = &counting, .remember = Counting.remember, .rememberMany = Counting.many, .lookup = Counting.lookup, .renamePrefix = Counting.rename };
    const fsid: [16]u8 = @splat(3);
    const first = [_]Entry{
        .{ .fsid = fsid, .inode = 1, .path = "/srv/a" },
        .{ .fsid = fsid, .inode = 2, .path = "/srv/b" },
    };
    try files.rememberAll(io, &first);
    const again = [_]Entry{
        .{ .fsid = fsid, .inode = 1, .path = "/srv/a" },
        .{ .fsid = fsid, .inode = 2, .path = "/srv/c" },
    };
    try files.rememberAll(io, &again);
    try files.rememberAll(io, &again);
    try testing.expectEqual(2, counting.batches);
    try testing.expectEqual(3, counting.stored);
    try testing.expectEqual(0, counting.singles);
    try testing.expectEqualStrings("/srv/c", files.paths.get(.{ .fsid = fsid, .inode = 2 }).?);
}

test "renaming a directory moves the paths beneath it" {
    const io = testing.io;
    var files: Files = .init(testing.allocator);
    defer files.deinit();
    const h = struct {
        fn of(ino: u64) fh.Handle {
            return .{ .export_id = 1, .fsid = @splat(0), .inode = ino, .generation = 0 };
        }
    }.of;
    try files.remember(io, h(1), "/srv/a");
    try files.remember(io, h(2), "/srv/a/b/c");
    try files.remember(io, h(3), "/srv/ab");
    try files.renamePrefix(io, "/srv/a", "/srv/z");
    try testing.expectEqualStrings("/srv/a", files.paths.get(.{ .fsid = @splat(0), .inode = 1 }).?);
    try testing.expectEqualStrings("/srv/z/b/c", files.paths.get(.{ .fsid = @splat(0), .inode = 2 }).?);
    try testing.expectEqualStrings("/srv/ab", files.paths.get(.{ .fsid = @splat(0), .inode = 3 }).?);

    // A path grown past the limit is forgotten, not kept to overflow later.
    var deep: [sys.max_path - 8]u8 = @splat('d');
    @memcpy(deep[0..7], "/srv/z/");
    try files.remember(io, h(4), &deep);
    var long: [256]u8 = @splat('n');
    @memcpy(long[0..5], "/srv/");
    try files.renamePrefix(io, "/srv/z", &long);
    try testing.expect(files.paths.get(.{ .fsid = @splat(0), .inode = 4 }) == null);
    try testing.expect(files.paths.get(.{ .fsid = @splat(0), .inode = 2 }) != null);
    var out: [sys.max_path + 1]u8 = undefined;
    var attr: sys.Attr = undefined;
    try testing.expectError(error.Stale, files.resolve(io, h(4), &out, &attr));
}

test "resolve while the inode matches, and go stale after replacement" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hal", .data = "9000" });
    var root_buf: [sys.max_path]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/hal", .{root_buf[0..root_len]}, 0);
    defer testing.allocator.free(path);

    var attr: sys.Attr = undefined;
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat(path, &attr));
    const h: fh.Handle = .fromAttr(1, attr);

    var files: Files = .init(testing.allocator);
    defer files.deinit();
    var out: [sys.max_path + 1]u8 = undefined;
    try testing.expectError(error.Stale, files.resolve(io, h, &out, &attr));
    try files.remember(io, h, path);
    try testing.expectEqualStrings(path, try files.resolve(io, h, &out, &attr));

    // A new file at the same path is a different file.
    try tmp.dir.deleteFile(io, "hal");
    try tmp.dir.writeFile(io, .{ .sub_path = "keep", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hal", .data = "9000" });
    var now: sys.Attr = undefined;
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat(path, &now));
    if (now.ino != h.inode) try testing.expectError(error.Stale, files.resolve(io, h, &out, &attr));
}
