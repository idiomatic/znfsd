//! RPC serving: dispatch calls to programs, over UDP datagrams and TCP
//! record-marked streams.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const xdr = @import("xdr.zig");

const log = std.log.scoped(.libnfsd);

/// Largest UDP datagram.
pub const max_datagram = 65535;

/// Where a call came from.
pub const Context = struct {
    io: Io,
    from: net.IpAddress,
    protocol: net.Protocol,
    /// Told of every call answered, as for an activity monitor.
    observer: ?*const Observer = null,
};

/// One answered call, for an observer.
pub const Observed = struct {
    from: net.IpAddress,
    protocol: net.Protocol,
    prog: u32,
    vers: u32,
    proc: u32,
    reply: std.meta.Tag(rpc.Reply),
    /// Bytes of results.
    bytes: usize,
    nanoseconds: u64,
};

pub const Observer = struct {
    ptr: *anyopaque,
    observe: *const fn (ptr: *anyopaque, io: Io, call: Observed) void,
};

/// An RPC program: its number, supported versions, and handler.
pub const Program = struct {
    prog: u32,
    low: u32,
    high: u32,
    ptr: *anyopaque,
    /// Writes the results of a successful call to `results` and returns
    /// `.success`, or returns another status and writes nothing.
    handle: *const fn (ptr: *anyopaque, ctx: Context, call: rpc.Call, results: *Io.Writer) rpc.Reply,
};

/// Size of a success header: xid, REPLY, MSG_ACCEPTED, AUTH_NONE verifier,
/// and SUCCESS. Results are written after it, so they needn't be copied.
const success_header = 24;

/// Answers `message`, writing the reply into `out`. Returns the reply, or
/// null when the message gets none.
pub fn dispatch(programs: []const Program, ctx: Context, message: []const u8, out: []u8) ?[]const u8 {
    std.debug.assert(out.len >= success_header);
    const call, const reply: rpc.Reply = switch (rpc.decodeCall(message)) {
        .ignore => return null,
        .reject => |r| return encodeStatus(out, r.xid, r.reply),
        .call => |call| .{ call, status: {
            const program = for (programs) |*p| {
                if (p.prog == call.prog) break p;
            } else break :status .prog_unavail;
            if (call.vers < program.low or call.vers > program.high) {
                break :status .{ .prog_mismatch = .{ .low = program.low, .high = program.high } };
            }
            var results: Io.Writer = .fixed(out[success_header..]);
            log.debug("{f} {t}: prog {d} vers {d} proc {d}: arrived", .{ ctx.from, ctx.protocol, call.prog, call.vers, call.proc });
            const started = if (ctx.observer != null) Io.Clock.awake.now(ctx.io) else undefined;
            const reply = program.handle(program.ptr, ctx, call, &results);
            if (ctx.observer) |o| o.observe(o.ptr, ctx.io, .{
                .from = ctx.from,
                .protocol = ctx.protocol,
                .prog = call.prog,
                .vers = call.vers,
                .proc = call.proc,
                .reply = reply,
                .bytes = results.end,
                .nanoseconds = @intCast(@max(0, started.durationTo(Io.Clock.awake.now(ctx.io)).nanoseconds)),
            });
            log.debug("{f} {t}: prog {d} vers {d} proc {d}: {t}, {d} bytes", .{
                ctx.from, ctx.protocol, call.prog, call.vers, call.proc, reply, results.end,
            });
            if (reply == .none) return null;
            if (reply == .success) {
                var header: Io.Writer = .fixed(out[0..success_header]);
                rpc.Reply.encode(.success, .init(&header), call.xid) catch unreachable;
                std.debug.assert(header.end == success_header);
                return out[0 .. success_header + results.end];
            }
            break :status reply;
        } },
    };
    return encodeStatus(out, call.xid, reply);
}

fn encodeStatus(out: []u8, xid: u32, reply: rpc.Reply) []const u8 {
    var w: Io.Writer = .fixed(out);
    reply.encode(.init(&w), xid) catch unreachable; // a status header fits in `success_header` bytes plus a range
    return w.buffered();
}

/// Serves RPC over UDP on `socket` until canceled.
pub fn serveUdp(io: Io, gpa: std.mem.Allocator, programs: []const Program, socket: net.Socket, observer: ?*const Observer) Io.Cancelable!void {
    const buf = gpa.alloc(u8, 2 * max_datagram) catch {
        log.err("udp: out of memory", .{});
        return;
    };
    defer gpa.free(buf);
    const in = buf[0..max_datagram];
    const out = buf[max_datagram..];
    while (true) {
        const message = socket.receive(io, in) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("udp receive: {t}", .{err});
                continue;
            },
        };
        if (message.flags.trunc) continue;
        const ctx: Context = .{ .io = io, .from = message.from, .protocol = .udp, .observer = observer };
        const reply = dispatch(programs, ctx, message.data, out) orelse continue;
        socket.send(io, &message.from, reply) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => log.warn("udp send: {t}", .{err}),
        };
    }
}

/// How TCP connections, accepted or adopted, are served.
pub const ConnectionOptions = struct {
    /// Largest record accepted, and the room each reply gets.
    max_record: usize = 1024 * 1024 + 4096,
    /// Calls answered at once on one connection; their replies may go out
    /// in any order, matched by XID. Each holds up to two records' worth of
    /// buffers while it runs.
    max_calls: usize = 16,
    /// How long a connection may sit with no call in flight and no bytes
    /// arriving before it's closed; clients reconnect.
    idle_timeout: Io.Duration = .fromSeconds(360),
    /// How long a reply may take to write before the connection is closed,
    /// as when the peer stops reading.
    write_timeout: Io.Duration = .fromSeconds(120),
    /// What the connection counts in, and its calls take buffers from.
    pool: *Pool = &Pool.process,
    /// Told of every call answered.
    observer: ?*const Observer = null,
};

/// What the connections naming it share, across listeners: a cap on those
/// accepted, and a budget for their calls' buffers.
pub const Pool = struct {
    /// Connections accepted and open at once; more are closed unserved.
    /// At most half the soft descriptor limit, leaving the rest for files.
    max_connections: usize = 1024,
    open: std.atomic.Value(usize) = .init(0),
    /// Bytes held at once by calls, beyond the small record buffers slots
    /// keep; a call waits for room, though one alone may exceed it.
    max_bytes: usize = 256 * 1024 * 1024,
    mutex: Io.Mutex = .init,
    room: Io.Condition = .init,
    held: usize = 0,

    /// Shared by connections whose options name no other pool.
    pub var process: Pool = .{};

    /// Counts in a connection, unless as many as allowed are open.
    fn admit(p: *Pool) bool {
        const cap = @min(p.max_connections, descriptorCap());
        var n = p.open.load(.monotonic);
        while (n < cap) n = p.open.cmpxchgWeak(n, n + 1, .monotonic, .monotonic) orelse return true;
        return false;
    }

    fn descriptorCap() usize {
        const limit = std.posix.getrlimit(.NOFILE) catch return std.math.maxInt(usize);
        return std.math.cast(usize, limit.cur / 2) orelse std.math.maxInt(usize);
    }

    /// Waits for room for `bytes`, then holds them.
    fn reserve(p: *Pool, io: Io, bytes: usize, timeout: Io.Timeout) (Io.Cancelable || Io.Timeout.Error)!void {
        try p.mutex.lock(io);
        defer p.mutex.unlock(io);
        const deadline = timeout.toDeadline(io);
        while (p.held != 0 and p.held + bytes > p.max_bytes) try p.room.waitTimeout(io, &p.mutex, deadline);
        p.held += bytes;
    }

    /// Holds `bytes` without waiting, for a call already holding some, so
    /// that calls part read can't wait on each other.
    fn overdraw(p: *Pool, io: Io, bytes: usize) void {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        p.held += bytes;
    }

    fn release(p: *Pool, io: Io, bytes: usize) void {
        if (bytes == 0) return;
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        p.held -= bytes;
        p.room.broadcast(io);
    }
};

/// Serves RPC over TCP on `listener` until canceled, one task per connection.
pub fn serveTcp(
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    listener: *net.Server,
    options: ConnectionOptions,
) Io.Cancelable!void {
    var connections: Io.Group = .init;
    defer connections.cancel(io);
    const pool = options.pool;
    var backoff: Io.Duration = .zero;
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // Until a descriptor or memory frees up, accepting fails at
            // once, so wait first.
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                if (backoff.nanoseconds == 0) log.warn("tcp accept: {t}; backing off", .{err});
                backoff = .fromNanoseconds(std.math.clamp(backoff.nanoseconds * 2, 10 * std.time.ns_per_ms, std.time.ns_per_s));
                try io.sleep(backoff, .awake);
                continue;
            },
            else => {
                log.warn("tcp accept: {t}", .{err});
                continue;
            },
        };
        backoff = .zero;
        if (!pool.admit()) {
            log.warn("tcp: {d} connections open, refusing {f}", .{ pool.open.load(.monotonic), stream.socket.address });
            stream.close(io);
            continue;
        }
        connections.concurrent(io, counted, .{ io, gpa, programs, stream, options }) catch |err| {
            _ = pool.open.fetchSub(1, .monotonic);
            log.warn("tcp connection: {t}", .{err});
            stream.close(io);
        };
    }
}

/// Serves a connection, counted among its pool's open ones until it ends.
fn counted(io: Io, gpa: std.mem.Allocator, programs: []const Program, stream: net.Stream, options: ConnectionOptions) Io.Cancelable!void {
    defer _ = options.pool.open.fetchSub(1, .monotonic);
    return serveConnection(io, gpa, programs, stream, options);
}

/// Record buffers up to this size outlive their calls, for the next, and
/// aren't counted against the pool.
const kept_record = 4096;

/// A call's buffers: its record, and room for its reply. Both are sized
/// and reserved from the pool once the record's length is known, and
/// freed when the call ends, but a small record buffer is kept.
const Slot = struct {
    busy: std.atomic.Value(bool) = .init(false),
    message: std.ArrayList(u8) = .empty,
    out: []u8 = &.{},
    /// Bytes reserved from the pool.
    held: usize = 0,

    // An allocator may wait on a cancelable lock and drop the cancelation
    // (`DebugAllocator`'s stack traces do, on macOS), which would leave the
    // next read or write deaf to it, so these allocate and free with
    // cancelation blocked. Needless from the Zig release after 0.17.1,
    // which has https://codeberg.org/ziglang/zig/pulls/36010.

    /// Grows the record buffer to hold exactly `capacity` bytes, if smaller.
    fn grow(slot: *Slot, io: Io, gpa: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        try slot.message.ensureTotalCapacityPrecise(gpa, capacity);
    }

    fn allocateReply(slot: *Slot, io: Io, gpa: std.mem.Allocator, size: usize) std.mem.Allocator.Error!void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        slot.out = try gpa.alloc(u8, size);
    }

    /// Frees the call's buffers but a small record buffer, and returns
    /// what they held to the pool.
    fn finish(slot: *Slot, io: Io, gpa: std.mem.Allocator, pool: *Pool) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        gpa.free(slot.out);
        slot.out = &.{};
        if (slot.message.capacity > kept_record) slot.message.clearAndFree(gpa);
        pool.release(io, slot.held);
        slot.held = 0;
    }
};

/// Pool bytes a record buffer of `capacity` holds.
fn recordHeld(capacity: usize) usize {
    return if (capacity > kept_record) capacity else 0;
}

/// Why a connection is closed while the peer is still there.
const Stale = error{
    /// A reply took longer than `write_timeout` to write.
    ReplyStalled,
    /// No call was in flight, and no bytes came, for `idle_timeout`.
    Idle,
};

/// One connection's state, shared by its reader and its calls.
const Connection = struct {
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    options: ConnectionOptions,
    ctx: Context,
    stream: net.Stream,
    writer: *Io.Writer,
    /// Keeps replies whole.
    write_lock: Io.Mutex = .init,
    /// When the reply being written began, in awake-clock nanoseconds, or
    /// 0 when none is.
    writing_since: std.atomic.Value(i64) = .init(0),
    /// When bytes last arrived, in awake-clock nanoseconds.
    read_at: std.atomic.Value(i64),
    /// Calls read and not yet answered.
    in_flight: std.atomic.Value(usize) = .init(0),
    /// Slots not busy.
    free: Io.Semaphore,
    slots: []Slot,

    /// Reads a record into `slot`, first reserving its buffers.
    fn readRecord(c: *Connection, r: *Io.Reader, slot: *Slot) (Io.Reader.Error || error{ RecordTooLong, OutOfMemory } || Stale || Io.Cancelable)!void {
        slot.message.clearRetainingCapacity();
        const pool = c.options.pool;
        var first = true;
        while (true) : (first = false) {
            const header = try r.takeInt(u32, .big);
            const size = slot.message.items.len + (header & ~rpc.record.last_fragment);
            if (size > c.options.max_record) return error.RecordTooLong;
            if (first) {
                // Room for the reply, and for a record of one fragment.
                const held = c.options.max_record + recordHeld(@max(size, slot.message.capacity));
                try c.reserve(held);
                slot.held = held;
                try slot.grow(c.io, c.gpa, size);
            } else if (size > slot.message.capacity) {
                // More fragments grow the buffer geometrically, so tiny ones
                // can't make reading quadratic.
                try slot.grow(c.io, c.gpa, @min(c.options.max_record, @max(size, slot.message.capacity * 2)));
                const held = c.options.max_record + recordHeld(slot.message.capacity);
                pool.overdraw(c.io, held - slot.held);
                slot.held = held;
            }
            try r.readSliceAll(slot.message.addManyAsSliceAssumeCapacity(size - slot.message.items.len));
            if (header & rpc.record.last_fragment != 0) return;
        }
    }

    /// Answers the call in `slot`, then frees the slot.
    fn answer(c: *Connection, slot: *Slot) Io.Cancelable!void {
        defer {
            slot.finish(c.io, c.gpa, c.options.pool);
            _ = c.in_flight.fetchSub(1, .monotonic);
            slot.busy.store(false, .release);
            c.free.post(c.io);
        }
        slot.allocateReply(c.io, c.gpa, c.options.max_record) catch {
            log.warn("tcp: out of memory", .{});
            return c.broken();
        };
        const reply = dispatch(c.programs, c.ctx, slot.message.items, slot.out) orelse return;
        try c.write_lock.lock(c.io);
        defer c.write_lock.unlock(c.io);
        c.writing_since.store(now(c.io), .monotonic);
        defer c.writing_since.store(0, .monotonic);
        rpc.record.write(c.writer, reply) catch return c.broken();
        c.writer.flush() catch return c.broken();
    }

    /// A reply can't be sent, so stop reading calls too.
    fn broken(c: *Connection) void {
        c.stream.shutdown(c.io, .both) catch {};
    }

    /// Fails when the connection should be closed.
    fn watch(c: *Connection) Stale!void {
        const since = c.writing_since.load(.monotonic);
        const at = now(c.io);
        if (since != 0 and at - since > c.options.write_timeout.nanoseconds) return error.ReplyStalled;
        if (c.in_flight.load(.monotonic) == 0 and at - c.read_at.load(.monotonic) > c.options.idle_timeout.nanoseconds) return error.Idle;
    }

    /// How often a waiting reader checks the connection.
    fn tick(c: *Connection) Io.Timeout {
        const shortest = @min(c.options.write_timeout.nanoseconds, c.options.idle_timeout.nanoseconds);
        const nanoseconds = @max(std.time.ns_per_ms, @divTrunc(shortest, 4));
        return .{ .duration = .{ .raw = .fromNanoseconds(nanoseconds), .clock = .awake } };
    }

    /// Waits for room in the pool, checking the connection meanwhile, as
    /// its own calls may hold the room.
    fn reserve(c: *Connection, bytes: usize) (Stale || Io.Cancelable)!void {
        while (true) {
            c.options.pool.reserve(c.io, bytes, c.tick()) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => {
                    try c.watch();
                    continue;
                },
            };
            return;
        }
    }

    /// Waits for a free slot, checking the connection meanwhile.
    fn takeSlot(c: *Connection) (Stale || Io.Cancelable)!*Slot {
        while (true) {
            c.free.waitTimeout(c.io, c.tick()) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => {
                    try c.watch();
                    continue;
                },
            };
            break;
        }
        for (c.slots) |*s| {
            if (s.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) return s;
        } else unreachable; // a permit means a free slot
    }
};

fn now(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

/// Reads a connection's stream, checking the connection whenever no bytes
/// come for a tick.
const StreamReader = struct {
    interface: Io.Reader,
    c: *Connection,
    err: ?Error = null,

    const Error = net.Stream.Reader.Error || Stale;

    fn init(c: *Connection, buffer: []u8) StreamReader {
        return .{
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .c = c,
        };
    }

    fn stream(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *StreamReader = @alignCast(@fieldParentPtr("interface", io_r));
        const c = r.c;
        var iovecs_buffer: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const operation: Io.Operation = .{ .net_read = .{ .socket_handle = c.stream.socket.handle, .data = iovecs_buffer[0..dest_n] } };
        const result = while (true) {
            break c.io.operateTimeout(operation, c.tick()) catch |err| switch (err) {
                error.Timeout => {
                    c.watch() catch |e| {
                        r.err = e;
                        return error.ReadFailed;
                    };
                    continue;
                },
                // Without timeouts, the connection goes unchecked.
                error.ConcurrencyUnavailable => c.io.operate(operation) catch |e| {
                    r.err = e;
                    return error.ReadFailed;
                },
                error.Canceled => |e| {
                    r.err = e;
                    return error.ReadFailed;
                },
            };
        };
        const n = (result.net_read catch |err| {
            r.err = err;
            return error.ReadFailed;
        }).data_len;
        if (n == 0) return error.EndOfStream;
        c.read_at.store(now(c.io), .monotonic);
        if (n > data_size) {
            io_r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// Serves RPC over one connected stream (TCP, a Unix socket, vsock) until
/// the peer closes it or the task is canceled, then closes it. Calls run
/// concurrently, up to `options.max_calls`. `stream.socket.address` stands
/// for the peer in export rules and logs.
pub fn serveConnection(
    io: Io,
    gpa: std.mem.Allocator,
    programs: []const Program,
    stream: net.Stream,
    options: ConnectionOptions,
) Io.Cancelable!void {
    defer stream.close(io);
    const slots = gpa.alloc(Slot, @max(1, options.max_calls)) catch return;
    @memset(slots, .{});
    defer {
        for (slots) |*s| {
            s.finish(io, gpa, options.pool);
            s.message.deinit(gpa);
        }
        gpa.free(slots);
    }
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    var c: Connection = .{
        .io = io,
        .gpa = gpa,
        .programs = programs,
        .options = options,
        .ctx = .{ .io = io, .from = stream.socket.address, .protocol = .tcp, .observer = options.observer },
        .stream = stream,
        .writer = &writer.interface,
        .read_at = .init(now(io)),
        .free = .{ .permits = slots.len },
        .slots = slots,
    };
    var reader: StreamReader = .init(&c, &read_buf);
    var calls: Io.Group = .init;
    defer calls.cancel(io);

    while (true) {
        const slot = c.takeSlot() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Idle => {
                log.info("tcp: {f}: {t}", .{ c.ctx.from, err });
                break;
            },
            error.ReplyStalled => {
                log.warn("tcp: {f}: {t}", .{ c.ctx.from, err });
                c.broken();
                break;
            },
        };
        c.readRecord(&reader.interface, slot) catch |err| {
            slot.finish(io, gpa, options.pool);
            slot.busy.store(false, .release);
            c.free.post(io);
            const cause = switch (err) {
                error.ReadFailed => reader.err.?,
                else => |e| e,
            };
            switch (cause) {
                error.Canceled => return error.Canceled,
                error.EndOfStream => {},
                error.Idle => log.info("tcp: {f}: {t}", .{ c.ctx.from, cause }),
                error.ReplyStalled => {
                    log.warn("tcp: {f}: {t}", .{ c.ctx.from, cause });
                    c.broken();
                },
                else => log.warn("tcp read: {f}: {t}", .{ c.ctx.from, cause }),
            }
            break;
        };
        // Without a task to spare, answer before reading on.
        _ = c.in_flight.fetchAdd(1, .monotonic);
        calls.concurrent(io, Connection.answer, .{ &c, slot }) catch try c.answer(slot);
    }
    // The peer is gone or misbehaved; let calls already read finish, unless
    // their replies stall.
    for (slots) |_| _ = c.takeSlot() catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            c.broken();
            break;
        },
    };
    try calls.await(io);
}

const testing = std.testing;

const Echo = struct {
    calls: usize = 0,

    fn handle(ptr: *anyopaque, ctx: Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
        _ = ctx;
        const echo: *Echo = @ptrCast(@alignCast(ptr));
        echo.calls += 1;
        return switch (call.proc) {
            0 => .success,
            1 => {
                results.writeAll(call.args) catch return .system_err;
                return .success;
            },
            else => .proc_unavail,
        };
    }

    fn program(echo: *Echo) Program {
        return .{ .prog = 400000, .low = 1, .high = 2, .ptr = echo, .handle = handle };
    }
};

fn encodeCall(buf: []u8, prog: u32, vers: u32, proc: u32, args: []const u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    const call: rpc.Call = .{
        .xid = 9,
        .prog = prog,
        .vers = vers,
        .proc = proc,
        .cred = .none,
        .verf = .none,
        .args = args,
    };
    call.encode(.init(&w)) catch unreachable;
    return w.buffered();
}

fn acceptStat(reply: []const u8) u32 {
    return std.mem.readInt(u32, reply[20..24], .big);
}

test "dispatch to programs, versions, and procedures" {
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    const ctx: Context = .{ .io = testing.io, .from = .{ .ip4 = .loopback(0) }, .protocol = .udp };
    var call_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;

    var reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 1, "hal\x00"), &out).?;
    try testing.expectEqual(0, acceptStat(reply));
    try testing.expectEqualStrings("hal\x00", reply[24..]);

    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400001, 1, 0, ""), &out).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.prog_unavail), acceptStat(reply));

    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 3, 0, ""), &out).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.prog_mismatch), acceptStat(reply));
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x01\x00\x00\x00\x02", reply[24..32]);

    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 2, 7, ""), &out).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.proc_unavail), acceptStat(reply));

    var too_small: [26]u8 = undefined;
    reply = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 1, "perihelion\x00\x00"), &too_small).?;
    try testing.expectEqual(@backingInt(rpc.AcceptStat.system_err), acceptStat(reply));
    try testing.expectEqual(3, echo.calls);
}

test "an observer sees each answered call" {
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    const Seen = struct {
        calls: usize = 0,
        last: Observed = undefined,
        fn observe(ptr: *anyopaque, _: Io, call: Observed) void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            s.calls += 1;
            s.last = call;
        }
    };
    var seen: Seen = .{};
    const observer: Observer = .{ .ptr = &seen, .observe = Seen.observe };
    const ctx: Context = .{ .io = testing.io, .from = .{ .ip4 = .loopback(0) }, .protocol = .udp, .observer = &observer };
    var call_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    _ = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 1, "art\x00"), &out).?;
    _ = dispatch(&programs, ctx, encodeCall(&call_buf, 400000, 1, 7, ""), &out).?;
    try testing.expectEqual(2, seen.calls);
    try testing.expectEqual(.proc_unavail, seen.last.reply);
    try testing.expectEqual(7, seen.last.proc);
    // Programs that don't exist never reach a handler, so aren't observed.
    _ = dispatch(&programs, ctx, encodeCall(&call_buf, 400001, 1, 0, ""), &out).?;
    try testing.expectEqual(2, seen.calls);
}

test "serve over UDP and TCP on loopback" {
    const io = testing.io;
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};

    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    const udp = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer udp.close(io);
    var tcp = try any.listen(io, .{ .reuse_address = true });
    defer tcp.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveUdp, .{ io, testing.allocator, &programs, udp, null });
    try group.concurrent(io, serveTcp, .{ io, testing.allocator, &programs, &tcp, .{ .max_record = 4096 } });

    var call_buf: [64]u8 = undefined;
    const call = encodeCall(&call_buf, 400000, 1, 1, "art\x00");

    const client = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer client.close(io);
    try client.send(io, &udp.address, call);
    var in: [128]u8 = undefined;
    const message = try client.receiveTimeout(io, &in, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqualStrings("art\x00", message.data[24..]);

    const stream = try tcp.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buf: [128]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try rpc.record.write(&writer.interface, call);
    try writer.interface.flush();
    var read_buf: [128]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    try testing.expectEqualStrings("art\x00", reply.items[24..]);
}

/// A connected pair of Unix stream sockets, as `Stream`s.
fn testPair() ![2]net.Stream {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    var pair: [2]net.Stream = undefined;
    for (&pair, fds) |*s, fd| s.* = .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .unspecified(0) } } };
    return pair;
}

test "a connection answers calls concurrently, replies matched by XID" {
    const io = testing.io;
    // Procedure 1 waits for procedure 2, so answering one call at a time
    // would time out.
    const Gate = struct {
        open: Io.Event = .unset,

        fn handle(ptr: *anyopaque, ctx: Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
            _ = results;
            const gate: *@This() = @ptrCast(@alignCast(ptr));
            switch (call.proc) {
                1 => gate.open.waitTimeout(ctx.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch return .system_err,
                2 => gate.open.set(ctx.io),
                else => return .proc_unavail,
            }
            return .success;
        }
    };
    var gate: Gate = .{};
    const programs = [_]Program{.{ .prog = 400000, .low = 1, .high = 1, .ptr = &gate, .handle = Gate.handle }};
    const pair = try testPair();
    defer pair[1].close(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveConnection, .{ io, testing.allocator, &programs, pair[0], .{ .max_record = 4096 } });

    var write_buf: [128]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    for ([_]u32{ 1, 2 }) |proc| {
        var call_buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&call_buf);
        const call: rpc.Call = .{ .xid = 10 + proc, .prog = 400000, .vers = 1, .proc = proc, .cred = .none, .verf = .none, .args = &.{} };
        try call.encode(.init(&w));
        try rpc.record.write(&writer.interface, w.buffered());
        try writer.interface.flush();
    }
    var read_buf: [128]u8 = undefined;
    var reader = pair[1].reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    for ([_]u32{ 12, 11 }) |xid| {
        try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
        try testing.expectEqual(xid, std.mem.readInt(u32, reply.items[0..4], .big));
        try testing.expectEqual(0, acceptStat(reply.items));
    }
}

test "an idle connection holds no call buffers" {
    const io = testing.io;
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    const pair = try testPair();
    defer pair[1].close(io);
    var pool: Pool = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveConnection, .{ io, counting.allocator(), &programs, pair[0], .{ .pool = &pool } });

    try io.sleep(.fromMilliseconds(50), .awake);
    try testing.expect(counting.allocated_bytes - counting.freed_bytes < 64 * 1024);

    // A call takes buffers for its time only, but a small record buffer.
    var write_buf: [128]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    var call_buf: [64]u8 = undefined;
    try rpc.record.write(&writer.interface, encodeCall(&call_buf, 400000, 1, 1, "art\x00"));
    try writer.interface.flush();
    var read_buf: [128]u8 = undefined;
    var reader = pair[1].reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    try testing.expectEqualStrings("art\x00", reply.items[24..]);
    for (0..100) |_| {
        if (@atomicLoad(usize, &pool.held, .monotonic) == 0) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.StillHeld;
    try testing.expect(counting.allocated_bytes - counting.freed_bytes < 64 * 1024);
}

test "calls wait for room in their pool" {
    const io = testing.io;
    // Procedure 1 waits briefly for procedure 2, which can't run until 1
    // returns its buffers.
    const Gate = struct {
        open: Io.Event = .unset,

        fn handle(ptr: *anyopaque, ctx: Context, call: rpc.Call, results: *Io.Writer) rpc.Reply {
            _ = results;
            const gate: *@This() = @ptrCast(@alignCast(ptr));
            switch (call.proc) {
                1 => gate.open.waitTimeout(ctx.io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch return .system_err,
                2 => gate.open.set(ctx.io),
                else => return .proc_unavail,
            }
            return .success;
        }
    };
    var gate: Gate = .{};
    const programs = [_]Program{.{ .prog = 400000, .low = 1, .high = 1, .ptr = &gate, .handle = Gate.handle }};
    const pair = try testPair();
    defer pair[1].close(io);
    var pool: Pool = .{ .max_bytes = 4096 };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveConnection, .{ io, testing.allocator, &programs, pair[0], .{ .max_record = 4096, .pool = &pool } });

    var write_buf: [128]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    for ([_]u32{ 1, 2 }) |proc| {
        var call_buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&call_buf);
        const call: rpc.Call = .{ .xid = 10 + proc, .prog = 400000, .vers = 1, .proc = proc, .cred = .none, .verf = .none, .args = &.{} };
        try call.encode(.init(&w));
        try rpc.record.write(&writer.interface, w.buffered());
        try writer.interface.flush();
    }
    var read_buf: [128]u8 = undefined;
    var reader = pair[1].reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    try testing.expectEqual(11, std.mem.readInt(u32, reply.items[0..4], .big));
    try testing.expectEqual(@backingInt(rpc.AcceptStat.system_err), acceptStat(reply.items));
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    try testing.expectEqual(12, std.mem.readInt(u32, reply.items[0..4], .big));
}

test "a peer that stops reading replies is closed" {
    const io = testing.io;
    testing.log_level = .err; // the closing is logged
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    const pair = try testPair();
    defer pair[1].close(io);
    var pool: Pool = .{};
    const options: ConnectionOptions = .{ .max_record = 64 * 1024, .write_timeout = .fromMilliseconds(200), .pool = &pool };
    var served = try io.concurrent(serveConnection, .{ io, testing.allocator, &programs, pair[0], options });
    defer served.cancel(io) catch {};

    // Large echoes, never read, until the connection is closed.
    const args = try testing.allocator.alloc(u8, 60 * 1024);
    defer testing.allocator.free(args);
    @memset(args, 'x');
    const call_buf = try testing.allocator.alloc(u8, 61 * 1024);
    defer testing.allocator.free(call_buf);
    const call = encodeCall(call_buf, 400000, 1, 1, args);
    var write_buf: [1024]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    while (true) {
        rpc.record.write(&writer.interface, call) catch break;
        writer.interface.flush() catch break;
    }
    try served.await(io);
    try testing.expectEqual(0, pool.held);
}

test "an idle connection is closed" {
    const io = testing.io;
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    const pair = try testPair();
    defer pair[1].close(io);
    var pool: Pool = .{};
    const options: ConnectionOptions = .{ .max_record = 4096, .idle_timeout = .fromMilliseconds(100), .pool = &pool };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveConnection, .{ io, testing.allocator, &programs, pair[0], options });

    // A call answered, then nothing: the server closes its end.
    var write_buf: [128]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    var call_buf: [64]u8 = undefined;
    try rpc.record.write(&writer.interface, encodeCall(&call_buf, 400000, 1, 1, "art\x00"));
    try writer.interface.flush();
    var read_buf: [128]u8 = undefined;
    var reader = pair[1].reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
    var byte: [1]u8 = undefined;
    var data: [1][]u8 = .{&byte};
    const closed = try io.operateTimeout(.{ .net_read = .{ .socket_handle = pair[1].socket.handle, .data = &data } }, timeout);
    try testing.expectEqual(0, (try closed.net_read).data_len);
}

test "listeners sharing a pool share its connection cap" {
    const io = testing.io;
    testing.log_level = .err; // the refusal is logged
    var echo: Echo = .{};
    const programs = [_]Program{echo.program()};
    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var first = try any.listen(io, .{ .reuse_address = true });
    defer first.deinit(io);
    var second = try any.listen(io, .{ .reuse_address = true });
    defer second.deinit(io);
    var pool: Pool = .{ .max_connections = 1 };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for ([_]*net.Server{ &first, &second }) |l| {
        try group.concurrent(io, serveTcp, .{ io, testing.allocator, &programs, l, .{ .max_record = 4096, .pool = &pool } });
    }

    var call_buf: [64]u8 = undefined;
    const call = encodeCall(&call_buf, 400000, 1, 1, "art\x00");
    // The first is answered, and stays open, so the second is refused.
    var replies: [2]?usize = undefined;
    var streams: [2]net.Stream = undefined;
    defer for (streams) |s| s.close(io);
    for ([_]*net.Server{ &first, &second }, &streams, &replies) |l, *stream, *r| {
        stream.* = try l.socket.address.connect(io, .{ .mode = .stream });
        const s = stream.*;
        var write_buf: [128]u8 = undefined;
        var writer = s.writer(io, &write_buf);
        try rpc.record.write(&writer.interface, call);
        try writer.interface.flush();
        var read_buf: [128]u8 = undefined;
        var reader = s.reader(io, &read_buf);
        var reply: std.ArrayList(u8) = .empty;
        defer reply.deinit(testing.allocator);
        r.* = if (rpc.record.read(&reader.interface, testing.allocator, &reply, 4096)) reply.items.len else |_| null;
    }
    try testing.expectEqual(28, replies[0]);
    try testing.expectEqual(null, replies[1]);
}

test "a connection the embedder accepted carries MOUNT and NFS" {
    const io = testing.io;
    const exports = @import("exports.zig");
    const files_mod = @import("files.zig");
    const mount_mod = @import("mount.zig");
    const nfs_mod = @import("nfs.zig");
    const sys = @import("sys.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "share");
    var buf: [sys.max_path]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = try std.fmt.allocPrint(testing.allocator, "{s}/share", .{buf[0..n]});
    defer testing.allocator.free(root);
    const rules = [_]exports.Rule{.{ .path = root, .client = .any, .options = .{ .squash = .none } }};
    const table: exports.Table = .{ .rules = &rules };
    var mount: mount_mod.Mount = .init(testing.allocator, &table);
    defer mount.deinit();
    var files: files_mod.Files = .init(testing.allocator);
    defer files.deinit();
    var nfs: nfs_mod.Nfs = .init(testing.allocator, &table, &files, "znfsd-t\x00".*);

    const programs = [_]Program{ mount.program(), nfs.program() };
    const pair = try testPair();
    defer pair[1].close(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, serveConnection, .{ io, testing.allocator, &programs, pair[0], .{} });

    var cred_buf: [64]u8 = undefined;
    var cw: Io.Writer = .fixed(&cred_buf);
    const auth: rpc.AuthSys = .{ .stamp = 0, .machine_name = "perihelion", .uid = std.c.getuid(), .gid = std.c.getgid() };
    try auth.encode(.init(&cw));
    var write_buf: [1024]u8 = undefined;
    var writer = pair[1].writer(io, &write_buf);
    var read_buf: [1024]u8 = undefined;
    var reader = pair[1].reader(io, &read_buf);
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(testing.allocator);
    var args_buf: [sys.max_path + 8]u8 = undefined;

    // MNT, then GETATTR on the handle it returns, over the one connection.
    var aw: Io.Writer = .fixed(&args_buf);
    try xdr.Encoder.init(&aw).string(root);
    try sendCall(&writer.interface, 1, mount_mod.prog, 1, cw.buffered(), aw.buffered());
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    var d: xdr.Decoder = .init(reply.items[24..]);
    try testing.expectEqual(0, try d.u32_());
    const handle = try d.opaque_(64);

    aw = .fixed(&args_buf);
    try xdr.Encoder.init(&aw).opaque_(handle);
    try sendCall(&writer.interface, 2, nfs_mod.prog, 1, cw.buffered(), aw.buffered());
    try rpc.record.read(&reader.interface, testing.allocator, &reply, 4096);
    try testing.expectEqual(2, std.mem.readInt(u32, reply.items[0..4], .big));
    try testing.expectEqual(0, std.mem.readInt(u32, reply.items[20..24], .big));
    d = .init(reply.items[24..]);
    try testing.expectEqual(0, try d.u32_()); // NFS3_OK
    try testing.expectEqual(2, try d.u32_()); // NF3DIR
}

fn sendCall(w: *Io.Writer, xid: u32, prog: u32, proc: u32, cred: []const u8, args: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var cw: Io.Writer = .fixed(&buf);
    const call: rpc.Call = .{ .xid = xid, .prog = prog, .vers = 3, .proc = proc, .cred = .{ .flavor = .sys, .body = cred }, .verf = .none, .args = args };
    try call.encode(.init(&cw));
    try rpc.record.write(w, cw.buffered());
    try w.flush();
}
