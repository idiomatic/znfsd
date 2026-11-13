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
        if (c.statx(dir, path, c.AT.SYMLINK_NOFOLLOW, mask, &stx) != 0) return errno();
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
    if (c.fstatat(dir, path, &st, c.AT.SYMLINK_NOFOLLOW) != 0) return errno();
    attr.* = .{
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
        .gen = st.gen,
    };
    return .SUCCESS;
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

test "lstat a directory and a missing path" {
    var attr: Attr = undefined;
    try testing.expectEqual(E.SUCCESS, lstat("/", &attr));
    try testing.expectEqual(posix.S.IFDIR, attr.mode & posix.S.IFMT);
    try testing.expect(attr.ino != 0);
    try testing.expectEqual(E.NOENT, lstat("/skynet/does/not/exist", &attr));
}
