//! XDR (RFC 4506): big-endian, 4-byte-aligned encoding of RPC messages.
//!
//! `Decoder` reads from a complete message in memory, and its opaque and
//! string results are slices into that message. `Encoder` writes to any
//! `std.Io.Writer`.

const std = @import("std");
const Io = std.Io;

pub const DecodeError = error{
    /// The message ended before the item did.
    Truncated,
    /// A variable-length item is longer than its declared maximum.
    TooLong,
    /// A boolean or discriminant has a value outside its type.
    Invalid,
};

pub const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Decoder {
        return .{ .bytes = bytes };
    }

    /// Bytes not yet decoded.
    pub fn rest(d: *const Decoder) []const u8 {
        return d.bytes[d.pos..];
    }

    pub fn u32_(d: *Decoder) DecodeError!u32 {
        const b = try d.take(4);
        return std.mem.readInt(u32, b[0..4], .big);
    }

    pub fn i32_(d: *Decoder) DecodeError!i32 {
        return @bitCast(try d.u32_());
    }

    pub fn u64_(d: *Decoder) DecodeError!u64 {
        const b = try d.take(8);
        return std.mem.readInt(u64, b[0..8], .big);
    }

    pub fn i64_(d: *Decoder) DecodeError!i64 {
        return @bitCast(try d.u64_());
    }

    pub fn boolean(d: *Decoder) DecodeError!bool {
        return switch (try d.u32_()) {
            0 => false,
            1 => true,
            else => error.Invalid,
        };
    }

    /// Decodes an enum; exhaustive enums reject unknown values.
    pub fn enumeration(d: *Decoder, comptime E: type) DecodeError!E {
        return std.enums.fromInt(E, try d.u32_()) orelse error.Invalid;
    }

    /// Fixed-length opaque data of `n` bytes, skipping its padding.
    pub fn fixedOpaque(d: *Decoder, n: usize) DecodeError![]const u8 {
        const data = try d.take(n);
        _ = try d.take(padding(n));
        return data;
    }

    /// Variable-length opaque data of at most `max` bytes.
    pub fn opaque_(d: *Decoder, max: u32) DecodeError![]const u8 {
        const n = try d.u32_();
        if (n > max) return error.TooLong;
        return d.fixedOpaque(n);
    }

    /// A string of at most `max` bytes; XDR strings are opaque bytes.
    pub fn string(d: *Decoder, max: u32) DecodeError![]const u8 {
        return d.opaque_(max);
    }

    fn take(d: *Decoder, n: usize) DecodeError![]const u8 {
        if (d.bytes.len - d.pos < n) return error.Truncated;
        defer d.pos += n;
        return d.bytes[d.pos..][0..n];
    }
};

pub const Encoder = struct {
    w: *Io.Writer,

    pub const Error = Io.Writer.Error;

    pub fn init(w: *Io.Writer) Encoder {
        return .{ .w = w };
    }

    pub fn u32_(e: Encoder, v: u32) Error!void {
        try e.w.writeInt(u32, v, .big);
    }

    pub fn i32_(e: Encoder, v: i32) Error!void {
        try e.u32_(@bitCast(v));
    }

    pub fn u64_(e: Encoder, v: u64) Error!void {
        try e.w.writeInt(u64, v, .big);
    }

    pub fn i64_(e: Encoder, v: i64) Error!void {
        try e.u64_(@bitCast(v));
    }

    pub fn boolean(e: Encoder, v: bool) Error!void {
        try e.u32_(@intFromBool(v));
    }

    pub fn enumeration(e: Encoder, v: anytype) Error!void {
        try e.u32_(@backingInt(v));
    }

    /// Fixed-length opaque data, padded to a multiple of four bytes.
    pub fn fixedOpaque(e: Encoder, data: []const u8) Error!void {
        try e.w.writeAll(data);
        try e.w.splatByteAll(0, padding(data.len));
    }

    /// Variable-length opaque data: its length, then its padded bytes.
    pub fn opaque_(e: Encoder, data: []const u8) Error!void {
        try e.u32_(@intCast(data.len));
        try e.fixedOpaque(data);
    }

    pub fn string(e: Encoder, s: []const u8) Error!void {
        try e.opaque_(s);
    }
};

/// Bytes of zero padding after `n` bytes of opaque data.
pub fn padding(n: usize) usize {
    return (4 - n % 4) % 4;
}

const testing = std.testing;

test "integers are big-endian" {
    var buf: [24]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const e: Encoder = .init(&w);
    try e.u32_(0x01020304);
    try e.i32_(-2);
    try e.u64_(0x0102030405060708);
    try e.i64_(-1);
    try testing.expectEqualSlices(u8, &.{
        1,    2,    3,    4,
        0xff, 0xff, 0xff, 0xfe,
        1,    2,    3,    4,
        5,    6,    7,    8,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
    }, w.buffered());

    var d: Decoder = .init(w.buffered());
    try testing.expectEqual(0x01020304, try d.u32_());
    try testing.expectEqual(-2, try d.i32_());
    try testing.expectEqual(0x0102030405060708, try d.u64_());
    try testing.expectEqual(-1, try d.i64_());
    try testing.expectEqual(0, d.rest().len);
}

test "opaque data and strings are padded" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const e: Encoder = .init(&w);
    try e.string("hal");
    try e.opaque_("");
    try e.fixedOpaque("perihelion");
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x03hal\x00" ++ "\x00\x00\x00\x00" ++ "perihelion\x00\x00", w.buffered());

    var d: Decoder = .init(w.buffered());
    try testing.expectEqualStrings("hal", try d.string(255));
    try testing.expectEqualStrings("", try d.opaque_(0));
    try testing.expectEqualStrings("perihelion", try d.fixedOpaque(10));
    try testing.expectEqual(0, d.rest().len);
}

test "decoding rejects truncated, oversized, and invalid items" {
    var d: Decoder = .init("\x00\x00\x00");
    try testing.expectError(error.Truncated, d.u32_());

    d = .init("\x00\x00\x00\x05skynet\x00\x00");
    try testing.expectError(error.TooLong, d.string(4));

    d = .init("\x00\x00\x00\x05skyn");
    try testing.expectError(error.Truncated, d.string(8));

    d = .init("\x00\x00\x00\x02");
    try testing.expectError(error.Invalid, d.boolean());

    const Color = enum(u32) { red, green };
    d = .init("\x00\x00\x00\x01\x00\x00\x00\x07");
    try testing.expectEqual(Color.green, try d.enumeration(Color));
    try testing.expectError(error.Invalid, d.enumeration(Color));

    const Open = enum(u32) { red, _ };
    d = .init("\x00\x00\x00\x07");
    try testing.expectEqual(@as(Open, @fromBackingInt(@intCast(7))), try d.enumeration(Open));
}
