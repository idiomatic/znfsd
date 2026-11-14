# libnfsd

An embeddable NFS v3 server, with MOUNT, NLM (locking), NSM (status monitoring), and a portmapper of its own, in Zig 0.17. [znfsd](../znfsd) is built on it. This guide is for embedding it; [ARCHITECTURE.md](../../ARCHITECTURE.md) covers how it works inside.

libnfsd keeps no state on disk. You supply the export table, an `std.Io`, and an allocator, and optionally hooks that keep file handles, mount records, and monitored hosts across restarts.

## Using it

Add this repository as a dependency in `build.zig.zon` (a URL with a hash, or a `.path`), then import the `libnfsd` module:

```zig
const znfsd = b.dependency("znfsd", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("libnfsd", znfsd.module("libnfsd"));
```

The module links libc. Hosts are recent Linux and macOS.

## A minimal server

A read-only export to one subnet, with NFS and MOUNT but no locking:

```zig
const std = @import("std");
const libnfsd = @import("libnfsd");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Export paths must be canonical.
    var buf: [libnfsd.sys.max_path]u8 = undefined;
    var path: []const u8 = undefined;
    if (libnfsd.sys.canonical("/srv/share", &buf, &path) != .SUCCESS)
        return error.NoSuchExport;

    const rules = [_]libnfsd.exports.Rule{.{
        .path = path,
        .client = try .parse("192.168.1.0/24"),
        .options = .{ .read_only = true },
    }};
    const table: libnfsd.exports.Table = .{ .rules = &rules };

    var mount: libnfsd.mount.Mount = .init(gpa, &table);
    defer mount.deinit();
    var files: libnfsd.files.Files = .init(gpa);
    defer files.deinit();
    // Different at each start.
    var verifier: [8]u8 = undefined;
    const now = std.Io.Clock.real.now(io).nanoseconds;
    std.mem.writeInt(i64, &verifier, @truncate(now), .big);
    var nfs: libnfsd.nfs.Nfs = .init(gpa, &table, &files, verifier);

    const binds = [_]std.Io.net.IpAddress{
        .{ .ip4 = .unspecified(0) },
        .{ .ip6 = .unspecified(0) },
    };
    var diag: libnfsd.service.Diagnostic = .{};
    libnfsd.service.run(io, gpa, .{ .binds = &binds }, &.{
        .{ .program = mount.program(), .service = .mount },
        .{ .program = nfs.program(), .service = .nfs },
    }, &diag) catch |err| {
        std.log.err("{s}", .{diag.message()});
        return err;
    };
}
```

`service.run` binds UDP and TCP on each address, registers with the portmapper, and serves until its task is canceled, then unregisters. Run it with `io.concurrent` to do other work alongside, as znfsd does.

## Serving

`service.Config`:

| Field | Default | |
|---|---|---|
| `binds` | | addresses to listen on; ports are ignored |
| `ports` | nfs 2049, mount 20048, stat 32765, lock 32803 | per service |
| `portmap` | `.auto` | `.auto`: register with a portmapper that answers, else start one when root, else fail with `error.NoPortmapper`; `.off`: neither |
| `max_record` | 1 MiB + 4 KiB | largest TCP record |
| `after_bind` | | runs once every port is bound and registered, before any request; return false (with `diag` set) to stop |
| `observer` | | told of every call answered, for activity monitoring |

Each `Registration` pairs a program with the service whose port it uses: `mount.program()` with `.mount`, `nfs.program()` with `.nfs`, `nlm.program()` with `.lock`, and `nsm.program()` with `.stat`. A taken port fails with `error.PortInUse`, and a program another server registered (the host's own NFS services, say) with `error.AlreadyRegistered`; `diag` says which.

On macOS, the probe for a portmapper first wakes launchd's on-demand `rpcbind`.

## Concurrency and identity

* **Threads:** each UDP socket is served in a loop and each TCP connection concurrently, through the `Io` you supply (znfsd uses `std.Io.Threaded`). Every type here is safe to share among requests; the allocator must be thread-safe.
* **Acting as callers:** as root, each NFS request switches its thread's identity to the caller's (after squashing and maps), so the OS checks access and new files get the caller's owner. `Nfs.root` records this at `init`.
* **Dropping root:** to bind low ports as root and then serve as a user, drop privileges in `after_bind` and set `nfs.root = false` there. Unprivileged, files are reached as that user, maps can't apply, and NFS clients can't set owners.
* **Owner override:** a file's owner may open it whatever its mode, as the Linux kernel server allows.

## The export table

`exports.Table` holds `rules`, and the `groups` and `maps` they name. A `Rule` is a canonical path, a `Client`, and `Options`:

* `Client.parse`: `host`, `*.domain`, an address or CIDR (IPv4-mapped peers match IPv4), `@GROUP`, or `*`. For a path, the most specific matching client's rule wins, whole: host, longest CIDR, longest domain, group, then `*`.
* `Options`: `read_only`, `squash` (`.root`, the default, `.all`, or `.none`), and `map`, a name in `Table.maps`. `Options.apply` parses `rw`, `ro`, `squash=…`, and `map=…`.
* `Map`: entries that translate client IDs to host IDs, UIDs and GIDs independently; requests map remote to local, replies local to its first remote. An entry with no remote IDs is the anon, which unmapped IDs and squashing use; without one, unmapped IDs pass through and squashing uses the host's `nobody`.

Exports are always synchronous, cross mount points, skip subtree checks, and take AUTH_SYS only. Paths can't escape an export: every file is opened component by component without following symbolic links.

To change exports while serving, build a new table and call `setTable` on `Mount` and `Nfs`. Keep the old table alive: requests already running may still read it. znfsd keeps every table in an arena until exit.

## Locking and restarts

Locking takes three more parts, sharing one `Locks`:

```zig
var locks: libnfsd.locks.Locks = .init(gpa);
defer locks.deinit();
var status: libnfsd.nsm.Nsm = .init(gpa, state);
defer status.deinit();
var nlm: libnfsd.nlm.Nlm = .init(gpa, &nfs, &locks, &status);
defer nlm.deinit(io);
status.rebooted = nlm.rebooted(); // a client's restart drops its locks
```

Register `nlm.program()` as `.lock` and `status.program()` as `.stat`. Locking needs a portmapper: clients find NLM and NSM through it, and NLM's callbacks find clients' through theirs.

Locks live only in memory. After a restart, clients reclaim them:

1. Advance the NSM state number with `nsm.nextState(previous)`, keep it, and pass it to `Nsm.init`.
2. Read the hosts that were monitored before (see `nsm.Store`), and forget them.
3. If there were any, call `nlm.startGrace(io)`: for about 90 seconds only reclaims are granted.
4. Once serving, call `nsm.notify(io, hosts, state)` (it returns how many answered), so their clients reclaim.

`nlm.releaseHost` releases a host's locks, on one file or all, as for an administrator; `locks.snapshot` lists them. `Nfs.locate` turns a file handle into the lock table's key.

## Persistence hooks

Without hooks, file handles go stale and mounts and monitors are forgotten when the server restarts. Each hook is a pointer and functions, set as a field before serving. They can't fail: log and carry on. libnfsd calls them as the server's own identity, never a caller's.

| Hook | Field | Calls |
|---|---|---|
| `files.Store` | `Files.store` | `remember` (a file's path by file-system ID and inode), optional `rememberMany` (one transaction), `lookup`, and `renamePrefix` (a directory moved) |
| `mount.Store` | `Mount.store` | `mounted` and `unmounted`; at start, `Mount.restore` re-adds records without storing them again |
| `nsm.Store` | `Nsm.store` | `monitor` and `unmonitor` |

File handles are 36 bytes: format version, export ID (a hash of the export path), file-system ID (the device number), inode, and generation. A handle resolves to its file's last-known path, from memory or else `files.Store`, while that path's device and inode still match; otherwise it's stale, except for export roots. MNT, LOOKUP, READDIRPLUS, and creation record paths, and renames move them.

## Other transports

`server.dispatch(programs, ctx, message, out)` answers one RPC message, writing into `out`, or returns null when none is due; `rpc.record` frames TCP records. These serve RPC over anything, or test without sockets.

## Limits

* Reads and writes: up to 1 MiB; every write is `FILE_SYNC`.
* UDP replies: 65,535 bytes, so large reads need TCP.
* Callers' supplementary groups: 16, as AUTH_SYS carries.

## Not yet

* **Host-name matching:** `host` and `*.domain` clients match only a caller's name, which nothing resolves yet (planned: forward-confirmed reverse DNS, cached), so such rules match no one. Use addresses or CIDRs.
* **Opening by handle:** `open_by_handle_at` on Linux and `fsgetpath` on macOS, so handles outlive changes made on the server itself; and volume UUIDs as file-system IDs.
* NFS v4, and file-system backends other than the local one; see [DEVELOPMENT.md](../../DEVELOPMENT.md).

## Testing

`zig build test` runs libnfsd's unit and loopback tests; `src/libnfsd/fuzz.zig` fuzzes record marking and dispatch. See [DEVELOPMENT.md](../../DEVELOPMENT.md).
