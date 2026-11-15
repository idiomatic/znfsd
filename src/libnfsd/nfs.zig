//! NFS version 3 (RFC 1813).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");
const server = @import("server.zig");
const exports = @import("exports.zig");
const fh = @import("fh.zig");
const sys = @import("sys.zig");
const Files = @import("files.zig").Files;
const exportId = @import("mount.zig").exportId;

pub const prog: u32 = 100003;
pub const vers: u32 = 3;

/// Largest READ or WRITE, and the preferred size.
pub const max_transfer: u32 = 1024 * 1024;
pub const max_name = 255;
pub const max_path = 1024;
pub const max_handle = 64;

pub const Proc = enum(u32) {
    null = 0,
    getattr = 1,
    setattr = 2,
    lookup = 3,
    access = 4,
    readlink = 5,
    read = 6,
    write = 7,
    create = 8,
    mkdir = 9,
    symlink = 10,
    mknod = 11,
    remove = 12,
    rmdir = 13,
    rename = 14,
    link = 15,
    readdir = 16,
    readdirplus = 17,
    fsstat = 18,
    fsinfo = 19,
    pathconf = 20,
    commit = 21,
    _,
};

pub const Status = enum(u32) {
    ok = 0,
    perm = 1,
    noent = 2,
    io = 5,
    nxio = 6,
    acces = 13,
    exist = 17,
    xdev = 18,
    nodev = 19,
    notdir = 20,
    isdir = 21,
    inval = 22,
    fbig = 27,
    nospc = 28,
    rofs = 30,
    mlink = 31,
    nametoolong = 63,
    notempty = 66,
    dquot = 69,
    stale = 70,
    remote = 71,
    badhandle = 10001,
    not_sync = 10002,
    bad_cookie = 10003,
    notsupp = 10004,
    toosmall = 10005,
    serverfault = 10006,
    badtype = 10007,
    jukebox = 10008,

    pub fn fromErrno(e: sys.E) Status {
        return switch (e) {
            .SUCCESS => .ok,
            .PERM => .perm,
            .NOENT => .noent,
            .NXIO => .nxio,
            .ACCES => .acces,
            .EXIST => .exist,
            .XDEV => .xdev,
            .NODEV => .nodev,
            .NOTDIR, .LOOP => .notdir,
            .ISDIR => .isdir,
            .INVAL => .inval,
            .FBIG => .fbig,
            .NOSPC => .nospc,
            .ROFS => .rofs,
            .MLINK => .mlink,
            .NAMETOOLONG => .nametoolong,
            .NOTEMPTY => .notempty,
            .DQUOT => .dquot,
            .STALE => .stale,
            else => .io,
        };
    }
};

pub const Ftype = enum(u32) { reg = 1, dir = 2, blk = 3, chr = 4, lnk = 5, sock = 6, fifo = 7 };

pub fn ftype(mode: u32) Ftype {
    return switch (mode & posix.S.IFMT) {
        posix.S.IFDIR => .dir,
        posix.S.IFBLK => .blk,
        posix.S.IFCHR => .chr,
        posix.S.IFLNK => .lnk,
        posix.S.IFSOCK => .sock,
        posix.S.IFIFO => .fifo,
        else => .reg,
    };
}

/// ACCESS3 bits.
pub const Access = struct {
    pub const read: u32 = 0x01;
    pub const lookup: u32 = 0x02;
    pub const modify: u32 = 0x04;
    pub const extend: u32 = 0x08;
    pub const delete: u32 = 0x10;
    pub const execute: u32 = 0x20;
};

/// The caller's identity, after squashing.
pub const Creds = struct {
    uid: u32,
    gid: u32,
    gids: []const u32,

    /// Whether these credentials have all of `want` (bits 4, 2, 1 for read,
    /// write, execute) on a file with `attr`.
    pub fn allows(c: Creds, attr: sys.Attr, want: u32) bool {
        if (c.uid == 0) {
            // Root may execute only what someone may.
            return want & 1 == 0 or attr.mode & 0o111 != 0 or ftype(attr.mode) == .dir;
        }
        const bits = if (attr.uid == c.uid)
            attr.mode >> 6
        else if (attr.gid == c.gid or std.mem.indexOfScalar(u32, c.gids, attr.gid) != null)
            attr.mode >> 3
        else
            attr.mode;
        return bits & want == want;
    }
};

pub const Nfs = struct {
    gpa: std.mem.Allocator,
    table: *const exports.Table,
    files: *Files,
    nobody: @TypeOf(sys.nobody()),
    /// Changes whenever the server restarts, so clients know to resend
    /// unstable writes not yet committed.
    verifier: [8]u8,
    /// As root, each request acts as its caller, so the OS checks access
    /// with the caller's own credentials.
    root: bool,

    pub fn init(gpa: std.mem.Allocator, table: *const exports.Table, files: *Files, verifier: [8]u8) Nfs {
        return .{ .gpa = gpa, .table = table, .files = files, .nobody = sys.nobody(), .verifier = verifier, .root = sys.isRoot() };
    }

    /// Replaces the export table while serving. The old table must outlive
    /// any request still using it.
    pub fn setTable(n: *Nfs, table: *const exports.Table) void {
        @atomicStore(*const exports.Table, &n.table, table, .release);
    }

    pub fn program(n: *Nfs) server.Program {
        return .{ .prog = prog, .low = vers, .high = vers, .ptr = n, .handle = handle };
    }

    pub const Located = struct {
        file: @import("locks.zig").File,
        path_buf: [sys.max_path + 1]u8,
        path_len: usize,

        pub fn path(l: *const Located) []const u8 {
            return l.path_buf[0..l.path_len];
        }
    };

    /// Whether an export rule covers `from`, as NLM requires of any caller.
    pub fn admits(n: *Nfs, from: Io.net.IpAddress) bool {
        return @atomicLoad(*const exports.Table, &n.table, .acquire).admits(from, null);
    }

    /// The file a handle names, if it still exists and `from` may reach
    /// it, as for NLM's lock requests.
    pub fn locate(n: *Nfs, io: Io, bytes: []const u8, from: Io.net.IpAddress, out: *Located) bool {
        const h = fh.Handle.decode(bytes) catch return false;
        const table = @atomicLoad(*const exports.Table, &n.table, .acquire);
        var attr: sys.Attr = undefined;
        const path = n.files.resolve(io, h, &out.path_buf, &attr) catch |err| switch (err) {
            error.Stale => exportRootPath(n.files, table, io, h, &attr, &out.path_buf) orelse return false,
            error.Canceled => return false,
        };
        if (table.match(path, from, null) == null) return false;
        out.file = .{ .fsid = h.fsid, .inode = h.inode };
        out.path_len = path.len;
        return true;
    }

    fn handle(ptr: *anyopaque, ctx: server.Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
        const n: *Nfs = @ptrCast(@alignCast(ptr));
        if (call.proc == @backingInt(Proc.null)) return .success;
        if (call.cred.flavor != .sys) return .{ .auth_error = .tooweak };
        const auth = rpc.AuthSys.decode(call.cred.body) catch return .{ .auth_error = .badcred };
        var r: Request = .{
            .n = n,
            .table = @atomicLoad(*const exports.Table, &n.table, .acquire),
            .ctx = ctx,
            .auth = auth,
            .d = .init(call.args),
            .e = .init(results),
            .results = results,
        };
        defer if (n.root) sys.revert();
        r.dispatch(@fromBackingInt(@intCast(call.proc))) catch |err| return switch (err) {
            error.Truncated, error.TooLong, error.Invalid => .garbage_args,
            error.WriteFailed, error.OutOfMemory, error.Canceled => .system_err,
        };
        return .success;
    }
};

/// A file found from a handle: where it is, what it is, and the rule
/// covering it.
const Found = struct {
    handle: fh.Handle,
    path: [:0]const u8,
    attr: sys.Attr,
    match: exports.Table.Match,
};

const Error = xdr.DecodeError || Io.Writer.Error || std.mem.Allocator.Error || Io.Cancelable;

const Request = struct {
    n: *Nfs,
    /// The export table when the request arrived.
    table: *const exports.Table,
    /// The map of the rule covering the last file found, if any.
    map: ?exports.Map = null,
    /// The device of the export root covering the last file found, if
    /// it could be read.
    root_dev: ?u64 = null,
    /// Supplementary GIDs after mapping.
    gid_buf: [rpc.AuthSys.max_gids]u32 = undefined,
    ctx: server.Context,
    auth: rpc.AuthSys,
    d: xdr.Decoder,
    e: xdr.Encoder,
    results: *Io.Writer,
    path_buf: [sys.max_path + 1]u8 = undefined,

    fn dispatch(r: *Request, proc: Proc) Error!void {
        switch (proc) {
            .null => {},
            .getattr => try r.getattr(),
            .lookup => try r.lookup(),
            .access => try r.access(),
            .readlink => try r.readlink(),
            .read => try r.read(),
            .readdir => try r.readdir(false),
            .readdirplus => try r.readdir(true),
            .fsstat => try r.fsstat(),
            .fsinfo => try r.fsinfo(),
            .pathconf => try r.pathconf(),
            .setattr => try r.setattr(),
            .write => try r.write(),
            .create => try r.create(),
            .mkdir => try r.make(.dir),
            .symlink => try r.make(.lnk),
            .mknod => try r.make(.fifo),
            .remove => try r.remove(false),
            .rmdir => try r.remove(true),
            .rename => try r.rename(),
            .link => try r.link(),
            .commit => try r.commit(),
            _ => try r.status(.notsupp),
        }
    }

    /// Attributes as the client sees them: owners mapped back to its IDs,
    /// and the fileid made unique across file systems.
    fn outward(r: *const Request, a: sys.Attr) Outward {
        var out = a;
        out.ino = r.fileid(a.dev, a.ino);
        if (r.map) |m| {
            out.uid = m.remoteUid(a.uid);
            out.gid = m.remoteGid(a.gid);
        }
        return .{ .attr = out };
    }

    /// A file's fileid: its inode on the export root's own file system;
    /// elsewhere (crossmnt), its inode with bits of the file system's ID
    /// folded in, since clients report one device for the whole mount.
    fn fileid(r: *const Request, dev: u64, ino: u64) u64 {
        const root = r.root_dev orelse return ino;
        if (dev == root) return ino;
        const salt = std.hash.Wyhash.hash(0, std.mem.asBytes(&dev)) << 40 | 1 << 63;
        return ino ^ salt;
    }

    fn fattrOut(r: *Request, a: sys.Attr) Error!void {
        try fattr(r.e, r.outward(a));
    }

    fn postOp(r: *Request, a: ?sys.Attr) Error!void {
        try postOpAttr(r.e, if (a) |x| r.outward(x) else null);
    }

    fn wccData(r: *Request, pre: ?sys.Attr, post: ?sys.Attr) Error!void {
        try wcc(r.e, pre, if (post) |x| r.outward(x) else null);
    }

    /// Owners a client asks to set, as host IDs.
    fn inward(r: *const Request, s: *Sattr) void {
        const m = r.map orelse return;
        if (s.uid) |u| s.uid = m.localUid(u);
        if (s.gid) |g| s.gid = m.localGid(g);
    }

    fn status(r: *Request, s: Status) Error!void {
        try r.e.enumeration(s);
    }

    fn emptyWcc(r: *Request) Error!void {
        try r.e.boolean(false);
        try r.e.boolean(false);
    }

    /// The caller's credentials under `rule`'s squashing and map: squashed
    /// callers act as the map's anon, else the host's `nobody`.
    fn creds(r: *Request, rule: *const exports.Rule) Creds {
        const m = r.mapOf(rule);
        const anon: Creds = .{
            .uid = if (m) |x| x.anonUid() orelse r.n.nobody.uid else r.n.nobody.uid,
            .gid = if (m) |x| x.anonGid() orelse r.n.nobody.gid else r.n.nobody.gid,
            .gids = &.{},
        };
        switch (rule.options.squash) {
            .all => return anon,
            .root => if (r.auth.uid == 0) return anon,
            .none => {},
        }
        // Squashing root squashes group 0 too: as the primary group it
        // becomes the anon's, and from the supplementary groups it goes.
        const squash_group = rule.options.squash == .root;
        var n: usize = 0;
        for (r.auth.gids()) |g| {
            if (squash_group and g == 0) continue;
            r.gid_buf[n] = if (m) |x| x.localGid(g) else g;
            n += 1;
        }
        const gid = if (squash_group and r.auth.gid == 0)
            anon.gid
        else if (m) |x| x.localGid(r.auth.gid) else r.auth.gid;
        const uid = if (m) |x| x.localUid(r.auth.uid) else r.auth.uid;
        return .{ .uid = uid, .gid = gid, .gids = r.gid_buf[0..n] };
    }

    fn mapOf(r: *const Request, rule: *const exports.Rule) ?exports.Map {
        const name = rule.options.map orelse return null;
        return r.table.maps.get(name);
    }

    /// Decodes a handle and finds its file, keeping its path in `buf`, or
    /// returns the status to report.
    fn find(r: *Request, buf: *[sys.max_path + 1]u8) Error!union(enum) { found: Found, failed: Status } {
        const bytes = try r.d.opaque_(max_handle);
        const h = fh.Handle.decode(bytes) catch return .{ .failed = .badhandle };
        var attr: sys.Attr = undefined;
        const path = r.n.files.resolve(r.ctx.io, h, buf, &attr) catch |err| switch (err) {
            error.Stale => r.exportRoot(h, &attr, buf) orelse return .{ .failed = .stale },
            error.Canceled => return error.Canceled,
        };
        const match = r.table.match(path, r.ctx.from, null) orelse return .{ .failed = .acces };
        r.map = r.mapOf(match.rule);
        r.root_dev = rootDev(match.path);
        if (r.n.root) {
            const c = r.creds(match.rule);
            if (sys.become(.{ .uid = c.uid, .gid = c.gid, .gids = c.gids }) != .SUCCESS) return .{ .failed = .serverfault };
        }
        return .{ .found = .{ .handle = h, .path = path, .attr = attr, .match = match } };
    }

    fn exportRoot(r: *Request, h: fh.Handle, attr: *sys.Attr, buf: *[sys.max_path + 1]u8) ?[:0]const u8 {
        return exportRootPath(r.n.files, r.table, r.ctx.io, h, attr, buf);
    }

    fn getattr(r: *Request) Error!void {
        const f = switch (try r.find(&r.path_buf)) {
            .found => |f| f,
            .failed => |s| return r.status(s),
        };
        try r.status(.ok);
        try r.fattrOut(f.attr);
    }

    fn lookup(r: *Request) Error!void {
        const dir = switch (try r.find(&r.path_buf)) {
            .found => |f| f,
            .failed => |s| {
                _ = try r.d.string(max_path);
                try r.status(s);
                return r.postOp(null);
            },
        };
        const name = try r.d.string(max_path);
        const fail = struct {
            fn f(req: *Request, s: Status, attr: sys.Attr) Error!void {
                try req.status(s);
                try req.postOp(attr);
            }
        }.f;
        if (ftype(dir.attr.mode) != .dir) return fail(r, .notdir, dir.attr);
        if (!r.creds(dir.match.rule).allows(dir.attr, 1)) return fail(r, .acces, dir.attr);
        if (name.len > max_name) return fail(r, .nametoolong, dir.attr);
        if (!validName(name) and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) return fail(r, .noent, dir.attr);

        var target_buf: [sys.max_path + 1]u8 = undefined;
        const target: [:0]const u8 = if (std.mem.eql(u8, name, "."))
            dir.path
        else if (std.mem.eql(u8, name, "..")) parent: {
            const parent = std.fs.path.dirname(dir.path) orelse "/";
            // `..` stops at the export's root.
            if (!exports.contains(dir.match.path, parent)) break :parent dir.path;
            break :parent copyZ(&target_buf, parent);
        } else join(&target_buf, dir.path, name) orelse return fail(r, .nametoolong, dir.attr);

        var attr: sys.Attr = undefined;
        const e = sys.lstat(target, &attr);
        if (e != .SUCCESS) return fail(r, .fromErrno(e), dir.attr);
        const h: fh.Handle = .fromAttr(exportId(dir.match.path), attr);
        try r.n.files.remember(r.ctx.io, h, target);
        try r.status(.ok);
        try r.e.opaque_(&h.encode());
        try r.postOp(attr);
        try r.postOp(dir.attr);
    }

    fn access(r: *Request) Error!void {
        const f = switch (try r.find(&r.path_buf)) {
            .found => |f| f,
            .failed => |s| {
                _ = try r.d.u32_();
                try r.status(s);
                return r.postOp(null);
            },
        };
        const wanted = try r.d.u32_();
        const c = r.creds(f.match.rule);
        // Owners may read and write their files whatever the mode, as READ
        // and WRITE allow.
        const owns_file = ftype(f.attr.mode) == .reg and c.uid == f.attr.uid;
        const can_read = owns_file or c.allows(f.attr, 4);
        const can_write = owns_file or c.allows(f.attr, 2);
        const can_exec = c.allows(f.attr, 1);
        var granted: u32 = 0;
        if (can_read) granted |= Access.read;
        if (ftype(f.attr.mode) == .dir) {
            if (can_exec) granted |= Access.lookup;
            if (can_write) granted |= Access.modify | Access.extend | Access.delete;
        } else {
            if (can_write) granted |= Access.modify | Access.extend;
            if (can_exec) granted |= Access.execute;
        }
        if (f.match.rule.options.read_only) granted &= ~(Access.modify | Access.extend | Access.delete);
        try r.status(.ok);
        try r.postOp(f.attr);
        try r.e.u32_(granted & wanted);
    }

    fn readlink(r: *Request) Error!void {
        const f = switch (try r.find(&r.path_buf)) {
            .found => |f| f,
            .failed => |s| {
                try r.status(s);
                return r.postOp(null);
            },
        };
        if (ftype(f.attr.mode) != .lnk) {
            try r.status(.inval);
            return r.postOp(f.attr);
        }
        var buf: [max_path]u8 = undefined;
        var target: []const u8 = undefined;
        const e = sys.readLink(f.path, &buf, &target);
        try r.status(.fromErrno(e));
        try r.postOp(f.attr);
        if (e == .SUCCESS) try r.e.string(target);
    }

    fn read(r: *Request) Error!void {
        const found = try r.find(&r.path_buf);
        const offset = try r.d.u64_();
        const count = try r.d.u32_();
        const f = switch (found) {
            .found => |f| f,
            .failed => |s| {
                try r.status(s);
                return r.postOp(null);
            },
        };
        const fail = switch (ftype(f.attr.mode)) {
            .reg => if (r.creds(f.match.rule).allows(f.attr, 4) or r.creds(f.match.rule).uid == f.attr.uid) null else Status.acces,
            .dir => Status.isdir,
            else => Status.inval,
        };
        if (fail) |s| {
            try r.status(s);
            return r.postOp(f.attr);
        }
        // Fit the reply: status, attributes, count, eof, and length take
        // under 128 bytes.
        const room = r.results.buffer.len - r.results.end;
        const want = @min(count, max_transfer, if (room > 128) room - 128 else 0);
        const data = try r.n.gpa.alloc(u8, want);
        defer r.n.gpa.free(data);
        var got: usize = 0;
        var fd: sys.Fd = undefined;
        var now: sys.Attr = undefined;
        var e = sys.openOwned(f.path, .{}, f.handle.inode, &fd, &now);
        if (e == .SUCCESS) {
            e = sys.readFd(fd, offset, data, &got);
            sys.closeFd(fd);
        }
        try r.status(.fromErrno(e));
        try r.postOp(if (e == .SUCCESS) now else f.attr);
        if (e != .SUCCESS) return;
        try r.e.u32_(@intCast(got));
        try r.e.boolean(offset +| got >= now.size);
        try r.e.opaque_(data[0..got]);
    }

    fn readdir(r: *Request, plus: bool) Error!void {
        const found = try r.find(&r.path_buf);
        const cookie = try r.d.u64_();
        const sent_verf = (try r.d.fixedOpaque(8))[0..8].*;
        const dircount = if (plus) try r.d.u32_() else std.math.maxInt(u32);
        const maxcount = try r.d.u32_();
        const dir = switch (found) {
            .found => |f| f,
            .failed => |s| {
                try r.status(s);
                return r.postOp(null);
            },
        };
        if (ftype(dir.attr.mode) != .dir) {
            try r.status(.notdir);
            return r.postOp(dir.attr);
        }
        if (!r.creds(dir.match.rule).allows(dir.attr, 4)) {
            try r.status(.acces);
            return r.postOp(dir.attr);
        }
        if (maxcount < 256) {
            try r.status(.toosmall);
            return r.postOp(dir.attr);
        }
        // Cookies count entries, so they hold only while the directory is
        // unchanged; after a change, the client starts over.
        var verf: [8]u8 = undefined;
        std.mem.writeInt(u32, verf[0..4], @truncate(@as(u64, @bitCast(dir.attr.mtime.sec))), .big);
        std.mem.writeInt(u32, verf[4..8], dir.attr.mtime.nsec, .big);
        if (cookie != 0 and !std.mem.eql(u8, &verf, &sent_verf)) {
            try r.status(.bad_cookie);
            return r.postOp(dir.attr);
        }
        var reader: sys.DirReader = undefined;
        var dir_fd: sys.Fd = undefined;
        var now: sys.Attr = undefined;
        var e = sys.openVerified(dir.path, .{ .DIRECTORY = true }, dir.handle.inode, &dir_fd, &now);
        if (e == .SUCCESS) e = sys.DirReader.fromFd(dir_fd, &reader);
        if (e != .SUCCESS) {
            try r.status(.fromErrno(e));
            return r.postOp(dir.attr);
        }
        defer reader.close();

        try r.status(.ok);
        try r.postOp(dir.attr);
        try r.e.fixedOpaque(&verf);

        // Budgets: the whole reply (`maxcount`), and for READDIRPLUS the
        // names and cookies alone (`dircount`). The 24 is the RPC header.
        const limit = @min(maxcount, r.results.buffer.len + 24) -| 24;
        const export_id = exportId(dir.match.path);
        var dir_used: usize = 0;
        // Entries' paths, stored together after the loop.
        var arena_state: std.heap.ArenaAllocator = .init(r.n.gpa);
        defer arena_state.deinit();
        var entries: std.ArrayList(@import("files.zig").Entry) = .empty;
        var index: u64 = 0;
        var eof = true;
        while (reader.next()) |entry| {
            index += 1;
            if (index <= cookie) continue;
            const name_size = 4 + entry.name.len + xdr.padding(entry.name.len);
            const base = 4 + 8 + name_size + 8;
            const plus_size: usize = 4 + 84 + 4 + 4 + fh.size;
            const size = base + if (plus) plus_size else 0;
            if (r.results.end + size + 8 > limit or dir_used + base > dircount) {
                eof = false;
                break;
            }
            dir_used += base;
            try r.e.boolean(true);
            try r.e.u64_(r.fileid(dir.attr.dev, entry.ino));
            try r.e.string(entry.name);
            try r.e.u64_(index);
            if (plus) {
                var attr: sys.Attr = undefined;
                var path_buf: [sys.max_path + 1]u8 = undefined;
                const dot = std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..");
                const path = if (dot) null else join(&path_buf, dir.path, entry.name);
                if (path != null and sys.lstat(path.?, &attr) == .SUCCESS) {
                    const h: fh.Handle = .fromAttr(export_id, attr);
                    try entries.append(arena_state.allocator(), .{
                        .fsid = h.fsid,
                        .inode = h.inode,
                        .path = try arena_state.allocator().dupe(u8, path.?),
                    });
                    try r.postOp(attr);
                    try r.e.boolean(true);
                    try r.e.opaque_(&h.encode());
                } else {
                    try r.e.boolean(false);
                    try r.e.boolean(false);
                }
            }
        }
        try r.e.boolean(false);
        try r.e.boolean(eof);
        try r.n.files.rememberAll(r.ctx.io, entries.items);
    }

    fn fsstat(r: *Request) Error!void {
        const f = switch (try r.find(&r.path_buf)) {
            .found => |f| f,
            .failed => |s| {
                try r.status(s);
                return r.postOp(null);
            },
        };
        var s: sys.FsStat = undefined;
        const e = sys.fsStat(f.path, &s);
        try r.status(.fromErrno(e));
        try r.postOp(f.attr);
        if (e != .SUCCESS) return;
        try r.e.u64_(s.blocks *| s.block_size);
        try r.e.u64_(s.blocks_free *| s.block_size);
        try r.e.u64_(s.blocks_avail *| s.block_size);
        try r.e.u64_(s.files);
        try r.e.u64_(s.files_free);
        try r.e.u64_(s.files_free);
        try r.e.u32_(0);
    }

    fn fsinfo(r: *Request) Error!void {
        const f = switch (try r.find(&r.path_buf)) {
            .found => |f| f,
            .failed => |s| {
                try r.status(s);
                return r.postOp(null);
            },
        };
        try r.status(.ok);
        try r.postOp(f.attr);
        try r.e.u32_(max_transfer); // rtmax
        try r.e.u32_(max_transfer); // rtpref
        try r.e.u32_(4096); // rtmult
        try r.e.u32_(max_transfer); // wtmax
        try r.e.u32_(max_transfer); // wtpref
        try r.e.u32_(4096); // wtmult
        try r.e.u32_(64 * 1024); // dtpref
        try r.e.u64_(std.math.maxInt(i64)); // maxfilesize
        try r.e.u32_(0); // time_delta: 1 ns
        try r.e.u32_(1);
        // FSF3_LINK, FSF3_SYMLINK, FSF3_HOMOGENEOUS, FSF3_CANSETTIME
        try r.e.u32_(0x0001 | 0x0002 | 0x0008 | 0x0010);
    }

    fn pathconf(r: *Request) Error!void {
        const f = switch (try r.find(&r.path_buf)) {
            .found => |f| f,
            .failed => |s| {
                try r.status(s);
                return r.postOp(null);
            },
        };
        try r.status(.ok);
        try r.postOp(f.attr);
        try r.e.u32_(32767); // linkmax
        try r.e.u32_(max_name);
        try r.e.boolean(true); // no_trunc
        try r.e.boolean(true); // chown_restricted
        try r.e.boolean(!sys.caseSensitive(f.path)); // case_insensitive
        try r.e.boolean(true); // case_preserving
    }

    // Writes. Each acts through descriptors opened without following links
    // and checked against the handle, never through a path alone.

    fn setattr(r: *Request) Error!void {
        const found = try r.find(&r.path_buf);
        const s = try decodeSattr(&r.d);
        const guard: ?sys.Timespec = if (try r.d.boolean()) try decodeTime(&r.d) else null;
        const f = switch (found) {
            .found => |f| f,
            .failed => |st| {
                try r.status(st);
                return r.emptyWcc();
            },
        };
        var mapped = s;
        r.inward(&mapped);
        const st = r.applySattr(f, mapped, guard);
        var post: sys.Attr = undefined;
        const have_post = sys.lstat(f.path, &post) == .SUCCESS;
        try r.status(st);
        try r.wccData(f.attr, if (have_post) post else null);
    }

    /// Checks and applies `s` to `f`'s file.
    fn applySattr(r: *Request, f: Found, s: Sattr, guard: ?sys.Timespec) Status {
        if (f.match.rule.options.read_only) return .rofs;
        if (guard) |g| if (g.sec != f.attr.ctime.sec or g.nsec != f.attr.ctime.nsec) return .not_sync;
        const c = r.creds(f.match.rule);
        const owner = c.uid == 0 or c.uid == f.attr.uid;
        if ((s.mode != null or s.uid != null or s.gid != null) and !owner) return .perm;
        if (s.uid) |uid| if (uid != f.attr.uid and c.uid != 0) return .perm;
        if (s.gid) |gid| if (gid != f.attr.gid and c.uid != 0 and gid != c.gid and std.mem.indexOfScalar(u32, c.gids, gid) == null) return .perm;
        if (s.size != null) {
            switch (ftype(f.attr.mode)) {
                .reg => {},
                .dir => return .isdir,
                else => return .inval,
            }
            if (!owner and !c.allows(f.attr, 2)) return .acces;
        }
        if (s.atime == .at or s.mtime == .at) {
            if (!owner) return .perm;
        } else if (s.atime == .now or s.mtime == .now) {
            if (!owner and !c.allows(f.attr, 2)) return .acces;
        }

        const kind = ftype(f.attr.mode);
        // Only truncation needs the file open; the rest goes through its
        // directory, which works whatever the file's own mode.
        if (s.size) |size| {
            var fd: sys.Fd = undefined;
            var now: sys.Attr = undefined;
            var e = sys.openOwned(f.path, .{ .ACCMODE = .WRONLY }, f.handle.inode, &fd, &now);
            if (e != .SUCCESS) return .fromErrno(e);
            defer sys.closeFd(fd);
            e = sys.truncateFd(fd, size);
            if (e == .SUCCESS) e = sys.sync(fd);
            if (e != .SUCCESS) return .fromErrno(e);
        }
        if (s.mode == null and s.uid == null and s.gid == null and s.atime == .omit and s.mtime == .omit) return .ok;
        var parent: Parent = undefined;
        const pe = Request.openParent(f, &parent);
        if (pe != .ok) return pe;
        defer sys.closeFd(parent.fd);
        if (s.mode) |mode| if (kind != .lnk) {
            const e = sys.chmodIn(parent.fd, parent.name, mode & 0o7777);
            if (e != .SUCCESS) return .fromErrno(e);
        };
        if (s.uid != null or s.gid != null) {
            const e = sys.chownIn(parent.fd, parent.name, s.uid, s.gid);
            if (e != .SUCCESS) return .fromErrno(e);
        }
        if (s.atime != .omit or s.mtime != .omit) {
            const e = sys.setTimesIn(parent.fd, parent.name, s.atime, s.mtime);
            if (e != .SUCCESS) return .fromErrno(e);
        }
        return .ok;
    }

    const Parent = struct {
        fd: sys.Fd,
        name: [:0]const u8,
        name_buf: [max_name + 1]u8,
    };

    /// Opens the directory holding `f` and checks the entry is still `f`.
    fn openParent(f: Found, p: *Parent) Status {
        const dir = std.fs.path.dirname(f.path) orelse return .inval;
        const base = std.fs.path.basename(f.path);
        if (base.len > max_name) return .nametoolong;
        @memcpy(p.name_buf[0..base.len], base);
        p.name_buf[base.len] = 0;
        p.name = p.name_buf[0..base.len :0];
        var dir_buf: [sys.max_path + 1]u8 = undefined;
        var e = sys.openSafe(copyZ(&dir_buf, dir), .{ .DIRECTORY = true }, 0, &p.fd);
        if (e != .SUCCESS) return .stale;
        var attr: sys.Attr = undefined;
        e = sys.statIn(p.fd, p.name, &attr);
        if (e != .SUCCESS or attr.ino != f.handle.inode) {
            sys.closeFd(p.fd);
            return .stale;
        }
        return .ok;
    }

    fn write(r: *Request) Error!void {
        const found = try r.find(&r.path_buf);
        const offset = try r.d.u64_();
        const count = try r.d.u32_();
        // stable_how: UNSTABLE waits for COMMIT; the others are FILE_SYNC.
        const unstable = try r.d.u32_() == 0;
        const data = try r.d.opaque_(max_transfer);
        const f = switch (found) {
            .found => |f| f,
            .failed => |st| {
                try r.status(st);
                return r.emptyWcc();
            },
        };
        const c = r.creds(f.match.rule);
        const fail: ?Status = if (f.match.rule.options.read_only)
            .rofs
        else switch (ftype(f.attr.mode)) {
            // Owners may write files they made read-only, as local programs can
            // through a descriptor opened before the change.
            .reg => if (c.allows(f.attr, 2) or c.uid == f.attr.uid) null else .acces,
            .dir => .isdir,
            else => .inval,
        };
        if (fail) |st| {
            try r.status(st);
            return r.wccData(f.attr, f.attr);
        }
        const n = @min(count, data.len);
        var fd: sys.Fd = undefined;
        var post: sys.Attr = undefined;
        var e = sys.openOwned(f.path, .{ .ACCMODE = .WRONLY }, f.handle.inode, &fd, &post);
        if (e == .SUCCESS) {
            e = sys.writeAt(fd, offset, data[0..n]);
            if (e == .SUCCESS and !unstable) e = sys.sync(fd);
            _ = sys.fstat(fd, &post);
            sys.closeFd(fd);
        }
        try r.status(.fromErrno(e));
        try r.wccData(f.attr, if (e == .SUCCESS) post else null);
        if (e != .SUCCESS) return;
        try r.e.u32_(@intCast(n));
        try r.e.u32_(if (unstable) 0 else 2); // UNSTABLE or FILE_SYNC
        try r.e.fixedOpaque(&r.n.verifier);
    }

    fn commit(r: *Request) Error!void {
        const found = try r.find(&r.path_buf);
        _ = try r.d.u64_();
        _ = try r.d.u32_();
        const f = switch (found) {
            .found => |f| f,
            .failed => |st| {
                try r.status(st);
                return r.emptyWcc();
            },
        };
        // The whole file, whatever the range: fsync has no finer grain.
        // Writers may lack read permission, so open for writing first.
        var e: sys.E = .SUCCESS;
        if (ftype(f.attr.mode) == .reg) {
            var fd: sys.Fd = undefined;
            var post: sys.Attr = undefined;
            e = sys.openOwned(f.path, .{ .ACCMODE = .WRONLY }, f.handle.inode, &fd, &post);
            if (e == .ACCES) e = sys.openOwned(f.path, .{}, f.handle.inode, &fd, &post);
            if (e == .SUCCESS) {
                e = sys.sync(fd);
                sys.closeFd(fd);
            }
        }
        try r.status(.fromErrno(e));
        try r.wccData(f.attr, f.attr);
        if (e != .SUCCESS) return;
        try r.e.fixedOpaque(&r.n.verifier);
    }

    /// The directory and new name of a CREATE, MKDIR, SYMLINK, MKNOD,
    /// REMOVE, RMDIR, RENAME, or LINK, opened and checked for changes.
    const Where = struct {
        dir: Found,
        fd: sys.Fd,
        name: [:0]const u8,
        name_buf: [max_name + 1]u8,
        path_buf: [sys.max_path + 1]u8,

        fn close(w: *Where) void {
            sys.closeFd(w.fd);
        }

        /// The directory's attributes now, for wcc data.
        fn post(w: *const Where) ?sys.Attr {
            var a: sys.Attr = undefined;
            return if (sys.fstat(w.fd, &a) == .SUCCESS) a else null;
        }

        fn path(w: *const Where, buf: *[sys.max_path + 1]u8) ?[:0]const u8 {
            return join(buf, w.dir.path, w.name);
        }
    };

    const WhereResult = union(enum) {
        ok: Where,
        /// The status, with the directory's attributes if it was found.
        failed: struct { status: Status, attr: ?sys.Attr },
    };

    /// Decodes diropargs3 and opens its directory for changing an entry.
    fn where(r: *Request, w: *Where) Error!WhereResult {
        const found = try r.find(&w.path_buf);
        const name = try r.d.string(max_path);
        const dir = switch (found) {
            .found => |f| f,
            .failed => |st| return .{ .failed = .{ .status = st, .attr = null } },
        };
        const fail = struct {
            fn f(st: Status, a: sys.Attr) WhereResult {
                return .{ .failed = .{ .status = st, .attr = a } };
            }
        }.f;
        if (ftype(dir.attr.mode) != .dir) return fail(.notdir, dir.attr);
        if (dir.match.rule.options.read_only) return fail(.rofs, dir.attr);
        if (!r.creds(dir.match.rule).allows(dir.attr, 3)) return fail(.acces, dir.attr);
        if (name.len > max_name) return fail(.nametoolong, dir.attr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return fail(.exist, dir.attr);
        if (!validName(name)) return fail(.inval, dir.attr);
        var now: sys.Attr = undefined;
        const e = sys.openVerified(dir.path, .{ .DIRECTORY = true }, dir.handle.inode, &w.fd, &now);
        if (e != .SUCCESS) return fail(.fromErrno(e), dir.attr);
        @memcpy(w.name_buf[0..name.len], name);
        w.name_buf[name.len] = 0;
        w.name = w.name_buf[0..name.len :0];
        w.dir = dir;
        return .{ .ok = w.* };
    }

    /// Sets any mode asked for exactly, without the umask, and any owner
    /// asked for. Acting as the caller, a new entry is already theirs; on
    /// macOS, whose new entries take their directory's group, the caller's
    /// group is set too, where the host allows it.
    fn settle(r: *Request, w: *const Where, s: Sattr, kind: Ftype) sys.E {
        if (s.mode) |mode| if (kind != .lnk) {
            const e = sys.chmodIn(w.fd, w.name, mode & 0o7777);
            if (e != .SUCCESS) return e;
        };
        if (s.uid != null or s.gid != null) return sys.chownIn(w.fd, w.name, s.uid, s.gid);
        if (r.n.root and builtin.os.tag.isDarwin()) {
            _ = sys.chownIn(w.fd, w.name, null, r.creds(w.dir.match.rule).gid);
        }
        return .SUCCESS;
    }

    /// Replies to a successful CREATE, MKDIR, SYMLINK, or MKNOD.
    fn created(r: *Request, w: *const Where) Error!void {
        var attr: sys.Attr = undefined;
        var buf: [sys.max_path + 1]u8 = undefined;
        const have = sys.statIn(w.fd, w.name, &attr) == .SUCCESS;
        try r.status(.ok);
        if (have) {
            const h: fh.Handle = .fromAttr(exportId(w.dir.match.path), attr);
            if (w.path(&buf)) |p| try r.n.files.remember(r.ctx.io, h, p);
            try r.e.boolean(true);
            try r.e.opaque_(&h.encode());
            try r.postOp(attr);
        } else {
            try r.e.boolean(false);
            try r.postOp(null);
        }
        try r.wccData(w.dir.attr, w.post());
    }

    fn whereFailed(r: *Request, failed: anytype) Error!void {
        try r.status(failed.status);
        try r.wccData(failed.attr, failed.attr);
    }

    fn create(r: *Request) Error!void {
        var w: Where = undefined;
        const result = try r.where(&w);
        const how = try r.d.u32_();
        var s: Sattr = .{};
        var verf: [8]u8 = undefined;
        switch (how) {
            0, 1 => s = try decodeSattr(&r.d),
            2 => verf = (try r.d.fixedOpaque(8))[0..8].*,
            else => return error.Invalid,
        }
        switch (result) {
            .failed => |failed| return r.whereFailed(failed),
            .ok => {},
        }
        defer w.close();
        r.inward(&s);

        // EXCLUSIVE keeps its verifier in the file's times, so a retransmitted
        // CREATE finds its own file and succeeds.
        const verf_atime: sys.Timespec = .{ .sec = std.mem.readInt(u32, verf[0..4], .big), .nsec = 0 };
        const verf_mtime: sys.Timespec = .{ .sec = std.mem.readInt(u32, verf[4..8], .big), .nsec = 0 };
        var fd: sys.Fd = undefined;
        var e = sys.createIn(w.fd, w.name, how != 0, s.mode orelse 0o600, &fd);
        if (e == .EXIST and how == 2) {
            var existing: sys.Attr = undefined;
            if (sys.statIn(w.fd, w.name, &existing) == .SUCCESS and
                existing.atime.sec == verf_atime.sec and existing.mtime.sec == verf_mtime.sec)
            {
                return r.created(&w);
            }
        }
        if (e != .SUCCESS) {
            try r.status(.fromErrno(e));
            return r.wccData(w.dir.attr, w.post());
        }
        defer sys.closeFd(fd);
        if (how == 2) {
            e = sys.setTimesFd(fd, .{ .at = verf_atime }, .{ .at = verf_mtime });
        } else if (s.size) |size| {
            e = sys.truncateFd(fd, size);
        }
        if (e == .SUCCESS) e = r.settle(&w, s, .reg);
        if (e == .SUCCESS and how != 2 and (s.atime != .omit or s.mtime != .omit)) e = sys.setTimesFd(fd, s.atime, s.mtime);
        if (e != .SUCCESS) {
            try r.status(.fromErrno(e));
            return r.wccData(w.dir.attr, w.post());
        }
        return r.created(&w);
    }

    /// MKDIR, SYMLINK, and MKNOD (whose kind is in its arguments).
    fn make(r: *Request, kind: Ftype) Error!void {
        var w: Where = undefined;
        const result = try r.where(&w);
        var s: Sattr = .{};
        var target_buf: [sys.max_path + 1]u8 = undefined;
        var target: [:0]const u8 = "";
        var node: struct { kind: Ftype = .fifo, major: u32 = 0, minor: u32 = 0 } = .{};
        var bad_type = false;
        switch (kind) {
            .dir => s = try decodeSattr(&r.d),
            .lnk => {
                s = try decodeSattr(&r.d);
                const t = try r.d.string(max_path);
                target = copyZ(&target_buf, t);
            },
            else => {
                const raw = try r.d.u32_();
                switch (raw) {
                    @backingInt(Ftype.chr), @backingInt(Ftype.blk) => {
                        node.kind = @fromBackingInt(@intCast(raw));
                        s = try decodeSattr(&r.d);
                        node.major = try r.d.u32_();
                        node.minor = try r.d.u32_();
                    },
                    @backingInt(Ftype.sock), @backingInt(Ftype.fifo) => {
                        node.kind = @fromBackingInt(@intCast(raw));
                        s = try decodeSattr(&r.d);
                    },
                    else => bad_type = true,
                }
            },
        }
        switch (result) {
            .failed => |failed| return r.whereFailed(failed),
            .ok => {},
        }
        defer w.close();
        r.inward(&s);
        if (bad_type) {
            try r.status(.badtype);
            return r.wccData(w.dir.attr, w.post());
        }
        var e: sys.E = switch (kind) {
            .dir => sys.mkdirIn(w.fd, w.name, s.mode orelse 0o755),
            .lnk => sys.symlinkIn(target, w.fd, w.name),
            else => sys.mknodIn(w.fd, w.name, @as(u32, switch (node.kind) {
                .chr => posix.S.IFCHR,
                .blk => posix.S.IFBLK,
                .sock => posix.S.IFSOCK,
                else => posix.S.IFIFO,
            }) | ((s.mode orelse 0o644) & 0o7777), sys.makeDev(node.major, node.minor)),
        };
        if (e == .SUCCESS) e = r.settle(&w, s, if (kind == .lnk) .lnk else kind);
        if (e != .SUCCESS) {
            try r.status(.fromErrno(e));
            return r.wccData(w.dir.attr, w.post());
        }
        return r.created(&w);
    }

    /// Whether a sticky directory stops `c` removing or renaming `target`.
    fn sticky(dir: sys.Attr, target: sys.Attr, c: Creds) bool {
        return dir.mode & posix.S.ISVTX != 0 and c.uid != 0 and c.uid != dir.uid and c.uid != target.uid;
    }

    fn remove(r: *Request, directory: bool) Error!void {
        var w: Where = undefined;
        const result = try r.where(&w);
        switch (result) {
            .failed => |failed| {
                // RMDIR of `.` is invalid, not an existing entry.
                if (directory and failed.status == .exist) return r.whereFailed(.{ .status = Status.inval, .attr = failed.attr });
                return r.whereFailed(failed);
            },
            .ok => {},
        }
        defer w.close();
        var target: sys.Attr = undefined;
        var e = sys.statIn(w.fd, w.name, &target);
        const st: Status = if (e != .SUCCESS)
            .fromErrno(e)
        else if (directory and ftype(target.mode) != .dir)
            .notdir
        else if (!directory and ftype(target.mode) == .dir)
            .isdir
        else if (sticky(w.dir.attr, target, r.creds(w.dir.match.rule)))
            .acces
        else st: {
            e = sys.unlinkIn(w.fd, w.name, directory);
            break :st .fromErrno(e);
        };
        try r.status(st);
        try r.wccData(w.dir.attr, w.post());
    }

    fn rename(r: *Request) Error!void {
        var from: Where = undefined;
        const from_result = try r.where(&from);
        var to: Where = undefined;
        const to_result = try r.where(&to);
        if (from_result == .failed or to_result == .failed) {
            if (from_result == .ok) from.close();
            if (to_result == .ok) to.close();
            const st = if (from_result == .failed) from_result.failed.status else to_result.failed.status;
            try r.status(st);
            const fa = if (from_result == .failed) from_result.failed.attr else from.dir.attr;
            const ta = if (to_result == .failed) to_result.failed.attr else to.dir.attr;
            try r.wccData(fa, fa);
            return r.wccData(ta, ta);
        }
        defer from.close();
        defer to.close();

        const c = r.creds(from.dir.match.rule);
        var source: sys.Attr = undefined;
        var existing: sys.Attr = undefined;
        var e = sys.statIn(from.fd, from.name, &source);
        const st: Status = if (!std.mem.eql(u8, from.dir.match.path, to.dir.match.path))
            .xdev
        else if (e != .SUCCESS)
            .fromErrno(e)
        else if (sticky(from.dir.attr, source, c) or
            (sys.statIn(to.fd, to.name, &existing) == .SUCCESS and sticky(to.dir.attr, existing, c)))
            .acces
        else st: {
            e = sys.renameIn(from.fd, from.name, to.fd, to.name);
            break :st .fromErrno(e);
        };
        if (st == .ok) {
            var old_buf: [sys.max_path + 1]u8 = undefined;
            var new_buf: [sys.max_path + 1]u8 = undefined;
            if (from.path(&old_buf)) |old| if (to.path(&new_buf)) |new| {
                try r.n.files.remember(r.ctx.io, .fromAttr(exportId(to.dir.match.path), source), new);
                if (ftype(source.mode) == .dir) try r.n.files.renamePrefix(r.ctx.io, old, new);
            };
        }
        try r.status(st);
        try r.wccData(from.dir.attr, from.post());
        try r.wccData(to.dir.attr, to.post());
    }

    fn link(r: *Request) Error!void {
        const found = try r.find(&r.path_buf);
        var w: Where = undefined;
        const result = try r.where(&w);
        const f = switch (found) {
            .found => |f| f,
            .failed => |st| {
                if (result == .ok) w.close();
                try r.status(st);
                try r.postOp(null);
                return r.wccData(null, null);
            },
        };
        switch (result) {
            .failed => |failed| {
                try r.status(failed.status);
                try r.postOp(f.attr);
                return r.wccData(failed.attr, failed.attr);
            },
            .ok => {},
        }
        defer w.close();
        var st: Status = if (!std.mem.eql(u8, f.match.path, w.dir.match.path))
            .xdev
        else if (ftype(f.attr.mode) == .dir)
            .isdir
        else
            .ok;
        if (st == .ok) {
            var parent: Parent = undefined;
            st = Request.openParent(f, &parent);
            if (st == .ok) {
                st = .fromErrno(sys.linkIn(parent.fd, parent.name, w.fd, w.name));
                sys.closeFd(parent.fd);
            }
        }
        var post: sys.Attr = undefined;
        const have = sys.statIn(w.fd, w.name, &post) == .SUCCESS and post.ino == f.handle.inode;
        try r.status(st);
        try r.postOp(if (have) post else f.attr);
        try r.wccData(w.dir.attr, w.post());
    }
};

/// sattr3: which attributes to set.
const Sattr = struct {
    mode: ?u32 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    size: ?u64 = null,
    atime: sys.SetTime = .omit,
    mtime: sys.SetTime = .omit,
};

fn decodeSattr(d: *xdr.Decoder) xdr.DecodeError!Sattr {
    var s: Sattr = .{};
    if (try d.boolean()) s.mode = try d.u32_();
    if (try d.boolean()) s.uid = try d.u32_();
    if (try d.boolean()) s.gid = try d.u32_();
    if (try d.boolean()) s.size = try d.u64_();
    s.atime = try decodeSetTime(d);
    s.mtime = try decodeSetTime(d);
    return s;
}

fn decodeSetTime(d: *xdr.Decoder) xdr.DecodeError!sys.SetTime {
    return switch (try d.u32_()) {
        0 => .omit, // DONT_CHANGE
        1 => .now, // SET_TO_SERVER_TIME
        2 => .{ .at = try decodeTime(d) }, // SET_TO_CLIENT_TIME
        else => error.Invalid,
    };
}

fn decodeTime(d: *xdr.Decoder) xdr.DecodeError!sys.Timespec {
    return .{ .sec = try d.u32_(), .nsec = try d.u32_() };
}

/// Attributes ready for a reply, made only by `Request.outward`, so none
/// goes out with host owners or fileids.
const Outward = struct { attr: sys.Attr };

/// wcc_data: attributes before (size and times) and after a change.
fn wcc(e: xdr.Encoder, pre: ?sys.Attr, post: ?Outward) Error!void {
    try e.boolean(pre != null);
    if (pre) |a| {
        try e.u64_(a.size);
        try time(e, a.mtime);
        try time(e, a.ctime);
    }
    try postOpAttr(e, post);
}

/// The device of an export's root, as the server sees it.
fn rootDev(path: []const u8) ?u64 {
    var buf: [sys.max_path + 1]u8 = undefined;
    var attr: sys.Attr = undefined;
    if (path.len > sys.max_path or sys.lstat(copyZ(&buf, path), &attr) != .SUCCESS) return null;
    return attr.dev;
}

/// The path of the export whose root `h` is, so root handles always
/// resolve, even before any lookup and across restarts.
fn exportRootPath(files: *Files, table: *const exports.Table, io: Io, h: fh.Handle, attr: *sys.Attr, buf: *[sys.max_path + 1]u8) ?[:0]const u8 {
    for (table.rules) |rule| {
        if (exportId(rule.path) != h.export_id or rule.path.len > sys.max_path) continue;
        const path = copyZ(buf, rule.path);
        if (sys.lstat(path, attr) != .SUCCESS) continue;
        if (!h.eql(fh.Handle.fromAttr(h.export_id, attr.*))) continue;
        files.remember(io, h, path) catch {};
        return path;
    }
    return null;
}

/// Whether `name` is an ordinary directory entry name.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn join(buf: *[sys.max_path + 1]u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    const sep: []const u8 = if (std.mem.endsWith(u8, dir, "/")) "" else "/";
    const len = dir.len + sep.len + name.len;
    if (len > sys.max_path) return null;
    @memcpy(buf[0..dir.len], dir);
    @memcpy(buf[dir.len..][0..sep.len], sep);
    @memcpy(buf[dir.len + sep.len ..][0..name.len], name);
    buf[len] = 0;
    return buf[0..len :0];
}

fn copyZ(buf: *[sys.max_path + 1]u8, s: []const u8) [:0]const u8 {
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn time(e: xdr.Encoder, t: sys.Timespec) Error!void {
    try e.u32_(@truncate(@as(u64, @bitCast(t.sec))));
    try e.u32_(t.nsec);
}

/// fattr3: 84 bytes.
fn fattr(e: xdr.Encoder, out: Outward) Error!void {
    const a = out.attr;
    try e.enumeration(ftype(a.mode));
    try e.u32_(a.mode & 0o7777);
    try e.u32_(a.nlink);
    try e.u32_(a.uid);
    try e.u32_(a.gid);
    try e.u64_(a.size);
    try e.u64_(a.blocks * 512);
    const major, const minor = devParts(a.rdev);
    try e.u32_(major);
    try e.u32_(minor);
    try e.u64_(a.dev);
    try e.u64_(a.ino);
    try time(e, a.atime);
    try time(e, a.mtime);
    try time(e, a.ctime);
}

fn devParts(rdev: u64) struct { u32, u32 } {
    if (@import("builtin").os.tag.isDarwin()) return .{ @intCast(rdev >> 24 & 0xff), @intCast(rdev & 0xffffff) };
    return .{ @truncate(rdev >> 32), @truncate(rdev) };
}

fn postOpAttr(e: xdr.Encoder, attr: ?Outward) Error!void {
    try e.boolean(attr != null);
    if (attr) |a| try fattr(e, a);
}

const testing = std.testing;
const mount = @import("mount.zig");
const net = Io.net;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    rules: [1]exports.Rule,
    table: exports.Table,
    files: Files,
    nfs: Nfs,
    mount: mount.Mount,
    out: [70000]u8 = undefined,
    from: net.IpAddress,
    /// The client's UID and GID; by default, those running the tests.
    uid: u32 = 0,
    gid: u32 = 0,

    fn init(f: *Fixture) !void {
        const io = testing.io;
        f.tmp = testing.tmpDir(.{});
        try f.tmp.dir.createDirPath(io, "share/dir");
        try f.tmp.dir.writeFile(io, .{ .sub_path = "share/hal", .data = "I'm sorry, Dave." });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "share/dir/art", .data = "" });
        try f.tmp.dir.symLink(io, "hal", "share/link", .{});
        var buf: [sys.max_path]u8 = undefined;
        const n = try f.tmp.dir.realPath(io, &buf);
        f.root = try std.fmt.allocPrint(testing.allocator, "{s}/share", .{buf[0..n]});
        // Root's calls aren't squashed, so they reach the test directory.
        f.rules = .{.{ .path = f.root, .client = .any, .options = .{ .squash = if (sys.isRoot()) .none else .root } }};
        f.table = .{ .rules = &f.rules };
        f.files = .init(testing.allocator);
        f.nfs = .init(testing.allocator, &f.table, &f.files, "znfsd-t\x00".*);
        f.mount = .init(testing.allocator, &f.table);
        f.from = try .parse("10.1.2.3", 800);
        f.uid = std.c.getuid();
        f.gid = std.c.getgid();
    }

    fn deinit(f: *Fixture) void {
        f.mount.deinit();
        f.files.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// Calls a program with AUTH_SYS as the user running the tests, and
    /// returns the results.
    fn call(f: *Fixture, p: server.Program, proc: u32, args: []const u8) ![]const u8 {
        var cred_buf: [64]u8 = undefined;
        var cw: Io.Writer = .fixed(&cred_buf);
        const auth: rpc.AuthSys = .{ .stamp = 0, .machine_name = "perihelion", .uid = f.uid, .gid = f.gid };
        try auth.encode(.init(&cw));
        var buf: [2048]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        const c: rpc.Call = .{
            .xid = 1,
            .prog = p.prog,
            .vers = 3,
            .proc = proc,
            .cred = .{ .flavor = .sys, .body = cw.buffered() },
            .verf = .none,
            .args = args,
        };
        try c.encode(.init(&w));
        const programs = [_]server.Program{p};
        const ctx: server.Context = .{ .io = testing.io, .from = f.from, .protocol = .tcp };
        const reply = server.dispatch(&programs, ctx, w.buffered(), &f.out).?;
        try testing.expectEqual(0, std.mem.readInt(u32, reply[20..24], .big));
        return reply[24..];
    }

    fn rootHandle(f: *Fixture) ![fh.size]u8 {
        var args: [sys.max_path + 8]u8 = undefined;
        var w: Io.Writer = .fixed(&args);
        try xdr.Encoder.init(&w).string(f.root);
        var d: xdr.Decoder = .init(try f.call(f.mount.program(), 1, w.buffered()));
        try testing.expectEqual(0, try d.u32_());
        return (try d.opaque_(64))[0..fh.size].*;
    }

    fn lookup(f: *Fixture, dir: [fh.size]u8, name: []const u8) !union(enum) { ok: [fh.size]u8, err: Status } {
        var args: [128]u8 = undefined;
        var w: Io.Writer = .fixed(&args);
        const e: xdr.Encoder = .init(&w);
        try e.opaque_(&dir);
        try e.string(name);
        var d: xdr.Decoder = .init(try f.call(f.nfs.program(), @backingInt(Proc.lookup), w.buffered()));
        const s = try d.enumeration(Status);
        if (s != .ok) return .{ .err = s };
        return .{ .ok = (try d.opaque_(64))[0..fh.size].* };
    }
};

fn handleArgs(buf: []u8, h: [fh.size]u8, extra: []const u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    xdr.Encoder.init(&w).opaque_(&h) catch unreachable;
    w.writeAll(extra) catch unreachable;
    return w.buffered();
}

test "look up, get attributes, read, and read links" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const root = try f.rootHandle();

    const hal = (try f.lookup(root, "hal")).ok;
    try testing.expectEqual(Status.noent, (try f.lookup(root, "skynet")).err);
    try testing.expectEqual(Status.noent, (try f.lookup(root, "dir/art")).err);
    // `..` at the export's root stays there.
    try testing.expectEqualSlices(u8, &root, &(try f.lookup(root, "..")).ok);
    const dir = (try f.lookup(root, "dir")).ok;
    try testing.expectEqualSlices(u8, &root, &(try f.lookup(dir, "..")).ok);

    var args: [128]u8 = undefined;
    var d: xdr.Decoder = .init(try f.call(f.nfs.program(), @backingInt(Proc.getattr), handleArgs(&args, hal, "")));
    try testing.expectEqual(Status.ok, try d.enumeration(Status));
    try testing.expectEqual(Ftype.reg, try d.enumeration(Ftype));
    _ = try d.fixedOpaque(16);
    try testing.expectEqual(16, try d.u64_());

    // READ at offset 4, count 100: "sorry, Dave." and eof.
    const read_args = "\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x64";
    d = .init(try f.call(f.nfs.program(), @backingInt(Proc.read), handleArgs(&args, hal, read_args)));
    try testing.expectEqual(Status.ok, try d.enumeration(Status));
    try testing.expect(try d.boolean());
    _ = try d.fixedOpaque(84);
    try testing.expectEqual(12, try d.u32_());
    try testing.expect(try d.boolean());
    try testing.expectEqualStrings("sorry, Dave.", try d.opaque_(100));

    d = .init(try f.call(f.nfs.program(), @backingInt(Proc.read), handleArgs(&args, dir, read_args)));
    try testing.expectEqual(Status.isdir, try d.enumeration(Status));

    const link = (try f.lookup(root, "link")).ok;
    d = .init(try f.call(f.nfs.program(), @backingInt(Proc.readlink), handleArgs(&args, link, "")));
    try testing.expectEqual(Status.ok, try d.enumeration(Status));
    _ = try d.fixedOpaque(4 + 84);
    try testing.expectEqualStrings("hal", try d.string(max_path));

    // Garbage handles are bad; well-formed ones nobody handed out are stale.
    var bogus = hal;
    bogus[0] = 9;
    d = .init(try f.call(f.nfs.program(), @backingInt(Proc.getattr), handleArgs(&args, bogus, "")));
    try testing.expectEqual(Status.badhandle, try d.enumeration(Status));
    bogus = hal;
    bogus[31] ^= 0xff;
    d = .init(try f.call(f.nfs.program(), @backingInt(Proc.getattr), handleArgs(&args, bogus, "")));
    try testing.expectEqual(Status.stale, try d.enumeration(Status));
}

test "read directories, plain and plus, across several calls" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const root = try f.rootHandle();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    var cookie: u64 = 0;
    var verf: [8]u8 = @splat(0);
    var calls: usize = 0;
    while (true) : (calls += 1) {
        // READDIRPLUS with a small budget, forcing several calls.
        var extra: [28]u8 = undefined;
        std.mem.writeInt(u64, extra[0..8], cookie, .big);
        extra[8..16].* = verf;
        std.mem.writeInt(u32, extra[16..20], 4096, .big); // dircount
        std.mem.writeInt(u32, extra[20..24], 400, .big); // maxcount
        var args: [128]u8 = undefined;
        var d: xdr.Decoder = .init(try f.call(f.nfs.program(), @backingInt(Proc.readdirplus), handleArgs(&args, root, extra[0..24])));
        try testing.expectEqual(Status.ok, try d.enumeration(Status));
        _ = try d.boolean();
        _ = try d.fixedOpaque(84);
        verf = (try d.fixedOpaque(8))[0..8].*;
        while (try d.boolean()) {
            _ = try d.u64_();
            try names.append(testing.allocator, try testing.allocator.dupe(u8, try d.string(max_name)));
            cookie = try d.u64_();
            if (try d.boolean()) _ = try d.fixedOpaque(84);
            if (try d.boolean()) _ = try d.opaque_(64);
        }
        if (try d.boolean()) break;
    }
    try testing.expect(calls > 0);
    for ([_][]const u8{ ".", "..", "hal", "dir", "link" }) |want| {
        for (names.items) |n| {
            if (std.mem.eql(u8, n, want)) break;
        } else return error.Missing;
    }
    try testing.expectEqual(5, names.items.len);
    // Entries found by READDIRPLUS resolve without a LOOKUP.
    try testing.expect((try f.lookup(root, "dir")) == .ok);
}

test "a continued READDIR with a stale verifier is a bad cookie" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const root = try f.rootHandle();
    var extra: [16]u8 = undefined;
    std.mem.writeInt(u64, extra[0..8], 2, .big);
    @memset(extra[8..16], 0xff);
    var tail: [8]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], 4096, .big);
    std.mem.writeInt(u32, tail[4..8], 4096, .big);
    var args: [128]u8 = undefined;
    var d: xdr.Decoder = .init(try f.call(f.nfs.program(), @backingInt(Proc.readdir), handleArgs(&args, root, &(extra ++ tail[4..8].*))));
    try testing.expectEqual(Status.bad_cookie, try d.enumeration(Status));
}

/// Builds arguments: a handle, then XDR items.
const Args = struct {
    buf: [4096]u8 = undefined,
    w: Io.Writer = undefined,

    fn start(a: *Args, h: [fh.size]u8) xdr.Encoder {
        a.w = .fixed(&a.buf);
        const e: xdr.Encoder = .init(&a.w);
        e.opaque_(&h) catch unreachable;
        return e;
    }

    fn bytes(a: *Args) []const u8 {
        return a.w.buffered();
    }
};

/// sattr3 setting only the mode, or nothing.
fn sattrMode(e: xdr.Encoder, mode: ?u32) !void {
    try e.boolean(mode != null);
    if (mode) |m| try e.u32_(m);
    for (0..3) |_| try e.boolean(false); // uid, gid, size
    try e.u32_(0); // atime: don't change
    try e.u32_(0); // mtime: don't change
}

fn expectStatus(want: Status, results: []const u8) !xdr.Decoder {
    var d: xdr.Decoder = .init(results);
    try testing.expectEqual(want, try d.enumeration(Status));
    return d;
}

/// The handle from a successful CREATE, MKDIR, SYMLINK, or MKNOD.
fn createdHandle(results: []const u8) ![fh.size]u8 {
    var d = try expectStatus(.ok, results);
    try testing.expect(try d.boolean());
    return (try d.opaque_(64))[0..fh.size].*;
}

test "create, write, set attributes, rename, link, and remove" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const nfs = f.nfs.program();
    const root = try f.rootHandle();
    var a: Args = .{};

    // CREATE (UNCHECKED, mode 0640), then WRITE and READ it back.
    var e = a.start(root);
    try e.string("art");
    try e.u32_(0);
    try sattrMode(e, 0o640);
    const art = try createdHandle(try f.call(nfs, @backingInt(Proc.create), a.bytes()));

    e = a.start(art);
    try e.u64_(2);
    try e.u32_(5);
    try e.u32_(0); // UNSTABLE
    try e.opaque_("perihelion");
    var d = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.write), a.bytes()));
    _ = try d.boolean();
    _ = try d.fixedOpaque(24);
    try testing.expect(try d.boolean());
    _ = try d.fixedOpaque(84);
    try testing.expectEqual(5, try d.u32_());
    try testing.expectEqual(0, try d.u32_());
    try testing.expectEqualSlices(u8, "znfsd-t\x00", try d.fixedOpaque(8));

    // DATA_SYNC is answered FILE_SYNC; COMMIT returns the same verifier.
    e = a.start(art);
    try e.u64_(2);
    try e.u32_(5);
    try e.u32_(1);
    try e.opaque_("perihelion");
    d = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.write), a.bytes()));
    _ = try d.fixedOpaque(4 + 24 + 4 + 84 + 4);
    try testing.expectEqual(2, try d.u32_());
    e = a.start(art);
    try e.u64_(0);
    try e.u32_(0);
    d = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.commit), a.bytes()));
    _ = try d.fixedOpaque(4 + 24 + 4 + 84);
    try testing.expectEqualSlices(u8, "znfsd-t\x00", try d.fixedOpaque(8));

    var content: [16]u8 = undefined;
    const got = try f.tmp.dir.readFile(testing.io, "share/art", &content);
    try testing.expectEqualSlices(u8, "\x00\x00perih", got);
    var attr: sys.Attr = undefined;
    const art_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/art", .{f.root}, 0);
    defer testing.allocator.free(art_path);
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat(art_path, &attr));
    try testing.expectEqual(0o640, attr.mode & 0o777);

    // CREATE GUARDED over it fails; EXCLUSIVE twice with one verifier succeeds.
    e = a.start(root);
    try e.string("art");
    try e.u32_(1);
    try sattrMode(e, null);
    _ = try expectStatus(.exist, try f.call(nfs, @backingInt(Proc.create), a.bytes()));
    for (0..2) |_| {
        e = a.start(root);
        try e.string("once");
        try e.u32_(2);
        try e.fixedOpaque("verifier");
        _ = try createdHandle(try f.call(nfs, @backingInt(Proc.create), a.bytes()));
    }

    // SETATTR: truncate to 3 bytes.
    e = a.start(art);
    for (0..3) |_| try e.boolean(false);
    try e.boolean(true);
    try e.u64_(3);
    try e.u32_(0);
    try e.u32_(0);
    try e.boolean(false); // no guard
    _ = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.setattr), a.bytes()));
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat(art_path, &attr));
    try testing.expectEqual(3, attr.size);

    // MKDIR, move art into it, then RENAME the directory: art's handle
    // still resolves.
    e = a.start(root);
    try e.string("box");
    try sattrMode(e, 0o750);
    const box = try createdHandle(try f.call(nfs, @backingInt(Proc.mkdir), a.bytes()));
    e = a.start(root);
    try e.string("art");
    try e.opaque_(&box);
    try e.string("art");
    _ = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.rename), a.bytes()));
    e = a.start(root);
    try e.string("box");
    try e.opaque_(&root);
    try e.string("crate");
    _ = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.rename), a.bytes()));
    e = a.start(art);
    _ = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.getattr), a.bytes()));

    // LINK art as hard, SYMLINK soft to it, then REMOVE and RMDIR.
    e = a.start(art);
    try e.opaque_(&root);
    try e.string("hard");
    d = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.link), a.bytes()));
    try testing.expect(try d.boolean());
    e = a.start(root);
    try e.string("soft");
    try sattrMode(e, null);
    try e.string("crate/art");
    _ = try createdHandle(try f.call(nfs, @backingInt(Proc.symlink), a.bytes()));
    var link_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("crate/art", link_buf[0..try f.tmp.dir.readLink(testing.io, "share/soft", &link_buf)]);

    e = a.start(root);
    try e.string("crate");
    _ = try expectStatus(.notempty, try f.call(nfs, @backingInt(Proc.rmdir), a.bytes()));
    e = a.start(root);
    try e.string("crate");
    _ = try expectStatus(.isdir, try f.call(nfs, @backingInt(Proc.remove), a.bytes()));
    for ([_][]const u8{ "hard", "soft" }) |name| {
        e = a.start(root);
        try e.string(name);
        _ = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.remove), a.bytes()));
    }
    e = a.start(box);
    try e.string("art");
    _ = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.remove), a.bytes()));
    e = a.start(root);
    try e.string("crate");
    _ = try expectStatus(.ok, try f.call(nfs, @backingInt(Proc.rmdir), a.bytes()));
    e = a.start(art);
    _ = try expectStatus(.stale, try f.call(nfs, @backingInt(Proc.getattr), a.bytes()));

    // Names can't reach elsewhere.
    e = a.start(root);
    try e.string("../skynet");
    try e.u32_(0);
    try sattrMode(e, null);
    _ = try expectStatus(.inval, try f.call(nfs, @backingInt(Proc.create), a.bytes()));
    e = a.start(root);
    try e.string("..");
    try sattrMode(e, null);
    _ = try expectStatus(.exist, try f.call(nfs, @backingInt(Proc.mkdir), a.bytes()));
}

test "maps translate callers and owners" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const me = std.c.getuid();
    const entries = [_]exports.MapEntry{
        .{ .local = .{ .uid = me }, .remote = .{ .uid = 1000 } },
        .{ .local = .{ .uid = 65534 }, .remote = null },
    };
    try f.table.maps.put(testing.allocator, "m", .{ .entries = &entries });
    defer f.table.maps.deinit(testing.allocator);
    f.rules[0].options.map = "m";
    f.uid = 1000;
    const root = try f.rootHandle();
    var a: Args = .{};

    // Client UID 1000 acts as the test user: it may create here, and sees
    // the new file as its own.
    var e = a.start(root);
    try e.string("art");
    try e.u32_(0);
    try sattrMode(e, 0o644);
    var d = try expectStatus(.ok, try f.call(f.nfs.program(), @backingInt(Proc.create), a.bytes()));
    try testing.expect(try d.boolean());
    _ = try d.opaque_(64);
    try testing.expect(try d.boolean());
    _ = try d.fixedOpaque(12); // type, mode, nlink
    try testing.expectEqual(1000, try d.u32_());
    var attr: sys.Attr = undefined;
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/art", .{f.root}, 0);
    defer testing.allocator.free(path);
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat(path, &attr));
    try testing.expectEqual(me, attr.uid);

    // An unmapped client acts as the anon, who may not.
    f.uid = 4242;
    e = a.start(root);
    try e.string("skynet");
    try e.u32_(0);
    try sattrMode(e, null);
    _ = try expectStatus(.acces, try f.call(f.nfs.program(), @backingInt(Proc.create), a.bytes()));
}

/// How many attribute sets in `results` show owner 4000:4001.
fn mappedOwners(results: []const u8) usize {
    const want = "\x00\x00\x0f\xa0\x00\x00\x0f\xa1";
    var count: usize = 0;
    var i: usize = 0;
    while (i + want.len <= results.len) : (i += 4) {
        if (std.mem.eql(u8, results[i..][0..want.len], want)) count += 1;
    }
    return count;
}

test "every reply maps owners, failures too" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The client sees the files' owner, whoever runs the tests, as 4000:4001.
    var root_attr: sys.Attr = undefined;
    var root_buf: [sys.max_path + 1]u8 = undefined;
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat(copyZ(&root_buf, f.root), &root_attr));
    const entries = [_]exports.MapEntry{.{
        .local = .{ .uid = root_attr.uid, .gid = root_attr.gid },
        .remote = .{ .uid = 4000, .gid = 4001 },
    }};
    try f.table.maps.put(testing.allocator, "m", .{ .entries = &entries });
    defer f.table.maps.deinit(testing.allocator);
    f.rules[0].options.map = "m";
    f.uid = 4000;
    f.gid = 4001;
    const nfs = f.nfs.program();
    const root = try f.rootHandle();
    const hal = (try f.lookup(root, "hal")).ok;
    const link = (try f.lookup(root, "link")).ok;
    var a: Args = .{};

    const Case = struct { proc: Proc, sets: usize };
    const check = struct {
        fn run(fx: *Fixture, p: server.Program, c: Case, args: []const u8) !void {
            const got = mappedOwners(try fx.call(p, @backingInt(c.proc), args));
            if (got != c.sets) {
                std.debug.print("{t}: {d} mapped attribute sets, want {d}\n", .{ c.proc, got, c.sets });
                return error.TestUnexpectedResult;
            }
        }
    }.run;

    _ = a.start(root);
    try check(&f, nfs, .{ .proc = .getattr, .sets = 1 }, a.bytes());
    for ([_]struct { [fh.size]u8, []const u8, usize }{
        .{ root, "hal", 2 },
        .{ root, "skynet", 1 }, // missing: the directory's attributes
        .{ hal, "x", 1 }, // not a directory
    }) |l| {
        var e = a.start(l[0]);
        try e.string(l[1]);
        try check(&f, nfs, .{ .proc = .lookup, .sets = l[2] }, a.bytes());
    }
    var e = a.start(hal);
    try e.u32_(0x3f);
    try check(&f, nfs, .{ .proc = .access, .sets = 1 }, a.bytes());
    _ = a.start(link);
    try check(&f, nfs, .{ .proc = .readlink, .sets = 1 }, a.bytes());
    e = a.start(hal);
    try e.u64_(0);
    try e.u32_(4);
    try check(&f, nfs, .{ .proc = .read, .sets = 1 }, a.bytes());
    e = a.start(hal);
    try e.u64_(0);
    try e.u32_(1);
    try e.u32_(0);
    try e.opaque_("I");
    try check(&f, nfs, .{ .proc = .write, .sets = 1 }, a.bytes());
    e = a.start(hal);
    try sattrMode(e, null);
    try e.boolean(false);
    try check(&f, nfs, .{ .proc = .setattr, .sets = 1 }, a.bytes());
    e = a.start(hal);
    try e.u64_(0);
    try e.u32_(0);
    try check(&f, nfs, .{ .proc = .commit, .sets = 1 }, a.bytes());

    // CREATE, then again GUARDED (exists: the directory's wcc).
    for ([_]struct { u32, usize }{ .{ 0, 2 }, .{ 1, 1 } }) |c| {
        e = a.start(root);
        try e.string("art");
        try e.u32_(c[0]);
        try sattrMode(e, null);
        try check(&f, nfs, .{ .proc = .create, .sets = c[1] }, a.bytes());
    }
    e = a.start(root);
    try e.string("box");
    try sattrMode(e, null);
    try check(&f, nfs, .{ .proc = .mkdir, .sets = 2 }, a.bytes());
    e = a.start(root);
    try e.string("soft");
    try sattrMode(e, null);
    try e.string("hal");
    try check(&f, nfs, .{ .proc = .symlink, .sets = 2 }, a.bytes());
    e = a.start(hal);
    try e.opaque_(&root);
    try e.string("hard");
    try check(&f, nfs, .{ .proc = .link, .sets = 2 }, a.bytes());
    e = a.start(root);
    try e.string("art");
    try e.opaque_(&root);
    try e.string("art2");
    try check(&f, nfs, .{ .proc = .rename, .sets = 2 }, a.bytes());
    for ([_]struct { Proc, []const u8 }{ .{ .remove, "skynet" }, .{ .remove, "hard" }, .{ .rmdir, "box" } }) |c| {
        e = a.start(root);
        try e.string(c[1]);
        try check(&f, nfs, .{ .proc = c[0], .sets = 1 }, a.bytes());
    }

    e = a.start(root);
    try e.u64_(0);
    try e.fixedOpaque(&@as([8]u8, @splat(0)));
    try e.u32_(8192);
    try check(&f, nfs, .{ .proc = .readdir, .sets = 1 }, a.bytes());
    e = a.start(root);
    try e.u64_(0);
    try e.fixedOpaque(&@as([8]u8, @splat(0)));
    try e.u32_(8192);
    try e.u32_(32768);
    // The directory, then hal, dir, link, art2, and soft.
    try check(&f, nfs, .{ .proc = .readdirplus, .sets = 6 }, a.bytes());
    for ([_]Proc{ .fsstat, .fsinfo, .pathconf }) |p| {
        _ = a.start(root);
        try check(&f, nfs, .{ .proc = p, .sets = 1 }, a.bytes());
    }
}

test "fileids stay inodes on the export root's file system, and differ elsewhere" {
    var r: Request = undefined;
    r.root_dev = 5;
    try testing.expectEqual(2, r.fileid(5, 2));
    const b = r.fileid(6, 2);
    const c = r.fileid(7, 2);
    try testing.expect(b != 2 and c != 2 and b != c);
    // Distinct inodes on one other file system stay distinct.
    try testing.expect(r.fileid(6, 3) != b);
    r.root_dev = null;
    try testing.expectEqual(2, r.fileid(6, 2));
}

test "read-only exports refuse writes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.rules[0].options.read_only = true;
    const root = try f.rootHandle();
    var a: Args = .{};
    var e = a.start(root);
    try e.string("hal");
    _ = try expectStatus(.rofs, try f.call(f.nfs.program(), @backingInt(Proc.remove), a.bytes()));
    const hal = (try f.lookup(root, "hal")).ok;
    e = a.start(hal);
    try e.u64_(0);
    try e.u32_(1);
    try e.u32_(2);
    try e.opaque_("x");
    _ = try expectStatus(.rofs, try f.call(f.nfs.program(), @backingInt(Proc.write), a.bytes()));
}

test "access follows mode bits, squashing, and read-only exports" {
    const attr: sys.Attr = .{
        .dev = 1,
        .ino = 2,
        .mode = posix.S.IFREG | 0o640,
        .nlink = 1,
        .uid = 501,
        .gid = 20,
        .rdev = 0,
        .size = 0,
        .blocks = 0,
        .atime = .{ .sec = 0, .nsec = 0 },
        .mtime = .{ .sec = 0, .nsec = 0 },
        .ctime = .{ .sec = 0, .nsec = 0 },
        .gen = 0,
    };
    const owner: Creds = .{ .uid = 501, .gid = 20, .gids = &.{} };
    const member: Creds = .{ .uid = 502, .gid = 99, .gids = &.{20} };
    const other: Creds = .{ .uid = 666, .gid = 666, .gids = &.{} };
    const root: Creds = .{ .uid = 0, .gid = 0, .gids = &.{} };
    try testing.expect(owner.allows(attr, 6));
    try testing.expect(member.allows(attr, 4) and !member.allows(attr, 2));
    try testing.expect(!other.allows(attr, 4));
    try testing.expect(root.allows(attr, 6) and !root.allows(attr, 1));
}
