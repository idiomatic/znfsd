# Changelog

All notable changes to znfsd are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## Planned

* NFS v4.0, v4.1, and v4.2
* Retro clients: macOS 10.15.7+
* Admin users and passwords, stored hashed
* Pluggable file-system backends in libnfsd

## Unreleased

### Fixed

* READDIR and READDIRPLUS answer `NFS3ERR_TOOSMALL` when no entry fits `maxcount`, and send one entry even past `dircount`, so a client is never sent an empty, unfinished listing to ask for again forever
* MNT answers ACCES for any path not inside an export admitting the caller without links, so it no longer tells which paths exist elsewhere
* Handles' stats, link reads, and file-system queries refuse symbolic links mid-path, as opens do, so a client racing a RENAME and SYMLINK can't read metadata outside its export
* `mount del HOST` without the daemon drops HOST, by name or address, from the stored statd monitor list too, as it does with the daemon
* SM_NOTIFY and the grace period start once every service is bound and registered, not after a fixed 2 seconds and before binding, so clients told of a restart find NLM and NSM, and the grace period isn't spent waiting for macOS's portmapper
* `export add|set` refuse `map=` for a map that doesn't exist, and `map del` refuses to empty a map rules name, so the running daemon never maps nothing and the next start doesn't fail
* A second `serve` exits before changing anything stored, rather than advancing the running daemon's NSM state number and, with `--no-portmap`, deleting its monitored hosts
* `--run-as` gives USER only the database's own files, and its directory only if that holds nothing else; database files that are links are refused, so none can hand USER, or aim root's writes at, another file
* Lock owners include the caller's address, so a client giving another's name and process can't release its locks, and can't take over its monitoring or its FREE_ALL
* Renaming a directory forgets cached paths it grows past the path limit, rather than crashing the daemon when they're next used
* An IPv4-mapped CLIENT (`::ffff:10.1.2.3`, or a CIDR of at least `/96`) is IPv4; one no longer crashes the daemon at the next IPv4 request
* TCP listeners serve at most 1024 connections (`ConnectionOptions.max_connections`), and the web monitor drops requests with over 100 header lines
* Owner overrides work for files directly under `/`; CREATE UNCHECKED doesn't open an existing device or FIFO
* READ replies carry the attributes and end-of-file seen at the read; ACCESS grants owners read and write as READ and WRITE do; FSSTAT sizes saturate

* `export add|set`, `group add`, and ephemeral exports and groups refuse host and `*.domain` clients until name matching is built, so a restrictive host rule can't be bypassed by a broader one

* READDIR and READDIRPLUS answer `NFS3ERR_BAD_COOKIE` when the directory changed since the listing began, so no entries are skipped
* `squash=root` squashes group 0 too: as the primary group it becomes the anon's, and from the supplementary groups it is dropped
* macOS syncs with `F_FULLFSYNC`
* The path cache doesn't hold its lock while storing; the database commits with `synchronous=NORMAL`, checkpointing the NSM state number

* COMMIT opens files for writing and reports sync failures
* MNT hides which paths exist from callers outside every export
* Database writes wait for a batch's transaction, so its rollback can't undo them
* Monitored hosts stay in the database until told of a restart, with no 256-host limit
* NLM UNLOCK, CANCEL, and the `_MSG` callbacks answer only hosts an export covers; FREE_ALL and SM_NOTIFY act only for a host at its monitored address
* A failed switch to a caller's identity restores the server's on Linux

### Added

* Specification in [AGENTS.md](AGENTS.md): NFS v3 with integrated mountd, statd, lockd, and portmapper; stored and ephemeral exports, groups, and maps; SQLite state; restart recovery; and the activity monitor
* Build scaffold: `libnfsd` module, `znfsd` executable, `zig build test`, and command-line parsing with `help`
* XDR and ONC RPC codec in `libnfsd`: call headers, replies, AUTH_SYS, and TCP record marking
* RPC serving over UDP and TCP; a portmapper of our own, or registration with the host's (waking macOS's on-demand `rpcbind`)
* `serve` options parsing; `serve` runs until SIGINT or SIGTERM, then unregisters
* Export rules: clients by host, `*.domain`, CIDR, `@GROUP`, or `*`, the most specific winning; IPv4-mapped peers match IPv4 rules
* File handles (36 bytes: export, filesystem, inode, generation)
* MOUNT versions 1 through 3: MNT (version 3), DUMP, UMNT, UMNTALL, and EXPORT; paths are canonicalized, so `..` and symbolic links can't leave an export
* NFS v3: all 22 procedures; UNSTABLE writes wait for COMMIT, others are `FILE_SYNC`; EXCLUSIVE CREATE keeps its verifier in the file's times, and sticky directories are honored
* File access through descriptors opened without following links in any component, checked against each handle
* `serve` ephemeral exports and `--group`, laid over stored ones
* State in SQLite (vendored 3.54.1) at `--db` or the default path: export rules, groups, and mount records, restored at startup
* `export list|add|set|del`, `group list|add|del`, and `mount list|del`, on the database
* Control socket (mode 0600): commands reach a running daemon and apply at once; `stop`
* Locking: NLM 4 (synchronous and `_MSG` procedures, blocking locks granted by callback, `FREE_ALL`) and NSM 1; after a restart, the NSM state advances, monitored clients are notified, and a 90-second grace period admits only reclaims
* `lock list|del` on the live locks
* File handles' paths kept in the database, so handles survive restarts; a READDIRPLUS reply's paths are written in one transaction
* Maps: `map list|add|del` and `serve --map`, applied to callers, squashing, owners in replies, and owners set by clients
* `--run-as USER`: drops root once every port is bound and registered; disables maps
* RPC calls logged at debug level
* Fuzz tests of record marking and request dispatch, and `-Dtest-filter`
* Activity monitor at `--web [ADDR:]PORT` (default `127.0.0.1:8049`): clients, procedures with timing, exports, mounts, locks, and recent calls, live; `znfsd activity` prints the snapshot as JSON
* Owner override: files are opened for their owner whatever their mode, as a program keeps using a file it opened before a chmod; SETATTR changes modes, owners, and times through the directory
* As root, each NFS request acts as its caller (per-thread credentials: `setfsuid`/`setfsgid`/`setgroups` on Linux, `pthread_setugid_np` on macOS)
* `serve --no-portmap`, for running without root or a portmapper
* Fileids unique across the file systems an export crosses into
* Concurrent calls on each TCP connection, up to 16 (`Config.max_calls`), replies matched by XID
* libnfsd adopted connections: `server.serveConnection` serves a stream the embedder accepted (vsock, say), every given program on it, with no listener or portmapper
* [README.md](README.md), [libnfsd's guide](src/libnfsd/README.md), [DEVELOPMENT.md](DEVELOPMENT.md), [ARCHITECTURE.md](ARCHITECTURE.md), [LICENSE](LICENSE) (BSD 3-Clause), the [specifications](docs/specifications/README.md) index, and this changelog
