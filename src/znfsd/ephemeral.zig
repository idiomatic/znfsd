//! `serve`'s ephemeral exports (`PATH[:OPTIONS[:CLIENTS]]`) and groups
//! (`GROUP:CLIENT[,CLIENT ...]`).

const std = @import("std");
const libnfsd = @import("libnfsd");
const exports = libnfsd.exports;

pub const Error = error{
    BadExport,
    BadGroup,
    UnknownOption,
    BadClient,
    OutOfMemory,
};

pub const Export = struct {
    path: []const u8,
    options: exports.Options,
    clients: []const exports.Client,
};

/// Parses one export argument. `:` in PATH is escaped as `\:`; CLIENTS,
/// the last field, needs no escaping, so IPv6 addresses work as written.
pub fn parseExport(arena: std.mem.Allocator, text: []const u8) Error!Export {
    var path: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == ':') {
            try path.append(arena, ':');
            i += 1;
        } else if (text[i] == ':') {
            break;
        } else {
            try path.append(arena, text[i]);
        }
    }
    if (path.items.len == 0) return error.BadExport;
    var result: Export = .{ .path = path.items, .options = .{}, .clients = &.{.any} };
    if (i == text.len) return result;

    const rest = text[i + 1 ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    const options = rest[0 .. colon orelse rest.len];
    var words = std.mem.tokenizeScalar(u8, options, ',');
    while (words.next()) |word| try result.options.apply(word);

    if (colon) |c| {
        var clients: std.ArrayList(exports.Client) = .empty;
        var it = std.mem.tokenizeScalar(u8, rest[c + 1 ..], ',');
        while (it.next()) |client| try clients.append(arena, try .parse(client));
        if (clients.items.len > 0) result.clients = clients.items;
    }
    return result;
}

pub const Group = struct {
    name: []const u8,
    clients: []const exports.Client,
};

pub fn parseGroup(arena: std.mem.Allocator, text: []const u8) Error!Group {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.BadGroup;
    if (colon == 0) return error.BadGroup;
    var clients: std.ArrayList(exports.Client) = .empty;
    var it = std.mem.tokenizeScalar(u8, text[colon + 1 ..], ',');
    while (it.next()) |client| {
        const c: exports.Client = try .parse(client);
        if (c == .group) return error.BadGroup;
        try clients.append(arena, c);
    }
    if (clients.items.len == 0) return error.BadGroup;
    return .{ .name = text[0..colon], .clients = clients.items };
}

const testing = std.testing;

test "exports: path only, options, clients, and escapes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try parseExport(arena, "/srv/media");
    try testing.expectEqualStrings("/srv/media", plain.path);
    try testing.expect(!plain.options.read_only);
    try testing.expectEqual(exports.Client.any, plain.clients[0]);

    const full = try parseExport(arena, "/srv/home/art:rw,map=art:@lab,fd00::/8");
    try testing.expectEqualStrings("art", full.options.map.?);
    try testing.expectEqual(2, full.clients.len);
    try testing.expectEqualStrings("lab", full.clients[0].group);
    try testing.expectEqual(8, full.clients[1].cidr.prefix);

    const escaped = try parseExport(arena, "/a\\:b:ro");
    try testing.expectEqualStrings("/a:b", escaped.path);
    try testing.expect(escaped.options.read_only);

    const default_options = try parseExport(arena, "/srv::10.0.0.0/8");
    try testing.expect(!default_options.options.read_only);
    try testing.expectEqual(1, default_options.clients.len);

    try testing.expectError(error.UnknownOption, parseExport(arena, "/srv:async"));
    try testing.expectError(error.BadExport, parseExport(arena, ":ro"));
}

test "groups" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const g = try parseGroup(arena_state.allocator(), "lab:10.1.0.0/16,fd00::/8");
    try testing.expectEqualStrings("lab", g.name);
    try testing.expectEqual(2, g.clients.len);
    try testing.expectError(error.BadGroup, parseGroup(arena_state.allocator(), "lab"));
    try testing.expectError(error.BadGroup, parseGroup(arena_state.allocator(), "lab:@ops"));
}
