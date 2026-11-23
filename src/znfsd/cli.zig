//! Command-line parsing: global options, then a command and its arguments.

const std = @import("std");

pub const Globals = struct {
    socket: ?[]const u8 = null,
    run_as: ?[]const u8 = null,
    db: ?[]const u8 = null,
    /// Repeatable; empty means the defaults, `0.0.0.0` and `::`.
    binds: []const []const u8 = &.{},
};

pub const Noun = enum { serve, stop, activity, help, @"export", group, map, mount, lock };

pub const Verb = enum { list, add, set, del };

pub const Command = struct {
    noun: Noun,
    /// Null for `serve`, `stop`, `activity`, and `help`.
    verb: ?Verb = null,
    /// Arguments after the command, unparsed.
    args: []const []const u8 = &.{},
};

pub const Invocation = struct {
    globals: Globals,
    command: Command,
    /// The command's words as given, from its noun on, for sending to a
    /// running daemon.
    words: []const []const u8 = &.{},
};

pub const Error = error{
    MissingValue,
    UnknownOption,
    UnknownCommand,
    UnknownVerb,
    MissingVerb,
    OutOfMemory,
};

/// Parses `args`, excluding the program name. Slices point into `args`;
/// `binds` is allocated with `arena`.
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) Error!Invocation {
    var globals: Globals = .{};
    var binds: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
        const option = args[i];
        i += 1;
        if (i == args.len) return error.MissingValue;
        const value = args[i];
        if (std.mem.eql(u8, option, "--socket")) {
            globals.socket = value;
        } else if (std.mem.eql(u8, option, "--run-as")) {
            globals.run_as = value;
        } else if (std.mem.eql(u8, option, "--db")) {
            globals.db = value;
        } else if (std.mem.eql(u8, option, "--bind")) {
            try binds.append(arena, value);
        } else {
            return error.UnknownOption;
        }
    }
    globals.binds = binds.items;

    if (i == args.len) return .{ .globals = globals, .command = .{ .noun = .help } };
    const words = args[i..];
    const noun = std.meta.stringToEnum(Noun, args[i]) orelse return error.UnknownCommand;
    i += 1;
    switch (noun) {
        .serve, .stop, .activity, .help => return .{
            .globals = globals,
            .command = .{ .noun = noun, .args = args[i..] },
            .words = words,
        },
        else => {},
    }
    if (i == args.len) return error.MissingVerb;
    const verb = parseVerb(args[i]) orelse return error.UnknownVerb;
    if (!allows(noun, verb)) return error.UnknownVerb;
    return .{
        .globals = globals,
        .command = .{ .noun = noun, .verb = verb, .args = args[i + 1 ..] },
        .words = words,
    };
}

pub const Serve = struct {
    nfs_port: ?u16 = null,
    mount_port: ?u16 = null,
    stat_port: ?u16 = null,
    lock_port: ?u16 = null,
    web: ?[]const u8 = null,
    no_portmap: bool = false,
    /// `GROUP:CLIENT[,CLIENT ...]`, unparsed.
    groups: []const []const u8 = &.{},
    /// `MAP:LOCAL=[REMOTE[,REMOTE ...]]`, unparsed.
    maps: []const []const u8 = &.{},
    /// `PATH[:OPTIONS[:CLIENTS]]`, unparsed.
    exports: []const []const u8 = &.{},
};

/// `serve` options that take a value.
const ServeOption = enum { @"nfs-port", @"mount-port", @"stat-port", @"lock-port", web, group, map };

pub const ServeError = error{ MissingValue, UnknownOption, BadPort, OutOfMemory };

pub fn parseServe(arena: std.mem.Allocator, args: []const []const u8) ServeError!Serve {
    var s: Serve = .{};
    var groups: std.ArrayList([]const u8) = .empty;
    var maps: std.ArrayList([]const u8) = .empty;
    var exports: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) {
            try exports.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-portmap")) {
            s.no_portmap = true;
            continue;
        }
        const option = std.meta.stringToEnum(ServeOption, arg[2..]) orelse return error.UnknownOption;
        i += 1;
        if (i == args.len) return error.MissingValue;
        const value = args[i];
        switch (option) {
            .@"nfs-port" => s.nfs_port = try parsePort(value),
            .@"mount-port" => s.mount_port = try parsePort(value),
            .@"stat-port" => s.stat_port = try parsePort(value),
            .@"lock-port" => s.lock_port = try parsePort(value),
            .web => s.web = value,
            .group => try groups.append(arena, value),
            .map => try maps.append(arena, value),
        }
    }
    s.groups = groups.items;
    s.maps = maps.items;
    s.exports = exports.items;
    return s;
}

fn parsePort(text: []const u8) error{BadPort}!u16 {
    return std.fmt.parseInt(u16, text, 10) catch error.BadPort;
}

fn parseVerb(word: []const u8) ?Verb {
    const aliases = std.StaticStringMap(Verb).initComptime(.{
        .{ "list", .list },
        .{ "ls", .list },
        .{ "add", .add },
        .{ "set", .set },
        .{ "del", .del },
        .{ "delete", .del },
        .{ "rm", .del },
    });
    return aliases.get(word);
}

fn allows(noun: Noun, verb: Verb) bool {
    return switch (noun) {
        .@"export" => true,
        .group, .map => verb != .set,
        .mount, .lock => verb == .list or verb == .del,
        .serve, .stop, .activity, .help => false,
    };
}

const testing = std.testing;

fn parseTest(args: []const []const u8) Error!Invocation {
    return parse(testing.allocator, args);
}

test "no arguments means help" {
    const inv = try parseTest(&.{});
    try testing.expectEqual(Noun.help, inv.command.noun);
}

test "globals, repeated bind, and serve arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const inv = try parse(arena.allocator(), &.{
        "--socket", "/tmp/z.sock", "--bind", "10.0.0.1", "--bind", "::1",
        "serve",    "/srv:ro",
    });
    try testing.expectEqualStrings("/tmp/z.sock", inv.globals.socket.?);
    try testing.expectEqual(2, inv.globals.binds.len);
    try testing.expectEqualStrings("::1", inv.globals.binds[1]);
    try testing.expectEqual(Noun.serve, inv.command.noun);
    try testing.expectEqualStrings("/srv:ro", inv.command.args[0]);
}

test "verb aliases" {
    const inv = try parseTest(&.{ "export", "rm", "/srv", "hal" });
    try testing.expectEqual(Noun.@"export", inv.command.noun);
    try testing.expectEqual(Verb.del, inv.command.verb.?);
    try testing.expectEqual(2, inv.command.args.len);
}

test "verbs a noun doesn't take" {
    try testing.expectError(error.UnknownVerb, parseTest(&.{ "group", "set", "lab" }));
    try testing.expectError(error.UnknownVerb, parseTest(&.{ "lock", "add", "hal" }));
    try testing.expectError(error.MissingVerb, parseTest(&.{"map"}));
}

test "serve options, repeated groups and maps, and exports" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try parseServe(arena.allocator(), &.{
        "--nfs-port", "12049",           "--no-portmap", "/srv/media:ro",
        "--group",    "lab:10.1.0.0/16", "--map",        "art:art=501,1000",
        "--group",    "ops:fd00::/8",    "/srv/home",
    });
    try testing.expectEqual(12049, s.nfs_port.?);
    try testing.expectEqual(null, s.mount_port);
    try testing.expect(s.no_portmap);
    try testing.expectEqual(2, s.groups.len);
    try testing.expectEqualStrings("art:art=501,1000", s.maps[0]);
    try testing.expectEqualStrings("/srv/home", s.exports[1]);
    try testing.expectError(error.BadPort, parseServe(arena.allocator(), &.{ "--lock-port", "70000" }));
    try testing.expectError(error.UnknownOption, parseServe(arena.allocator(), &.{"--skynet"}));
}

test "activity takes no verb" {
    const inv = try parseTest(&.{"activity"});
    try testing.expectEqual(Noun.activity, inv.command.noun);
    try testing.expectEqual(null, inv.command.verb);
    try testing.expectEqualStrings("activity", inv.words[0]);
}

test "bad options and commands" {
    try testing.expectError(error.UnknownOption, parseTest(&.{ "--skynet", "x", "stop" }));
    try testing.expectError(error.MissingValue, parseTest(&.{"--db"}));
    try testing.expectError(error.UnknownCommand, parseTest(&.{"launch"}));
}
