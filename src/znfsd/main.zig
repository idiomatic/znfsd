//! znfsd: the CLI daemon built on libnfsd.

const std = @import("std");
const Io = std.Io;
const libnfsd = @import("libnfsd");
const cli = @import("cli.zig");

const usage = @embedFile("usage.txt");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const status: u8 = run(arena, args[1..], stdout, stderr) catch |err| status: {
        try stderr.print("znfsd: {s}\n", .{@errorName(err)});
        break :status 2;
    };
    try stdout.flush();
    try stderr.flush();
    return status;
}

fn run(arena: std.mem.Allocator, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    const invocation = try cli.parse(arena, args);
    switch (invocation.command.noun) {
        .help => {
            try stdout.writeAll(usage);
            return 0;
        },
        else => |noun| {
            try stderr.print("znfsd {f}: {s}: not implemented\n", .{ libnfsd.version, @tagName(noun) });
            return 1;
        },
    }
}

test {
    _ = cli;
}
