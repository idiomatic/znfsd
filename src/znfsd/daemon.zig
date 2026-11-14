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
    const config: libnfsd.service.Config = .{
        .binds = binds.items,
        .ports = ports,
        .portmap = if (options.no_portmap) .off else .auto,
    };

    // Ephemeral groups and exports, checked once.
    if (options.maps.len > 0) {
        try stderr.writeAll("znfsd: --map: maps aren't implemented yet\n");
        return 2;
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
        if (parsed.options.map != null) {
            try stderr.print("znfsd: {s}: maps aren't implemented yet\n", .{text});
            return 2;
        }
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
        .mount = undefined,
        .nfs = undefined,
    };
    defer d.tables.deinit();
    const table = d.build(stderr) catch return 1;
    for (rules.items) |r| if (r.client == .group and !table.groups.contains(r.client.group)) {
        try stderr.print("znfsd: {s}: no group {s}\n", .{ r.path, r.client.group });
        return 2;
    };

    var mount: libnfsd.mount.Mount = .init(gpa, table);
    defer mount.deinit();
    for (try db.mounts(arena, null)) |m| try mount.restore(io, m.host, m.path);
    mount.store = db.mountStore();
    var files: libnfsd.files.Files = .init(gpa);
    defer files.deinit();
    var verifier: [8]u8 = undefined;
    std.mem.writeInt(i64, &verifier, @truncate(Io.Clock.real.now(io).nanoseconds), .big);
    var nfs: libnfsd.nfs.Nfs = .init(gpa, table, &files, verifier);
    d.mount = &mount;
    d.nfs = &nfs;
    const registrations = [_]libnfsd.service.Registration{
        .{ .program = mount.program(), .service = .mount },
        .{ .program = nfs.program(), .service = .nfs },
    };

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

    var diag: libnfsd.service.Diagnostic = .{};
    var result: Outcome = .running;
    var service = try io.concurrent(runService, .{ io, gpa, config, &registrations, &diag, &result });
    var controller = try io.concurrent(control.serve, .{ io, gpa, &socket, d.handler() });
    var signal: c_int = 0;
    _ = std.c.sigwait(&signals, &signal);
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
    mount: *libnfsd.mount.Mount,
    nfs: *libnfsd.nfs.Nfs,

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
        for (stored.rules.items) |r| if (r.options.map != null) {
            err.print("znfsd: stored rule for {s}: maps aren't implemented yet\n", .{r.path}) catch {};
            return error.MapsUnimplemented;
        };
        const table = try arena.create(exports.Table);
        table.* = .{};
        var it = stored.groups.iterator();
        while (it.next()) |g| try table.groups.put(arena, g.key_ptr.*, g.value_ptr.items);
        for (d.ephemeral_groups) |g| try table.groups.put(arena, g.name, g.clients);

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
            .lock => switch (c.verb.?) {
                // No lock manager yet, so no locks.
                .list => return 0,
                else => {
                    try err.writeAll("znfsd: no such locks\n");
                    return 1;
                },
            },
            .@"export", .group, .mount => {
                const ctx: commands.Context = .{ .db = d.db, .arena = arena, .out = out, .err = err };
                const status = try commands.run(ctx, c.noun, c.verb.?, c.args);
                if (status != 0 or c.verb.? == .list) return status;
                switch (c.noun) {
                    .mount => try d.mount.unmount(d.io, c.args[0], if (c.args.len > 1) c.args[1] else null),
                    else => {
                        const table = d.build(err) catch return 1;
                        d.mount.setTable(table);
                        d.nfs.setTable(table);
                    },
                }
                return 0;
            },
            .serve, .help, .map => {
                try err.print("znfsd: {t}: not a command for the daemon\n", .{c.noun});
                return 2;
            },
        }
    }
};

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
