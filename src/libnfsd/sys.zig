//! File-system calls `std.Io` lacks, through libc. Each returns an errno,
//! so callers can map it to a protocol status.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

pub const E = posix.E;

pub const Timespec = struct {
    sec: i64,
    nsec: u32,

    fn from(ts: c.timespec) Timespec {
        return .{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) };
    }
};

/// The attributes NFS reports, from `stat`.
pub const Attr = struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64,
    size: u64,
    /// 512-byte blocks allocated.
    blocks: u64,
    atime: Timespec,
    mtime: Timespec,
    ctime: Timespec,
    /// Inode generation, or 0 when unknown.
    gen: u32,
};

/// `stat` without following a final symbolic link.
pub fn lstat(path: [*:0]const u8, attr: *Attr) E {
    return statAt(c.AT.FDCWD, path, attr);
}

/// `fstatat` relative to `dir`, without following a final symbolic link.
pub fn statAt(dir: c.fd_t, path: [*:0]const u8, attr: *Attr) E {
    return statAtFlags(dir, path, 0, attr);
}

fn statAtFlags(dir: c.fd_t, path: [*:0]const u8, flags: u32, attr: *Attr) E {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const mask: linux.STATX = .{
            .TYPE = true,
            .MODE = true,
            .NLINK = true,
            .UID = true,
            .GID = true,
            .ATIME = true,
            .MTIME = true,
            .CTIME = true,
            .INO = true,
            .SIZE = true,
            .BLOCKS = true,
        };
        if (c.statx(dir, path, c.AT.SYMLINK_NOFOLLOW | flags, mask, &stx) != 0) return errno();
        attr.* = .{
            .dev = @as(u64, stx.dev_major) << 32 | stx.dev_minor,
            .ino = stx.ino,
            .mode = stx.mode,
            .nlink = stx.nlink,
            .uid = stx.uid,
            .gid = stx.gid,
            .rdev = @as(u64, stx.rdev_major) << 32 | stx.rdev_minor,
            .size = stx.size,
            .blocks = stx.blocks,
            .atime = .{ .sec = stx.atime.sec, .nsec = stx.atime.nsec },
            .mtime = .{ .sec = stx.mtime.sec, .nsec = stx.mtime.nsec },
            .ctime = .{ .sec = stx.ctime.sec, .nsec = stx.ctime.nsec },
            .gen = 0,
        };
        return .SUCCESS;
    }
    var st: c.Stat = undefined;
    if (c.fstatat(dir, path, &st, c.AT.SYMLINK_NOFOLLOW | flags) != 0) return errno();
    attr.* = fromStat(st);
    return .SUCCESS;
}

fn fromStat(st: c.Stat) Attr {
    return .{
        .dev = @as(u32, @bitCast(st.dev)),
        .ino = st.ino,
        .mode = st.mode,
        .nlink = st.nlink,
        .uid = st.uid,
        .gid = st.gid,
        .rdev = @as(u32, @bitCast(st.rdev)),
        .size = @intCast(st.size),
        .blocks = @intCast(st.blocks),
        .atime = .from(st.atime()),
        .mtime = .from(st.mtime()),
        .ctime = .from(st.ctime()),
        .gen = if (@hasField(c.Stat, "gen")) st.gen else 0,
    };
}

pub const Fd = c.fd_t;

/// Opens `path` refusing symbolic links in every component, so a path
/// can't be redirected outside an export: `O_NOFOLLOW_ANY` on macOS,
/// `openat2` with `RESOLVE_NO_SYMLINKS` on Linux.
pub fn openSafe(path: [*:0]const u8, flags: c.O, mode: u32, fd: *Fd) E {
    var o = flags;
    o.CLOEXEC = true;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const How = extern struct { flags: u64, mode: u64, resolve: u64 };
        const RESOLVE_NO_SYMLINKS = 0x04;
        var how: How = .{ .flags = @as(u32, @bitCast(o)), .mode = mode, .resolve = RESOLVE_NO_SYMLINKS };
        const rc = linux.syscall4(.openat2, @bitCast(@as(isize, c.AT.FDCWD)), @intFromPtr(path), @intFromPtr(&how), @sizeOf(How));
        const e = linux.errno(rc);
        if (e != .SUCCESS) return e;
        fd.* = @intCast(rc);
        return .SUCCESS;
    }
    // `O_NOFOLLOW_ANY` shares its bit with the old `O_ALERT`.
    o.ALERT = true;
    const r = c.open(path, o, @as(c.mode_t, @intCast(mode)));
    if (r < 0) return errno();
    fd.* = r;
    return .SUCCESS;
}

/// Opens `path` safely and checks it's still the file with inode `ino`.
pub fn openVerified(path: [*:0]const u8, flags: c.O, ino: u64, fd: *Fd, attr: *Attr) E {
    var o = flags;
    o.NONBLOCK = true; // FIFOs and devices mustn't block the open
    const e = openSafe(path, o, 0, fd);
    if (e != .SUCCESS) return if (e == .LOOP) .STALE else e;
    const s = fstat(fd.*, attr);
    if (s != .SUCCESS or attr.ino != ino) {
        closeFd(fd.*);
        return if (s != .SUCCESS) s else .STALE;
    }
    return .SUCCESS;
}

pub fn closeFd(fd: Fd) void {
    _ = c.close(fd);
}

pub fn fstat(fd: Fd, attr: *Attr) E {
    if (builtin.os.tag == .linux) return statAtFlags(fd, "", std.os.linux.AT.EMPTY_PATH, attr);
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return errno();
    attr.* = fromStat(st);
    return .SUCCESS;
}

/// Writes all of `data` at `offset`.
pub fn writeAt(fd: Fd, offset: u64, data: []const u8) E {
    var done: usize = 0;
    while (done < data.len) {
        const r = c.pwrite(fd, data[done..].ptr, data.len - done, @intCast(offset + done));
        if (r < 0) {
            if (errno() == .INTR) continue;
            return errno();
        }
        done += @intCast(r);
    }
    return .SUCCESS;
}

/// Reads up to `out.len` bytes at `offset`.
pub fn readFd(fd: Fd, offset: u64, out: []u8, n: *usize) E {
    var done: usize = 0;
    while (done < out.len) {
        const r = c.pread(fd, out[done..].ptr, out.len - done, @intCast(offset + done));
        if (r < 0) {
            if (errno() == .INTR) continue;
            return errno();
        }
        if (r == 0) break;
        done += @intCast(r);
    }
    n.* = done;
    return .SUCCESS;
}

fn check(rc: c_int) E {
    return if (rc == 0) .SUCCESS else errno();
}

pub fn sync(fd: Fd) E {
    return check(c.fsync(fd));
}

pub fn truncateFd(fd: Fd, size: u64) E {
    return check(c.ftruncate(fd, @intCast(size)));
}

pub fn chmodFd(fd: Fd, mode: u32) E {
    return check(c.fchmod(fd, @intCast(mode)));
}

pub fn chownFd(fd: Fd, uid: ?u32, gid: ?u32) E {
    return check(c.fchown(fd, uid orelse std.math.maxInt(u32), gid orelse std.math.maxInt(u32)));
}

/// A time to set: unchanged, now, or a given time.
pub const SetTime = union(enum) {
    omit,
    now,
    at: Timespec,

    fn timespec(t: SetTime) c.timespec {
        return switch (t) {
            .omit => c.UTIME.OMIT,
            .now => c.UTIME.NOW,
            .at => |ts| .{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) },
        };
    }
};

pub fn setTimesFd(fd: Fd, atime: SetTime, mtime: SetTime) E {
    const times: [2]c.timespec = .{ atime.timespec(), mtime.timespec() };
    return check(c.futimens(fd, &times));
}

/// `fstatat` relative to `dir` without following a final symbolic link.
pub fn statIn(dir: Fd, name: [*:0]const u8, attr: *Attr) E {
    return statAt(dir, name, attr);
}

pub fn chownIn(dir: Fd, name: [*:0]const u8, uid: ?u32, gid: ?u32) E {
    return check(c.fchownat(dir, name, uid orelse std.math.maxInt(u32), gid orelse std.math.maxInt(u32), c.AT.SYMLINK_NOFOLLOW));
}

/// Changes the mode of a non-link entry of `dir`. macOS refuses to follow a
/// final symbolic link; Linux can't chmod links at all, so callers skip them.
pub fn chmodIn(dir: Fd, name: [*:0]const u8, mode: u32) E {
    const flags: c_uint = if (builtin.os.tag.isDarwin()) c.AT.SYMLINK_NOFOLLOW else 0;
    return check(c.fchmodat(dir, name, @intCast(mode), flags));
}

pub fn setTimesIn(dir: Fd, name: [*:0]const u8, atime: SetTime, mtime: SetTime) E {
    const times: [2]c.timespec = .{ atime.timespec(), mtime.timespec() };
    return check(c.utimensat(dir, name, &times, c.AT.SYMLINK_NOFOLLOW));
}

/// Opens or creates a regular file in `dir`, never following a link there.
pub fn createIn(dir: Fd, name: [*:0]const u8, exclusive: bool, mode: u32, fd: *Fd) E {
    const o: c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = exclusive, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true };
    const r = c.openat(dir, name, o, @as(c.mode_t, @intCast(mode)));
    if (r < 0) return errno();
    fd.* = r;
    return .SUCCESS;
}

pub fn mkdirIn(dir: Fd, name: [*:0]const u8, mode: u32) E {
    return check(c.mkdirat(dir, name, @intCast(mode)));
}

pub fn symlinkIn(target: [*:0]const u8, dir: Fd, name: [*:0]const u8) E {
    return check(c.symlinkat(target, dir, name));
}

extern "c" fn mknodat(dir: Fd, path: [*:0]const u8, mode: c.mode_t, dev: c.dev_t) c_int;

pub fn mknodIn(dir: Fd, name: [*:0]const u8, mode: u32, dev: u64) E {
    return check(mknodat(dir, name, @intCast(mode), @intCast(dev)));
}

pub fn unlinkIn(dir: Fd, name: [*:0]const u8, directory: bool) E {
    return check(c.unlinkat(dir, name, if (directory) c.AT.REMOVEDIR else 0));
}

pub fn renameIn(from_dir: Fd, from: [*:0]const u8, to_dir: Fd, to: [*:0]const u8) E {
    return check(c.renameat(from_dir, from, to_dir, to));
}

/// Hard-links `from_dir`'s `from` as `to_dir`'s `to`, not following links.
pub fn linkIn(from_dir: Fd, from: [*:0]const u8, to_dir: Fd, to: [*:0]const u8) E {
    return check(c.linkat(from_dir, from, to_dir, to, 0));
}

/// A device number from its parts, as this system encodes them.
pub fn makeDev(major: u32, minor: u32) u64 {
    if (builtin.os.tag.isDarwin()) return (@as(u64, major) << 24) | (minor & 0xffffff);
    return (@as(u64, major & 0xfff) << 8) | (@as(u64, major & ~@as(u32, 0xfff)) << 32) |
        (minor & 0xff) | (@as(u64, minor & ~@as(u32, 0xff)) << 12);
}

pub fn isRoot() bool {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.geteuid() == 0,
        else => c.geteuid() == 0,
    };
}

/// File-system capacity, from `statfs` (macOS) or `statvfs` (Linux).
pub const FsStat = struct {
    block_size: u64,
    blocks: u64,
    blocks_free: u64,
    blocks_avail: u64,
    files: u64,
    files_free: u64,
};

const MacStatfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

const LinuxStatvfs = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [16]c_int,
};

const statfs_symbol = if (builtin.os.tag.isDarwin() and builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs";
const macStatfs = @extern(*const fn ([*:0]const u8, *MacStatfs) callconv(.c) c_int, .{ .name = statfs_symbol });
extern "c" fn statvfs(path: [*:0]const u8, buf: *LinuxStatvfs) c_int;

pub fn fsStat(path: [*:0]const u8, out: *FsStat) E {
    if (builtin.os.tag.isDarwin()) {
        var s: MacStatfs = undefined;
        if (macStatfs(path, &s) != 0) return errno();
        out.* = .{ .block_size = s.bsize, .blocks = s.blocks, .blocks_free = s.bfree, .blocks_avail = s.bavail, .files = s.files, .files_free = s.ffree };
    } else {
        var s: LinuxStatvfs = undefined;
        if (statvfs(path, &s) != 0) return errno();
        out.* = .{ .block_size = s.frsize, .blocks = s.blocks, .blocks_free = s.bfree, .blocks_avail = s.bavail, .files = s.files, .files_free = s.ffree };
    }
    return .SUCCESS;
}

/// Whether names on the file system holding `path` are case-sensitive.
pub fn caseSensitive(path: [*:0]const u8) bool {
    if (!builtin.os.tag.isDarwin()) return true;
    const _PC_CASE_SENSITIVE = 11;
    return pathconf(path, _PC_CASE_SENSITIVE) != 0;
}
extern "c" fn pathconf(path: [*:0]const u8, name: c_int) c_long;

/// Reads the target of the symbolic link at `path` into `out`.
pub fn readLink(path: [*:0]const u8, out: []u8, result: *[]const u8) E {
    const n = c.readlink(path, out.ptr, out.len);
    if (n < 0) return errno();
    result.* = out[0..@intCast(n)];
    return .SUCCESS;
}

/// A directory's entries, read in order.
pub const DirReader = struct {
    dir: *c.DIR,

    /// Reads the directory open at `fd`, taking ownership of it.
    pub fn fromFd(fd: Fd, out: *DirReader) E {
        out.dir = c.fdopendir(fd) orelse {
            const e = errno();
            closeFd(fd);
            return e;
        };
        return .SUCCESS;
    }

    pub fn close(r: *DirReader) void {
        _ = c.closedir(r.dir);
    }

    pub const Entry = struct { ino: u64, name: []const u8 };

    pub fn next(r: *DirReader) ?Entry {
        const ent = c.readdir(r.dir) orelse return null;
        return .{ .ino = ent.ino, .name = std.mem.sliceTo(&ent.name, 0) };
    }
};

/// The user and group IDs of `nobody`, for squashing.
pub fn nobody() struct { uid: u32, gid: u32 } {
    if (c.getpwnam("nobody")) |pw| return .{ .uid = pw.uid, .gid = pw.gid };
    return .{ .uid = 65534, .gid = 65534 };
}

extern "c" fn realpath(noalias path: [*:0]const u8, noalias resolved: [*]u8) ?[*:0]u8;

pub const max_path = c.PATH_MAX;

/// Sets `result` to the canonical absolute path of `path`, resolving `.`,
/// `..`, and symbolic links, in `out`.
pub fn canonical(path: []const u8, out: *[max_path]u8, result: *[]const u8) E {
    var z: [max_path]u8 = undefined;
    if (path.len >= z.len) return .NAMETOOLONG;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const resolved = realpath(z[0..path.len :0], out) orelse return errno();
    result.* = std.mem.span(resolved);
    return .SUCCESS;
}

fn errno() E {
    return @fromBackingInt(@intCast(c._errno().*));
}

const testing = std.testing;

test "safe opens refuse links in any component; descriptor-relative calls" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.symLink(io, "real", "alias", .{});
    var root_buf: [max_path]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    var buf: [max_path + 1]u8 = undefined;
    const real = try std.fmt.bufPrintSentinel(&buf, "{s}/real", .{root}, 0);
    var dir: Fd = undefined;
    try testing.expectEqual(E.SUCCESS, openSafe(real, .{ .DIRECTORY = true }, 0, &dir));
    defer closeFd(dir);

    var fd: Fd = undefined;
    try testing.expectEqual(E.SUCCESS, createIn(dir, "hal", true, 0o600, &fd));
    try testing.expectEqual(E.EXIST, createIn(dir, "hal", true, 0o600, &fd)); // fd unchanged
    try testing.expectEqual(E.SUCCESS, writeAt(fd, 3, "9000"));
    try testing.expectEqual(E.SUCCESS, sync(fd));
    var out: [16]u8 = undefined;
    var n: usize = 0;
    try testing.expectEqual(E.SUCCESS, readFd(fd, 0, &out, &n));
    try testing.expectEqualSlices(u8, "\x00\x00\x009000", out[0..n]);
    try testing.expectEqual(E.SUCCESS, truncateFd(fd, 2));
    try testing.expectEqual(E.SUCCESS, chmodFd(fd, 0o640));
    try testing.expectEqual(E.SUCCESS, setTimesFd(fd, .omit, .{ .at = .{ .sec = 1_000_000_000, .nsec = 7 } }));
    var attr: Attr = undefined;
    try testing.expectEqual(E.SUCCESS, fstat(fd, &attr));
    try testing.expectEqual(2, attr.size);
    try testing.expectEqual(0o640, attr.mode & 0o777);
    try testing.expectEqual(1_000_000_000, attr.mtime.sec);
    closeFd(fd);

    // The same directory through a link in the path is refused.
    const through = try std.fmt.bufPrintSentinel(&buf, "{s}/alias/hal", .{root}, 0);
    try testing.expect(openSafe(through, .{}, 0, &fd) != .SUCCESS);
    const direct = try std.fmt.bufPrintSentinel(&buf, "{s}/real/hal", .{root}, 0);
    try testing.expectEqual(E.SUCCESS, openVerified(direct, .{}, attr.ino, &fd, &attr));
    closeFd(fd);
    try testing.expectEqual(E.STALE, openVerified(direct, .{}, attr.ino + 1, &fd, &attr));

    try testing.expectEqual(E.SUCCESS, mkdirIn(dir, "sub", 0o755));
    try testing.expectEqual(E.SUCCESS, symlinkIn("hal", dir, "link"));
    try testing.expectEqual(E.SUCCESS, chownIn(dir, "link", null, null));
    try testing.expectEqual(E.SUCCESS, setTimesIn(dir, "link", .now, .now));
    try testing.expectEqual(E.SUCCESS, chmodIn(dir, "sub", 0o700));
    try testing.expectEqual(E.SUCCESS, linkIn(dir, "hal", dir, "hal2"));
    try testing.expectEqual(E.SUCCESS, statIn(dir, "hal2", &attr));
    try testing.expectEqual(2, attr.nlink);
    try testing.expectEqual(E.SUCCESS, renameIn(dir, "hal2", dir, "sub/hal3"));
    try testing.expectEqual(E.SUCCESS, mknodIn(dir, "fifo", std.posix.S.IFIFO | 0o600, 0));
    try testing.expectEqual(E.SUCCESS, statIn(dir, "fifo", &attr));
    try testing.expectEqual(std.posix.S.IFIFO, attr.mode & std.posix.S.IFMT);
    try testing.expectEqual(E.NOTEMPTY, unlinkIn(dir, "sub", true));
    try testing.expectEqual(E.SUCCESS, unlinkIn(dir, "sub/hal3", false));
    try testing.expectEqual(E.SUCCESS, unlinkIn(dir, "sub", true));
}

test "lstat a directory and a missing path" {
    var attr: Attr = undefined;
    try testing.expectEqual(E.SUCCESS, lstat("/", &attr));
    try testing.expectEqual(posix.S.IFDIR, attr.mode & posix.S.IFMT);
    try testing.expect(attr.ino != 0);
    try testing.expectEqual(E.NOENT, lstat("/skynet/does/not/exist", &attr));
}
