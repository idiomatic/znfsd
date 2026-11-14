//! `serve`: the daemon. It builds the export table from the database and
//! its ephemeral exports, runs libnfsd's service, and answers commands on
//! the control socket, applying changes at once.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const libnfsd = @import("libnfsd");
const exports = libnfsd.exports;
const cli = @import("cli.zig");
const ephemeral = @import("ephemeral.zig");
const dbm = @import("db.zig");
const commands = @import("commands.zig");
const control = @import("control.zig");
const activity_ = @import("activity.zig");
const web = @import("web.zig");

pub fn serve(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    invocation: cli.Invocation,
    db: *dbm.Db,
    socket_path: []const u8,
    stderr: *Io.Writer,
) !u8 {
    const options = try cli.parseServe(arena, invocation.command.args);

    var binds: std.ArrayList(net.IpAddress) = .empty;
    for (invocation.globals.binds) |text| {
        try binds.append(arena, net.IpAddress.parse(text, 0) catch {
            try stderr.print("znfsd: --bind {s}: not an IP address\n", .{text});
            return 2;
        });
    }
    if (binds.items.len == 0) {
        try binds.appendSlice(arena, &.{ .{ .ip4 = .unspecified(0) }, .{ .ip6 = .unspecified(0) } });
    }
    var ports: libnfsd.service.Ports = .{};
    if (options.nfs_port) |p| ports.nfs = p;
    if (options.mount_port) |p| ports.mount = p;
    if (options.stat_port) |p| ports.stat = p;
    if (options.lock_port) |p| ports.lock = p;
    var config: libnfsd.service.Config = .{
        .binds = binds.items,
        .ports = ports,
        .portmap = if (options.no_portmap) .off else .auto,
    };

    // --run-as: resolved now, applied once every port is bound.
    var drop: ?Drop = null;
    if (invocation.globals.run_as) |user| {
        if (!libnfsd.sys.isRoot()) {
            try stderr.writeAll("znfsd: --run-as needs root\n");
            return 2;
        }
        drop = Drop.init(arena, user, db.path, socket_path) catch {
            try stderr.print("znfsd: --run-as {s}: no such user\n", .{user});
            return 2;
        };
    }

    // Ephemeral groups, maps, and exports, checked once.
    var maps: std.StringArrayHashMapUnmanaged(std.ArrayList(exports.MapEntry)) = .empty;
    for (options.maps) |text| {
        const m = ephemeral.parseMap(arena, text) catch |err| {
            try stderr.print("znfsd: --map {s}: {t}\n", .{ text, err });
            return 2;
        };
        const gop = try maps.getOrPut(arena, m.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.appendSlice(arena, m.entries);
    }
    var groups: std.ArrayList(ephemeral.Group) = .empty;
    for (options.groups) |text| {
        try groups.append(arena, ephemeral.parseGroup(arena, text) catch |err| {
            try stderr.print("znfsd: --group {s}: {t}\n", .{ text, err });
            return 2;
        });
    }
    var rules: std.ArrayList(exports.Rule) = .empty;
    for (options.exports) |text| {
        const parsed = ephemeral.parseExport(arena, text) catch |err| {
            try stderr.print("znfsd: {s}: {t}\n", .{ text, err });
            return 2;
        };
        const path_buf = try arena.create([libnfsd.sys.max_path]u8);
        var path: []const u8 = undefined;
        const e = libnfsd.sys.canonical(parsed.path, path_buf, &path);
        if (e != .SUCCESS) {
            try stderr.print("znfsd: {s}: {t}\n", .{ parsed.path, e });
            return 2;
        }
        for (parsed.clients) |client| {
            try rules.append(arena, .{ .path = path, .client = client, .options = parsed.options });
        }
    }

    var d: Daemon = .{
        .io = io,
        .gpa = gpa,
        .db = db,
        .tables = .init(gpa),
        .ephemeral_rules = rules.items,
        .ephemeral_groups = groups.items,
        .ephemeral_maps = &maps,
        .maps_enabled = drop == null,
        .mount = undefined,
        .nfs = undefined,
        .files = undefined,
        .nlm = undefined,
        .nsm = undefined,
        .table = undefined,
        .activity = .init(gpa, io),
    };
    defer d.activity.deinit();
    defer d.tables.deinit();
    const table = d.build(stderr) catch return 1;
    d.table = table;
    for (rules.items) |r| if (r.client == .group and !table.groups.contains(r.client.group)) {
        try stderr.print("znfsd: {s}: no group {s}\n", .{ r.path, r.client.group });
        return 2;
    };
    for (table.rules) |r| if (r.options.map) |m| {
        if (drop != null) {
            try stderr.print("znfsd: {s}: map={s} is ignored: --run-as disables maps\n", .{ r.path, m });
        } else if (!table.maps.contains(m)) {
            try stderr.print("znfsd: {s}: no map {s}\n", .{ r.path, m });
            return 2;
        }
    };

    var mount: libnfsd.mount.Mount = .init(gpa, table);
    defer mount.deinit();
    for (try db.mounts(arena, null)) |m| try mount.restore(io, m.host, m.path);
    mount.store = db.mountStore();
    var files: libnfsd.files.Files = .init(gpa);
    defer files.deinit();
    db.io = io;
    files.store = db.filesStore();
    var verifier: [8]u8 = undefined;
    std.mem.writeInt(i64, &verifier, @truncate(Io.Clock.real.now(io).nanoseconds), .big);
    var nfs: libnfsd.nfs.Nfs = .init(gpa, table, &files, verifier);

    // Locking: a new NSM state number at each start; hosts that held locks
    // before are told, and get a grace period to reclaim them.
    const state = try db.advanceNsmState();
    const previous = try db.monitors(arena);
    for (previous) |h| try db.deleteMonitor(h.name);
    var locks: libnfsd.locks.Locks = .init(gpa);
    defer locks.deinit();
    var status: libnfsd.nsm.Nsm = .init(gpa, state);
    defer status.deinit();
    status.store = db.nsmStore();
    var nlm: libnfsd.nlm.Nlm = .init(gpa, &nfs, &locks, &status);
    defer nlm.deinit(io);
    status.rebooted = nlm.rebooted();
    const locking = !options.no_portmap;
    if (locking and previous.len > 0) nlm.startGrace(io);

    d.mount = &mount;
    d.nfs = &nfs;
    d.files = &files;
    d.nlm = &nlm;
    d.nsm = &status;
    var registrations: std.ArrayList(libnfsd.service.Registration) = .empty;
    try registrations.appendSlice(arena, &.{
        .{ .program = mount.program(), .service = .mount },
        .{ .program = nfs.program(), .service = .nfs },
    });
    if (locking) try registrations.appendSlice(arena, &.{
        .{ .program = nlm.program(), .service = .lock },
        .{ .program = status.program(), .service = .stat },
    });

    var socket = control.listen(io, socket_path) catch |err| {
        switch (err) {
            error.InUse => try stderr.print("znfsd: another znfsd is running, with control socket {s}\n", .{socket_path}),
            else => try stderr.print("znfsd: control socket {s}: {t}\n", .{ socket_path, err }),
        }
        return 1;
    };
    defer {
        socket.deinit(io);
        control.remove(socket_path);
    }

    // Signals are taken by `sigwait` below, so block them before any thread
    // starts; threads inherit the mask.
    var signals = posix.sigemptyset();
    posix.sigaddset(&signals, .INT);
    posix.sigaddset(&signals, .TERM);
    posix.sigprocmask(posix.SIG.BLOCK, &signals, null);

    if (drop) |*dr| {
        dr.nfs = &nfs;
        config.after_bind = dr.hook();
    }
    config.observer = d.activity.observer();

    // The activity monitor: wanted, not needed, so a taken port only warns.
    const web_address = web.parseAddress(options.web orelse "127.0.0.1:8049") catch {
        try stderr.print("znfsd: --web {s}: not [ADDR:]PORT\n", .{options.web.?});
        return 2;
    };
    var web_server: ?net.Server = web_address.listen(io, .{ .reuse_address = true }) catch |err| blk: {
        try stderr.print("znfsd: activity monitor: {f}: {t}\n", .{ web_address, err });
        try stderr.flush();
        break :blk null;
    };
    defer if (web_server) |*w| w.deinit(io);
    var diag: libnfsd.service.Diagnostic = .{};
    var result: Outcome = .running;
    var service = try io.concurrent(runService, .{ io, gpa, config, registrations.items, &diag, &result });
    var controller = try io.concurrent(control.serve, .{ io, gpa, &socket, d.handler() });
    var notifier = try io.concurrent(notifyRestart, .{ io, if (locking) previous else &.{}, state });
    var monitor: ?Io.Future(Io.Cancelable!void) = if (web_server) |*w|
        try io.concurrent(web.serve, .{ io, gpa, w, d.provider() })
    else
        null;
    var signal: c_int = 0;
    _ = std.c.sigwait(&signals, &signal);
    if (monitor) |*m| m.cancel(io) catch {};
    notifier.cancel(io);
    _ = controller.cancel(io) catch {};
    _ = service.cancel(io);

    switch (result) {
        .running, .canceled => return 0,
        .failed => |err| {
            if (diag.len > 0) {
                try stderr.print("znfsd: {s}\n", .{diag.message()});
            } else {
                try stderr.print("znfsd: {t}\n", .{err});
            }
            return 1;
        },
    }
}

const Daemon = struct {
    io: Io,
    gpa: std.mem.Allocator,
    db: *dbm.Db,
    /// Every table built, kept until exit: requests may still be reading
    /// a replaced one.
    tables: std.heap.ArenaAllocator,
    ephemeral_rules: []const exports.Rule,
    ephemeral_groups: []const ephemeral.Group,
    ephemeral_maps: *const std.StringArrayHashMapUnmanaged(std.ArrayList(exports.MapEntry)),
    /// False under --run-as, which can't act as other users.
    maps_enabled: bool,
    mount: *libnfsd.mount.Mount,
    nfs: *libnfsd.nfs.Nfs,
    files: *libnfsd.files.Files,
    nlm: *libnfsd.nlm.Nlm,
    nsm: *libnfsd.nsm.Nsm,
    /// The table in force, for the activity monitor.
    table: *const exports.Table,
    activity: activity_.Activity,

    /// Builds the table: stored rules and groups, with ephemeral ones laid
    /// over them by path and client, and by name.
    fn build(d: *Daemon, err: *Io.Writer) !*const exports.Table {
        const arena = d.tables.allocator();
        const stored = d.db.table(arena) catch |e| {
            if (e == error.Sqlite) {
                err.print("znfsd: database: {s}\n", .{d.db.errorMessage()}) catch {};
            } else err.print("znfsd: database: a stored rule is invalid: {t}\n", .{e}) catch {};
            return e;
        };
        const table = try arena.create(exports.Table);
        table.* = .{};
        var it = stored.groups.iterator();
        while (it.next()) |g| try table.groups.put(arena, g.key_ptr.*, g.value_ptr.items);
        for (d.ephemeral_groups) |g| try table.groups.put(arena, g.name, g.clients);
        if (d.maps_enabled) {
            var maps = stored.maps.iterator();
            while (maps.next()) |m| try table.maps.put(arena, m.key_ptr.*, .{ .entries = m.value_ptr.items });
            var ephemeral_maps = d.ephemeral_maps.iterator();
            while (ephemeral_maps.next()) |m| try table.maps.put(arena, m.key_ptr.*, .{ .entries = m.value_ptr.items });
        }

        var rules: std.ArrayList(exports.Rule) = .empty;
        try rules.appendSlice(arena, d.ephemeral_rules);
        for (stored.rules.items) |r| {
            const shadowed = for (d.ephemeral_rules) |e| {
                if (std.mem.eql(u8, e.path, r.path) and sameClient(e.client, r.client)) break true;
            } else false;
            if (!shadowed) try rules.append(arena, r);
        }
        table.rules = rules.items;
        return table;
    }

    fn provider(d: *Daemon) web.Provider {
        return .{ .ptr = d, .write = writeSnapshot };
    }

    /// The activity monitor's snapshot: activity, exports, mounts, and locks.
    fn writeSnapshot(ptr: *anyopaque, arena: std.mem.Allocator, w: *Io.Writer) anyerror!void {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const Row3 = struct { path: []const u8, client: []const u8, options: []const u8 };
        const LockRow = struct { host: []const u8, path: []const u8, range: []const u8, kind: []const u8 };
        const table = @atomicLoad(*const exports.Table, &d.table, .acquire);
        var export_rows: std.ArrayList(Row3) = .empty;
        for (table.rules) |r| {
            var cw: Io.Writer.Allocating = .init(arena);
            try r.client.format(&cw.writer);
            var ow: Io.Writer.Allocating = .init(arena);
            try dbm.formatOptions(r.options, &ow.writer);
            try export_rows.append(arena, .{ .path = r.path, .client = cw.written(), .options = ow.written() });
        }
        var lock_rows: std.ArrayList(LockRow) = .empty;
        for (try d.nlm.locks.snapshot(d.io, arena)) |l| {
            try lock_rows.append(arena, .{
                .host = l.owner.host,
                .path = try d.files.pathOf(d.io, arena, l.file.fsid, l.file.inode) orelse try std.fmt.allocPrint(arena, "inode {d}", .{l.file.inode}),
                .range = if (l.range.end == libnfsd.locks.Range.eof)
                    try std.fmt.allocPrint(arena, "{d}-", .{l.range.start})
                else
                    try std.fmt.allocPrint(arena, "{d}-{d}", .{ l.range.start, l.range.end - 1 }),
                .kind = if (l.exclusive) "exclusive" else "shared",
            });
        }
        try std.json.Stringify.value(.{
            .activity = try d.activity.snapshot(d.io, arena),
            .exports = export_rows.items,
            .mounts = try d.mount.snapshot(d.io, arena),
            .locks = lock_rows.items,
        }, .{}, w);
    }

    fn handler(d: *Daemon) control.Handler {
        return .{ .ptr = d, .handle = handle };
    }

    fn handle(ptr: *anyopaque, arena: std.mem.Allocator, words: []const []const u8, out: *Io.Writer, err: *Io.Writer) u8 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.command(arena, words, out, err) catch |e| {
            if (e == error.Sqlite) {
                err.print("znfsd: database: {s}\n", .{d.db.errorMessage()}) catch {};
            } else err.print("znfsd: {t}\n", .{e}) catch {};
            return 1;
        };
    }

    fn command(d: *Daemon, arena: std.mem.Allocator, words: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
        const invocation = cli.parse(arena, words) catch |e| {
            try err.print("znfsd: {t}\n", .{e});
            return 2;
        };
        const c = invocation.command;
        switch (c.noun) {
            .stop => {
                _ = std.c.kill(std.c.getpid(), .TERM);
                return 0;
            },
            .activity => {
                if (c.args.len > 0) return usage(err, "activity");
                try writeSnapshot(d, arena, out);
                try out.writeByte('\n');
                return 0;
            },
            .lock => return d.lockCommand(arena, c.verb.?, c.args, out, err),
            .@"export", .group, .mount, .map => {
                const ctx: commands.Context = .{ .db = d.db, .arena = arena, .out = out, .err = err };
                const status = try commands.run(ctx, c.noun, c.verb.?, c.args);
                if (status != 0 or c.verb.? == .list) return status;
                switch (c.noun) {
                    .mount => {
                        try d.mount.unmount(d.io, c.args[0], if (c.args.len > 1) c.args[1] else null);
                        try d.nsm.forget(d.io, c.args[0]);
                    },
                    else => {
                        const table = d.build(err) catch return 1;
                        d.mount.setTable(table);
                        d.nfs.setTable(table);
                        @atomicStore(*const exports.Table, &d.table, table, .release);
                    },
                }
                return 0;
            },
            .serve, .help => {
                try err.print("znfsd: {t}: not a command for the daemon\n", .{c.noun});
                return 2;
            },
        }
    }

    /// `lock list [PATH]` and `lock del HOST [PATH]`, on the live locks.
    fn lockCommand(d: *Daemon, arena: std.mem.Allocator, verb: cli.Verb, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
        switch (verb) {
            .list => {
                if (args.len > 1) return usage(err, "lock list [PATH]");
                const only: ?libnfsd.locks.File = if (args.len == 1) fileOf(args[0]) orelse return 0 else null;
                var rows: std.ArrayList([4][]const u8) = .empty;
                for (try d.nlm.locks.snapshot(d.io, arena)) |l| {
                    if (only) |f| if (!std.meta.eql(f, l.file)) continue;
                    const path = try d.files.pathOf(d.io, arena, l.file.fsid, l.file.inode) orelse
                        try std.fmt.allocPrint(arena, "inode {d}", .{l.file.inode});
                    const range = if (l.range.end == libnfsd.locks.Range.eof)
                        try std.fmt.allocPrint(arena, "{d}-", .{l.range.start})
                    else
                        try std.fmt.allocPrint(arena, "{d}-{d}", .{ l.range.start, l.range.end - 1 });
                    try rows.append(arena, .{ l.owner.host, path, range, if (l.exclusive) "exclusive" else "shared" });
                }
                try commands.table(out, 4, rows.items);
                return 0;
            },
            .del => {
                if (args.len < 1 or args.len > 2) return usage(err, "lock del HOST [PATH]");
                const file: ?libnfsd.locks.File = if (args.len == 2) fileOf(args[1]) orelse {
                    try err.print("znfsd: {s}: no such file\n", .{args[1]});
                    return 1;
                } else null;
                if (try d.nlm.releaseHost(d.io, args[0], file) == 0) {
                    try err.writeAll("znfsd: no such locks\n");
                    return 1;
                }
                if (file == null) try d.nsm.forget(d.io, args[0]);
                return 0;
            },
            .add, .set => unreachable,
        }
    }
};

/// Dropping root for --run-as: the user, and what must become theirs first.
const Drop = struct {
    name: [:0]const u8,
    uid: u32,
    gid: u32,
    db_path: []const u8,
    socket_path: []const u8,
    nfs: ?*libnfsd.nfs.Nfs = null,

    fn init(arena: std.mem.Allocator, user: []const u8, db_path: []const u8, socket_path: []const u8) !Drop {
        const name = try arena.dupeSentinel(u8, user, 0);
        const pw = std.c.getpwnam(name) orelse return error.NoSuchUser;
        return .{ .name = name, .uid = pw.uid, .gid = pw.gid, .db_path = db_path, .socket_path = socket_path };
    }

    fn hook(d: *Drop) libnfsd.service.AfterBind {
        return .{ .ptr = d, .call = call };
    }

    fn call(ptr: *anyopaque, diag: *libnfsd.service.Diagnostic) bool {
        const d: *Drop = @ptrCast(@alignCast(ptr));
        // The database's directory and files, and the control socket.
        var buf: [libnfsd.sys.max_path + 8]u8 = undefined;
        if (std.fs.path.dirname(d.db_path)) |dir| chown(&buf, dir, "", d);
        for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| chown(&buf, d.db_path, suffix, d);
        chown(&buf, d.socket_path, "", d);
        if (initgroups(d.name, @bitCast(d.gid)) != 0 or std.c.setgid(d.gid) != 0 or std.c.setuid(d.uid) != 0) {
            diag.set("--run-as {s}: can't drop root", .{d.name});
            return false;
        }
        if (std.c.setuid(0) == 0) {
            diag.set("--run-as {s}: root wasn't dropped", .{d.name});
            return false;
        }
        // Files are now reached as the user, who can't give them to others.
        if (d.nfs) |n| n.root = false;
        return true;
    }

    fn chown(buf: []u8, path: []const u8, suffix: []const u8, d: *const Drop) void {
        const z = std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ path, suffix }, 0) catch return;
        _ = std.c.fchownat(std.c.AT.FDCWD, z, d.uid, d.gid, 0);
    }
};

extern "c" fn initgroups(user: [*:0]const u8, group: c_int) c_int;

fn usage(err: *Io.Writer, text: []const u8) !u8 {
    try err.print("znfsd: usage: znfsd {s}\n", .{text});
    return 2;
}

/// The lock table's key for the file at `path`.
fn fileOf(path: []const u8) ?libnfsd.locks.File {
    var buf: [libnfsd.sys.max_path]u8 = undefined;
    var canonical: []const u8 = undefined;
    if (libnfsd.sys.canonical(path, &buf, &canonical) != .SUCCESS) return null;
    var z: [libnfsd.sys.max_path + 1]u8 = undefined;
    @memcpy(z[0..canonical.len], canonical);
    z[canonical.len] = 0;
    var attr: libnfsd.sys.Attr = undefined;
    if (libnfsd.sys.lstat(z[0..canonical.len :0], &attr) != .SUCCESS) return null;
    const h: libnfsd.fh.Handle = .fromAttr(0, attr);
    return .{ .fsid = h.fsid, .inode = h.inode };
}

/// After a restart, tells the hosts that held locks, once our services are
/// registered, retrying those that don't answer.
fn notifyRestart(io: Io, hosts: []const libnfsd.nsm.Host, state: u32) void {
    var pending: [256]bool = @splat(true);
    const count = @min(hosts.len, pending.len);
    for (0..5) |_| {
        io.sleep(.fromSeconds(2), .awake) catch return;
        var left: usize = 0;
        for (hosts[0..count], 0..) |h, i| {
            if (!pending[i]) continue;
            if (libnfsd.nsm.notify(io, &.{h}, state) == 1) {
                pending[i] = false;
            } else left += 1;
        }
        if (left == 0) return;
    }
}

fn sameClient(a: exports.Client, b: exports.Client) bool {
    var abuf: [300]u8 = undefined;
    var bbuf: [300]u8 = undefined;
    var aw: Io.Writer = .fixed(&abuf);
    var bw: Io.Writer = .fixed(&bbuf);
    a.format(&aw) catch return false;
    b.format(&bw) catch return false;
    return std.mem.eql(u8, aw.buffered(), bw.buffered());
}

const Outcome = union(enum) {
    running,
    canceled,
    failed: anyerror,
};

/// Runs the service; if it stops on its own, wakes `serve`'s `sigwait`.
fn runService(
    io: Io,
    gpa: std.mem.Allocator,
    config: libnfsd.service.Config,
    registrations: []const libnfsd.service.Registration,
    diag: *libnfsd.service.Diagnostic,
    result: *Outcome,
) void {
    libnfsd.service.run(io, gpa, config, registrations, diag) catch |err| {
        result.* = if (err == error.Canceled) .canceled else .{ .failed = err };
        if (err != error.Canceled) _ = std.c.kill(std.c.getpid(), .TERM);
        return;
    };
    result.* = .canceled;
    _ = std.c.kill(std.c.getpid(), .TERM);
}
