//! Command-line parsing: global options, then a command and its arguments.

const std = @import("std");

pub const Globals = struct {
    socket: ?[]const u8 = null,
    run_as: ?[]const u8 = null,
    db: ?[]const u8 = null,
    /// Repeatable; empty means the defaults, `0.0.0.0` and `::`.
    binds: []const []const u8 = &.{},
};

pub const Noun = enum { serve, stop, help, @"export", group, map, mount, lock };

pub const Verb = enum { list, add, set, del };

pub const Command = struct {
    noun: Noun,
    /// Null for `serve`, `stop`, and `help`.
    verb: ?Verb = null,
    /// Arguments after the command, unparsed.
    args: []const []const u8 = &.{},
};

pub const Invocation = struct {
    globals: Globals,
    command: Command,
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
    const noun = std.meta.stringToEnum(Noun, args[i]) orelse return error.UnknownCommand;
    i += 1;
    switch (noun) {
        .serve, .stop, .help => return .{
            .globals = globals,
            .command = .{ .noun = noun, .args = args[i..] },
        },
        else => {},
    }
    if (i == args.len) return error.MissingVerb;
    const verb = parseVerb(args[i]) orelse return error.UnknownVerb;
    if (!allows(noun, verb)) return error.UnknownVerb;
    return .{
        .globals = globals,
        .command = .{ .noun = noun, .verb = verb, .args = args[i + 1 ..] },
    };
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
        .serve, .stop, .help => false,
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

test "bad options and commands" {
    try testing.expectError(error.UnknownOption, parseTest(&.{ "--skynet", "x", "stop" }));
    try testing.expectError(error.MissingValue, parseTest(&.{"--db"}));
    try testing.expectError(error.UnknownCommand, parseTest(&.{"launch"}));
}
