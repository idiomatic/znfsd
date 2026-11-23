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
    /// What a running daemon serves beyond the database.
    ephemera: Ephemera = .{},
};

/// A running daemon's ephemeral maps and rules, which stored rules may
/// name and which may name stored maps.
pub const Ephemera = struct {
    maps: []const []const u8 = &.{},
    rules: []const exports.Rule = &.{},
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
    const parsed = exports.Client.parse(text) catch {
        try c.err.print("znfsd: {s}: not a host, *.domain, CIDR, @group, or *\n", .{text});
        return null;
    };
    if (parsed.needsName()) {
        try c.err.print("znfsd: {s}: host names aren't matched yet; use an address, CIDR, @group, or *\n", .{text});
        return null;
    }
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
            if (options.map) |m| if (!try mapExists(c, m)) {
                try c.err.print("znfsd: map={s}: no such map; add it with map add\n", .{m});
                return 1;
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
            var remotes: std.ArrayList([]const u8) = .empty;
            for (args[1..]) |text| {
                const remote = exports.Ids.parse(text) catch {
                    try c.err.print("znfsd: {s}: not [UID][:GID] in numbers\n", .{text});
                    return 2;
                };
                var rw: Io.Writer.Allocating = .init(c.arena);
                try remote.format(&rw.writer);
                try remotes.append(c.arena, rw.written());
            }
            // A map with no entries left is gone, so rules mustn't name it.
            const left = for (try c.db.mapEntries(c.arena, args[0])) |e| {
                if (args.len > 1 and !contains(remotes.items, e.remote)) break true;
            } else false;
            if (!left) if (try mapUser(c, args[0])) |path| {
                try c.err.print("znfsd: map {s}: {s} uses it; change or delete its rules first\n", .{ args[0], path });
                return 1;
            };
            var removed: usize = 0;
            if (args.len == 1) {
                removed = try c.db.deleteMapEntries(args[0], null);
            } else for (remotes.items) |r| {
                removed += try c.db.deleteMapEntries(args[0], r);
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

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

/// Whether map `name` exists: stored, or the running daemon's own.
fn mapExists(c: Context, name: []const u8) !bool {
    if (contains(c.ephemera.maps, name)) return true;
    return (try c.db.mapEntries(c.arena, name)).len > 0;
}

/// The path of a rule that needs stored map `name`: any stored rule naming
/// it, or a running daemon's ephemeral one unless its own map shadows it.
fn mapUser(c: Context, name: []const u8) !?[]const u8 {
    for (try c.db.rules(c.arena, null)) |r| {
        const options = dbm.parseOptions(r.options) catch continue;
        if (options.map) |m| if (std.mem.eql(u8, m, name)) return r.path;
    }
    if (contains(c.ephemera.maps, name)) return null;
    for (c.ephemera.rules) |r| if (r.options.map) |m| {
        if (std.mem.eql(u8, m, name)) return r.path;
    };
    return null;
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
            // Its statd monitor goes too; a running daemon then forgets it
            // in memory.
            try c.db.forgetMonitors(args[0]);
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

const testing = std.testing;

/// A scratch database and a context writing to discarded buffers.
const Scratch = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    db: Db,
    dir: []const u8,
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,

    fn init(s: *Scratch) !void {
        s.tmp = testing.tmpDir(.{});
        s.arena = .init(testing.allocator);
        const arena = s.arena.allocator();
        var buf: [libnfsd.sys.max_path]u8 = undefined;
        s.dir = try arena.dupe(u8, buf[0..try s.tmp.dir.realPath(testing.io, &buf)]);
        s.db = try .open(try std.fmt.allocPrintSentinel(arena, "{s}/znfsd.db", .{s.dir}, 0));
        s.out = .init(arena);
        s.err = .init(arena);
    }

    fn deinit(s: *Scratch) void {
        s.db.close();
        s.arena.deinit();
        s.tmp.cleanup();
    }

    fn context(s: *Scratch) Context {
        return .{ .db = &s.db, .arena = s.arena.allocator(), .out = &s.out.writer, .err = &s.err.writer };
    }
};

test "rules name only maps that exist, and maps in use stay" {
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const c = s.context();
    try testing.expectEqual(1, try run(c, .@"export", .add, &.{ s.dir, "*", "map=art" }));
    try testing.expectEqual(0, try run(c, .map, .add, &.{ "art", "501", "1000" }));
    try testing.expectEqual(0, try run(c, .@"export", .add, &.{ s.dir, "*", "map=art" }));
    try testing.expectEqual(1, try run(c, .map, .del, &.{"art"}));
    // Deleting its last entry would delete the map.
    try testing.expectEqual(1, try run(c, .map, .del, &.{ "art", "1000" }));
    try testing.expectEqual(0, try run(c, .map, .add, &.{ "art", "501", "1001" }));
    try testing.expectEqual(0, try run(c, .map, .del, &.{ "art", "1000" }));
    try testing.expectEqual(0, try run(c, .@"export", .del, &.{s.dir}));
    try testing.expectEqual(0, try run(c, .map, .del, &.{"art"}));

    // A running daemon's own maps count, and its rules keep stored maps.
    var live = c;
    const rule: exports.Rule = .{ .path = "/srv", .client = .any, .options = .{ .map = "hal" } };
    live.ephemera = .{ .maps = &.{"perihelion"}, .rules = &.{rule} };
    try testing.expectEqual(0, try run(live, .@"export", .add, &.{ s.dir, "*", "map=perihelion" }));
    try testing.expectEqual(0, try run(live, .map, .add, &.{ "hal", "501" }));
    try testing.expectEqual(1, try run(live, .map, .del, &.{"hal"}));
}

test "mount del forgets the host's monitor, by name or address" {
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const c = s.context();
    const store = s.db.nsmStore();
    store.monitor(store.ptr, .{ .name = "art", .address = "192.168.213.11" });
    store.monitor(store.ptr, .{ .name = "hal", .address = "192.168.213.12" });
    try s.db.addMount("art", "/srv");
    try s.db.addMount("192.168.213.12", "/srv");
    try testing.expectEqual(0, try run(c, .mount, .del, &.{"art"}));
    try testing.expectEqual(0, try run(c, .mount, .del, &.{ "192.168.213.12", "/srv" }));
    try testing.expectEqual(0, (try s.db.monitors(c.arena)).len);
}
