# Architecture

How znfsd is put together. [AGENTS.md](AGENTS.md) is the specification; [DEVELOPMENT.md](DEVELOPMENT.md) covers the workflow.

Built so far: XDR and RPC, UDP and TCP serving, the portmapper and registration, export rules, file handles, and MOUNT. The rest describes the design.

## Components

```
            clients (macOS, Linux, Windows)
                        │ ONC RPC over TCP and UDP
┌───────────────────────▼──────────────────────────┐
│ libnfsd                                          │
│   RPC/XDR ─► portmapper   NFS v3   MOUNT v3      │
│              NLM v4       NSM v1                 │
│   exports · maps · file handles · locks          │
│   state-storage hooks                            │
└──────▲─────────────────────────────▲─────────────┘
       │ std.Io                      │ hooks
┌──────┴─────────────────────────────┴─────────────┐
│ znfsd                                            │
│   CLI · control socket · SQLite · web monitor    │
└──────────────────────────────────────────────────┘
```

* **libnfsd** implements the protocols and server logic. It has no CLI, no database, and no fixed I/O model: the embedder supplies an `Io`, an `Allocator`, and state-storage hooks.
* **znfsd** is one embedder: it parses the command line, implements the hooks with SQLite, serves the control socket, and runs the admin web server.

## RPC programs

| Program | Number | Version | Port |
| --- | --- | --- | --- |
| Portmapper | 100000 | 2 (rpcbind 3 and 4 as clients need) | 111 |
| NFS | 100003 | 3 | 2049 |
| MOUNT | 100005 | 3 | 20048 |
| NLM | 100021 | 4 | 32803 |
| NSM | 100024 | 1 | 32765 |

Each program listens on TCP and UDP at every `--bind` address. When both `0.0.0.0` and `::` are requested, as by default, znfsd binds one dual-stack `::` socket instead, which also serves IPv4: Zig 0.17 can't make a TCP listener IPv6-only, and on Linux the two would collide. At startup, znfsd probes port 111; on macOS, it first connects to `/var/run/portmap.socket`, which makes launchd start the on-demand `rpcbind`, and retries for up to 6 seconds, since `rpcbind` takes a moment to answer after a wake, and until it binds, pings fail at once rather than time out. It exits when idle, but stays while it holds registrations. If a portmapper answers, znfsd registers with it; otherwise it serves its own when root, or exits. With `--no-portmap`, it skips the portmapper entirely and serves only NFS and MOUNT on their fixed ports. Any existing registration or bound port that znfsd needs is fatal, which keeps it from silently sharing duties with the host's own NFS services.

## Requests

1. A record arrives: a datagram, or a record-marked TCP fragment sequence.
2. XDR decodes the RPC call header; the program, version, and procedure select a handler.
3. AUTH_SYS credentials pass through squash and the matching rule's map, yielding host IDs.
4. The handler resolves file handles, checks access against the export rule, performs the operation, and encodes the reply, mapping host IDs back to client IDs.

Writes are always stable: data reaches storage before the reply, so COMMIT has nothing left to do.

## Export rules

A rule is (path, client, options). Stored rules come from the hooks; ephemeral rules from `serve` arguments overlay them by (path, client), and ephemeral groups and maps overlay stored ones by name. For each request, the most specific matching client wins. Host and `*.domain` clients need the caller's name, found by forward-confirmed reverse DNS and cached.

## File handles

```
version │ export ID │ filesystem ID │ inode │ generation
```

Handles name a file without its path, so they survive renames. To resolve one, libnfsd opens by handle on Linux (`open_by_handle_at`), asks the filesystem for the path on macOS (`fsgetpath`), and otherwise falls back to the last-known path, accepting it only if the inode still matches. Each handle's last-known path is stored and updated on NFS renames.

## Locks and recovery

NLM locks live only in memory. NSM records which clients hold state, and that list persists with an NSM state number. At startup, znfsd increments the number, notifies each listed client with SM_NOTIFY, and for about 90 seconds grants only lock reclaims, so clients recover their locks before new ones compete.

## State

znfsd stores exports, groups, maps, file handles, mount records, the NSM monitor list, and the NSM state number in SQLite, using WAL mode and a busy timeout. While the daemon runs, commands reach it through the control socket and it writes the database; otherwise commands open the database themselves.

## I/O

Network and basic file I/O go through `std.Io`; file-system calls it lacks (`fstatat`/`statx`, `realpath`, and later the `*at` calls, `open_by_handle_at`, and `fsgetpath`) go through libc in `sys.zig`, returning errno values for mapping to protocol statuses. Under `std.Io.Threaded`, these blocking calls run on worker threads like any other.

All other I/O goes through `std.Io`, so libnfsd runs on whatever implementation its embedder chooses. znfsd uses `std.Io.Threaded`, the only implementation in Zig 0.17 that can run a server: `std.Io.Evented` stubs TCP listen and accept on Linux (io_uring) and also UDP bind on macOS (Grand Central Dispatch). Switching later touches only znfsd's `main`.

## Privileges

When root, znfsd binds its ports, then with `--run-as USER` drops to that user and accesses files as them; maps are disabled because acting as other users needs root. Opening files by handle on Linux needs `CAP_DAC_READ_SEARCH`, so an unprivileged znfsd relies on stored paths.
