# znfsd

NFS v3 server daemon with few options and sensible defaults.

## Scope

* Services: NFS v3, mountd, statd, lockd, and portmapper, all integrated
* Hosts: recent Linux and macOS
* Clients: macOS 15.8+, Linux 6.12+, Windows 10+
* `libnfsd`: embeddable implementation with state-storage hooks
* `znfsd`: CLI daemon built on `libnfsd`
* `libnfsd` adopted connections: `server.serveConnection` serves a stream the embedder accepted (any address family), every given program on it, until the peer closes it or the task is canceled, then closes it; AUTH_SYS taken as given

## Behavior

* Portmapper: register with an incumbent if a probe finds one; otherwise start one when root, else fail
* Portmapper probe on macOS: first wake launchd's on-demand `rpcbind` by connecting to `/var/run/portmap.socket`, then retry briefly
* `--no-portmap`: neither register nor start a portmapper; clients must name ports, and NLM and NSM are off
* Host NFS services (e.g., macOS `nfsd`, Linux kernel `nfsd`/`lockd`): fail on any port or RPC registration collision
* Exports: always sync, crossmnt, no subtree check, AUTH_SYS
* MNT: ACCES unless the path lies, reached without links, inside an export admitting the caller, so it tells nothing of other paths
* Writes: UNSTABLE ones reach storage by COMMIT, others before the reply
* fileid: the inode on the export root's file system; elsewhere, the inode with the filesystem ID folded in
* Commands: `add` is idempotent and merges options into an existing rule, `set` replaces a rule's options, and changes apply immediately; they go through the control socket when the daemon runs, else operate on the database directly
* Database: WAL mode with a busy timeout
* `lock` commands: need the daemon; without it, `list` is empty and `del` fails
* `mount` commands: work with or without the daemon
* Rule matching: the most specific CLIENT wins, whole, without merging: host, longest CIDR, longest `*.domain`, `@GROUP`, `*`
* Host and `*.domain` matching: forward-confirmed reverse DNS, cached, resolved asynchronously; until built, new rules and groups refuse such CLIENTs, since they'd match no one
* `--bind`: repeatable; default `0.0.0.0` and `::`
* Ports: fixed; nfs 2049, mount 20048, stat 32765, lock 32803
* TCP connections: up to 1024 per listener, each up to 16 calls at once; replies in any order, matched by XID
* `--socket` default: root `/var/run/znfsd.sock`; else `$XDG_RUNTIME_DIR/znfsd.sock` (Linux), `$TMPDIR/znfsd.sock` (macOS)
* `--db` default: root `/var/lib/znfsd/znfsd.db` (Linux), `/var/db/znfsd/znfsd.db` (macOS); else `~/.local/state/znfsd/znfsd.db` (Linux), `~/Library/Application Support/znfsd/znfsd.db` (macOS)
* `--run-as USER`: drops root after binding low ports, then accesses the host as USER; disables maps; gives USER the database's files, and its directory only if it holds nothing else
* Database files: each a file of its own (no symbolic or hard links), so none aims znfsd's writes elsewhere
* Maps: at most one per export rule, via `map=MAP`; translate UIDs and GIDs independently; requests map REMOTE to LOCAL, replies map LOCAL to its first REMOTE; local names resolve to numbers on `add`
* Anon: a map's REMOTE-less entry; unmapped IDs and squash use it; without one, unmapped IDs pass through and squash uses the host's `nobody`
* `serve` ephemera: exports, `--group`, and `--map` shadow stored rules, groups, and maps of the same key while serving, without being stored; `--group` and `--map` repeat, one entry each
* Ephemeral export: `PATH[:OPTIONS[:CLIENTS]]`; escape `:` in PATH as `\:`; OPTIONS and CLIENTS comma-separated; CLIENTS defaults to `*`
* State: SQLite at `--db` (exports, groups, maps, file handles, mount records, statd monitor list, NSM state number); locks aren't stored
* Restart: increment the NSM state number, send SM_NOTIFY to monitored hosts, then grant only lock reclaims during a ~90 s grace period
* `mount del` and `lock del`: also drop the host from the statd monitor list
* File handles: ≤64 bytes: format version, export ID, filesystem ID (volume UUID where available), inode, and generation (0 when unreadable)
* Paths from clients or handles: opened, stated, read as links, and queried for capacity through descriptors that follow no symbolic link in any component, so none reaches outside its export
* Handle resolution: `open_by_handle_at` (Linux), `fsgetpath` (macOS), else the stored last-known path if its inode matches; else `NFS3ERR_STALE`; NFS renames update stored paths
* Control: Unix socket at `--socket`, mode 0600
* Admin web server: `--web`, default `127.0.0.1:8049`; live activity monitor only, no auth
* `activity`: the monitor's snapshot as JSON, from the running daemon

## Code

* Zig 0.17+
* I/O: through `std.Io`; libnfsd takes an `Io` from its embedder
* libc: linked; file-system calls `std.Io` lacks go through `std.c` and `std.posix`
* znfsd: `std.Io.Threaded`; revisit `std.Io.Evented` once it supports TCP listen and UDP bind

## Docs

* Keep this file, [README.md](README.md), [DEVELOPMENT.md](DEVELOPMENT.md), [ARCHITECTURE.md](ARCHITECTURE.md), and [CHANGELOG.md](CHANGELOG.md) current with each change
* Specifications: copy to `docs/specifications/` and index in its [README.md](docs/specifications/README.md)

## Usage

```
znfsd [--socket PATH] [--run-as USER] [--bind ADDR ...] [--db PATH]
    serve [--{nfs,mount,stat,lock}-port PORT]
          [--web [ADDR:]PORT]
          [--no-portmap]
          [--group GROUP:CLIENT[,CLIENT ...] ...]
          [--map MAP:LOCAL=[REMOTE[,REMOTE ...]] ...]
          [PATH[:OPTION[,OPTION ...][:CLIENT[,CLIENT ...]]] ...]
    stop
    activity                                   # the monitor's JSON snapshot

    export list [PATH]
    export add  PATH CLIENT [OPTION ...]
    export set  PATH CLIENT OPTION ...
    export del  PATH [CLIENT]

    group  list [GROUP]
    group  add  GROUP CLIENT ...
    group  del  GROUP [CLIENT ...]

    map    list [MAP]
    map    add  MAP LOCAL [REMOTE ...]         # no REMOTE: anon
    map    del  MAP [REMOTE ...]

    mount  list [PATH]
    mount  del  HOST [PATH]                    # forgets mount records

    lock   list [PATH]
    lock   del  HOST [PATH]                    # releases locks

    help

Aliases  list: ls    del: delete, rm

CLIENT   host | *.domain | CIDR | @GROUP | *
OPTION   rw | ro                               # default rw
         squash=root|all|none                  # default root
         map=MAP
LOCAL    [UID|USER][:GID|:GROUP]
REMOTE   [UID][:GID]
```

## Deferred, supported by design

* NFS v4.0, v4.1, and v4.2
* Retro clients: macOS 10.15.7+
* Admin users and passwords, stored hashed
* Pluggable file-system backends in libnfsd, the local file system being one

## Unresolved

None.
