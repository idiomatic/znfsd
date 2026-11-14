# Architecture

How znfsd is put together. [AGENTS.md](AGENTS.md) is the specification; [DEVELOPMENT.md](DEVELOPMENT.md) covers the workflow.

Built so far: XDR and RPC, UDP and TCP serving (with concurrent calls per connection), adopted connections, the portmapper and registration, export rules, file handles, MOUNT, and NFS v3. The rest describes the design.

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

Each program listens on TCP and UDP at every `--bind` address. When both `0.0.0.0` and `::` are requested, as by default, znfsd binds one dual-stack `::` socket instead, which also serves IPv4: Zig 0.17 can't make a TCP listener IPv6-only, and on Linux the two would collide. At startup, znfsd probes port 111; on macOS, it first connects to `/var/run/portmap.socket`, which makes launchd start the on-demand `rpcbind`, and retries for up to 15 seconds: launchd waits 10 seconds before relaunching a daemon that recently ran, and until `rpcbind` binds, pings fail at once rather than time out. It exits when idle, but stays while it holds registrations. If a portmapper answers, znfsd registers with it; otherwise it serves its own when root, or exits. With `--no-portmap`, it skips the portmapper entirely and serves only NFS and MOUNT on their fixed ports. Any existing registration or bound port that znfsd needs is fatal, which keeps it from silently sharing duties with the host's own NFS services.

Embedders can also adopt connections they accepted themselves (vsock, say): `server.serveConnection` serves each with every program given, dispatched by program number, with no listener or portmapper.

## Requests

1. A record arrives: a datagram, or a record-marked TCP fragment sequence. A TCP connection's reader takes one of 16 slots per record and answers it in a task of its own, so a slow call doesn't hold up the rest; each reply is written whole, under a lock, as its call finishes, so replies may go out of order, matched by XID. With every slot busy, the reader waits.
2. XDR decodes the RPC call header; the program, version, and procedure select a handler.
3. AUTH_SYS credentials pass through squash and the matching rule's map, yielding host IDs.
4. The handler resolves file handles, checks access against the export rule, performs the operation, and encodes the reply, mapping host IDs back to client IDs.

Writes asked for as FILE_SYNC or DATA_SYNC reach storage (`fsync`) before the reply; UNSTABLE ones are left to COMMIT, which syncs the whole file, as Linux's kernel server does for `sync` exports. The write verifier changes at each start, so clients resend whatever a restart may have lost.

Every attribute in a reply goes through one function that maps owners back to client IDs and folds the file system into the fileid; the encoders accept nothing else, so no reply, failure or not, can carry host owners.

Files are reached through descriptors, never bare paths: a handle's cached path is opened refusing symbolic links in every component (`O_NOFOLLOW_ANY` on macOS, `openat2` with `RESOLVE_NO_SYMLINKS` on Linux) and its inode checked, then entries are changed relative to that descriptor (`openat`, `mkdirat`, `renameat`, and so on), so a client swapping a directory for a link can't redirect an operation outside its export. A renamed directory's cached descendants move with it.

## Maps

A map is a list of entries, each a host ID (`[UID][:GID]`) and the client IDs that act as it, or with none, the map's anon. Each rule names at most one. In a request, the caller's UID, GID, and supplementary GIDs each become their mapped host ID, else the anon's, else themselves; squashed callers become the anon, else the host's `nobody`. In replies, owners become the first client ID mapped to them; owners a client sets (SETATTR, and the attributes of CREATE, MKDIR, SYMLINK, and MKNOD) are mapped like callers. Stored maps keep host IDs as numbers, names resolved when an entry is added.

## Export rules

A rule is (path, client, options). Stored rules come from the hooks; ephemeral rules from `serve` arguments overlay them by (path, client), and ephemeral groups and maps overlay stored ones by name. For each request, the most specific matching client wins. Host and `*.domain` clients need the caller's name, to be found by forward-confirmed reverse DNS and cached; until that's built, no caller has a name, so those rules match no one.

## File handles

```
version │ export ID │ filesystem ID │ inode │ generation
```

Handles name a file without its path, so they survive renames. They're distinct across file systems an export crosses into, but clients see one device per mount, so fileids are too: the inode on the export root's own file system, and elsewhere the inode XORed with bits from a hash of the file system's ID (its top bit set, so they can't meet the root's). Built so far: resolution through the last-known path, cached by MNT, LOOKUP, READDIRPLUS, and creation, and kept in the database through libnfsd's `files.Store` hook, so handles survive restarts (locks are reclaimed by handle); export roots are always recognized. Only new or changed paths are written, and a READDIRPLUS reply's entries go together, in one transaction. Planned: libnfsd opens by handle on Linux (`open_by_handle_at`), asks the filesystem for the path on macOS (`fsgetpath`), and otherwise falls back to the last-known path, accepting it only if the inode still matches. Each handle's last-known path is stored and updated on NFS renames.

## Locks and recovery

NLM locks live only in memory, with POSIX byte-range semantics per owner (client host, process ID, and owner handle); they coordinate NFS clients with each other, not with processes on the server, since one server process can't hold host locks for many owners. Linux clients use NLM's synchronous procedures; macOS clients use the `_MSG` ones, whose results go back as `_RES` calls to the client's lock manager, found through its portmapper. A blocked request waits in a queue and is granted with a `GRANTED_MSG` callback, sent in the background. With `--no-portmap`, NLM and NSM aren't served.

NLM locks live only in memory. NSM records which clients hold state, and that list persists with an NSM state number. At startup, znfsd increments the number, notifies each listed client with SM_NOTIFY, and for about 90 seconds grants only lock reclaims, so clients recover their locks before new ones compete.

## State

znfsd stores exports, groups, maps, file handles, mount records, the NSM monitor list, and the NSM state number in SQLite, using WAL mode and a busy timeout. Built so far: export rules (path, client, and every option written out, defaults included), group members, mount records (through `mount.Store`, restored at startup), file handles' paths (through `files.Store`), the NSM state number, and monitored hosts (through `nsm.Store`). `serve` lays its ephemeral rules over the stored ones by path and client, and its groups by name. While the daemon runs, commands reach it through the control socket and it writes the database; otherwise commands open the database themselves.

## Control socket

A Unix socket, mode 0600, at `--socket` or the default path. Each connection carries one request, a command's words (a count, then each word's length and bytes), and one reply: the exit status, the output, and the error text, each length-prefixed, all integers big-endian u32s. The daemon runs the same command code as the CLI against its database, then applies the change: export and group changes rebuild the export table, swapped into MOUNT and NFS atomically, and `mount del` also forgets the record in memory. Replaced tables are kept until exit, since requests may still be reading them. A socket file nobody answers on is stale and replaced; one that answers means another daemon is running.

## I/O

Network and basic file I/O go through `std.Io`; file-system calls it lacks (`fstatat`/`statx`, `realpath`, and later the `*at` calls, `open_by_handle_at`, and `fsgetpath`) go through libc in `sys.zig`, returning errno values for mapping to protocol statuses. `realpath`, which Zig discourages ([#19353](https://github.com/ziglang/zig/issues/19353)), is used only where a path must be resolved as a client named it: export paths once at startup, and MNT's requested path, which must then lie inside an export. Under `std.Io.Threaded`, these blocking calls run on worker threads like any other.

All other I/O goes through `std.Io`, so libnfsd runs on whatever implementation its embedder chooses. znfsd uses `std.Io.Threaded`, the only implementation in Zig 0.17 that can run a server: `std.Io.Evented` stubs TCP listen and accept on Linux (io_uring) and also UDP bind on macOS (Grand Central Dispatch). Switching later touches only znfsd's `main`.

## Activity monitor

libnfsd's dispatcher tells an optional observer (`Config.observer`) of every answered call: client, program, procedure, outcome, result size, and time taken. znfsd's observer keeps calls by procedure and by client and a ring of the latest 200. A small HTTP/1.1 server, GET only, serves a page, its script and style, and a JSON snapshot that adds exports, mounts, and locks; the page polls it each second. Bound to loopback, it refuses requests whose `Host` isn't loopback, against DNS rebinding, and every response forbids caching and sets `Content-Security-Policy: default-src 'self'`. `znfsd activity` returns the same snapshot over the control socket. A taken web port only warns. Plans for web administration are in [DEVELOPMENT.md](DEVELOPMENT.md).

## Privileges

When root, znfsd binds its ports, then with `--run-as USER` drops to that user and accesses files as them: once every port is bound and registered (libnfsd's `Config.after_bind`), it hands the database's directory and files and the control socket to USER, then sets USER's groups, GID, and UID, and checks root can't be regained; maps are disabled because acting as other users needs root. Opening files by handle on Linux needs `CAP_DAC_READ_SEARCH`, so an unprivileged znfsd relies on stored paths. Unprivileged, znfsd can't set owners, so a root client's `cp -a` loses ownership. It can open files whose mode denies their owner, as Linux's kernel server's owner override does: when refused on a file the effective user owns (the caller being acted as, else the server's user), it briefly grants the owner read and write to open it, then restores the mode, checking the inode throughout. Mode, owner, and time changes go through the file's directory (`fchmodat2` on Linux, `fchmodat` on macOS, neither following links), so they need no open at all. As root without `--run-as`, each NFS request acts as its caller once its file's rule is known, so the OS checks access with the caller's credentials (after squashing and mapping) and new entries are theirs: on Linux through per-thread `setfsuid`, `setfsgid`, and `setgroups` system calls (libc's wrappers would change every thread), which also drops root's overrides; on macOS through `pthread_setugid_np`, which takes supplementary groups from the host's membership rather than the client's, and gives new entries their directory's group under BSD rules, so znfsd then sets the caller's group where the host allows it. Each request returns to the server's identity when it ends, and the path cache's database writes pause the caller's identity.
