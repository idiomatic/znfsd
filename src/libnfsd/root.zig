//! libnfsd: an embeddable NFS v3 server with integrated MOUNT, NLM, NSM,
//! and portmapper services. Embedders supply an `std.Io`, an allocator, and
//! state-storage hooks.

const std = @import("std");

pub const xdr = @import("xdr.zig");
pub const rpc = @import("rpc.zig");
pub const server = @import("server.zig");
pub const portmap = @import("portmap.zig");
pub const service = @import("service.zig");

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

test {
    std.testing.refAllDecls(@This());
}
