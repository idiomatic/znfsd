//! ONC RPC version 2 (RFC 5531): call headers, replies, AUTH_SYS
//! credentials, and TCP record marking.

const std = @import("std");
const Io = std.Io;
const xdr = @import("xdr.zig");

pub const version: u32 = 2;

/// Largest opaque_auth body.
pub const max_auth_bytes = 400;

pub const MsgType = enum(u32) { call = 0, reply = 1 };

pub const ReplyStat = enum(u32) { accepted = 0, denied = 1 };

pub const AcceptStat = enum(u32) {
    success = 0,
    prog_unavail = 1,
    prog_mismatch = 2,
    proc_unavail = 3,
    garbage_args = 4,
    system_err = 5,
};

pub const RejectStat = enum(u32) { rpc_mismatch = 0, auth_error = 1 };

pub const AuthStat = enum(u32) {
    ok = 0,
    badcred = 1,
    rejectedcred = 2,
    badverf = 3,
    rejectedverf = 4,
    tooweak = 5,
    invalidresp = 6,
    failed = 7,
};

pub const AuthFlavor = enum(u32) {
    none = 0,
    sys = 1,
    short = 2,
    dh = 3,
    rpcsec_gss = 6,
    _,
};

pub const OpaqueAuth = struct {
    flavor: AuthFlavor,
    body: []const u8,

    pub const none: OpaqueAuth = .{ .flavor = .none, .body = &.{} };

    fn decode(d: *xdr.Decoder) xdr.DecodeError!OpaqueAuth {
        return .{
            .flavor = try d.enumeration(AuthFlavor),
            .body = try d.opaque_(max_auth_bytes),
        };
    }

    fn encode(a: OpaqueAuth, e: xdr.Encoder) xdr.Encoder.Error!void {
        try e.enumeration(a.flavor);
        try e.opaque_(a.body);
    }
};

/// AUTH_SYS credentials (RFC 5531, appendix A).
pub const AuthSys = struct {
    stamp: u32,
    machine_name: []const u8,
    uid: u32,
    gid: u32,
    gid_buf: [max_gids]u32 = undefined,
    gid_count: u8 = 0,

    pub const max_gids = 16;
    pub const max_machine_name = 255;

    /// Supplementary group IDs.
    pub fn gids(a: *const AuthSys) []const u32 {
        return a.gid_buf[0..a.gid_count];
    }

    pub fn setGids(a: *AuthSys, list: []const u32) error{TooLong}!void {
        if (list.len > max_gids) return error.TooLong;
        @memcpy(a.gid_buf[0..list.len], list);
        a.gid_count = @intCast(list.len);
    }

    pub fn decode(body: []const u8) xdr.DecodeError!AuthSys {
        var d: xdr.Decoder = .init(body);
        var a: AuthSys = .{
            .stamp = try d.u32_(),
            .machine_name = try d.string(max_machine_name),
            .uid = try d.u32_(),
            .gid = try d.u32_(),
        };
        const n = try d.u32_();
        if (n > max_gids) return error.TooLong;
        for (a.gid_buf[0..n]) |*g| g.* = try d.u32_();
        a.gid_count = @intCast(n);
        return a;
    }

    pub fn encode(a: *const AuthSys, e: xdr.Encoder) xdr.Encoder.Error!void {
        try e.u32_(a.stamp);
        try e.string(a.machine_name);
        try e.u32_(a.uid);
        try e.u32_(a.gid);
        try e.u32_(a.gid_count);
        for (a.gids()) |g| try e.u32_(g);
    }
};

pub const Call = struct {
    xid: u32,
    prog: u32,
    vers: u32,
    proc: u32,
    cred: OpaqueAuth,
    verf: OpaqueAuth,
    /// The procedure's encoded arguments.
    args: []const u8,

    pub fn encode(c: *const Call, e: xdr.Encoder) xdr.Encoder.Error!void {
        try e.u32_(c.xid);
        try e.enumeration(MsgType.call);
        try e.u32_(version);
        try e.u32_(c.prog);
        try e.u32_(c.vers);
        try e.u32_(c.proc);
        try c.cred.encode(e);
        try c.verf.encode(e);
        try e.w.writeAll(c.args);
    }
};

/// Supported version range, for PROG_MISMATCH and RPC_MISMATCH.
pub const Range = struct { low: u32, high: u32 };

/// A reply's status. After `success`, the caller encodes the results.
pub const Reply = union(enum) {
    success,
    /// Send nothing, as for NLM's asynchronous `_MSG` procedures.
    none,
    prog_unavail,
    prog_mismatch: Range,
    proc_unavail,
    garbage_args,
    system_err,
    rpc_mismatch: Range,
    auth_error: AuthStat,

    /// Encodes the reply header for `xid`, with an AUTH_NONE verifier.
    pub fn encode(r: Reply, e: xdr.Encoder, xid: u32) xdr.Encoder.Error!void {
        try e.u32_(xid);
        try e.enumeration(MsgType.reply);
        switch (r) {
            .rpc_mismatch, .auth_error => {
                try e.enumeration(ReplyStat.denied);
                switch (r) {
                    .rpc_mismatch => |range| {
                        try e.enumeration(RejectStat.rpc_mismatch);
                        try e.u32_(range.low);
                        try e.u32_(range.high);
                    },
                    .auth_error => |stat| {
                        try e.enumeration(RejectStat.auth_error);
                        try e.enumeration(stat);
                    },
                    else => unreachable,
                }
            },
            else => {
                try e.enumeration(ReplyStat.accepted);
                try OpaqueAuth.none.encode(e);
                switch (r) {
                    .success => try e.enumeration(AcceptStat.success),
                    .prog_unavail => try e.enumeration(AcceptStat.prog_unavail),
                    .prog_mismatch => |range| {
                        try e.enumeration(AcceptStat.prog_mismatch);
                        try e.u32_(range.low);
                        try e.u32_(range.high);
                    },
                    .proc_unavail => try e.enumeration(AcceptStat.proc_unavail),
                    .garbage_args => try e.enumeration(AcceptStat.garbage_args),
                    .system_err => try e.enumeration(AcceptStat.system_err),
                    .rpc_mismatch, .auth_error, .none => unreachable,
                }
            },
        }
    }
};

/// What to do with an incoming message.
pub const Incoming = union(enum) {
    call: Call,
    /// Reply at once with this status, for the given xid.
    reject: struct { xid: u32, reply: Reply },
    /// Drop the message: it isn't a call, or it's too short to answer.
    ignore,
};

pub fn decodeCall(message: []const u8) Incoming {
    var d: xdr.Decoder = .init(message);
    const xid = d.u32_() catch return .ignore;
    const msg_type = d.u32_() catch return .ignore;
    if (msg_type != @backingInt(MsgType.call)) return .ignore;
    const rpcvers = d.u32_() catch return .ignore;
    if (rpcvers != version) {
        return .{ .reject = .{ .xid = xid, .reply = .{ .rpc_mismatch = .{ .low = version, .high = version } } } };
    }
    const prog = d.u32_() catch return .ignore;
    const vers = d.u32_() catch return .ignore;
    const proc = d.u32_() catch return .ignore;
    const cred = OpaqueAuth.decode(&d) catch
        return .{ .reject = .{ .xid = xid, .reply = .{ .auth_error = .badcred } } };
    const verf = OpaqueAuth.decode(&d) catch
        return .{ .reject = .{ .xid = xid, .reply = .{ .auth_error = .badverf } } };
    return .{ .call = .{
        .xid = xid,
        .prog = prog,
        .vers = vers,
        .proc = proc,
        .cred = cred,
        .verf = verf,
        .args = d.rest(),
    } };
}

/// TCP record marking (RFC 5531, section 11): each record is one or more
/// fragments, each preceded by a 4-byte header whose top bit marks the last.
pub const record = struct {
    pub const last_fragment: u32 = 0x8000_0000;

    pub const ReadError = Io.Reader.Error || error{ RecordTooLong, OutOfMemory };

    /// Reads one record into `buf`, replacing its contents.
    pub fn read(r: *Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), max: usize) ReadError!void {
        buf.clearRetainingCapacity();
        while (true) {
            const header = try r.takeInt(u32, .big);
            const len = header & ~last_fragment;
            if (buf.items.len + len > max) return error.RecordTooLong;
            const dest = try buf.addManyAsSlice(gpa, len);
            try r.readSliceAll(dest);
            if (header & last_fragment != 0) return;
        }
    }

    /// Writes `payload` as a one-fragment record.
    pub fn write(w: *Io.Writer, payload: []const u8) Io.Writer.Error!void {
        try w.writeInt(u32, last_fragment | @as(u32, @intCast(payload.len)), .big);
        try w.writeAll(payload);
    }
};

const testing = std.testing;

/// A portmapper GETPORT call for NFS v3 over TCP, as a client sends it.
const getport_call = [_]u8{
    0x12, 0x34, 0x56, 0x78, // xid
    0, 0, 0, 0, // CALL
    0, 0, 0, 2, // RPC version 2
    0, 1, 0x86, 0xa0, // program 100000
    0, 0, 0, 2, // version 2
    0, 0, 0, 3, // GETPORT
    0, 0, 0, 0, 0, 0, 0, 0, // AUTH_NONE credential
    0, 0, 0, 0, 0, 0, 0, 0, // AUTH_NONE verifier
    0, 1, 0x86, 0xa3, 0, 0, 0, 3, 0, 0, 0, 6, 0, 0, 0, 0, // mapping
};

test "decode a call" {
    const call = decodeCall(&getport_call).call;
    try testing.expectEqual(0x12345678, call.xid);
    try testing.expectEqual(100000, call.prog);
    try testing.expectEqual(2, call.vers);
    try testing.expectEqual(3, call.proc);
    try testing.expectEqual(AuthFlavor.none, call.cred.flavor);
    try testing.expectEqual(16, call.args.len);

    var buf: [getport_call.len]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try call.encode(.init(&w));
    try testing.expectEqualSlices(u8, &getport_call, w.buffered());
}

test "reject other RPC versions; ignore replies and fragments" {
    var msg = getport_call;
    msg[11] = 3;
    const reject = decodeCall(&msg).reject;
    try testing.expectEqual(0x12345678, reject.xid);
    try testing.expectEqual(Range{ .low = 2, .high = 2 }, reject.reply.rpc_mismatch);

    msg = getport_call;
    msg[7] = 1;
    try testing.expectEqual(.ignore, std.meta.activeTag(decodeCall(&msg)));
    try testing.expectEqual(.ignore, std.meta.activeTag(decodeCall(getport_call[0..6])));
    try testing.expectEqual(.auth_error, std.meta.activeTag(decodeCall(getport_call[0..30]).reject.reply));
}

test "encode replies" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const e: xdr.Encoder = .init(&w);

    try (Reply{ .prog_mismatch = .{ .low = 3, .high = 3 } }).encode(e, 7);
    try testing.expectEqualSlices(u8, &.{
        0, 0, 0, 7, 0, 0, 0, 1, // xid, REPLY
        0, 0, 0, 0, // MSG_ACCEPTED
        0, 0, 0, 0, 0, 0, 0, 0, // AUTH_NONE verifier
        0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 3, // PROG_MISMATCH 3..3
    }, w.buffered());

    w = .fixed(&buf);
    try (Reply{ .auth_error = .tooweak }).encode(e, 7);
    try testing.expectEqualSlices(u8, &.{
        0, 0, 0, 7, 0, 0, 0, 1, // xid, REPLY
        0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 5, // MSG_DENIED, AUTH_ERROR, AUTH_TOOWEAK
    }, w.buffered());
}

test "AUTH_SYS round trip and limits" {
    var a: AuthSys = .{ .stamp = 1, .machine_name = "perihelion", .uid = 501, .gid = 20 };
    try a.setGids(&.{ 12, 61, 79 });
    const seventeen: [17]u32 = @splat(0);
    try testing.expectError(error.TooLong, a.setGids(&seventeen));
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try a.encode(.init(&w));

    const b: AuthSys = try .decode(w.buffered());
    try testing.expectEqualStrings("perihelion", b.machine_name);
    try testing.expectEqual(501, b.uid);
    try testing.expectEqualSlices(u32, &.{ 12, 61, 79 }, b.gids());

    // The gid count follows the stamp (4 bytes), the name (4 + 12), uid, and gid.
    std.mem.writeInt(u32, buf[28..32], 17, .big);
    try testing.expectError(error.TooLong, AuthSys.decode(w.buffered()));
}

test "record marking joins fragments and limits size" {
    const stream = "\x00\x00\x00\x03abc" ++ "\x80\x00\x00\x02de" ++ "\x80\x00\x00\x09toolarge!";
    var r: Io.Reader = .fixed(stream);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try record.read(&r, testing.allocator, &buf, 8);
    try testing.expectEqualStrings("abcde", buf.items);
    try testing.expectError(error.RecordTooLong, record.read(&r, testing.allocator, &buf, 8));

    var out: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    try record.write(&w, "hal");
    try testing.expectEqualSlices(u8, "\x80\x00\x00\x03hal", w.buffered());
}
