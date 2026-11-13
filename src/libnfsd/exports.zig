//! Export rules: which clients may mount which paths, and how.

const std = @import("std");
const net = std.Io.net;

pub const Squash = enum { root, all, none };

pub const Options = struct {
    read_only: bool = false,
    squash: Squash = .root,
    /// Name of a map, or null for none.
    map: ?[]const u8 = null,

    pub const ParseError = error{UnknownOption};

    /// Applies one `OPTION` word (`rw`, `ro`, `squash=...`, `map=NAME`).
    pub fn apply(o: *Options, word: []const u8) ParseError!void {
        if (std.mem.eql(u8, word, "rw")) {
            o.read_only = false;
        } else if (std.mem.eql(u8, word, "ro")) {
            o.read_only = true;
        } else if (std.mem.startsWith(u8, word, "squash=")) {
            o.squash = std.meta.stringToEnum(Squash, word["squash=".len..]) orelse return error.UnknownOption;
        } else if (std.mem.startsWith(u8, word, "map=") and word.len > "map=".len) {
            o.map = word["map=".len..];
        } else {
            return error.UnknownOption;
        }
    }
};

/// Which clients a rule covers.
pub const Client = union(enum) {
    host: []const u8,
    /// `*.example.com`, stored as `.example.com`.
    domain: []const u8,
    cidr: Cidr,
    group: []const u8,
    any,

    pub const ParseError = error{BadClient};

    pub fn parse(text: []const u8) ParseError!Client {
        if (text.len == 0) return error.BadClient;
        if (std.mem.eql(u8, text, "*")) return .any;
        if (text[0] == '@') {
            if (text.len == 1) return error.BadClient;
            return .{ .group = text[1..] };
        }
        if (std.mem.startsWith(u8, text, "*.")) {
            if (text.len == 2) return error.BadClient;
            return .{ .domain = text[1..] };
        }
        if (std.mem.indexOfScalar(u8, text, '/') != null) return .{ .cidr = try .parse(text) };
        if (net.IpAddress.parse(text, 0)) |address| {
            return .{ .cidr = .{ .address = normalize(address), .prefix = if (address == .ip4) 32 else 128 } };
        } else |_| {}
        return .{ .host = text };
    }

    /// Writes the client as written in a rule.
    pub fn format(c: Client, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (c) {
            .any => try w.writeByte('*'),
            .host => |h| try w.writeAll(h),
            .domain => |d| try w.print("*{s}", .{d}),
            .group => |g| try w.print("@{s}", .{g}),
            .cidr => |r| try r.format(w),
        }
    }

    /// How specific a match is: higher wins. Exact hosts beat CIDRs,
    /// longer prefixes and suffixes beat shorter ones, then groups, then `*`.
    fn rank(c: Client) u32 {
        return switch (c) {
            .host => 4 << 16,
            .cidr => |r| if (r.prefix == r.bits()) 4 << 16 else (3 << 16) + @as(u32, r.prefix),
            .domain => |d| (2 << 16) + @as(u32, @intCast(d.len)),
            .group => 1 << 16,
            .any => 0,
        };
    }

    /// Whether `peer`, whose name is `name` when known, matches. Groups match
    /// through `groups`; group members can't be groups.
    fn matches(c: Client, peer: net.IpAddress, name: ?[]const u8, groups: *const Groups) bool {
        return switch (c) {
            .any => true,
            .cidr => |r| r.contains(peer),
            .host => |h| if (name) |n| std.ascii.eqlIgnoreCase(trimDot(n), trimDot(h)) else false,
            .domain => |d| if (name) |n| std.ascii.endsWithIgnoreCase(trimDot(n), d) else false,
            .group => |g| for (groups.get(g) orelse &.{}) |member| {
                if (member != .group and member.matches(peer, name, groups)) break true;
            } else false,
        };
    }
};

pub const Cidr = struct {
    address: net.IpAddress,
    prefix: u8,

    pub fn parse(text: []const u8) Client.ParseError!Cidr {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.BadClient;
        const address = net.IpAddress.parse(text[0..slash], 0) catch return error.BadClient;
        const prefix = std.fmt.parseInt(u8, text[slash + 1 ..], 10) catch return error.BadClient;
        const c: Cidr = .{ .address = normalize(address), .prefix = prefix };
        if (prefix > c.bits()) return error.BadClient;
        return c;
    }

    /// Writes `ADDRESS/PREFIX`, or the bare address for a single host.
    pub fn format(c: Cidr, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (c.address) {
            .ip4 => |a| try w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
            .ip6 => |a| {
                var buf: [64]u8 = undefined;
                var aw: std.Io.Writer = .fixed(&buf);
                try a.format(&aw);
                // `Ip6Address.format` writes `[ADDRESS]:PORT`.
                const text = aw.buffered();
                const end = std.mem.lastIndexOfScalar(u8, text, ']') orelse text.len;
                try w.writeAll(std.mem.trimStart(u8, text[0..end], "["));
            },
        }
        if (c.prefix != c.bits()) try w.print("/{d}", .{c.prefix});
    }

    fn bits(c: Cidr) u8 {
        return if (c.address == .ip4) 32 else 128;
    }

    pub fn contains(c: Cidr, peer: net.IpAddress) bool {
        const a = bytesOf(&c.address);
        const p = normalize(peer);
        const b = bytesOf(&p);
        if (a.len != b.len) return false;
        const whole = c.prefix / 8;
        if (!std.mem.eql(u8, a[0..whole], b[0..whole])) return false;
        const rest: u3 = @intCast(c.prefix % 8);
        if (rest == 0) return true;
        const mask = ~(@as(u8, 0xff) >> rest);
        return a[whole] & mask == b[whole] & mask;
    }
};

fn bytesOf(address: *const net.IpAddress) []const u8 {
    return switch (address.*) {
        .ip4 => |*a| &a.bytes,
        .ip6 => |*a| &a.bytes,
    };
}

/// IPv4-mapped IPv6 addresses, as a dual-stack socket reports IPv4 peers,
/// become plain IPv4.
pub fn normalize(address: net.IpAddress) net.IpAddress {
    return switch (address) {
        .ip4 => address,
        .ip6 => |a| if (net.Ip4Address.fromIp6(a)) |v4| .{ .ip4 = v4 } else address,
    };
}

fn trimDot(name: []const u8) []const u8 {
    return std.mem.trimEnd(u8, name, ".");
}

pub const Rule = struct {
    path: []const u8,
    client: Client,
    options: Options,
};

pub const Groups = std.StringHashMapUnmanaged([]const Client);

/// Export rules and the groups they name.
pub const Table = struct {
    rules: []const Rule = &.{},
    groups: Groups = .empty,

    /// Distinct exported paths, in rule order.
    pub fn paths(t: *const Table, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (t.rules) |r| {
            for (out.items) |p| {
                if (std.mem.eql(u8, p, r.path)) break;
            } else try out.append(arena, r.path);
        }
        return out.items;
    }

    pub const Match = struct {
        /// The export containing the requested path.
        path: []const u8,
        rule: *const Rule,
    };

    /// The rule for `peer` mounting or reaching `path`: the export is the
    /// longest exported path containing `path`, and within it the most
    /// specific matching client wins whole.
    pub fn match(t: *const Table, path: []const u8, peer: net.IpAddress, name: ?[]const u8) ?Match {
        var export_path: ?[]const u8 = null;
        for (t.rules) |r| {
            if (contains(r.path, path) and (export_path == null or r.path.len > export_path.?.len)) {
                export_path = r.path;
            }
        }
        const p = export_path orelse return null;
        var best: ?*const Rule = null;
        for (t.rules) |*r| {
            if (!std.mem.eql(u8, r.path, p) or !r.client.matches(peer, name, &t.groups)) continue;
            if (best == null or r.client.rank() > best.?.client.rank()) best = r;
        }
        return .{ .path = p, .rule = best orelse return null };
    }
};

/// Whether `path` is `root` or lies beneath it, by whole components.
pub fn contains(root: []const u8, path: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, path, r)) return false;
    return path.len == r.len or path[r.len] == '/';
}

const testing = std.testing;

fn ip(text: []const u8) net.IpAddress {
    return net.IpAddress.parse(text, 0) catch unreachable;
}

test "parse clients" {
    try testing.expectEqual(Client.any, try Client.parse("*"));
    try testing.expectEqualStrings("lab", (try Client.parse("@lab")).group);
    try testing.expectEqualStrings(".example.com", (try Client.parse("*.example.com")).domain);
    try testing.expectEqualStrings("hal.example.com", (try Client.parse("hal.example.com")).host);
    try testing.expectEqual(16, (try Client.parse("10.1.0.0/16")).cidr.prefix);
    try testing.expectEqual(8, (try Client.parse("fd00::/8")).cidr.prefix);
    try testing.expectEqual(32, (try Client.parse("192.168.64.4")).cidr.prefix);
    try testing.expectError(error.BadClient, Client.parse("10.0.0.0/33"));
    try testing.expectError(error.BadClient, Client.parse("@"));
    try testing.expectError(error.BadClient, Client.parse(""));
}

test "format clients as written" {
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "*", "@lab", "*.example.com", "hal", "10.1.0.0/16", "192.168.64.4", "fd00::/8" }) |text| {
        var w: std.Io.Writer = .fixed(&buf);
        try (try Client.parse(text)).format(&w);
        try testing.expectEqualStrings(text, w.buffered());
    }
}

test "options" {
    var o: Options = .{};
    try o.apply("ro");
    try o.apply("squash=all");
    try o.apply("map=art");
    try testing.expect(o.read_only);
    try testing.expectEqual(Squash.all, o.squash);
    try testing.expectEqualStrings("art", o.map.?);
    try testing.expectError(error.UnknownOption, o.apply("squash=skynet"));
    try testing.expectError(error.UnknownOption, o.apply("async"));
}

test "CIDRs contain addresses, including IPv4-mapped ones" {
    const c = try Cidr.parse("10.1.0.0/16");
    try testing.expect(c.contains(ip("10.1.200.3")));
    try testing.expect(!c.contains(ip("10.2.0.1")));
    try testing.expect(c.contains(ip("::ffff:10.1.0.9")));
    const odd = try Cidr.parse("192.168.64.0/20");
    try testing.expect(odd.contains(ip("192.168.79.255")));
    try testing.expect(!odd.contains(ip("192.168.80.0")));
    try testing.expect((try Cidr.parse("fd00::/8")).contains(ip("fd12::1")));
    try testing.expect(!(try Cidr.parse("fd00::/8")).contains(ip("10.0.0.1")));
}

test "the most specific client wins, whole" {
    var groups: Groups = .empty;
    defer groups.deinit(testing.allocator);
    try groups.put(testing.allocator, "lab", &.{try Client.parse("10.1.0.0/16")});
    const rules = [_]Rule{
        .{ .path = "/srv", .client = .any, .options = .{ .read_only = true } },
        .{ .path = "/srv", .client = try .parse("@lab"), .options = .{ .squash = .all } },
        .{ .path = "/srv", .client = try .parse("10.1.2.0/24"), .options = .{ .squash = .none } },
        .{ .path = "/srv", .client = try .parse("hal.example.com"), .options = .{ .map = "art" } },
        .{ .path = "/srv", .client = try .parse("*.example.com"), .options = .{ .read_only = true, .squash = .none } },
        .{ .path = "/srv/home", .client = try .parse("10.0.0.0/8"), .options = .{} },
    };
    const t: Table = .{ .rules = &rules, .groups = groups };

    try testing.expect(t.match("/srv", ip("192.168.1.1"), null).?.rule.options.read_only);
    try testing.expectEqual(Squash.all, t.match("/srv", ip("10.1.9.9"), null).?.rule.options.squash);
    try testing.expectEqual(Squash.none, t.match("/srv/media", ip("10.1.2.3"), null).?.rule.options.squash);
    try testing.expectEqualStrings("art", t.match("/srv", ip("10.1.2.3"), "HAL.example.com.").?.rule.options.map.?);
    try testing.expectEqual(Squash.none, t.match("/srv", ip("192.168.1.1"), "perihelion.example.com").?.rule.options.squash);

    // /srv/home is its own export: its rules alone apply there.
    const home = t.match("/srv/home/art", ip("10.1.2.3"), null).?;
    try testing.expectEqualStrings("/srv/home", home.path);
    try testing.expect(!home.rule.options.read_only);
    try testing.expectEqual(null, t.match("/srv/home", ip("192.168.1.1"), null));
    try testing.expectEqual(null, t.match("/srvx", ip("10.1.2.3"), null));
    try testing.expectEqual(null, t.match("/etc", ip("10.1.2.3"), null));
}

test "paths contain subpaths by whole components" {
    try testing.expect(contains("/srv", "/srv"));
    try testing.expect(contains("/srv/", "/srv/a"));
    try testing.expect(contains("/", "/etc"));
    try testing.expect(!contains("/srv", "/srvx"));
}
