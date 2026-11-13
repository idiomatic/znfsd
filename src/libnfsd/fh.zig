//! File handles: a file's identity without its path, so they survive renames.
//!
//! Layout (36 bytes, under NFS v3's 64): version, filesystem ID kind,
//! two reserved bytes, export ID, filesystem ID (16 bytes), inode, and
//! generation, all big-endian.

const std = @import("std");
const sys = @import("sys.zig");

pub const size = 36;
pub const format_version = 1;

pub const FsidKind = enum(u8) {
    /// The device number, in the first eight bytes.
    device = 0,
    /// The volume's UUID.
    uuid = 1,
    _,
};

pub const Handle = struct {
    export_id: u32,
    fsid_kind: FsidKind = .device,
    fsid: [16]u8,
    inode: u64,
    generation: u32,

    pub const DecodeError = error{BadHandle};

    pub fn fromAttr(export_id: u32, attr: sys.Attr) Handle {
        var fsid: [16]u8 = @splat(0);
        std.mem.writeInt(u64, fsid[0..8], attr.dev, .big);
        return .{ .export_id = export_id, .fsid = fsid, .inode = attr.ino, .generation = attr.gen };
    }

    pub fn encode(h: Handle) [size]u8 {
        var b: [size]u8 = @splat(0);
        b[0] = format_version;
        b[1] = @backingInt(h.fsid_kind);
        std.mem.writeInt(u32, b[4..8], h.export_id, .big);
        b[8..24].* = h.fsid;
        std.mem.writeInt(u64, b[24..32], h.inode, .big);
        std.mem.writeInt(u32, b[32..36], h.generation, .big);
        return b;
    }

    pub fn decode(b: []const u8) DecodeError!Handle {
        if (b.len != size or b[0] != format_version) return error.BadHandle;
        return .{
            .fsid_kind = @fromBackingInt(@intCast(b[1])),
            .export_id = std.mem.readInt(u32, b[4..8], .big),
            .fsid = b[8..24].*,
            .inode = std.mem.readInt(u64, b[24..32], .big),
            .generation = std.mem.readInt(u32, b[32..36], .big),
        };
    }

    /// Whether two handles name the same file.
    pub fn eql(a: Handle, b: Handle) bool {
        return std.mem.eql(u8, &a.encode(), &b.encode());
    }
};

const testing = std.testing;

test "round trip, and reject other versions and sizes" {
    var attr: sys.Attr = undefined;
    try testing.expectEqual(sys.E.SUCCESS, sys.lstat("/", &attr));
    const h: Handle = .fromAttr(7, attr);
    const b = h.encode();
    const back: Handle = try .decode(&b);
    try testing.expect(h.eql(back));
    try testing.expectEqual(7, back.export_id);
    try testing.expectEqual(attr.ino, back.inode);

    var other = b;
    other[0] = 2;
    try testing.expectError(error.BadHandle, Handle.decode(&other));
    try testing.expectError(error.BadHandle, Handle.decode(b[0..32]));
}
