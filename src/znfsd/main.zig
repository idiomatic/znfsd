//! znfsd: the CLI daemon built on libnfsd.

const std = @import("std");
const Io = std.Io;
const libnfsd = @import("libnfsd");
const cli = @import("cli.zig");
const dbm = @import("db.zig");
const commands = @import("commands.zig");
const control = @import("control.zig");
const daemon = @import("daemon.zig");

const usage = @embedFile("usage.txt");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const status: u8 = run(io, init.gpa, arena, init.environ_map, args[1..], stdout, stderr) catch |err| status: {
        try stderr.print("znfsd: {t}\n", .{err});
        break :status 2;
    };
    try stdout.flush();
    try stderr.flush();
    return status;
}

fn run(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !u8 {
    const invocation = try cli.parse(arena, args);
    const c = invocation.command;
    if (c.noun == .help) {
        try stdout.writeAll(usage);
        return 0;
    }
    if (c.noun == .map) {
        try stderr.writeAll("znfsd: map: maps aren't implemented yet\n");
        return 1;
    }
    const socket = invocation.globals.socket orelse control.defaultPath(arena, environ, libnfsd.sys.isRoot()) catch |err| {
        try stderr.print("znfsd: no control socket path: {t}; use --socket PATH\n", .{err});
        return 2;
    };

    if (c.noun == .serve) {
        var db = try openDb(io, arena, invocation.globals, environ, stderr) orelse return 1;
        defer db.close();
        return daemon.serve(io, gpa, arena, invocation, &db, socket, stderr);
    }

    // Other commands go to a running daemon, so changes apply at once.
    if (try control.send(io, arena, socket, invocation.words)) |reply| {
        try stdout.writeAll(reply.out);
        try stderr.writeAll(reply.err);
        return reply.status;
    }
    switch (c.noun) {
        .stop => {
            try stderr.print("znfsd: no daemon answers at {s}\n", .{socket});
            return 1;
        },
        .lock => {
            try stderr.print("znfsd: lock: needs the running daemon; none answers at {s}\n", .{socket});
            return 1;
        },
        .@"export", .group, .mount => {
            var db = try openDb(io, arena, invocation.globals, environ, stderr) orelse return 1;
            defer db.close();
            const ctx: commands.Context = .{ .db = &db, .arena = arena, .out = stdout, .err = stderr };
            return commands.run(ctx, c.noun, c.verb.?, c.args) catch |err| switch (err) {
                error.Sqlite => {
                    try stderr.print("znfsd: database: {s}\n", .{db.errorMessage()});
                    return 1;
                },
                else => return err,
            };
        },
        .help, .map, .serve => unreachable,
    }
}

/// Opens the database at `--db` or the default path, creating its
/// directory; reports failures and returns null.
fn openDb(io: Io, arena: std.mem.Allocator, globals: cli.Globals, environ: *const std.process.Environ.Map, stderr: *Io.Writer) !?dbm.Db {
    const path: [:0]const u8 = if (globals.db) |p| try arena.dupeSentinel(u8, p, 0) else dbm.defaultPath(arena, environ, libnfsd.sys.isRoot()) catch |err| {
        try stderr.print("znfsd: no database path: {t}; use --db PATH\n", .{err});
        return null;
    };
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        try stderr.print("znfsd: {s}: {t}\n", .{ dir, err });
        return null;
    };
    return dbm.Db.open(path) catch {
        try stderr.print("znfsd: {s}: can't open the database\n", .{path});
        return null;
    };
}

test {
    _ = cli;
    _ = @import("ephemeral.zig");
    _ = dbm;
    _ = commands;
    _ = control;
    _ = daemon;
}
