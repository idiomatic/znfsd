//! MOUNT versions 1 through 3 (RFC 1813, appendix I): root file handles for
//! exports, the export list, and records of who has mounted what.
//!
//! Version 1 and 2 clients can list exports and mounts, but not mount: their
//! 32-byte handles are too small for ours.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");
const server = @import("server.zig");
const exports = @import("exports.zig");
const fh = @import("fh.zig");
const sys = @import("sys.zig");

pub const prog: u32 = 100005;
pub const max_path = 1024;
pub const max_name = 255;

pub const Proc = enum(u32) {
    null = 0,
    mnt = 1,
    dump = 2,
    umnt = 3,
    umntall = 4,
    @"export" = 5,
    _,
};

pub const Status = enum(u32) {
    ok = 0,
    perm = 1,
    noent = 2,
    io = 5,
    acces = 13,
    notdir = 20,
    inval = 22,
    nametoolong = 63,
    notsupp = 10004,
    serverfault = 10006,
};

/// A stable ID for an export, carried in its file handles.
pub fn exportId(path: []const u8) u32 {
    return std.hash.Fnv1a_32.hash(path);
}

pub const Record = struct {
    host: []const u8,
    path: []const u8,
};

/// Where an embedder keeps mount records across restarts.
pub const Store = struct {
    ptr: *anyopaque,
    mounted: *const fn (ptr: *anyopaque, host: []const u8, path: []const u8) void,
    /// Forgets `host`'s mount of `path`, or of everything when null.
    unmounted: *const fn (ptr: *anyopaque, host: []const u8, path: ?[]const u8) void,
};

pub const Mount = struct {
    gpa: std.mem.Allocator,
    store: ?Store = null,
    /// Exported paths must be canonical.
    table: *const exports.Table,
    mutex: Io.Mutex = .init,
    records: std.ArrayList(Record) = .empty,

    pub fn init(gpa: std.mem.Allocator, table: *const exports.Table) Mount {
        return .{ .gpa = gpa, .table = table };
    }

    pub fn deinit(m: *Mount) void {
        for (m.records.items) |r| m.freeRecord(r);
        m.records.deinit(m.gpa);
    }

    /// Adds a record kept from before a restart, without storing it again.
    pub fn restore(m: *Mount, io: Io, host: []const u8, path: []const u8) !void {
        _ = try m.add(io, host, path);
    }

    pub fn program(m: *Mount) server.Program {
        return .{ .prog = prog, .low = 1, .high = 3, .ptr = m, .handle = handle };
    }

    fn handle(ptr: *anyopaque, ctx: server.Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
        const m: *Mount = @ptrCast(@alignCast(ptr));
        return m.handleCall(ctx, call, results) catch |err| switch (err) {
            error.Truncated, error.TooLong, error.Invalid => .garbage_args,
            error.WriteFailed, error.OutOfMemory, error.Canceled => .system_err,
        };
    }

    fn handleCall(m: *Mount, ctx: server.Context, call: rpc.Call, results: *Io.Writer) !rpc.Reply {
        const e: xdr.Encoder = .init(results);
        var d: xdr.Decoder = .init(call.args);
        var host_buf: [64]u8 = undefined;
        const host = hostName(ctx.from, &host_buf);
        switch (@as(Proc, @fromBackingInt(@intCast(call.proc)))) {
            .null => {},
            .mnt => {
                const path = try d.string(max_path);
                if (call.vers < 3) {
                    try e.u32_(@backingInt(Status.notsupp));
                    return .success;
                }
                var handle_buf: [fh.size]u8 = undefined;
                const status = try m.mnt(ctx, host, path, &handle_buf);
                try e.enumeration(status);
                if (status == .ok) {
                    try e.opaque_(&handle_buf);
                    try e.u32_(1);
                    try e.enumeration(rpc.AuthFlavor.sys);
                }
            },
            .dump => {
                try m.mutex.lock(ctx.io);
                defer m.mutex.unlock(ctx.io);
                for (m.records.items) |r| {
                    try e.boolean(true);
                    try e.string(r.host);
                    try e.string(r.path);
                }
                try e.boolean(false);
            },
            .umnt => {
                const path = try d.string(max_path);
                try m.forget(ctx.io, host, path);
            },
            .umntall => try m.forget(ctx.io, host, null),
            .@"export" => {
                var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
                defer arena_state.deinit();
                for (try m.table.paths(arena_state.allocator())) |path| {
                    try e.boolean(true);
                    try e.string(path);
                    for (m.table.rules) |r| {
                        if (!std.mem.eql(u8, r.path, path)) continue;
                        var buf: [max_name]u8 = undefined;
                        var w: Io.Writer = .fixed(&buf);
                        try r.client.format(&w);
                        try e.boolean(true);
                        try e.string(w.buffered());
                    }
                    try e.boolean(false);
                }
                try e.boolean(false);
            },
            _ => return .proc_unavail,
        }
        return .success;
    }

    /// Checks access to `path` and makes its handle.
    fn mnt(m: *Mount, ctx: server.Context, host: []const u8, path: []const u8, out: *[fh.size]u8) !Status {
        var canonical_buf: [sys.max_path]u8 = undefined;
        var canonical: []const u8 = undefined;
        switch (sys.canonical(path, &canonical_buf, &canonical)) {
            .SUCCESS => {},
            .NOENT => return .noent,
            .NOTDIR => return .notdir,
            .NAMETOOLONG => return .nametoolong,
            .ACCES => return .acces,
            else => return .io,
        }
        const match = m.table.match(canonical, ctx.from, null) orelse return .acces;

        var attr: sys.Attr = undefined;
        var z: [sys.max_path + 1]u8 = undefined;
        @memcpy(z[0..canonical.len], canonical);
        z[canonical.len] = 0;
        switch (sys.lstat(z[0..canonical.len :0], &attr)) {
            .SUCCESS => {},
            .NOENT => return .noent,
            .ACCES => return .acces,
            else => return .io,
        }
        if (attr.mode & std.posix.S.IFMT != std.posix.S.IFDIR) return .notdir;
        out.* = fh.Handle.fromAttr(exportId(match.path), attr).encode();
        try m.remember(ctx.io, host, canonical);
        return .ok;
    }

    fn remember(m: *Mount, io: Io, host: []const u8, path: []const u8) !void {
        if (try m.add(io, host, path)) if (m.store) |s| s.mounted(s.ptr, host, path);
    }

    /// Adds a record; returns whether it was new.
    fn add(m: *Mount, io: Io, host: []const u8, path: []const u8) !bool {
        try m.mutex.lock(io);
        defer m.mutex.unlock(io);
        for (m.records.items) |r| {
            if (std.mem.eql(u8, r.host, host) and std.mem.eql(u8, r.path, path)) return false;
        }
        const record: Record = .{ .host = try m.gpa.dupe(u8, host), .path = try m.gpa.dupe(u8, path) };
        errdefer m.freeRecord(record);
        try m.records.append(m.gpa, record);
        return true;
    }

    /// Forgets `host`'s mount of `path`, or of everything when null.
    fn forget(m: *Mount, io: Io, host: []const u8, path: ?[]const u8) !void {
        if (m.store) |s| s.unmounted(s.ptr, host, path);
        try m.mutex.lock(io);
        defer m.mutex.unlock(io);
        var i: usize = 0;
        while (i < m.records.items.len) {
            const r = m.records.items[i];
            if (std.mem.eql(u8, r.host, host) and (path == null or std.mem.eql(u8, r.path, path.?))) {
                m.freeRecord(m.records.orderedRemove(i));
            } else i += 1;
        }
    }

    fn freeRecord(m: *Mount, r: Record) void {
        m.gpa.free(r.host);
        m.gpa.free(r.path);
    }
};

/// A client's address as text, without the port.
fn hostName(address: net.IpAddress, buf: []u8) []const u8 {
    const c: exports.Cidr = switch (exports.normalize(address)) {
        .ip4 => |a| .{ .address = .{ .ip4 = a }, .prefix = 32 },
        .ip6 => |a| .{ .address = .{ .ip6 = a }, .prefix = 128 },
    };
    var w: Io.Writer = .fixed(buf);
    c.format(&w) catch {};
    return w.buffered();
}

const testing = std.testing;

fn callMount(m: *Mount, vers: u32, proc: Proc, args: []const u8, from: net.IpAddress, out: []u8) ![]const u8 {
    const programs = [_]server.Program{m.program()};
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const call: rpc.Call = .{ .xid = 1, .prog = prog, .vers = vers, .proc = @backingInt(proc), .cred = .none, .verf = .none, .args = args };
    try call.encode(.init(&w));
    const ctx: server.Context = .{ .io = testing.io, .from = from, .protocol = .udp };
    const reply = server.dispatch(&programs, ctx, w.buffered(), out).?;
    try testing.expectEqual(0, std.mem.readInt(u32, reply[20..24], .big));
    return reply[24..];
}

fn pathArg(buf: []u8, path: []const u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    xdr.Encoder.init(&w).string(path) catch unreachable;
    return w.buffered();
}

test "mount, list, and unmount" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "share/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "share/file", .data = "hal" });
    var root_buf: [sys.max_path]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buf);
    const share = try std.fmt.allocPrint(testing.allocator, "{s}/share", .{root_buf[0..root_len]});
    defer testing.allocator.free(share);

    const rules = [_]exports.Rule{.{ .path = share, .client = try .parse("10.0.0.0/8"), .options = .{} }};
    const table: exports.Table = .{ .rules = &rules };
    var m: Mount = .init(testing.allocator, &table);
    defer m.deinit();

    const lab = try net.IpAddress.parse("10.1.2.3", 700);
    const skynet = try net.IpAddress.parse("192.0.2.66", 700);
    var args_buf: [sys.max_path + 8]u8 = undefined;
    var out: [512]u8 = undefined;

    // The export and a directory inside it mount; files, outsiders, and
    // escapes through `..` don't.
    var r = try callMount(&m, 3, .mnt, pathArg(&args_buf, share), lab, &out);
    try testing.expectEqual(0, std.mem.readInt(u32, r[0..4], .big));
    try testing.expectEqual(fh.size, std.mem.readInt(u32, r[4..8], .big));
    const h: fh.Handle = try .decode(r[8 .. 8 + fh.size]);
    try testing.expectEqual(exportId(share), h.export_id);

    const sub = try std.fmt.allocPrint(testing.allocator, "{s}/sub/../sub", .{share});
    defer testing.allocator.free(sub);
    r = try callMount(&m, 3, .mnt, pathArg(&args_buf, sub), lab, &out);
    try testing.expectEqual(0, std.mem.readInt(u32, r[0..4], .big));

    const file = try std.fmt.allocPrint(testing.allocator, "{s}/file", .{share});
    defer testing.allocator.free(file);
    r = try callMount(&m, 3, .mnt, pathArg(&args_buf, file), lab, &out);
    try testing.expectEqual(@backingInt(Status.notdir), std.mem.readInt(u32, r[0..4], .big));

    r = try callMount(&m, 3, .mnt, pathArg(&args_buf, share), skynet, &out);
    try testing.expectEqual(@backingInt(Status.acces), std.mem.readInt(u32, r[0..4], .big));

    const escape = try std.fmt.allocPrint(testing.allocator, "{s}/..", .{share});
    defer testing.allocator.free(escape);
    r = try callMount(&m, 3, .mnt, pathArg(&args_buf, escape), lab, &out);
    try testing.expectEqual(@backingInt(Status.acces), std.mem.readInt(u32, r[0..4], .big));

    r = try callMount(&m, 1, .mnt, pathArg(&args_buf, share), lab, &out);
    try testing.expectEqual(@backingInt(Status.notsupp), std.mem.readInt(u32, r[0..4], .big));

    // Two records, for the export and its subdirectory.
    r = try callMount(&m, 3, .dump, "", lab, &out);
    var d: xdr.Decoder = .init(r);
    var count: usize = 0;
    while (try d.boolean()) : (count += 1) {
        try testing.expectEqualStrings("10.1.2.3", try d.string(max_name));
        _ = try d.string(max_path);
    }
    try testing.expectEqual(2, count);

    _ = try callMount(&m, 3, .umnt, pathArg(&args_buf, share), lab, &out);
    try testing.expectEqual(1, m.records.items.len);
    _ = try callMount(&m, 3, .umntall, "", lab, &out);
    try testing.expectEqual(0, m.records.items.len);

    // The export list names each export's clients.
    r = try callMount(&m, 1, .@"export", "", skynet, &out);
    d = .init(r);
    try testing.expect(try d.boolean());
    try testing.expectEqualStrings(share, try d.string(max_path));
    try testing.expect(try d.boolean());
    try testing.expectEqualStrings("10.0.0.0/8", try d.string(max_name));
    try testing.expect(!try d.boolean());
    try testing.expect(!try d.boolean());
}
