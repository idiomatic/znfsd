//! znfsd's state in SQLite: export rules, groups, and mount records.

const std = @import("std");
const builtin = @import("builtin");
const libnfsd = @import("libnfsd");
const exports = libnfsd.exports;

const sqlite = struct {
    const ok = 0;
    const row = 100;
    const done = 101;
    const open_readwrite = 0x02;
    const open_create = 0x04;
    const open_fullmutex = 0x10000;
    /// SQLITE_TRANSIENT: SQLite copies bound text.
    const transient: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

    extern fn sqlite3_open_v2(path: [*:0]const u8, db: *?*anyopaque, flags: c_int, vfs: ?[*:0]const u8) c_int;
    extern fn sqlite3_close_v2(db: ?*anyopaque) c_int;
    extern fn sqlite3_errmsg(db: ?*anyopaque) [*:0]const u8;
    extern fn sqlite3_exec(db: ?*anyopaque, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
    extern fn sqlite3_busy_timeout(db: ?*anyopaque, ms: c_int) c_int;
    extern fn sqlite3_changes(db: ?*anyopaque) c_int;
    extern fn sqlite3_prepare_v2(db: ?*anyopaque, sql: [*]const u8, len: c_int, stmt: *?*anyopaque, tail: ?*?[*]const u8) c_int;
    extern fn sqlite3_bind_text(stmt: ?*anyopaque, i: c_int, text: [*]const u8, len: c_int, destructor: ?*const anyopaque) c_int;
    extern fn sqlite3_bind_int64(stmt: ?*anyopaque, i: c_int, value: i64) c_int;
    extern fn sqlite3_step(stmt: ?*anyopaque) c_int;
    extern fn sqlite3_column_text(stmt: ?*anyopaque, i: c_int) ?[*]const u8;
    extern fn sqlite3_column_bytes(stmt: ?*anyopaque, i: c_int) c_int;
    extern fn sqlite3_column_int64(stmt: ?*anyopaque, i: c_int) i64;
    extern fn sqlite3_finalize(stmt: ?*anyopaque) c_int;
};

pub const Error = error{ Sqlite, OutOfMemory };

/// The schema's version, in `PRAGMA user_version`.
const schema_version = 3;
const schema =
    \\CREATE TABLE IF NOT EXISTS export_rules (
    \\  path TEXT NOT NULL,
    \\  client TEXT NOT NULL,
    \\  options TEXT NOT NULL,
    \\  PRIMARY KEY (path, client)
    \\);
    \\CREATE TABLE IF NOT EXISTS group_members (
    \\  name TEXT NOT NULL,
    \\  client TEXT NOT NULL,
    \\  PRIMARY KEY (name, client)
    \\);
    \\CREATE TABLE IF NOT EXISTS mounts (
    \\  host TEXT NOT NULL,
    \\  path TEXT NOT NULL,
    \\  PRIMARY KEY (host, path)
    \\);
    \\CREATE TABLE IF NOT EXISTS nsm (
    \\  id INTEGER PRIMARY KEY CHECK (id = 1),
    \\  state INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS monitors (
    \\  name TEXT PRIMARY KEY,
    \\  address TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS file_handles (
    \\  fsid TEXT NOT NULL,
    \\  inode INTEGER NOT NULL,
    \\  path TEXT NOT NULL,
    \\  PRIMARY KEY (fsid, inode)
    \\);
;

pub const Db = struct {
    handle: ?*anyopaque,
    /// The last error's message, for showing.
    message: [256]u8 = undefined,
    message_len: usize = 0,

    /// Opens or creates the database at `path`, in WAL mode with a busy
    /// timeout, and brings its schema up to date.
    pub fn open(path: [:0]const u8) Error!Db {
        var handle: ?*anyopaque = null;
        const rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.open_readwrite | sqlite.open_create | sqlite.open_fullmutex, null);
        var db: Db = .{ .handle = handle };
        if (rc != sqlite.ok) {
            db.remember();
            _ = sqlite.sqlite3_close_v2(handle);
            db.handle = null;
            return error.Sqlite;
        }
        errdefer db.close();
        _ = sqlite.sqlite3_busy_timeout(handle, 5000);
        try db.exec("PRAGMA journal_mode = WAL");
        try db.exec("PRAGMA foreign_keys = ON");
        try db.exec("BEGIN IMMEDIATE");
        try db.exec(schema);
        try db.exec(std.fmt.comptimePrint("PRAGMA user_version = {d}", .{schema_version}));
        try db.exec("COMMIT");
        return db;
    }

    pub fn close(db: *Db) void {
        _ = sqlite.sqlite3_close_v2(db.handle);
        db.handle = null;
    }

    pub fn errorMessage(db: *const Db) []const u8 {
        return db.message[0..db.message_len];
    }

    fn remember(db: *Db) void {
        const m = std.mem.span(sqlite.sqlite3_errmsg(db.handle));
        db.message_len = @min(m.len, db.message.len);
        @memcpy(db.message[0..db.message_len], m[0..db.message_len]);
    }

    pub fn exec(db: *Db, sql: [:0]const u8) Error!void {
        if (sqlite.sqlite3_exec(db.handle, sql, null, null, null) != sqlite.ok) {
            db.remember();
            return error.Sqlite;
        }
    }

    /// Runs `sql` with text parameters, ignoring any rows; returns how many
    /// rows it changed.
    pub fn run(db: *Db, sql: []const u8, params: []const []const u8) Error!usize {
        var stmt = try db.prepare(sql, params);
        defer stmt.finish();
        while (try stmt.next()) {}
        return @intCast(sqlite.sqlite3_changes(db.handle));
    }

    pub fn prepare(db: *Db, sql: []const u8, params: []const []const u8) Error!Stmt {
        var handle: ?*anyopaque = null;
        if (sqlite.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &handle, null) != sqlite.ok) {
            db.remember();
            return error.Sqlite;
        }
        const stmt: Stmt = .{ .db = db, .handle = handle };
        for (params, 1..) |p, i| {
            if (sqlite.sqlite3_bind_text(handle, @intCast(i), p.ptr, @intCast(p.len), sqlite.transient) != sqlite.ok) {
                db.remember();
                _ = sqlite.sqlite3_finalize(handle);
                return error.Sqlite;
            }
        }
        return stmt;
    }

    // Export rules.

    pub const StoredRule = struct { path: []const u8, client: []const u8, options: []const u8 };

    pub fn rules(db: *Db, arena: std.mem.Allocator, path: ?[]const u8) Error![]StoredRule {
        var stmt = if (path) |p|
            try db.prepare("SELECT path, client, options FROM export_rules WHERE path = ?1 ORDER BY path, client", &.{p})
        else
            try db.prepare("SELECT path, client, options FROM export_rules ORDER BY path, client", &.{});
        defer stmt.finish();
        var out: std.ArrayList(StoredRule) = .empty;
        while (try stmt.next()) {
            try out.append(arena, .{
                .path = try arena.dupe(u8, stmt.text(0)),
                .client = try arena.dupe(u8, stmt.text(1)),
                .options = try arena.dupe(u8, stmt.text(2)),
            });
        }
        return out.items;
    }

    /// The options of the rule for `path` and `client`, if there is one.
    pub fn ruleOptions(db: *Db, arena: std.mem.Allocator, path: []const u8, client: []const u8) Error!?[]const u8 {
        var stmt = try db.prepare("SELECT options FROM export_rules WHERE path = ?1 AND client = ?2", &.{ path, client });
        defer stmt.finish();
        if (!try stmt.next()) return null;
        return try arena.dupe(u8, stmt.text(0));
    }

    pub fn putRule(db: *Db, path: []const u8, client: []const u8, options: []const u8) Error!void {
        _ = try db.run("INSERT INTO export_rules (path, client, options) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT (path, client) DO UPDATE SET options = excluded.options", &.{ path, client, options });
    }

    pub fn deleteRules(db: *Db, path: []const u8, client: ?[]const u8) Error!usize {
        if (client) |c| return db.run("DELETE FROM export_rules WHERE path = ?1 AND client = ?2", &.{ path, c });
        return db.run("DELETE FROM export_rules WHERE path = ?1", &.{path});
    }

    // Groups.

    pub const Member = struct { name: []const u8, client: []const u8 };

    pub fn members(db: *Db, arena: std.mem.Allocator, name: ?[]const u8) Error![]Member {
        var stmt = if (name) |n|
            try db.prepare("SELECT name, client FROM group_members WHERE name = ?1 ORDER BY name, client", &.{n})
        else
            try db.prepare("SELECT name, client FROM group_members ORDER BY name, client", &.{});
        defer stmt.finish();
        var out: std.ArrayList(Member) = .empty;
        while (try stmt.next()) {
            try out.append(arena, .{ .name = try arena.dupe(u8, stmt.text(0)), .client = try arena.dupe(u8, stmt.text(1)) });
        }
        return out.items;
    }

    pub fn addMember(db: *Db, name: []const u8, client: []const u8) Error!void {
        _ = try db.run("INSERT OR IGNORE INTO group_members (name, client) VALUES (?1, ?2)", &.{ name, client });
    }

    pub fn deleteMembers(db: *Db, name: []const u8, client: ?[]const u8) Error!usize {
        if (client) |c| return db.run("DELETE FROM group_members WHERE name = ?1 AND client = ?2", &.{ name, c });
        return db.run("DELETE FROM group_members WHERE name = ?1", &.{name});
    }

    // Mount records.

    pub const Mount = struct { host: []const u8, path: []const u8 };

    pub fn mounts(db: *Db, arena: std.mem.Allocator, path: ?[]const u8) Error![]Mount {
        var stmt = if (path) |p|
            try db.prepare("SELECT host, path FROM mounts WHERE path = ?1 ORDER BY path, host", &.{p})
        else
            try db.prepare("SELECT host, path FROM mounts ORDER BY path, host", &.{});
        defer stmt.finish();
        var out: std.ArrayList(Mount) = .empty;
        while (try stmt.next()) {
            try out.append(arena, .{ .host = try arena.dupe(u8, stmt.text(0)), .path = try arena.dupe(u8, stmt.text(1)) });
        }
        return out.items;
    }

    pub fn addMount(db: *Db, host: []const u8, path: []const u8) Error!void {
        _ = try db.run("INSERT OR IGNORE INTO mounts (host, path) VALUES (?1, ?2)", &.{ host, path });
    }

    /// Keeps MOUNT's records here, so `mount list` shows them and they
    /// survive restarts. Failures can't reach the client, so they're dropped.
    pub fn mountStore(db: *Db) libnfsd.mount.Store {
        const S = struct {
            fn mounted(ptr: *anyopaque, host: []const u8, path: []const u8) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                d.addMount(host, path) catch {};
            }
            fn unmounted(ptr: *anyopaque, host: []const u8, path: ?[]const u8) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                _ = d.deleteMounts(host, path) catch {};
            }
        };
        return .{ .ptr = db, .mounted = S.mounted, .unmounted = S.unmounted };
    }

    pub fn deleteMounts(db: *Db, host: []const u8, path: ?[]const u8) Error!usize {
        if (path) |p| return db.run("DELETE FROM mounts WHERE host = ?1 AND path = ?2", &.{ host, p });
        return db.run("DELETE FROM mounts WHERE host = ?1", &.{host});
    }

    // File handles' last-known paths.

    /// Keeps the path cache's entries here, so handles survive restarts.
    /// Failures only lose that, so they're dropped.
    pub fn filesStore(db: *Db) libnfsd.files.Store {
        const S = struct {
            fn keys(fsid: [16]u8, inode: u64, fsid_hex: *[32]u8, inode_buf: *[20]u8) [2][]const u8 {
                fsid_hex.* = std.fmt.bytesToHex(fsid, .lower);
                return .{ fsid_hex, std.fmt.bufPrint(inode_buf, "{d}", .{inode}) catch unreachable };
            }
            fn remember(ptr: *anyopaque, fsid: [16]u8, inode: u64, path: []const u8) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                var hex: [32]u8 = undefined;
                var ino: [20]u8 = undefined;
                const k = keys(fsid, inode, &hex, &ino);
                _ = d.run("INSERT INTO file_handles (fsid, inode, path) VALUES (?1, ?2, ?3) " ++
                    "ON CONFLICT (fsid, inode) DO UPDATE SET path = excluded.path", &.{ k[0], k[1], path }) catch {};
            }
            fn lookup(ptr: *anyopaque, fsid: [16]u8, inode: u64, out: []u8) ?usize {
                const d: *Db = @ptrCast(@alignCast(ptr));
                var hex: [32]u8 = undefined;
                var ino: [20]u8 = undefined;
                const k = keys(fsid, inode, &hex, &ino);
                var stmt = d.prepare("SELECT path FROM file_handles WHERE fsid = ?1 AND inode = ?2", &k) catch return null;
                defer stmt.finish();
                if (!(stmt.next() catch return null)) return null;
                const p = stmt.text(0);
                if (p.len > out.len) return null;
                @memcpy(out[0..p.len], p);
                return p.len;
            }
            fn renamePrefix(ptr: *anyopaque, old: []const u8, new: []const u8) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                _ = d.run("UPDATE file_handles SET path = ?2 || substr(path, length(?1) + 1) " ++
                    "WHERE substr(path, 1, length(?1) + 1) = ?1 || '/'", &.{ old, new }) catch {};
            }
        };
        return .{ .ptr = db, .remember = S.remember, .lookup = S.lookup, .renamePrefix = S.renamePrefix };
    }

    // The status monitor.

    /// Advances and stores the NSM state number, as at each start.
    pub fn advanceNsmState(db: *Db) Error!u32 {
        var previous: u32 = 0;
        {
            var stmt = try db.prepare("SELECT state FROM nsm WHERE id = 1", &.{});
            defer stmt.finish();
            if (try stmt.next()) previous = @truncate(@as(u64, @bitCast(stmt.int(0))));
        }
        const state = libnfsd.nsm.nextState(previous);
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{state}) catch unreachable;
        _ = try db.run("INSERT INTO nsm (id, state) VALUES (1, ?1) ON CONFLICT (id) DO UPDATE SET state = excluded.state", &.{text});
        return state;
    }

    pub fn monitors(db: *Db, arena: std.mem.Allocator) Error![]libnfsd.nsm.Host {
        var stmt = try db.prepare("SELECT name, address FROM monitors ORDER BY name", &.{});
        defer stmt.finish();
        var out: std.ArrayList(libnfsd.nsm.Host) = .empty;
        while (try stmt.next()) {
            try out.append(arena, .{ .name = try arena.dupe(u8, stmt.text(0)), .address = try arena.dupe(u8, stmt.text(1)) });
        }
        return out.items;
    }

    pub fn deleteMonitor(db: *Db, name: []const u8) Error!void {
        _ = try db.run("DELETE FROM monitors WHERE name = ?1", &.{name});
    }

    /// Keeps NSM's monitored hosts here, for notifying after a restart.
    pub fn nsmStore(db: *Db) libnfsd.nsm.Store {
        const S = struct {
            fn monitor(ptr: *anyopaque, host: libnfsd.nsm.Host) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                _ = d.run("INSERT INTO monitors (name, address) VALUES (?1, ?2) " ++
                    "ON CONFLICT (name) DO UPDATE SET address = excluded.address", &.{ host.name, host.address }) catch {};
            }
            fn unmonitor(ptr: *anyopaque, name: []const u8) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                d.deleteMonitor(name) catch {};
            }
        };
        return .{ .ptr = db, .monitor = S.monitor, .unmonitor = S.unmonitor };
    }

    /// Builds an export table from the stored rules and groups.
    pub fn table(db: *Db, arena: std.mem.Allocator) (Error || exports.Client.ParseError || exports.Options.ParseError)!Loaded {
        var loaded: Loaded = .{};
        for (try db.members(arena, null)) |m| {
            const gop = try loaded.groups.getOrPut(arena, m.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, try .parse(m.client));
        }
        for (try db.rules(arena, null)) |r| {
            try loaded.rules.append(arena, .{
                .path = r.path,
                .client = try .parse(r.client),
                .options = try parseOptions(r.options),
            });
        }
        return loaded;
    }
};

/// Stored rules and groups, before ephemeral ones are laid over them.
pub const Loaded = struct {
    rules: std.ArrayList(exports.Rule) = .empty,
    groups: std.StringHashMapUnmanaged(std.ArrayList(exports.Client)) = .empty,
};

pub const Stmt = struct {
    db: *Db,
    handle: ?*anyopaque,

    /// Steps to the next row; false when there are no more.
    pub fn next(s: *Stmt) Error!bool {
        return switch (sqlite.sqlite3_step(s.handle)) {
            sqlite.row => true,
            sqlite.done => false,
            else => {
                s.db.remember();
                return error.Sqlite;
            },
        };
    }

    pub fn text(s: *Stmt, i: c_int) []const u8 {
        const p = sqlite.sqlite3_column_text(s.handle, i) orelse return "";
        return p[0..@intCast(sqlite.sqlite3_column_bytes(s.handle, i))];
    }

    pub fn int(s: *Stmt, i: c_int) i64 {
        return sqlite.sqlite3_column_int64(s.handle, i);
    }

    pub fn finish(s: *Stmt) void {
        _ = sqlite.sqlite3_finalize(s.handle);
    }
};

/// Parses stored or given `OPTION` words, comma- or space-separated.
pub fn parseOptions(text: []const u8) exports.Options.ParseError!exports.Options {
    var o: exports.Options = .{};
    var words = std.mem.tokenizeAny(u8, text, ", ");
    while (words.next()) |w| try o.apply(w);
    return o;
}

/// Writes options as stored and listed: every option, defaults included.
pub fn formatOptions(o: exports.Options, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{s},squash={t}", .{ if (o.read_only) "ro" else "rw", o.squash });
    if (o.map) |m| try w.print(",map={s}", .{m});
}

/// The default database path: per the user unless root, per the OS.
pub fn defaultPath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map, root: bool) error{ OutOfMemory, NoHome }![:0]const u8 {
    const mac = builtin.os.tag.isDarwin();
    if (root) return if (mac) "/var/db/znfsd/znfsd.db" else "/var/lib/znfsd/znfsd.db";
    const home = environ.get("HOME") orelse return error.NoHome;
    if (mac) return std.fmt.allocPrintSentinel(arena, "{s}/Library/Application Support/znfsd/znfsd.db", .{home}, 0);
    if (environ.get("XDG_STATE_HOME")) |state| return std.fmt.allocPrintSentinel(arena, "{s}/znfsd/znfsd.db", .{state}, 0);
    return std.fmt.allocPrintSentinel(arena, "{s}/.local/state/znfsd/znfsd.db", .{home}, 0);
}

const testing = std.testing;

test "store, merge, list, and delete rules and groups" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [libnfsd.sys.max_path]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/znfsd.db", .{dir}, 0);
    defer testing.allocator.free(path);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db: Db = try .open(path);
    defer db.close();
    try db.putRule("/srv", "*", "ro,squash=root");
    try db.putRule("/srv", "@lab", "rw,squash=none");
    try db.putRule("/srv", "@lab", "rw,squash=all");
    try db.addMember("lab", "10.1.0.0/16");
    try db.addMember("lab", "10.1.0.0/16");
    try testing.expectEqual(2, (try db.rules(arena, "/srv")).len);
    try testing.expectEqualStrings("rw,squash=all", (try db.ruleOptions(arena, "/srv", "@lab")).?);
    try testing.expectEqual(1, (try db.members(arena, "lab")).len);

    const loaded = try db.table(arena);
    try testing.expectEqual(2, loaded.rules.items.len);
    try testing.expectEqual(1, loaded.groups.get("lab").?.items.len);

    // Reopening finds the same state.
    db.close();
    db = try .open(path);
    try testing.expectEqual(1, try db.deleteRules("/srv", "*"));
    try testing.expectEqual(1, (try db.rules(arena, null)).len);
    try testing.expectEqual(1, try db.deleteMembers("lab", null));
}

test "NSM state numbers advance and stay odd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [libnfsd.sys.max_path]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/znfsd.db", .{dir}, 0);
    defer testing.allocator.free(path);
    var db: Db = try .open(path);
    defer db.close();
    try testing.expectEqual(1, try db.advanceNsmState());
    try testing.expectEqual(3, try db.advanceNsmState());
    const store = db.nsmStore();
    store.monitor(store.ptr, .{ .name = "art", .address = "192.168.213.11" });
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("192.168.213.11", (try db.monitors(arena_state.allocator()))[0].address);
    store.unmonitor(store.ptr, "art");
    try testing.expectEqual(0, (try db.monitors(arena_state.allocator())).len);
}

test "file handle paths persist and move with renamed directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [libnfsd.sys.max_path]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/znfsd.db", .{dir}, 0);
    defer testing.allocator.free(path);
    var db: Db = try .open(path);
    defer db.close();
    const s = db.filesStore();
    const fsid: [16]u8 = @splat(7);
    s.remember(s.ptr, fsid, 42, "/srv/a/b");
    s.remember(s.ptr, fsid, 43, "/srv/ab");
    s.renamePrefix(s.ptr, "/srv/a", "/srv/z");
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("/srv/z/b", out[0..s.lookup(s.ptr, fsid, 42, &out).?]);
    try testing.expectEqualStrings("/srv/ab", out[0..s.lookup(s.ptr, fsid, 43, &out).?]);
    try testing.expectEqual(null, s.lookup(s.ptr, fsid, 44, &out));
}

test "options round trip" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatOptions(try parseOptions("ro map=art"), &w);
    try testing.expectEqualStrings("ro,squash=root,map=art", w.buffered());
    try testing.expectError(error.UnknownOption, parseOptions("rw,skynet"));
}
