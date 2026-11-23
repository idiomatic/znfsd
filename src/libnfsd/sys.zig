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

/// `stat` without following a final symbolic link, but following any
/// before it: for the server's own paths. Clients' go through `lstatSafe`.
pub fn lstat(path: [*:0]const u8, attr: *Attr) E {
    return statAt(c.AT.FDCWD, path, attr);
}

/// `lstat` refusing symbolic links before the last component, as
/// `openSafe` does, so a path can't be redirected outside an export.
pub fn lstatSafe(path: [*:0]const u8, attr: *Attr) E {
    var parent: Parent = undefined;
    const e = parent.open(path);
    if (e != .SUCCESS) return e;
    defer closeFd(parent.fd);
    return statAt(parent.fd, parent.name, attr);
}

/// The directory holding a path's last component, opened for lookups
/// only, and that component (`.` when the path ends in `/`).
const Parent = struct {
    fd: Fd,
    name: [:0]const u8,
    dir_buf: [max_path + 1]u8,

    /// Opens the directory refusing symbolic links on the way; `path` must
    /// be absolute and outlive `name`.
    fn open(p: *Parent, path: [*:0]const u8) E {
        const full = std.mem.span(path);
        const slash = std.mem.lastIndexOfScalar(u8, full, '/') orelse return .INVAL;
        const dir = if (slash + 1 == full.len) full else if (slash == 0) "/" else full[0..slash];
        p.name = if (slash + 1 == full.len) "." else full[slash + 1 ..];
        if (dir.len > max_path) return .NAMETOOLONG;
        @memcpy(p.dir_buf[0..dir.len], dir);
        p.dir_buf[dir.len] = 0;
        return openDirSafe(p.dir_buf[0..dir.len :0], &p.fd);
    }
};

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

/// Opens the directory `path` safely, for lookups and metadata only, so
/// it needs search permission, not read: `O_PATH` on Linux, `O_SEARCH` on
/// macOS.
pub fn openDirSafe(path: [*:0]const u8, fd: *Fd) E {
    var o: c.O = .{ .DIRECTORY = true };
    if (builtin.os.tag == .linux) {
        o.PATH = true;
    } else {
        const O_EXEC: u32 = 0x40000000; // with O_DIRECTORY, O_SEARCH
        o = @bitCast(@as(u32, @bitCast(o)) | O_EXEC);
    }
    return openSafe(path, o, 0, fd);
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
/// `offset + done` as a file offset, or null past the largest.
fn fileOffset(offset: u64, done: usize) ?c.off_t {
    return std.math.cast(c.off_t, std.math.add(u64, offset, done) catch return null);
}

/// Writes all of `data` at `offset`; past the largest file offset, `FBIG`.
pub fn writeAt(fd: Fd, offset: u64, data: []const u8) E {
    if (fileOffset(offset, data.len) == null) return .FBIG;
    var done: usize = 0;
    while (done < data.len) {
        const r = c.pwrite(fd, data[done..].ptr, data.len - done, fileOffset(offset, done).?);
        if (r < 0) {
            if (errno() == .INTR) continue;
            return errno();
        }
        done += @intCast(r);
    }
    return .SUCCESS;
}

/// Reads up to `out.len` bytes at `offset`; nothing past the largest file
/// offset, as at the end of a file.
pub fn readFd(fd: Fd, offset: u64, out: []u8, n: *usize) E {
    var done: usize = 0;
    while (done < out.len) {
        const at = fileOffset(offset, done) orelse break;
        // Linux refuses reads that would end past the largest offset.
        const room: u64 = @intCast(std.math.maxInt(c.off_t) - at);
        if (room == 0) break;
        const r = c.pread(fd, out[done..].ptr, @intCast(@min(out.len - done, room)), at);
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

/// Flushes `fd` to stable storage. macOS's `fsync` stops at the drive's
/// cache, so it asks for `F_FULLFSYNC` first, falling back to `fsync` on
/// file systems that refuse.
pub fn sync(fd: Fd) E {
    if (builtin.os.tag.isDarwin()) {
        const F_FULLFSYNC = 51;
        if (c.fcntl(fd, F_FULLFSYNC) == 0) return .SUCCESS;
    }
    return check(c.fsync(fd));
}

pub fn truncateFd(fd: Fd, size: u64) E {
    return check(c.ftruncate(fd, std.math.cast(c.off_t, size) orelse return .FBIG));
}

pub fn chmodFd(fd: Fd, mode: u32) E {
    return check(c.fchmod(fd, @intCast(mode & 0o7777)));
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

/// Changes the mode of an entry of `dir`, never following a final symbolic
/// link: `fchmodat` with `AT_SYMLINK_NOFOLLOW` on macOS, `fchmodat2` on
/// Linux (6.6+), whose `fchmodat` lacks the flag. Links themselves can't be
/// changed on Linux, so callers skip them.
pub fn chmodIn(dir: Fd, name: [*:0]const u8, mode: u32) E {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.syscall4(.fchmodat2, @bitCast(@as(isize, dir)), @intFromPtr(name), mode & 0o7777, c.AT.SYMLINK_NOFOLLOW);
        return linux.errno(rc);
    }
    return check(c.fchmodat(dir, name, @intCast(mode & 0o7777), c.AT.SYMLINK_NOFOLLOW));
}

/// Opens like `openVerified`, but when refused for want of permission on a
/// file the effective user owns (the caller being acted as, else this
/// process), briefly grants the owner read and write to open it, as a local
/// owner could: an owner may always change a file's mode, and a file stays
/// usable once open. Linux's kernel server calls this the owner override.
pub fn openOwned(path: [*:0]const u8, flags: c.O, ino: u64, fd: *Fd, attr: *Attr) E {
    const e = openVerified(path, flags, ino, fd, attr);
    if (e != .ACCES) return e;
    const owner = if (acting) |a| a.uid else c.geteuid();
    const full = std.mem.span(path);
    const dir_path = std.fs.path.dirname(full) orelse return e;
    const base = std.fs.path.basename(full);
    var dir_buf: [max_path + 1]u8 = undefined;
    @memcpy(dir_buf[0..dir_path.len], dir_path);
    dir_buf[dir_path.len] = 0;
    var dir: Fd = undefined;
    if (openSafe(dir_buf[0..dir_path.len :0], .{ .DIRECTORY = true }, 0, &dir) != .SUCCESS) return e;
    defer closeFd(dir);
    var name_buf: [max_path + 1]u8 = undefined;
    @memcpy(name_buf[0..base.len], base);
    name_buf[base.len] = 0;
    const name = name_buf[0..base.len :0];
    var before: Attr = undefined;
    if (statIn(dir, name, &before) != .SUCCESS or before.ino != ino) return .STALE;
    if (before.uid != owner or before.mode & std.posix.S.IFMT != std.posix.S.IFREG) return e;
    const mode = before.mode & 0o7777;
    if (chmodIn(dir, name, mode | 0o600) != .SUCCESS) return e;
    var o = flags;
    o.NOFOLLOW = true;
    o.NONBLOCK = true;
    o.CLOEXEC = true;
    const r = c.openat(dir, name, o, @as(c.mode_t, 0));
    const open_errno = if (r < 0) errno() else E.SUCCESS;
    _ = chmodIn(dir, name, mode);
    if (open_errno != .SUCCESS) return open_errno;
    fd.* = r;
    if (fstat(r, attr) != .SUCCESS or attr.ino != ino) {
        closeFd(r);
        return .STALE;
    }
    return .SUCCESS;
}

pub fn setTimesIn(dir: Fd, name: [*:0]const u8, atime: SetTime, mtime: SetTime) E {
    const times: [2]c.timespec = .{ atime.timespec(), mtime.timespec() };
    return check(c.utimensat(dir, name, &times, c.AT.SYMLINK_NOFOLLOW));
}

/// Opens or creates a regular file in `dir`, never following a link there.
pub fn createIn(dir: Fd, name: [*:0]const u8, exclusive: bool, mode: u32, fd: *Fd) E {
    // An existing device or FIFO isn't opened: opening can have effects.
    var existing: Attr = undefined;
    if (!exclusive and statIn(dir, name, &existing) == .SUCCESS and existing.mode & posix.S.IFMT != posix.S.IFREG) {
        return if (existing.mode & posix.S.IFMT == posix.S.IFDIR) .ISDIR else .INVAL;
    }
    const o: c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = exclusive, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true };
    const r = c.openat(dir, name, o, @as(c.mode_t, @intCast(mode & 0o7777)));
    if (r < 0) return errno();
    fd.* = r;
    return .SUCCESS;
}

pub fn mkdirIn(dir: Fd, name: [*:0]const u8, mode: u32) E {
    return check(c.mkdirat(dir, name, @intCast(mode & 0o7777)));
}

pub fn symlinkIn(target: [*:0]const u8, dir: Fd, name: [*:0]const u8) E {
    return check(c.symlinkat(target, dir, name));
}

extern "c" fn mknodat(dir: Fd, path: [*:0]const u8, mode: c.mode_t, dev: c.dev_t) c_int;

/// `mode` holds the file type and permissions; a `dev` too large for the
/// host is `INVAL`.
pub fn mknodIn(dir: Fd, name: [*:0]const u8, mode: u32, dev: u64) E {
    const d: c.dev_t = if (@typeInfo(c.dev_t).int.signedness == .signed)
        std.math.cast(c.dev_t, @as(i64, @bitCast(dev))) orelse return .INVAL
    else
        std.math.cast(c.dev_t, dev) orelse return .INVAL;
    return check(mknodat(dir, name, @intCast(mode & 0o177777), d));
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

/// A caller's identity, for acting as them in file-system calls.
pub const Identity = struct {
    uid: u32,
    gid: u32,
    /// Supplementary groups; on macOS, the host's own membership for `uid`
    /// applies instead.
    gids: []const u32 = &.{},
};

const max_groups = 32;

/// The identity this thread is acting as, if any; per thread.
threadlocal var acting: ?struct { uid: u32, gid: u32, gids: [max_groups]u32, n: u8 } = null;

/// Linux's NGROUPS_MAX, the most supplementary groups a thread can have.
const ngroups_max = 65536;

/// The server's supplementary groups, all of them, restored after acting as
/// a caller; untouched pages cost nothing.
var server_groups: [if (builtin.os.tag == .linux) ngroups_max else 0]u32 = undefined;
var server_groups_len: usize = 0;
var server_groups_state: std.atomic.Value(enum(u8) { unsaved, saving, saved }) = .init(.unsaved);

fn saveServerGroups() void {
    if (server_groups_state.load(.acquire) == .saved) return;
    if (server_groups_state.cmpxchgStrong(.unsaved, .saving, .acquire, .acquire) == null) {
        const n = std.os.linux.getgroups(server_groups.len, &server_groups);
        server_groups_len = if (std.os.linux.errno(n) == .SUCCESS) n else 0;
        server_groups_state.store(.saved, .release);
        return;
    }
    while (server_groups_state.load(.acquire) != .saved) std.atomic.spinLoopHint();
}

extern "c" fn pthread_setugid_np(uid: c.uid_t, gid: c.gid_t) c_int;
/// KAUTH_UID_NONE and KAUTH_GID_NONE: back to the process's identity.
const kauth_none: u32 = std.math.maxInt(u32) - 100;

/// Makes this thread's file-system calls act as `id`, until `revert`.
/// Only root can; per thread, so other requests are unaffected.
pub fn become(id: Identity) E {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        saveServerGroups();
        const n = @min(id.gids.len, max_groups);
        const rc = linux.syscall2(.setgroups, n, @intFromPtr(id.gids.ptr));
        if (linux.errno(rc) != .SUCCESS) return restoreLinux(linux.errno(rc));
        // setfsuid and setfsgid report the previous ID, never an error, so
        // a second call checks the first took. A failure after the first
        // change restores the server's own identity, so no thread is left
        // half-changed.
        _ = linux.syscall1(.setfsgid, id.gid);
        if (linux.syscall1(.setfsgid, id.gid) != id.gid) return restoreLinux(.PERM);
        _ = linux.syscall1(.setfsuid, id.uid);
        if (linux.syscall1(.setfsuid, id.uid) != id.uid) return restoreLinux(.PERM);
    } else if (builtin.os.tag.isDarwin()) {
        // From another identity, return to the process's first.
        if (acting != null) _ = pthread_setugid_np(kauth_none, kauth_none);
        if (pthread_setugid_np(id.uid, id.gid) != 0) return errno();
    } else return .NOSYS;
    var saved: @TypeOf(acting.?) = .{ .uid = id.uid, .gid = id.gid, .gids = undefined, .n = @intCast(@min(id.gids.len, max_groups)) };
    @memcpy(saved.gids[0..saved.n], id.gids[0..saved.n]);
    acting = saved;
    return .SUCCESS;
}

/// Puts this thread's Linux identity back to the server's, returning `e`:
/// its file-system IDs follow its effective ones again.
fn restoreLinux(e: E) E {
    const linux = std.os.linux;
    _ = linux.syscall1(.setfsuid, linux.geteuid());
    _ = linux.syscall1(.setfsgid, linux.getegid());
    _ = linux.syscall2(.setgroups, server_groups_len, @intFromPtr(&server_groups));
    return e;
}

/// Returns this thread to the server's own identity.
pub fn revert() void {
    if (acting == null) return;
    if (builtin.os.tag == .linux) {
        _ = restoreLinux(.SUCCESS);
    } else if (builtin.os.tag.isDarwin()) {
        _ = pthread_setugid_np(kauth_none, kauth_none);
    }
    acting = null;
}

/// Suspends acting as a caller, for the server's own files (its database),
/// returning what to `resume`.
pub fn pause() ?Identity {
    const a = acting orelse return null;
    revert();
    paused_gids = a.gids;
    return .{ .uid = a.uid, .gid = a.gid, .gids = paused_gids[0..a.n] };
}

threadlocal var paused_gids: [max_groups]u32 = undefined;

pub const ResumeError = error{ResumeFailed};

/// Acts as the paused caller again. On failure the thread is left as the
/// server, so the request must go no further: callers return the error.
pub fn @"resume"(id: ?Identity) ResumeError!void {
    if (id) |i| if (become(i) != .SUCCESS) return error.ResumeFailed;
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

const fstatfs_symbol = if (builtin.os.tag.isDarwin() and builtin.cpu.arch == .x86_64) "fstatfs$INODE64" else "fstatfs";
const macFstatfs = @extern(*const fn (Fd, *MacStatfs) callconv(.c) c_int, .{ .name = fstatfs_symbol });
extern "c" fn fstatvfs(fd: Fd, buf: *LinuxStatvfs) c_int;

/// Opens, safely, a directory on the file system holding `path`: the
/// directory itself, else (a file or a link) the one holding it.
fn openFsOf(path: [*:0]const u8, fd: *Fd) E {
    const e = openDirSafe(path, fd);
    if (e != .NOTDIR and e != .LOOP) return e;
    var parent: Parent = undefined;
    const pe = parent.open(path);
    fd.* = parent.fd;
    return pe;
}

/// The capacity of the file system holding `path`, reached safely.
pub fn fsStat(path: [*:0]const u8, out: *FsStat) E {
    var fd: Fd = undefined;
    const e = openFsOf(path, &fd);
    if (e != .SUCCESS) return e;
    defer closeFd(fd);
    if (builtin.os.tag.isDarwin()) {
        var s: MacStatfs = undefined;
        if (macFstatfs(fd, &s) != 0) return errno();
        out.* = .{ .block_size = s.bsize, .blocks = s.blocks, .blocks_free = s.bfree, .blocks_avail = s.bavail, .files = s.files, .files_free = s.ffree };
    } else {
        var s: LinuxStatvfs = undefined;
        if (fstatvfs(fd, &s) != 0) return errno();
        out.* = .{ .block_size = s.frsize, .blocks = s.blocks, .blocks_free = s.bfree, .blocks_avail = s.bavail, .files = s.files, .files_free = s.ffree };
    }
    return .SUCCESS;
}

/// Whether names on the file system holding `path`, reached safely, are
/// case-sensitive.
pub fn caseSensitive(path: [*:0]const u8) bool {
    if (!builtin.os.tag.isDarwin()) return true;
    var fd: Fd = undefined;
    if (openFsOf(path, &fd) != .SUCCESS) return true;
    defer closeFd(fd);
    const _PC_CASE_SENSITIVE = 11;
    return fpathconf(fd, _PC_CASE_SENSITIVE) != 0;
}
extern "c" fn fpathconf(fd: Fd, name: c_int) c_long;

/// Reads the target of the symbolic link at `path` into `out`, refusing
/// links before it as `lstatSafe` does.
pub fn readLinkSafe(path: [*:0]const u8, out: []u8, result: *[]const u8) E {
    var parent: Parent = undefined;
    const e = parent.open(path);
    if (e != .SUCCESS) return e;
    defer closeFd(parent.fd);
    const n = c.readlinkat(parent.fd, parent.name, out.ptr, out.len);
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

    pub const Entry = struct { ino: u64, name: [:0]const u8 };

    pub fn next(r: *DirReader) ?Entry {
        const ent = c.readdir(r.dir) orelse return null;
        return .{ .ino = ent.ino, .name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0) };
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

test "safe stats and link reads refuse links before the last component" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/hal", .data = "9000" });
    try tmp.dir.symLink(io, "hal", "real/link", .{});
    try tmp.dir.symLink(io, "real", "alias", .{});
    var root_buf: [max_path]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var buf: [max_path + 1]u8 = undefined;
    var attr: Attr = undefined;
    var out: [16]u8 = undefined;
    var target: []const u8 = undefined;
    var s: FsStat = undefined;

    // Direct paths work, and a final link is the link itself.
    var path = try std.fmt.bufPrintSentinel(&buf, "{s}/real/link", .{root}, 0);
    try testing.expectEqual(E.SUCCESS, lstatSafe(path, &attr));
    try testing.expectEqual(posix.S.IFLNK, attr.mode & posix.S.IFMT);
    try testing.expectEqual(E.SUCCESS, readLinkSafe(path, &out, &target));
    try testing.expectEqualStrings("hal", target);
    try testing.expectEqual(E.SUCCESS, fsStat(path, &s));
    path = try std.fmt.bufPrintSentinel(&buf, "{s}/real", .{root}, 0);
    try testing.expectEqual(E.SUCCESS, fsStat(path, &s));
    try testing.expectEqual(E.SUCCESS, lstatSafe("/", &attr));
    try testing.expectEqual(posix.S.IFDIR, attr.mode & posix.S.IFMT);

    // Through a link mid-path, all are refused, though `lstat` follows it.
    for ([_][]const u8{ "hal", "link" }) |name| {
        path = try std.fmt.bufPrintSentinel(&buf, "{s}/alias/{s}", .{ root, name }, 0);
        try testing.expectEqual(E.SUCCESS, lstat(path, &attr));
        try testing.expectEqual(E.LOOP, lstatSafe(path, &attr));
        try testing.expectEqual(E.LOOP, readLinkSafe(path, &out, &target));
        try testing.expectEqual(E.LOOP, fsStat(path, &s));
    }
    path = try std.fmt.bufPrintSentinel(&buf, "{s}/alias/", .{root}, 0);
    try testing.expectEqual(E.LOOP, lstatSafe(path, &attr));
    try testing.expectEqual(E.LOOP, fsStat(path, &s));
}

test "act as another user, then revert" {
    if (!isRoot()) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var dir: Fd = undefined;
    var z: [max_path + 1]u8 = undefined;
    try testing.expectEqual(E.SUCCESS, openSafe(try std.fmt.bufPrintSentinel(&z, "{s}", .{root}, 0), .{ .DIRECTORY = true }, 0, &dir));
    defer closeFd(dir);
    try testing.expectEqual(E.SUCCESS, chmodFd(dir, 0o777));

    try testing.expectEqual(E.SUCCESS, become(.{ .uid = 4242, .gid = 4242 }));
    defer revert();
    var fd: Fd = undefined;
    try testing.expectEqual(E.SUCCESS, createIn(dir, "theirs", true, 0o600, &fd));
    closeFd(fd);
    // Acting as 4242, root's directory isn't theirs to change.
    try testing.expectEqual(E.PERM, chmodFd(dir, 0o755));
    const paused = pause();
    try testing.expectEqual(E.SUCCESS, createIn(dir, "server", true, 0o600, &fd));
    closeFd(fd);
    try @"resume"(paused);
    // Root's override is gone: root's private file can't be opened.
    try testing.expectEqual(E.ACCES, createIn(dir, "server", false, 0o600, &fd));
    revert();

    var attr: Attr = undefined;
    try testing.expectEqual(E.SUCCESS, statIn(dir, "theirs", &attr));
    try testing.expectEqual(4242, attr.uid);
    try testing.expectEqual(E.SUCCESS, statIn(dir, "server", &attr));
    try testing.expectEqual(0, attr.uid);
}

test "reverting restores all the server's groups and its own IDs" {
    if (builtin.os.tag != .linux or !isRoot()) return error.SkipZigTest;
    const linux = std.os.linux;
    const none = std.math.maxInt(u32);
    // This thread alone, through raw system calls, takes many groups and an
    // effective GID other than 0, and saves them afresh.
    var original: [64]u32 = undefined;
    const n = linux.getgroups(original.len, &original);
    try testing.expectEqual(E.SUCCESS, linux.errno(n));
    var many: [40]u32 = undefined;
    for (&many, 0..) |*g, i| g.* = @intCast(5000 + i);
    try testing.expectEqual(E.SUCCESS, linux.errno(linux.setgroups(many.len, &many)));
    defer _ = linux.setgroups(n, &original);
    const egid = linux.getegid();
    try testing.expectEqual(E.SUCCESS, linux.errno(linux.setresgid(none, 4243, none)));
    defer _ = linux.setresgid(none, egid, none);
    server_groups_state.store(.unsaved, .release);
    defer server_groups_state.store(.unsaved, .release);

    try testing.expectEqual(E.SUCCESS, become(.{ .uid = 4242, .gid = 4242 }));
    revert();
    var now: [64]u32 = undefined;
    const got = linux.getgroups(now.len, &now);
    try testing.expectEqualSlices(u32, &many, now[0..got]);
    // An invalid ID changes nothing, reporting the current one.
    try testing.expectEqual(4243, linux.syscall1(.setfsgid, none));
    try testing.expectEqual(linux.geteuid(), linux.syscall1(.setfsuid, none));
}

test "a failed resume is an error" {
    if (isRoot()) return error.SkipZigTest; // root can become anyone
    try testing.expectError(error.ResumeFailed, @"resume"(.{ .uid = 4242, .gid = 4242 }));
    try @"resume"(null);
}

test "an owner opens their own file whatever its mode" {
    if (isRoot()) return error.SkipZigTest; // root needs no override
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hal", .data = "9000" });
    var buf: [max_path]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var z: [max_path + 1]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&z, "{s}/hal", .{root}, 0);
    var attr: Attr = undefined;
    try testing.expectEqual(E.SUCCESS, lstat(path, &attr));
    var fd: Fd = undefined;
    try testing.expectEqual(E.SUCCESS, openSafe(path, .{}, 0, &fd));
    try testing.expectEqual(E.SUCCESS, chmodFd(fd, 0));
    closeFd(fd);

    try testing.expectEqual(E.ACCES, openVerified(path, .{ .ACCMODE = .WRONLY }, attr.ino, &fd, &attr));
    try testing.expectEqual(E.SUCCESS, openOwned(path, .{ .ACCMODE = .WRONLY }, attr.ino, &fd, &attr));
    try testing.expectEqual(E.SUCCESS, writeAt(fd, 0, "2001"));
    closeFd(fd);
    // The mode is as it was.
    try testing.expectEqual(E.SUCCESS, lstat(path, &attr));
    try testing.expectEqual(0, attr.mode & 0o7777);
}

test "offsets past the largest file offset" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hal", .data = "9000" });
    var buf: [max_path]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var z: [max_path + 1]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&z, "{s}/hal", .{root}, 0);
    var fd: Fd = undefined;
    try testing.expectEqual(E.SUCCESS, openSafe(path, .{ .ACCMODE = .RDWR }, 0, &fd));
    defer closeFd(fd);
    var out: [4]u8 = undefined;
    var n: usize = 1;
    for ([_]u64{ std.math.maxInt(i64), std.math.maxInt(i64) + 1, std.math.maxInt(u64) }) |offset| {
        try testing.expectEqual(E.SUCCESS, readFd(fd, offset, &out, &n));
        try testing.expectEqual(0, n);
        try testing.expectEqual(E.FBIG, writeAt(fd, offset, "2001"));
    }
    try testing.expectEqual(E.FBIG, truncateFd(fd, std.math.maxInt(u64)));
}

test "lstat a directory and a missing path" {
    var attr: Attr = undefined;
    try testing.expectEqual(E.SUCCESS, lstat("/", &attr));
    try testing.expectEqual(posix.S.IFDIR, attr.mode & posix.S.IFMT);
    try testing.expect(attr.ino != 0);
    try testing.expectEqual(E.NOENT, lstat("/skynet/does/not/exist", &attr));
}
