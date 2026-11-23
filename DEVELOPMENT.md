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

### Low

* **CREATE UNCHECKED reapplies mode (and, on macOS, group) to an existing file** ([nfs.zig:1034](src/libnfsd/nfs.zig:1034)), failing with PERM for non-owners; apply only the size, as Linux does.
* **READLINK and SYMLINK cap targets at 1024 bytes** ([nfs.zig:496](src/libnfsd/nfs.zig:496), [nfs.zig:1056](src/libnfsd/nfs.zig:1056)): READLINK truncates silently, SYMLINK answers GARBAGE_ARGS. Use `sys.max_path`; answer NAMETOOLONG.
* **FSSTAT's `afiles` is the free count, not the available count** ([nfs.zig:666](src/libnfsd/nfs.zig:666)); report `f_favail` on Linux.

## To do

* Host-name matching: forward-confirmed reverse DNS, cached and resolved asynchronously, for `host` and `*.domain` clients
* Handle resolution: `open_by_handle_at` (Linux) and `fsgetpath` (macOS) before the last-known path, so handles outlive changes made on the server itself; volume UUIDs, where available, as file-system IDs in place of device numbers

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
