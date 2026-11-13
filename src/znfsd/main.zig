//! znfsd: the CLI daemon built on libnfsd.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const libnfsd = @import("libnfsd");
const cli = @import("cli.zig");
const ephemeral = @import("ephemeral.zig");

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

    const status: u8 = run(io, init.gpa, arena, args[1..], stdout, stderr) catch |err| status: {
        try stderr.print("znfsd: {t}\n", .{err});
        break :status 2;
    };
    try stdout.flush();
    try stderr.flush();
    return status;
}

fn run(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const invocation = try cli.parse(arena, args);
    switch (invocation.command.noun) {
        .help => {
            try stdout.writeAll(usage);
            return 0;
        },
        .serve => return serve(io, gpa, arena, invocation, stderr),
        else => |noun| {
            try stderr.print("znfsd {f}: {t}: not implemented\n", .{ libnfsd.version, noun });
            return 1;
        },
    }
}

fn serve(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, invocation: cli.Invocation, stderr: *Io.Writer) !u8 {
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

    var table: libnfsd.exports.Table = .{};
    defer table.groups.deinit(gpa);
    if (options.maps.len > 0) {
        try stderr.writeAll("znfsd: --map: maps aren't implemented yet\n");
        return 2;
    }
    for (options.groups) |text| {
        const group = ephemeral.parseGroup(arena, text) catch |err| {
            try stderr.print("znfsd: --group {s}: {t}\n", .{ text, err });
            return 2;
        };
        try table.groups.put(gpa, group.name, group.clients);
    }
    var rules: std.ArrayList(libnfsd.exports.Rule) = .empty;
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
            if (client == .group and !table.groups.contains(client.group)) {
                try stderr.print("znfsd: {s}: no group {s}\n", .{ text, client.group });
                return 2;
            }
            try rules.append(arena, .{ .path = path, .client = client, .options = parsed.options });
        }
    }
    table.rules = rules.items;

    var mount: libnfsd.mount.Mount = .init(gpa, &table);
    defer mount.deinit();
    var files: libnfsd.files.Files = .init(gpa);
    defer files.deinit();
    var verifier: [8]u8 = undefined;
    std.mem.writeInt(i64, &verifier, @truncate(Io.Clock.real.now(io).nanoseconds), .big);
    var nfs: libnfsd.nfs.Nfs = .init(gpa, &table, &files, verifier);
    const registrations = [_]libnfsd.service.Registration{
        .{ .program = mount.program(), .service = .mount },
        .{ .program = nfs.program(), .service = .nfs },
    };

    // Signals are taken by `sigwait` below, so block them before any thread
    // starts; threads inherit the mask.
    var signals = posix.sigemptyset();
    posix.sigaddset(&signals, .INT);
    posix.sigaddset(&signals, .TERM);
    posix.sigprocmask(posix.SIG.BLOCK, &signals, null);

    var diag: libnfsd.service.Diagnostic = .{};
    var result: Outcome = .running;
    var task = try io.concurrent(runService, .{ io, gpa, config, &registrations, &diag, &result });
    var signal: c_int = 0;
    _ = std.c.sigwait(&signals, &signal);
    _ = task.cancel(io);

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

test {
    _ = cli;
    _ = ephemeral;
}
