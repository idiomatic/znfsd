//! The activity monitor's web server: a page, and a JSON snapshot it polls.
//!
//! HTTP/1.1, GET only, one request per connection. Bound to loopback, as by
//! default, it answers only requests naming a loopback host, so a web page
//! elsewhere can't reach it by DNS rebinding.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const log = std.log.scoped(.znfsd);

const page = @embedFile("web/index.html");
const script = @embedFile("web/app.js");
const style = @embedFile("web/style.css");

pub const default_port = 8049;

/// Connections served at once; more are closed at once.
const max_connections = 64;

/// How long a connection may take, request and response together.
const deadline: Io.Duration = .fromSeconds(10);

/// Writes the JSON snapshot.
pub const Provider = struct {
    ptr: *anyopaque,
    write: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, w: *Io.Writer) anyerror!void,
};

/// Parses `[ADDR:]PORT`; IPv6 addresses are bracketed, as `[::1]:8049`.
pub fn parseAddress(text: []const u8) error{BadAddress}!net.IpAddress {
    if (std.fmt.parseInt(u16, text, 10)) |port| {
        return .{ .ip4 = .loopback(port) };
    } else |_| {}
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.BadAddress;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return error.BadAddress;
    const host = std.mem.trim(u8, text[0..colon], "[]");
    return net.IpAddress.parse(host, port) catch error.BadAddress;
}

fn isLoopback(address: net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| a.isLoopBack(),
    };
}

/// Answers requests on `server` until canceled.
pub fn serve(io: Io, gpa: std.mem.Allocator, server: *net.Server, provider: Provider) Io.Cancelable!void {
    var connections: Io.Group = .init;
    defer connections.cancel(io);
    const loopback_only = isLoopback(server.socket.address);
    var open: std.atomic.Value(usize) = .init(0);
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("web accept: {t}", .{err});
                continue;
            },
        };
        if (open.fetchAdd(1, .monotonic) >= max_connections) {
            _ = open.fetchSub(1, .monotonic);
            stream.close(io);
            continue;
        }
        connections.concurrent(io, answer, .{ io, gpa, stream, provider, loopback_only, &open }) catch {
            _ = open.fetchSub(1, .monotonic);
            stream.close(io);
        };
    }
}

/// Shuts `stream` down once `deadline` passes, unless canceled first,
/// ending any read or write waiting on it.
fn watchdog(io: Io, stream: net.Stream) Io.Cancelable!void {
    try io.sleep(deadline, .awake);
    stream.shutdown(io, .both) catch {};
}

fn answer(io: Io, gpa: std.mem.Allocator, stream: net.Stream, provider: Provider, loopback_only: bool, open: *std.atomic.Value(usize)) void {
    defer _ = open.fetchSub(1, .monotonic);
    defer stream.close(io);
    var timer = io.concurrent(watchdog, .{ io, stream }) catch return;
    defer timer.cancel(io) catch {};
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var write_buf: [16384]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;
    defer w.flush() catch {};

    const request_line = reader.interface.takeDelimiterInclusive('\n') catch return;
    var host: []const u8 = "";
    var headers: usize = 0;
    while (true) {
        headers += 1;
        if (headers > 100) return;
        const line = reader.interface.takeDelimiterInclusive('\n') catch return;
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "host:")) {
            host = arena.dupe(u8, std.mem.trim(u8, trimmed["host:".len..], " \t")) catch return;
        }
    }

    var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, request_line, "\r\n"), ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    if (!std.mem.eql(u8, method, "GET")) return respond(w, "405 Method Not Allowed", "text/plain", "GET only\n");
    if (loopback_only and !loopbackHost(host)) return respond(w, "403 Forbidden", "text/plain", "not a loopback host\n");

    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, path, "/")) return respond(w, "200 OK", "text/html; charset=utf-8", page);
    if (std.mem.eql(u8, path, "/app.js")) return respond(w, "200 OK", "text/javascript; charset=utf-8", script);
    if (std.mem.eql(u8, path, "/style.css")) return respond(w, "200 OK", "text/css; charset=utf-8", style);
    if (std.mem.eql(u8, path, "/activity.json")) {
        var body: Io.Writer.Allocating = .init(arena);
        provider.write(provider.ptr, arena, &body.writer) catch |err| {
            log.warn("web snapshot: {t}", .{err});
            return respond(w, "500 Internal Server Error", "text/plain", "snapshot failed\n");
        };
        return respond(w, "200 OK", "application/json", body.written());
    }
    respond(w, "404 Not Found", "text/plain", "not found\n");
}

/// Whether a Host header names loopback: 127.x, localhost, or [::1].
fn loopbackHost(host: []const u8) bool {
    const name = if (std.mem.startsWith(u8, host, "["))
        host[0 .. (std.mem.indexOfScalar(u8, host, ']') orelse return false) + 1]
    else
        host[0 .. std.mem.lastIndexOfScalar(u8, host, ':') orelse host.len];
    if (std.ascii.eqlIgnoreCase(name, "localhost") or std.mem.eql(u8, name, "[::1]")) return true;
    const a = net.Ip4Address.parse(name, 0) catch return false;
    return a.bytes[0] == 127;
}

fn respond(w: *Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) void {
    w.print("HTTP/1.1 {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "X-Content-Type-Options: nosniff\r\n" ++
        "Content-Security-Policy: default-src 'self'\r\n" ++
        "Connection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    w.writeAll(body) catch {};
}

const testing = std.testing;

test "addresses" {
    try testing.expectEqual(8050, (try parseAddress("8050")).getPort());
    try testing.expect(isLoopback(try parseAddress("8050")));
    try testing.expectEqual(9000, (try parseAddress("0.0.0.0:9000")).getPort());
    try testing.expect(isLoopback(try parseAddress("[::1]:8049")));
    try testing.expectError(error.BadAddress, parseAddress("skynet"));
}

test "loopback hosts" {
    try testing.expect(loopbackHost("127.0.0.1:8049"));
    try testing.expect(loopbackHost("localhost:8049"));
    try testing.expect(loopbackHost("LOCALHOST"));
    try testing.expect(loopbackHost("[::1]:8049"));
    try testing.expect(!loopbackHost("skynet.example.com:8049"));
    try testing.expect(!loopbackHost("[fd00::1]:8049"));
    try testing.expect(!loopbackHost(""));
}

test "serve the page and snapshot, and refuse other hosts" {
    const io = testing.io;
    var server = try net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const P = struct {
        fn write(_: *anyopaque, _: std.mem.Allocator, w: *Io.Writer) anyerror!void {
            try w.writeAll("{\"hal\":9000}");
        }
    };
    var dummy: u8 = 0;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serve, .{ io, testing.allocator, &server, Provider{ .ptr = &dummy, .write = P.write } });

    const Get = struct {
        fn run(addr: net.IpAddress, req: []const u8, out: []u8) ![]const u8 {
            const s = try addr.connect(testing.io, .{ .mode = .stream });
            defer s.close(testing.io);
            var wb: [512]u8 = undefined;
            var sw = s.writer(testing.io, &wb);
            try sw.interface.writeAll(req);
            try sw.interface.flush();
            var rb: [512]u8 = undefined;
            var sr = s.reader(testing.io, &rb);
            const n = try sr.interface.readSliceShort(out);
            return out[0..n];
        }
    };
    var out: [8192]u8 = undefined;
    const addr = server.socket.address;
    var r = try Get.run(addr, "GET /activity.json HTTP/1.1\r\nHost: 127.0.0.1:8049\r\n\r\n", &out);
    try testing.expectStringStartsWith(r, "HTTP/1.1 200 OK");
    try testing.expect(std.mem.endsWith(u8, r, "{\"hal\":9000}"));
    r = try Get.run(addr, "GET / HTTP/1.1\r\nHost: localhost:8049\r\n\r\n", &out);
    try testing.expect(std.mem.indexOf(u8, r, "text/html") != null);
    r = try Get.run(addr, "GET / HTTP/1.1\r\nHost: skynet.example.com\r\n\r\n", &out);
    try testing.expectStringStartsWith(r, "HTTP/1.1 403");
    r = try Get.run(addr, "POST / HTTP/1.1\r\nHost: localhost\r\n\r\n", &out);
    try testing.expectStringStartsWith(r, "HTTP/1.1 405");
    r = try Get.run(addr, "GET /etc/passwd HTTP/1.1\r\nHost: localhost\r\n\r\n", &out);
    try testing.expectStringStartsWith(r, "HTTP/1.1 404");
}

test "connections past the limit are closed" {
    const io = testing.io;
    var server = try net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const P = struct {
        fn write(_: *anyopaque, _: std.mem.Allocator, w: *Io.Writer) anyerror!void {
            try w.writeAll("{}");
        }
    };
    var dummy: u8 = 0;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serve, .{ io, testing.allocator, &server, Provider{ .ptr = &dummy, .write = P.write } });

    var idle: [max_connections]net.Stream = undefined;
    for (&idle) |*s| s.* = try server.socket.address.connect(io, .{ .mode = .stream });
    defer for (idle) |s| s.close(io);
    try io.sleep(.fromMilliseconds(100), .awake);
    const start: Io.Clock.Timestamp = .now(io, .awake);
    const extra = try server.socket.address.connect(io, .{ .mode = .stream });
    defer extra.close(io);
    var rb: [64]u8 = undefined;
    var reader = extra.reader(io, &rb);
    var out: [64]u8 = undefined;
    try testing.expectEqual(0, try reader.interface.readSliceShort(&out));
    // Closed at once, not at the deadline.
    try testing.expect(start.untilNow(io).raw.toSeconds() < 2);
}
