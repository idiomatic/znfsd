//! The `export`, `group`, and `mount` commands, on the database.

const std = @import("std");
const Io = std.Io;
const libnfsd = @import("libnfsd");
const exports = libnfsd.exports;
const cli = @import("cli.zig");
const Db = @import("db.zig").Db;
const dbm = @import("db.zig");

pub const Context = struct {
    db: *Db,
    arena: std.mem.Allocator,
    out: *Io.Writer,
    err: *Io.Writer,
};

pub fn run(c: Context, noun: cli.Noun, verb: cli.Verb, args: []const []const u8) !u8 {
    return switch (noun) {
        .@"export" => exportCommand(c, verb, args),
        .group => groupCommand(c, verb, args),
        .mount => mountCommand(c, verb, args),
        .map => mapCommand(c, verb, args),
        else => unreachable,
    };
}

fn usage(c: Context, text: []const u8) !u8 {
    try c.err.print("znfsd: usage: znfsd {s}\n", .{text});
    return 2;
}

/// An export path as stored: canonical when it exists, else as given.
fn exportPath(c: Context, path: []const u8, must_exist: bool) !?[]const u8 {
    const buf = try c.arena.create([libnfsd.sys.max_path]u8);
    var canonical: []const u8 = undefined;
    const e = libnfsd.sys.canonical(path, buf, &canonical);
    if (e == .SUCCESS) return canonical;
    if (!must_exist) return path;
    try c.err.print("znfsd: {s}: {t}\n", .{ path, e });
    return null;
}

/// Checks a client's syntax and returns it as written.
fn client(c: Context, text: []const u8) !?[]const u8 {
    _ = exports.Client.parse(text) catch {
        try c.err.print("znfsd: {s}: not a host, *.domain, CIDR, @group, or *\n", .{text});
        return null;
    };
    return text;
}

fn exportCommand(c: Context, verb: cli.Verb, args: []const []const u8) !u8 {
    switch (verb) {
        .list => {
            if (args.len > 1) return usage(c, "export list [PATH]");
            const path = if (args.len == 1) try exportPath(c, args[0], false) else null;
            var rows: std.ArrayList([3][]const u8) = .empty;
            for (try c.db.rules(c.arena, path)) |r| try rows.append(c.arena, .{ r.path, r.client, r.options });
            try table(c.out, 3, rows.items);
        },
        .add, .set => {
            if (args.len < 2 or (verb == .set and args.len < 3)) {
                return usage(c, if (verb == .add) "export add PATH CLIENT [OPTION ...]" else "export set PATH CLIENT OPTION ...");
            }
            const path = try exportPath(c, args[0], true) orelse return 1;
            const who = try client(c, args[1]) orelse return 2;
            // `add` merges into the rule's options; `set` replaces them.
            const existing = try c.db.ruleOptions(c.arena, path, who);
            if (verb == .set and existing == null) {
                try c.err.print("znfsd: no rule for {s} {s}; use export add\n", .{ path, who });
                return 1;
            }
            var options: exports.Options = if (verb == .add and existing != null) try dbm.parseOptions(existing.?) else .{};
            for (args[2..]) |word| options.apply(word) catch {
                try c.err.print("znfsd: {s}: not rw, ro, squash=root|all|none, or map=MAP\n", .{word});
                return 2;
            };
            var w: Io.Writer.Allocating = .init(c.arena);
            try dbm.formatOptions(options, &w.writer);
            try c.db.putRule(path, who, w.written());
        },
        .del => {
            if (args.len < 1 or args.len > 2) return usage(c, "export del PATH [CLIENT]");
            const path = try exportPath(c, args[0], false) orelse return 1;
            if (try c.db.deleteRules(path, if (args.len == 2) args[1] else null) == 0) {
                try c.err.print("znfsd: no such rule\n", .{});
                return 1;
            }
        },
    }
    return 0;
}

fn groupCommand(c: Context, verb: cli.Verb, args: []const []const u8) !u8 {
    switch (verb) {
        .list => {
            if (args.len > 1) return usage(c, "group list [GROUP]");
            var rows: std.ArrayList([2][]const u8) = .empty;
            for (try c.db.members(c.arena, if (args.len == 1) args[0] else null)) |m| try rows.append(c.arena, .{ m.name, m.client });
            try table(c.out, 2, rows.items);
        },
        .add => {
            if (args.len < 2) return usage(c, "group add GROUP CLIENT ...");
            for (args[1..]) |text| {
                const who = try client(c, text) orelse return 2;
                if (who[0] == '@') {
                    try c.err.print("znfsd: {s}: groups can't contain groups\n", .{who});
                    return 2;
                }
            }
            for (args[1..]) |who| try c.db.addMember(args[0], who);
        },
        .del => {
            if (args.len < 1) return usage(c, "group del GROUP [CLIENT ...]");
            var removed: usize = 0;
            if (args.len == 1) {
                removed = try c.db.deleteMembers(args[0], null);
            } else for (args[1..]) |who| {
                removed += try c.db.deleteMembers(args[0], who);
            }
            if (removed == 0) {
                try c.err.print("znfsd: no such group or member\n", .{});
                return 1;
            }
        },
        .set => unreachable,
    }
    return 0;
}

fn mapCommand(c: Context, verb: cli.Verb, args: []const []const u8) !u8 {
    switch (verb) {
        .list => {
            if (args.len > 1) return usage(c, "map list [MAP]");
            var rows: std.ArrayList([3][]const u8) = .empty;
            for (try c.db.mapEntries(c.arena, if (args.len == 1) args[0] else null)) |m| {
                try rows.append(c.arena, .{ m.name, m.local, if (m.remote.len == 0) "anon" else m.remote });
            }
            try table(c.out, 3, rows.items);
        },
        .add => {
            if (args.len < 2) return usage(c, "map add MAP LOCAL [REMOTE ...]");
            const local = resolveLocal(args[1]) catch {
                try c.err.print("znfsd: {s}: not [UID|USER][:GID|:GROUP] with known names\n", .{args[1]});
                return 2;
            };
            var lw: Io.Writer.Allocating = .init(c.arena);
            try local.format(&lw.writer);
            var remotes: std.ArrayList([]const u8) = .empty;
            for (args[2..]) |text| {
                const remote = exports.Ids.parse(text) catch {
                    try c.err.print("znfsd: {s}: not [UID][:GID] in numbers\n", .{text});
                    return 2;
                };
                if ((remote.uid == null or local.uid == null) and (remote.gid == null or local.gid == null)) {
                    try c.err.print("znfsd: {s}: maps nothing to {s}; pair UIDs with UIDs and GIDs with GIDs\n", .{ text, args[1] });
                    return 2;
                }
                var rw: Io.Writer.Allocating = .init(c.arena);
                try remote.format(&rw.writer);
                try remotes.append(c.arena, rw.written());
            }
            if (remotes.items.len == 0) {
                try c.db.putMapEntry(args[0], lw.written(), "");
            } else for (remotes.items) |r| try c.db.putMapEntry(args[0], lw.written(), r);
        },
        .del => {
            if (args.len < 1) return usage(c, "map del MAP [REMOTE ...]");
            var removed: usize = 0;
            if (args.len == 1) {
                removed = try c.db.deleteMapEntries(args[0], null);
            } else for (args[1..]) |text| {
                const remote = exports.Ids.parse(text) catch {
                    try c.err.print("znfsd: {s}: not [UID][:GID] in numbers\n", .{text});
                    return 2;
                };
                var rw: Io.Writer.Allocating = .init(c.arena);
                try remote.format(&rw.writer);
                removed += try c.db.deleteMapEntries(args[0], rw.written());
            }
            if (removed == 0) {
                try c.err.print("znfsd: no such map or entry\n", .{});
                return 1;
            }
        },
        .set => unreachable,
    }
    return 0;
}

/// `[UID|USER][:GID|:GROUP]`, with names looked up now.
pub fn resolveLocal(text: []const u8) error{BadId}!exports.Ids {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const user = text[0 .. colon orelse text.len];
    const group = if (colon) |i| text[i + 1 ..] else "";
    var ids: exports.Ids = .{};
    if (user.len > 0) ids.uid = std.fmt.parseInt(u32, user, 10) catch lookup: {
        var z: [256]u8 = undefined;
        if (user.len >= z.len) return error.BadId;
        @memcpy(z[0..user.len], user);
        z[user.len] = 0;
        const pw = std.c.getpwnam(z[0..user.len :0]) orelse return error.BadId;
        break :lookup pw.uid;
    };
    if (group.len > 0) ids.gid = std.fmt.parseInt(u32, group, 10) catch lookup: {
        var z: [256]u8 = undefined;
        if (group.len >= z.len) return error.BadId;
        @memcpy(z[0..group.len], group);
        z[group.len] = 0;
        const gr = std.c.getgrnam(z[0..group.len :0]) orelse return error.BadId;
        break :lookup gr.gid;
    };
    if (ids.uid == null and ids.gid == null) return error.BadId;
    return ids;
}

fn mountCommand(c: Context, verb: cli.Verb, args: []const []const u8) !u8 {
    switch (verb) {
        .list => {
            if (args.len > 1) return usage(c, "mount list [PATH]");
            var rows: std.ArrayList([2][]const u8) = .empty;
            for (try c.db.mounts(c.arena, if (args.len == 1) args[0] else null)) |m| try rows.append(c.arena, .{ m.host, m.path });
            try table(c.out, 2, rows.items);
        },
        .del => {
            if (args.len < 1 or args.len > 2) return usage(c, "mount del HOST [PATH]");
            if (try c.db.deleteMounts(args[0], if (args.len == 2) args[1] else null) == 0) {
                try c.err.print("znfsd: no such mount record\n", .{});
                return 1;
            }
        },
        .add, .set => unreachable,
    }
    return 0;
}

/// Prints rows in columns separated by two spaces.
pub fn table(out: *Io.Writer, comptime n: usize, rows: []const [n][]const u8) !void {
    var widths: [n]usize = @splat(0);
    for (rows) |row| for (row, &widths) |cell, *w| {
        w.* = @max(w.*, cell.len);
    };
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            try out.writeAll(cell);
            if (i + 1 < n) try out.splatByteAll(' ', widths[i] - cell.len + 2);
        }
        try out.writeByte('\n');
    }
}
