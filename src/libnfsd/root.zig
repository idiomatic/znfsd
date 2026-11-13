//! libnfsd: an embeddable NFS v3 server with integrated MOUNT, NLM, NSM,
//! and portmapper services. Embedders supply an `std.Io`, an allocator, and
//! state-storage hooks.

const std = @import("std");

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

/// Fixed default ports.
pub const Ports = struct {
    nfs: u16 = 2049,
    mount: u16 = 20048,
    stat: u16 = 32765,
    lock: u16 = 32803,
};

test {
    std.testing.refAllDecls(@This());
}
