//! The last-known path of each file handed out, for resolving handles back
//! to files. A path is trusted only while its inode still matches.

const std = @import("std");
const Io = std.Io;
const fh = @import("fh.zig");
const sys = @import("sys.zig");

pub const Files = struct {
    gpa: std.mem.Allocator,
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

    pub fn forget(f: *Files, io: Io, h: fh.Handle) Io.Cancelable!void {
        try f.mutex.lock(io);
        defer f.mutex.unlock(io);
        if (f.paths.fetchRemove(key(h))) |kv| f.gpa.free(kv.value);
    }

    /// After a directory moves from `old` to `new`, moves the cached paths
    /// of everything beneath it too.
    pub fn renamePrefix(f: *Files, io: Io, old: []const u8, new: []const u8) (std.mem.Allocator.Error || Io.Cancelable)!void {
        try f.mutex.lock(io);
        defer f.mutex.unlock(io);
        var it = f.paths.valueIterator();
        while (it.next()) |p| {
            const path = p.*;
            if (!std.mem.startsWith(u8, path, old) or path.len == old.len or path[old.len] != '/') continue;
            const moved = try std.mem.concat(f.gpa, u8, &.{ new, path[old.len..] });
            f.gpa.free(path);
            p.* = moved;
        }
    }

    pub const ResolveError = error{Stale} || Io.Cancelable;

    /// Copies `h`'s path into `out`, NUL-terminated, and stats it; the file
    /// there must still be `h`'s.
    pub fn resolve(f: *Files, io: Io, h: fh.Handle, out: *[sys.max_path + 1]u8, attr: *sys.Attr) ResolveError![:0]const u8 {
        const path = path: {
            try f.mutex.lock(io);
            defer f.mutex.unlock(io);
            const p = f.paths.get(key(h)) orelse return error.Stale;
            @memcpy(out[0..p.len], p);
            out[p.len] = 0;
            break :path out[0..p.len :0];
        };
        if (sys.lstat(path, attr) != .SUCCESS) return error.Stale;
        if (attr.ino != h.inode or !h.eql(fh.Handle.fromAttr(h.export_id, attr.*))) return error.Stale;
        return path;
    }
};

const testing = std.testing;

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
