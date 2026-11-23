//! znfsd's state in SQLite: export rules, groups, maps, mount records,
//! file handles' paths, and the status monitor's hosts and state number.

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

/// The schema's version, in `PRAGMA user_version`. Version 5 keys rules
/// and group members by `clientKey`.
const schema_version = 5;
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
    \\CREATE TABLE IF NOT EXISTS map_entries (
    \\  name TEXT NOT NULL,
    \\  local TEXT NOT NULL,
    \\  remote TEXT NOT NULL,
    \\  PRIMARY KEY (name, remote)
    \\);
    \\CREATE TABLE IF NOT EXISTS file_handles (
    \\  fsid TEXT NOT NULL,
    \\  inode INTEGER NOT NULL,
    \\  path TEXT NOT NULL,
    \\  PRIMARY KEY (fsid, inode)
    \\);
;

/// Whether this thread holds `Db.batch_mutex`, inside a transaction.
threadlocal var in_batch = false;

pub const Db = struct {
    handle: ?*anyopaque,
    /// Set by the daemon, for `batch_mutex`.
    io: ?std.Io = null,
    /// Keeps batched writes' transactions from nesting: the connection is
    /// shared by every request.
    batch_mutex: std.Io.Mutex = .init,
    /// Where the database is, for --run-as to hand it over.
    path: []const u8 = "",
    /// The last error's message, for showing.
    message: [256]u8 = undefined,
    message_len: usize = 0,

    /// Opens or creates the database at `path`, in WAL mode with a busy
    /// timeout, and brings its schema up to date.
    pub fn open(path: [:0]const u8) Error!Db {
        var handle: ?*anyopaque = null;
        const rc = sqlite.sqlite3_open_v2(path, &handle, sqlite.open_readwrite | sqlite.open_create | sqlite.open_fullmutex, null);
        var db: Db = .{ .handle = handle, .path = path };
        if (rc != sqlite.ok) {
            db.remember();
            _ = sqlite.sqlite3_close_v2(handle);
            db.handle = null;
            return error.Sqlite;
        }
        errdefer db.close();
        _ = sqlite.sqlite3_busy_timeout(handle, 5000);
        try db.exec("PRAGMA journal_mode = WAL");
        // WAL syncs at checkpoints, not each commit: a power loss can drop
        // the last commits, never corrupt, and the file-handle cache writes
        // on every first lookup. The NSM state number is checkpointed.
        try db.exec("PRAGMA synchronous = NORMAL");
        try db.exec("PRAGMA foreign_keys = ON");
        try db.exec("BEGIN IMMEDIATE");
        const version = try db.userVersion();
        try db.exec(schema);
        if (version < 5) {
            try db.canonicalizeClients("export_rules", "path");
            try db.canonicalizeClients("group_members", "name");
        }
        try db.exec(std.fmt.comptimePrint("PRAGMA user_version = {d}", .{schema_version}));
        try db.exec("COMMIT");
        return db;
    }

    fn userVersion(db: *Db) Error!i64 {
        var stmt = try db.prepare("PRAGMA user_version", &.{});
        defer stmt.finish();
        return if (try stmt.next()) stmt.int(0) else 0;
    }

    /// Rekeys `table`'s rows by `clientKey`; where two rows meet, the one
    /// already canonical stays.
    fn canonicalizeClients(db: *Db, comptime table_name: []const u8, comptime key: []const u8) Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const Row = struct { key: []const u8, client: []const u8 };
        var rows: std.ArrayList(Row) = .empty;
        {
            var stmt = try db.prepare("SELECT " ++ key ++ ", client FROM " ++ table_name, &.{});
            defer stmt.finish();
            while (try stmt.next()) try rows.append(arena, .{
                .key = try arena.dupe(u8, stmt.text(0)),
                .client = try arena.dupe(u8, stmt.text(1)),
            });
        }
        for (rows.items) |r| {
            const canonical = try clientKey(arena, r.client);
            if (std.mem.eql(u8, canonical, r.client)) continue;
            _ = try db.run("UPDATE OR IGNORE " ++ table_name ++ " SET client = ?3 WHERE " ++ key ++ " = ?1 AND client = ?2", &.{ r.key, r.client, canonical });
            _ = try db.run("DELETE FROM " ++ table_name ++ " WHERE " ++ key ++ " = ?1 AND client = ?2", &.{ r.key, r.client });
        }
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
        // Writes wait for any batch's transaction, so a batch's rollback
        // can't undo another thread's write; the batch itself runs on.
        const io = db.io;
        const wait = io != null and !in_batch;
        if (wait) db.batch_mutex.lockUncancelable(io.?);
        defer if (wait) db.batch_mutex.unlock(io.?);
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

    // Maps. Each row is one client ID, or with `remote` empty, the anon.

    pub const StoredMapEntry = struct { name: []const u8, local: []const u8, remote: []const u8 };

    pub fn mapEntries(db: *Db, arena: std.mem.Allocator, name: ?[]const u8) Error![]StoredMapEntry {
        var stmt = if (name) |n|
            try db.prepare("SELECT name, local, remote FROM map_entries WHERE name = ?1 ORDER BY name, remote", &.{n})
        else
            try db.prepare("SELECT name, local, remote FROM map_entries ORDER BY name, remote", &.{});
        defer stmt.finish();
        var out: std.ArrayList(StoredMapEntry) = .empty;
        while (try stmt.next()) {
            try out.append(arena, .{
                .name = try arena.dupe(u8, stmt.text(0)),
                .local = try arena.dupe(u8, stmt.text(1)),
                .remote = try arena.dupe(u8, stmt.text(2)),
            });
        }
        return out.items;
    }

    /// Adds or replaces the entry for `remote` ("" for the anon).
    pub fn putMapEntry(db: *Db, name: []const u8, local: []const u8, remote: []const u8) Error!void {
        _ = try db.run("INSERT INTO map_entries (name, local, remote) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT (name, remote) DO UPDATE SET local = excluded.local", &.{ name, local, remote });
    }

    pub fn deleteMapEntries(db: *Db, name: []const u8, remote: ?[]const u8) Error!usize {
        if (remote) |r| return db.run("DELETE FROM map_entries WHERE name = ?1 AND remote = ?2", &.{ name, r });
        return db.run("DELETE FROM map_entries WHERE name = ?1", &.{name});
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
            fn unmounted(ptr: *anyopaque, host: []const u8, path: []const u8) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                _ = d.deleteMount(host, path) catch {};
            }
            fn unmountedAll(ptr: *anyopaque, host: []const u8) void {
                const d: *Db = @ptrCast(@alignCast(ptr));
                _ = d.deleteHostMounts(host) catch {};
            }
        };
        return .{ .ptr = db, .mounted = S.mounted, .unmounted = S.unmounted, .unmountedAll = S.unmountedAll };
    }

    pub fn deleteMount(db: *Db, host: []const u8, path: []const u8) Error!usize {
        return db.run("DELETE FROM mounts WHERE host = ?1 AND path = ?2", &.{ host, path });
    }

    pub fn deleteHostMounts(db: *Db, host: []const u8) Error!usize {
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
        return .{ .ptr = db, .remember = S.remember, .rememberMany = rememberMany, .lookup = S.lookup, .renamePrefix = S.renamePrefix };
    }

    /// Stores many paths in one transaction.
    fn rememberMany(ptr: *anyopaque, entries: []const libnfsd.files.Entry) void {
        const d: *Db = @ptrCast(@alignCast(ptr));
        const io = d.io orelse {
            const store = d.filesStore();
            for (entries) |e| store.remember(d, e.fsid, e.inode, e.path);
            return;
        };
        d.batch_mutex.lockUncancelable(io);
        defer d.batch_mutex.unlock(io);
        in_batch = true;
        defer in_batch = false;
        d.exec("BEGIN IMMEDIATE") catch return;
        for (entries) |e| {
            var hex: [32]u8 = std.fmt.bytesToHex(e.fsid, .lower);
            var ino: [20]u8 = undefined;
            const inode = std.fmt.bufPrint(&ino, "{d}", .{e.inode}) catch unreachable;
            _ = d.run("INSERT INTO file_handles (fsid, inode, path) VALUES (?1, ?2, ?3) " ++
                "ON CONFLICT (fsid, inode) DO UPDATE SET path = excluded.path", &.{ &hex, inode, e.path }) catch {
                d.exec("ROLLBACK") catch {};
                return;
            };
        }
        d.exec("COMMIT") catch d.exec("ROLLBACK") catch {};
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
        // A repeated state number would make clients ignore our restart.
        try db.exec("PRAGMA wal_checkpoint(FULL)");
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

    /// Stops monitoring hosts named `key`, or at address `key`, as
    /// `Nsm.forget` does in a running daemon.
    pub fn forgetMonitors(db: *Db, key: []const u8) Error!void {
        _ = try db.run("DELETE FROM monitors WHERE name = ?1 OR address = ?1", &.{key});
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

    /// Builds an export table from the stored rules, groups, and maps.
    pub fn table(db: *Db, arena: std.mem.Allocator) (Error || exports.Client.ParseError || exports.Options.ParseError || error{BadMap})!Loaded {
        var loaded: Loaded = .{};
        for (try db.members(arena, null)) |m| {
            const gop = try loaded.groups.getOrPut(arena, m.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, try .parse(m.client));
        }
        for (try db.mapEntries(arena, null)) |m| {
            const gop = try loaded.maps.getOrPut(arena, m.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{
                .local = exports.Ids.parse(m.local) catch return error.BadMap,
                .remote = if (m.remote.len == 0) null else exports.Ids.parse(m.remote) catch return error.BadMap,
            });
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

/// Stored rules, groups, and maps, before ephemeral ones are laid over them.
pub const Loaded = struct {
    rules: std.ArrayList(exports.Rule) = .empty,
    groups: std.StringHashMapUnmanaged(std.ArrayList(exports.Client)) = .empty,
    maps: std.StringHashMapUnmanaged(std.ArrayList(exports.MapEntry)) = .empty,
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

/// A client as stored, so each is one key however it's written:
/// `Client.format`'s form, or the text as given if it doesn't parse.
pub fn clientKey(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    const parsed = exports.Client.parse(text) catch return text;
    var w: std.Io.Writer.Allocating = .init(arena);
    parsed.format(&w.writer) catch return error.OutOfMemory;
    return w.written();
}

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

    // Many at once, in one transaction.
    db.io = testing.io;
    const many = [_]libnfsd.files.Entry{
        .{ .fsid = fsid, .inode = 50, .path = "/srv/x" },
        .{ .fsid = fsid, .inode = 42, .path = "/srv/moved" },
    };
    s.rememberMany.?(s.ptr, &many);
    try testing.expectEqualStrings("/srv/x", out[0..s.lookup(s.ptr, fsid, 50, &out).?]);
    try testing.expectEqualStrings("/srv/moved", out[0..s.lookup(s.ptr, fsid, 42, &out).?]);
}

test "options round trip" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatOptions(try parseOptions("ro map=art"), &w);
    try testing.expectEqualStrings("ro,squash=root,map=art", w.buffered());
    try testing.expectError(error.UnknownOption, parseOptions("rw,skynet"));
}

test "clients are keyed canonically, and older rows rekeyed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [libnfsd.sys.max_path]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/znfsd.db", .{dir}, 0);
    defer testing.allocator.free(path);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("10.0.0.1", try clientKey(arena, "::ffff:10.0.0.1"));
    try testing.expectEqualStrings("10.0.0.1", try clientKey(arena, "10.0.0.1/32"));
    try testing.expectEqualStrings("fd00::/8", try clientKey(arena, "fd00:0::/8"));

    // A version 4 database, keyed as typed.
    var db: Db = try .open(path);
    try db.putRule("/srv", "10.0.0.1/32", "ro,squash=root");
    try db.putRule("/srv", "10.0.0.1", "rw,squash=root");
    try db.putRule("/srv", "::ffff:10.0.0.2", "rw,squash=all");
    try db.addMember("lab", "10.1.0.0/16");
    try db.addMember("lab", "::ffff:10.1.0.0/112");
    try db.exec("PRAGMA user_version = 4");
    db.close();

    db = try .open(path);
    defer db.close();
    const rules_ = try db.rules(arena, null);
    try testing.expectEqual(2, rules_.len);
    try testing.expectEqualStrings("10.0.0.1", rules_[0].client);
    try testing.expectEqualStrings("rw,squash=root", rules_[0].options);
    try testing.expectEqualStrings("10.0.0.2", rules_[1].client);
    const lab = try db.members(arena, "lab");
    try testing.expectEqual(1, lab.len);
    try testing.expectEqualStrings("10.1.0.0/16", lab[0].client);
}
