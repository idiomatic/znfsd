//! Fuzz tests: untrusted bytes through TCP record marking and through
//! `server.dispatch` to every program, each message to be answered or
//! dropped without crashing, leaking, or logging an error. `zig build test`
//! runs fixed pseudorandom inputs; `zig build test --fuzz` searches.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const Smith = testing.Smith;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");
const server = @import("server.zig");
const exports = @import("exports.zig");
const fh = @import("fh.zig");
const sys = @import("sys.zig");
const Files = @import("files.zig").Files;
const nfs = @import("nfs.zig");
const mount = @import("mount.zig");
const nlm = @import("nlm.zig");
const nsm = @import("nsm.zig");
const portmap = @import("portmap.zig");
const Locks = @import("locks.zig").Locks;

/// Inputs each test runs without `--fuzz`, from a fixed seed.
const smoke_inputs = 300;

/// Runs `testOne` on fixed pseudorandom inputs, then fuzzes it.
fn fuzz(context: anytype, comptime testOne: fn (@TypeOf(context), *Smith) anyerror!void) !void {
    var prng: std.Random.DefaultPrng = .init(0x9000);
    var input: [16384]u8 = undefined;
    for (0..smoke_inputs) |_| {
        const len = prng.random().uintLessThan(usize, input.len);
        prng.random().bytes(input[0..len]);
        var smith: Smith = .{ .in = input[0..len] };
        try testOne(context, &smith);
    }
    try testing.fuzz(context, testOne, .{});
}

test "fuzz record marking" {
    try fuzz({}, recordOne);
}

fn recordOne(_: void, smith: *Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const max = pick(smith, 129);
    var reader: Io.Reader = .fixed(bytes(smith, &buf));
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(testing.allocator);
    while (true) {
        rpc.record.read(&reader, testing.allocator, &message, max) catch break;
        try testing.expect(message.items.len <= max);
    }
}

test "fuzz dispatch" {
    // Reply buffers as the servers size them, reused across inputs.
    const out = try std.heap.page_allocator.alloc(u8, 1024 * 1024 + 4096);
    defer std.heap.page_allocator.free(out);
    try fuzz(out, dispatchOne);
}

/// Programs as a daemon serves them, over a fresh export.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    rules: [1]exports.Rule,
    map_entries: [2]exports.MapEntry,
    table: exports.Table,
    files: Files,
    nfs: nfs.Nfs,
    mount: mount.Mount,
    locks: Locks,
    nsm: nsm.Nsm,
    nlm: nlm.Nlm,
    portmap: portmap.Server,
    programs: [5]server.Program,
    /// File handles seen in replies, to use in later calls.
    handles: [16][fh.size]u8,
    handle_count: usize,

    /// Exports with options from `smith`: read-only at times, any squash,
    /// and at times a map.
    fn init(f: *Fixture, smith: *Smith) !void {
        const io = testing.io;
        const gpa = testing.allocator;
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        try f.tmp.dir.createDirPath(io, "share/dir");
        try f.tmp.dir.writeFile(io, .{ .sub_path = "share/hal", .data = "I'm sorry, Dave." });
        try f.tmp.dir.symLink(io, "hal", "share/link", .{});
        var buf: [sys.max_path]u8 = undefined;
        const n = try f.tmp.dir.realPath(io, &buf);
        f.root = try std.fmt.allocPrint(gpa, "{s}/share", .{buf[0..n]});
        const squashes = [_]exports.Squash{ .none, .root, .all };
        f.rules = .{.{ .path = f.root, .client = .any, .options = .{
            .read_only = rarely(smith, 4),
            .squash = squashes[pick(smith, squashes.len)],
            .map = if (rarely(smith, 2)) "m" else null,
        } }};
        f.table = .{ .rules = &f.rules };
        f.map_entries = .{
            .{ .local = .{ .uid = std.c.getuid(), .gid = std.c.getgid() }, .remote = .{ .uid = 1000, .gid = 1000 } },
            .{ .local = .{ .uid = 65534 }, .remote = null },
        };
        try f.table.maps.put(gpa, "m", .{ .entries = &f.map_entries });
        f.files = .init(gpa);
        f.nfs = .init(gpa, &f.table, &f.files, "znfsd-f\x00".*);
        f.mount = .init(gpa, &f.table);
        f.locks = .init(gpa);
        f.nsm = .init(gpa, 1);
        f.nlm = .init(gpa, &f.nfs, &f.locks, &f.nsm);
        f.portmap = .init(gpa);
        f.programs = .{ f.nfs.program(), f.mount.program(), f.nlm.program(), f.nsm.program(), f.portmap.program() };
        f.handle_count = 0;
    }

    fn deinit(f: *Fixture) void {
        const io = testing.io;
        f.portmap.deinit();
        f.nlm.deinit(io);
        f.nsm.deinit();
        f.locks.deinit();
        f.mount.deinit();
        f.files.deinit();
        f.table.maps.deinit(testing.allocator);
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    /// Keeps the file handles in a reply: opaques of handle size whose
    /// first byte is the format version.
    fn harvest(f: *Fixture, reply: []const u8) void {
        const marker = [_]u8{ 0, 0, 0, fh.size, fh.format_version };
        var i: usize = 0;
        while (std.mem.findPos(u8, reply, i, &marker)) |at| {
            if (at + 4 + fh.size > reply.len) break;
            if (f.handle_count < f.handles.len) {
                f.handles[f.handle_count] = reply[at + 4 ..][0..fh.size].*;
                f.handle_count += 1;
            }
            i = at + 4 + fh.size;
        }
    }
};

/// A caller on a host whose portmapper nobody answers, so callbacks go
/// nowhere.
const from: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 9 } };

fn dispatchOne(out: []u8, smith: *Smith) anyerror!void {
    var f: Fixture = undefined;
    try f.init(smith);
    defer f.deinit();

    // Mount the export and look up its entries, for real handles.
    var cred_buf: [64]u8 = undefined;
    var cw: Io.Writer = .fixed(&cred_buf);
    const auth: rpc.AuthSys = .{ .stamp = 0, .machine_name = "hal", .uid = std.c.getuid(), .gid = std.c.getgid() };
    try auth.encode(.init(&cw));
    const cred: rpc.OpaqueAuth = .{ .flavor = .sys, .body = cw.buffered() };
    var args: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&args);
    try xdr.Encoder.init(&w).string(f.root);
    send(&f, .tcp, out, mount.prog, 3, 1, cred, w.buffered());
    if (f.handle_count > 0) for ([_][]const u8{ "hal", "dir", "link" }) |name| {
        w = .fixed(&args);
        const e: xdr.Encoder = .init(&w);
        try e.opaque_(&f.handles[0]);
        try e.string(name);
        send(&f, .tcp, out, nfs.prog, nfs.vers, 3, cred, w.buffered());
    };

    for (0..pick(smith, 8) + 1) |_| {
        const protocol: net.Protocol = if (rarely(smith, 2)) .udp else .tcp;
        var message: [2048]u8 = undefined;
        const n = if (rarely(smith, 4)) bytes(smith, message[0..512]).len else try build(&f, smith, &message);
        sendRaw(&f, protocol, out, message[0..n]);
    }
}

/// Builds a call from parts: a program and version it serves (mostly), a
/// procedure, credentials, and arguments of handles, names, numbers, and
/// bytes.
fn build(f: *Fixture, smith: *Smith, buf: []u8) !usize {
    const program = f.programs[pick(smith, f.programs.len)];
    const version = if (rarely(smith, 8))
        word(smith)
    else
        program.low + @as(u32, @intCast(pick(smith, program.high - program.low + 1)));
    const proc: u32 = @intCast(pick(smith, 32));
    var cred_buf: [rpc.max_auth_bytes]u8 = undefined;
    const cred: rpc.OpaqueAuth = switch (pick(smith, 4)) {
        0 => .none,
        1, 2 => sys: {
            var auth: rpc.AuthSys = .{
                .stamp = 0,
                .machine_name = "skynet",
                .uid = switch (pick(smith, 4)) {
                    0, 1 => std.c.getuid(),
                    2 => 0,
                    else => word(smith),
                },
                .gid = std.c.getgid(),
            };
            var gids: [rpc.AuthSys.max_gids]u32 = undefined;
            const n = pick(smith, gids.len + 1);
            for (gids[0..n]) |*g| g.* = word(smith);
            try auth.setGids(gids[0..n]);
            var cw: Io.Writer = .fixed(&cred_buf);
            try auth.encode(.init(&cw));
            break :sys .{ .flavor = .sys, .body = cw.buffered() };
        },
        else => .{ .flavor = @fromBackingInt(@intCast(pick(smith, 8))), .body = bytes(smith, cred_buf[0..64]) },
    };

    var args_buf: [1536]u8 = undefined;
    var aw: Io.Writer = .fixed(&args_buf);
    const e: xdr.Encoder = .init(&aw);
    // Most NFS and NLM arguments start with a file handle.
    if (f.handle_count > 0 and !rarely(smith, 4)) try e.opaque_(&f.handles[pick(smith, f.handle_count)]);
    for (0..pick(smith, 9)) |_| {
        switch (pick(smith, 5)) {
            0 => if (f.handle_count > 0) try e.opaque_(&f.handles[pick(smith, f.handle_count)]),
            1 => {
                const names = [_][]const u8{ "hal", "dir", "link", "art", ".", "..", "", "dir/hal", "perihelion" };
                try e.string(names[pick(smith, names.len)]);
            },
            2 => try e.u32_(word(smith)),
            3 => try e.u64_(smith.value(u64)),
            else => {
                var buf_: [64]u8 = undefined;
                try aw.writeAll(bytes(smith, &buf_));
            },
        }
    }

    var mw: Io.Writer = .fixed(buf);
    const call: rpc.Call = .{
        .xid = word(smith),
        .prog = program.prog,
        .vers = version,
        .proc = proc,
        .cred = cred,
        .verf = .none,
        .args = aw.buffered(),
    };
    try call.encode(.init(&mw));
    return mw.end;
}

// Choices from whole `u64`s by plain arithmetic: replayed inputs give
// Smith eight bytes per value, and narrower types or ranges turn most of
// them into minimums, so fixed inputs would hardly vary.

fn pick(smith: *Smith, n: usize) usize {
    return @intCast(smith.value(u64) % n);
}

/// True one time in `n`, and never once input runs out (Smith then gives
/// zeros).
fn rarely(smith: *Smith, n: u64) bool {
    return smith.value(u64) % n == n - 1;
}

fn word(smith: *Smith) u32 {
    return @truncate(smith.value(u64));
}

fn bytes(smith: *Smith, buf: []u8) []u8 {
    const out = buf[0..pick(smith, buf.len + 1)];
    smith.bytes(out);
    return out;
}

fn send(f: *Fixture, protocol: net.Protocol, out: []u8, prog: u32, vers: u32, proc: u32, cred: rpc.OpaqueAuth, args: []const u8) void {
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const call: rpc.Call = .{ .xid = 1, .prog = prog, .vers = vers, .proc = proc, .cred = cred, .verf = .none, .args = args };
    call.encode(.init(&w)) catch unreachable;
    sendRaw(f, protocol, out, w.buffered());
}

fn sendRaw(f: *Fixture, protocol: net.Protocol, out: []u8, message: []const u8) void {
    // NLM's `_MSG` procedures answer by calling back, waiting for the
    // caller's portmapper; skip them rather than wait.
    switch (rpc.decodeCall(message)) {
        .call => |call| if (call.prog == nlm.prog and call.proc >= 6 and call.proc <= 9) return,
        else => {},
    }
    const size: usize = if (protocol == .udp) server.max_datagram else out.len;
    const ctx: server.Context = .{ .io = testing.io, .from = from, .protocol = protocol };
    const reply = server.dispatch(&f.programs, ctx, message, out[0..size]) orelse return;
    f.harvest(reply);
}
