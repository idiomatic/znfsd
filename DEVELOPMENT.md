# Development

How to work on znfsd. [AGENTS.md](AGENTS.md) is the specification; [README.md](README.md) explains it for users, and [ARCHITECTURE.md](ARCHITECTURE.md) describes the design.

So far, `serve` runs the portmapper logic, MOUNT, all of NFS v3, and locking (NLM and NSM, with restart recovery), with stored and ephemeral exports and groups; Linux 6.18 has mounted it read-write and locked, blocked, and reclaimed after a restart. Maps and `--run-as` work too. The `export`, `group`, `map`, `mount`, `lock`, and `stop` commands work, through the control socket when the daemon runs, so changes apply at once. Running as root, each request acts as its caller. macOS 27.2 and Windows 11 have mounted it too, read-write and locking. The activity monitor serves at `127.0.0.1:8049`. Each TCP connection answers up to 16 calls at once, and embedders can hand libnfsd connections they accepted themselves, such as vsock.

## Requirements

* Zig 0.17+
* A Linux or macOS host

SQLite is vendored as its C amalgamation in [vendor/sqlite](vendor/sqlite/README.md) and built by `zig build`; there are no other external dependencies.

## Layout

| Path | Contents |
| --- | --- |
| `src/libnfsd/` | Embeddable server: RPC, XDR, NFS v3, MOUNT, NLM, NSM, portmapper, and state-storage hooks; [guide](src/libnfsd/README.md) |
| `src/znfsd/` | CLI daemon: arguments (`cli.zig`), ephemeral exports (`ephemeral.zig`), SQLite storage (`db.zig`), commands (`commands.zig`), the control socket (`control.zig`), the daemon (`daemon.zig`), and the activity monitor (`activity.zig`, `web.zig`, and its page in `web/`) |
| `vendor/sqlite/` | The SQLite amalgamation; see its [README.md](vendor/sqlite/README.md) |
| `src/znfsd/usage.txt` | `help` output; a copy of the Usage block in [AGENTS.md](AGENTS.md), kept identical |
| `docs/specifications/` | Copies of the external specifications, indexed in its [README.md](docs/specifications/README.md) |

## Building and testing

```sh
zig build                 # build zig-out/bin/znfsd
zig build test            # run unit tests
zig build test -Dtest-filter=NAME   # only tests whose names contain NAME
zig build run -- help     # run znfsd with arguments
zig fmt build.zig src     # format
```

Cross-compile static Linux binaries for test machines:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe --prefix /tmp/znfsd-linux
```

## Fuzzing

`src/libnfsd/fuzz.zig` feeds untrusted bytes to TCP record marking and to `server.dispatch`, with all five programs over a scratch export whose options (read-only, squash, map) vary per input. Each input makes up to eight calls, raw or built from parts: file handles taken from earlier replies, likely names, numbers, and bytes. An input fails on a panic, a leak, or an error log. NLM's `_MSG` procedures are skipped, since their callbacks wait on the caller's portmapper. `zig build test` replays 300 fixed pseudorandom inputs per target; to search:

```sh
zig build test --fuzz=1M -Doptimize=ReleaseSafe -Dtest-filter="fuzz dispatch"
```

Run it on Linux as root too (a throwaway VM), where acting as callers, `openat2`, and `fchmodat2` come into play. Smith replays inputs eight bytes per value and maps out-of-range values to the minimum, so the harness draws whole `u64`s and reduces them itself, with zero (exhausted input) meaning the common choice.

## Test tiers

1. **`zig build test`**, no root: unit tests, plus loopback tests that run libnfsd in-process on ephemeral ports against an in-project RPC client.
2. **Unprivileged daemon with kernel clients:** `znfsd serve` on the host as yourself. Every `rpcbind` tested (macOS 27.2; Alpine, Ubuntu, and Fedora) accepts registrations from non-root over loopback, and macOS's on-demand `rpcbind` starts when any user connects to `/var/run/portmap.socket`. Where no portmapper is available, use `--no-portmap` and mount with explicit ports and `nolock` (see [README.md](README.md)).
3. **Full stack as root, isolated:** znfsd as root in an Apple `container` (static `aarch64-linux-musl` build), which has its own kernel, binds every port, and is reachable from the host and every VM on `192.168.64.0/24`. Kernel clients run in terrarium VMs. Container kernels have no NFS client, and terrarium VMs can't reach each other, so neither can stand in for the other's role. terrarium's named networks (`terrarium network znfsd --subnet CIDR --reserve client1=IP`, then `start --network znfsd:client1`) let VMs reach each other and the Mac (at the subnet's `.1`), so znfsd can also run on the Mac or as root in a VM serving client VMs. Alpine guests may get a default route via their own named-network address; delete it for internet access. Suites: Connectathon (`cthon04`) from Linux and macOS clients, server-restart and client-reboot lock recovery, and a Windows smoke test.

macOS clients ask before an app reads a network volume, and a background process like terrarium's helper can't be asked, so its reads block, then fail with "Operation not permitted". Run macOS client tests from Terminal in the VM's GUI, allowing its prompt once, and write results to a local file for `exec` to read. macOS handles `flock()` on NFS within the client; use `fcntl()` locks to test NLM. Debug builds log every RPC call (`debug(libnfsd)`), which shows what a client sent.

Connectathon: clone `git://git.linux-nfs.org/projects/steved/cthon04.git` on a Linux client with `gcc`, `make`, `libtirpc-devel`, and `nfs-utils`, build with `make`, then run `./server -a -o vers=3,proto=tcp -p EXPORT -m MOUNTPOINT SERVER` as root. To cover acting as an unprivileged caller, run each suite as a user: `cd SUITE && NFSTESTDIR=MOUNTPOINT/DIR ./runtests -t`. Fedora's Cloud Base Generic image (`terrarium start --provision cloud-init`) serves as both client and root server; Ubuntu's desktop ISO as a client with `--provision cloud-init --tweak ubuntu-no-welcome` (its live session needs `pkg-config` too). Copy the tree for the user with `cp -a`: newer timestamps make a suite rebuild, which fails under `dash`. For macOS clients, which lack developer tools, build on the host: in `tests.init.sh`'s MacOSX case, add `-DSTDARG` (without it, `tlock` crashes on arm64, whose variadic calling convention differs) and `-std=gnu89` with clang's newer errors downgraded, then `make FSTYPE=nfs OS=MacOSX` (`tools/` fails to build and isn't needed) and stage special's files with `make copy DESTDIR=DIR`. In the VM, mount as the user with `mount_nfs -o vers=3,tcp`, then run basic and lock with `runtests -t`, and special by copying the staged files into its test directory and running `sh runtests` there. General compiles code on the mount, so it needs the developer tools in the VM. On Linux clients, lock test 13.1 warns that `mmap` of a locked file succeeded; the client decides that, and the suite accepts it.

Lock recovery: hold a lock from a client (`fcntl.lockf` in a sleeping Python process) and check `znfsd lock list`. Server restart: restart znfsd; the client reclaims at once, a new lock from it waits out the grace period, and one after the grace period succeeds. Client crash: `echo b > /proc/sysrq-trigger` in the client; at boot its `sm-notify` tells znfsd, which drops the lock (the client's `/var/lib/nfs/statd/sm.bak` empties once acknowledged), and the client can lock again after remounting. Verify an uploaded binary's checksum in the VM before restarting the server: an upload can send a stale file.

Windows needs the Client for NFS feature (`Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly,ClientForNFS-Infrastructure -All`; Pro or better). `mount -o anon` sends UID and GID 4294967294, which a map can make a host user. It writes back lazily, so changes reach the server a while after a command returns, and it locks with NLM's NM_LOCK, unmonitored, plus SHARE and UNSHARE.

If a VM gets only a `169.254.x` address, the host's DHCP isn't answering; give it a static address on `192.168.64.0/24` with gateway `192.168.64.1` and DNS `1.1.1.1`.

Test against each supported client: macOS 15.8+, Linux 6.12+, and Windows 10+. Boot install media from `~/Developer/Images` read-only, run VMs without audio, and save prepared clients as new layers rather than changing shared ones.

## Routine

Each covers only what changed since the commit it last looked at.

| Task | Scope | Last done | Commit |
| --- | --- | --- | --- |
| Code review | libnfsd and znfsd: correctness, clarity, and conformance to [AGENTS.md](AGENTS.md) and the [specifications](docs/specifications/README.md) | 2026-11-23 | `ee622cc` |
| Security review | Untrusted AUTH_SYS clients, export confinement and symbolic-link races, identity switching and `--run-as`, the control socket, and the web monitor | Never | |

## Review findings

From the code review of `ee622cc`; each leaves this list when fixed or accepted as a limit.

### High

* **Long renamed paths crash the daemon:** `renamePrefix` lengthens cached paths unchecked ([files.zig:119](src/libnfsd/files.zig:119)), and `resolve` copies them into a `max_path` buffer ([files.zig:147](src/libnfsd/files.zig:147)); a client nesting directories near `PATH_MAX` and renaming the top one overflows it. Forget paths past `max_path`; treat them as stale.
* **Clients can release others' locks:** lock owners are only the client's `caller_name`, `svid`, and `oh`. UNLOCK and CANCEL check only `admits`, not the handle's export ([nlm.zig:285](src/libnfsd/nlm.zig:285), [nlm.zig:292](src/libnfsd/nlm.zig:292)), and TEST reveals holders' owners. A LOCK under another host's name moves its NSM entry to the caller ([nsm.zig:82](src/libnfsd/nsm.zig:82)), whose FREE_ALL then frees that host's locks. Key owners by address too, check exports on UNLOCK and CANCEL, and don't move a name that holds locks.
* **`--run-as` gives away files:** it changes the owner of `--db`'s parent directory, whatever it is, and follows symbolic links doing so ([daemon.zig:453](src/znfsd/daemon.zig:453), [daemon.zig:471](src/znfsd/daemon.zig:471)); a link planted at `znfsd.db-shm` hands its target to USER at the next start. Use `AT_SYMLINK_NOFOLLOW`, and change only directories znfsd created.

### Medium

* **Symbolic links mid-path escape the export for metadata:** path-based `lstat` and `readLink` ([sys.zig:40](src/libnfsd/sys.zig:40), [sys.zig:550](src/libnfsd/sys.zig:550)) follow links in every component but the last. In `Files.resolve`, LOOKUP, and READDIRPLUS, a client racing a RENAME and SYMLINK gets and keeps a handle whose GETATTR, ACCESS, READLINK, and LOOKUP reach outside the export (reads and writes still fail in `openSafe`). Stat and read links through descriptors from `openSafe`.
* **MNT probes outside exports:** `realpath` runs as the server, and its failures return the specific status ([mount.zig:186](src/libnfsd/mount.zig:186)), so MNT through a symbolic link tells which paths exist anywhere. Return ACCES unless the path stays inside an export.
* **READDIR can loop forever:** when no entry fits `maxcount` or `dircount`, the reply is OK, empty, and not EOF ([nfs.zig:613](src/libnfsd/nfs.zig:613)), so the client asks again forever. Return `NFS3ERR_TOOSMALL`; let the first entry exceed `dircount`, a hint.
* **Connections reserve memory up front:** each slot allocates `max_record` twice before reading ([server.zig:283](src/libnfsd/server.zig:283)): about 2 MiB per idle connection, 34 MiB for one pipelining without reading replies, across 1024 connections per listener. Size buffers to the record; budget them globally; time out stalled writes.
* **Descriptors run out before the connection cap:** 8 listeners × 1024 connections exceed default `RLIMIT_NOFILE`, connections never idle out, and `accept`'s quota error spins ([server.zig:160](src/libnfsd/server.zig:160)). Raise the limit at start, cap connections globally below it, back off on quota errors, and close idle connections.
* **Failed registrations linger:** `registered` is set only after every `set` succeeds ([service.zig:120](src/libnfsd/service.zig:120)), so a failure partway leaves mappings that make the next start fail with `AlreadyRegistered`. Unset them on error.
* **`_MSG` stalls NLM over UDP:** `_RES` is sent inline, after a GETPORT of up to 4 s ([nlm.zig:210](src/libnfsd/nlm.zig:210), [callback.zig:25](src/libnfsd/callback.zig:25)), and `serveUdp` handles one datagram at a time. Send it in the background, as GRANTED_MSG is; cache ports.
* **GRANTED_MSG isn't retried:** one lost datagram leaves a client never told of a lock it holds ([nlm.zig:360](src/libnfsd/nlm.zig:360)). Resend until GRANTED_RES; release after a few tries.
* **No limits on locks, waiters, or monitored hosts:** each grows per request ([locks.zig:59](src/libnfsd/locks.zig:59), [nlm.zig:125](src/libnfsd/nlm.zig:125), [nsm.zig:57](src/libnfsd/nsm.zig:57)), monitored hosts persist, and coalescing is quadratic. Cap them per host and overall (`denied_nolocks`); index locks by file.
* **A second `serve` changes the running daemon's state:** it advances the NSM state, and with `--no-portmap` deletes the monitor list, before `control.listen` finds the running daemon ([daemon.zig:148](src/znfsd/daemon.zig:148), [daemon.zig:177](src/znfsd/daemon.zig:177)). Listen first.
* **Missing maps pass IDs through:** `export add … map=X` and `map del X` don't check that X exists or is unused ([commands.zig:78](src/znfsd/commands.zig:78)), so the running daemon maps nothing ([nfs.zig:373](src/libnfsd/nfs.zig:373)) and the next start fails. Refuse both.
* **SM_NOTIFY can precede registration:** `notifyRestart` waits a fixed 2 s ([daemon.zig:505](src/znfsd/daemon.zig:505)), and the grace period starts before binding ([daemon.zig:160](src/znfsd/daemon.zig:160)), while the macOS portmapper probe can take 15 s. Start both once services are registered.
* **Offline `mount del` keeps the statd monitor** ([commands.zig:232](src/znfsd/commands.zig:232)), unlike AGENTS.md; delete it from `monitors` too.
* **Offline `lock list` fails** ([main.zig:72](src/znfsd/main.zig:72)); AGENTS.md says it's empty.

### Low

* **UMNT misses canonicalized records:** MNT stores the canonical path, UMNT matches the client's ([mount.zig:153](src/libnfsd/mount.zig:153)), so `/srv/share/` stays mounted. Canonicalize in UMNT.
* **CREATE UNCHECKED reapplies mode (and, on macOS, group) to an existing file** ([nfs.zig:1034](src/libnfsd/nfs.zig:1034)), failing with PERM for non-owners; apply only the size, as Linux does.
* **READLINK and SYMLINK cap targets at 1024 bytes** ([nfs.zig:496](src/libnfsd/nfs.zig:496), [nfs.zig:1056](src/libnfsd/nfs.zig:1056)): READLINK truncates silently, SYMLINK answers GARBAGE_ARGS. Use `sys.max_path`; answer NAMETOOLONG.
* **FSSTAT's `afiles` is the free count, not the available count** ([nfs.zig:666](src/libnfsd/nfs.zig:666)); report `f_favail` on Linux.
* **`sys.resume` ignores a failed switch back** ([sys.zig:468](src/libnfsd/sys.zig:468)), so the request would go on as the server; fail it.
* **Server groups past 32 are dropped** by `saveServerGroups`, and `restoreLinux` restores fsgid 0, not the process's own ([sys.zig:391](src/libnfsd/sys.zig:391)).
* **Races:** UNLOCK's `hostHolds` then `unmonitor` can unmonitor a host that just locked ([nlm.zig:295](src/libnfsd/nlm.zig:295)); an error in `wake` strands waiters already granted ([nlm.zig:346](src/libnfsd/nlm.zig:346)); a downgrade or shrink by a holder doesn't wake waiters ([nlm.zig:273](src/libnfsd/nlm.zig:273)).
* **Callbacks:** a `GRANTED_MSG` argument can exceed `callback.zig`'s 2048-byte buffer ([callback.zig:49](src/libnfsd/callback.zig:49)); replies aren't checked against the address called; FREE_ALL decodes `max_string + 1` ([nlm.zig:231](src/libnfsd/nlm.zig:231)).
* **`mapSetError` reports cancellation as a refusal** ([service.zig:158](src/libnfsd/service.zig:158)); `dispatch` asserts 24 bytes of `out` but may write 32 ([server.zig:60](src/libnfsd/server.zig:60)).
* **Rules and members are keyed as typed:** `10.0.0.1`, `10.0.0.1/32`, and `::ffff:10.0.0.1` are three rows ([commands.zig:54](src/znfsd/commands.zig:54)); store `Client.format`.
* **Repeated `--group` keeps only the last** ([daemon.zig:277](src/znfsd/daemon.zig:277)); merge as `--map` does.
* **`$XDG_STATE_HOME` overrides the default `--db`** ([db.zig:512](src/znfsd/db.zig:512)), which AGENTS.md doesn't say.
* **The control socket** unlinks whatever is at `--socket` when connecting fails ([control.zig:82](src/znfsd/control.zig:82)), and one silent peer blocks every command ([control.zig:99](src/znfsd/control.zig:99)); the web monitor's connections, off loopback, are unbounded and never time out ([web.zig:56](src/znfsd/web.zig:56)).
* **Anti-patterns:** control flags in `readdir(plus)`, `remove(directory)`, `make(kind)`, `unlinkIn(directory)`, `createIn(exclusive)`, `callback.call(reply: ?…)`, and nullable-means-all in `releaseHost(?File)`, `unmount(?path)`, and `forget(?path)`; boolean blindness in CREATE's raw `how`, WRITE's stability as a bool, and `server_groups_state` as 0/1/2.
* **Clarity:** `statIn` duplicates `statAt`; `if (kind == .lnk) .lnk else kind` ([nfs.zig:1096](src/libnfsd/nfs.zig:1096)); comments in [commands.zig](src/znfsd/commands.zig:1), [db.zig](src/znfsd/db.zig:1), and `Command.verb` ([cli.zig:19](src/znfsd/cli.zig:19)) omit maps and `activity`.
* **Spec ahead of code:** [AGENTS.md](AGENTS.md) states handle resolution by `open_by_handle_at` and `fsgetpath`, and volume UUIDs in handles, which aren't built; mark them unbuilt there until they ship.

## To do

* Host-name matching: forward-confirmed reverse DNS, cached and resolved asynchronously, for `host` and `*.domain` clients
* Handle resolution: `open_by_handle_at` (Linux) and `fsgetpath` (macOS) before the last-known path; volume UUIDs as file-system IDs

## File-system backends

Deferred. File-system calls already pass through one narrow layer, `sys.zig` (about 30 operations: stat, safe open, the `*at` calls, directory reading, reads and writes, sync, capacity, and identity switching), which is where a `libnfsd.Fs` interface would go, letting embedders serve synthesized file systems (in memory for tests, SQLite or object stores, generated content, overlays). `std.Io` isn't the place: libnfsd uses it only for networking, and its file model lacks owners, modes, inodes, links, devices, and file-system IDs.

* The backend supplies file identity (file-system ID, inode, generation) and resolves handles; the path cache and the no-links `*at` rules become the local backend's own.
* Calls take the caller's credentials: the local backend acts as the caller, a virtual one checks access its own way.
* NFS's procedures, MOUNT's root lookup, and NLM's handle lookup move behind the interface; RPC, protocol logic, locking, maps, and squashing stay as they are.
* An in-memory backend comes with it, to prove the interface and speed up tests.

## Web admin

The activity monitor is a znfsd module (`web.zig`, `activity.zig`) in the daemon's process; libnfsd only offers the observer hook it feeds on. That suits today's monitor: read-only, loopback only, GET only, small.

The deferred admin features (users and passwords, changes from the web, perhaps TLS or non-loopback access) should move it into its own process, so HTTP parsing, password checks, and sessions never run in the NFS daemon, possibly as root:

* The snapshot is already a control-socket request (`znfsd activity`), so a separate web process needs nothing new.
* `serve` starts `znfsd web` as a child, unprivileged, and gives it one end of a socket pair: no file permissions involved, and the daemon answers only what that channel allows (read-only until admin features exist).
* Admin changes are the CLI's commands over that channel, so the web side never reimplements them.
* Live updates: polling the snapshot each second, or a streaming `watch` request.

## Documentation

With each change, update [AGENTS.md](AGENTS.md), [README.md](README.md), this file, [ARCHITECTURE.md](ARCHITECTURE.md), and [CHANGELOG.md](CHANGELOG.md). Copy each external specification the code relies on into `docs/specifications/` and index it there.
