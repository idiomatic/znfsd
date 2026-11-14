# Development

How to work on znfsd. [AGENTS.md](AGENTS.md) is the specification; [README.md](README.md) explains it for users, and [ARCHITECTURE.md](ARCHITECTURE.md) describes the design.

So far, `serve` runs the portmapper logic, MOUNT, all of NFS v3, and locking (NLM and NSM, with restart recovery), with stored and ephemeral exports and groups; Linux 6.18 has mounted it read-write and locked, blocked, and reclaimed after a restart. Maps and `--run-as` work too. The `export`, `group`, `map`, `mount`, `lock`, and `stop` commands work, through the control socket when the daemon runs, so changes apply at once. Running as root, each request acts as its caller. macOS 27.2 and Windows 11 have mounted it too, read-write and locking. The activity monitor serves at `127.0.0.1:8049`.

## Requirements

* Zig 0.17+
* A Linux or macOS host

SQLite is vendored as its C amalgamation in [vendor/sqlite](vendor/sqlite/README.md) and built by `zig build`; there are no other external dependencies.

## Layout

| Path | Contents |
| --- | --- |
| `src/libnfsd/` | Embeddable server: RPC, XDR, NFS v3, MOUNT, NLM, NSM, portmapper, and state-storage hooks |
| `src/znfsd/` | CLI daemon: arguments (`cli.zig`), ephemeral exports (`ephemeral.zig`), SQLite storage (`db.zig`), commands (`commands.zig`), the control socket (`control.zig`), the daemon (`daemon.zig`), and the activity monitor (`activity.zig`, `web.zig`, and its page in `web/`) |
| `vendor/sqlite/` | The SQLite amalgamation; see its [README.md](vendor/sqlite/README.md) |
| `src/znfsd/usage.txt` | `help` output; a copy of the Usage block in [AGENTS.md](AGENTS.md), kept identical |
| `docs/specifications/` | Copies of the external specifications, indexed in its [README.md](docs/specifications/README.md) |

## Building and testing

```sh
zig build                 # build zig-out/bin/znfsd
zig build test            # run unit tests
zig build run -- help     # run znfsd with arguments
zig fmt build.zig src     # format
```

Cross-compile static Linux binaries for test machines:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe --prefix /tmp/znfsd-linux
```

## Test tiers

1. **`zig build test`**, no root: unit tests, plus loopback tests that run libnfsd in-process on ephemeral ports against an in-project RPC client.
2. **Unprivileged daemon with kernel clients:** `znfsd serve` on the host as yourself. Every `rpcbind` tested (macOS 27.2; Alpine, Ubuntu, and Fedora) accepts registrations from non-root over loopback, and macOS's on-demand `rpcbind` starts when any user connects to `/var/run/portmap.socket`. Where no portmapper is available, use `--no-portmap` and mount with explicit ports and `nolock` (see [README.md](README.md)).
3. **Full stack as root, isolated:** znfsd as root in an Apple `container` (static `aarch64-linux-musl` build), which has its own kernel, binds every port, and is reachable from the host and every VM on `192.168.64.0/24`. Kernel clients run in terrarium VMs. Container kernels have no NFS client, and terrarium VMs can't reach each other, so neither can stand in for the other's role. terrarium's named networks (`terrarium network znfsd --subnet CIDR --reserve client1=IP`, then `start --network znfsd:client1`) let VMs reach each other and the Mac (at the subnet's `.1`), so znfsd can also run on the Mac or as root in a VM serving client VMs. Alpine guests may get a default route via their own named-network address; delete it for internet access. Suites: Connectathon (`cthon04`) from Linux and macOS clients, server-restart and client-reboot lock recovery, and a Windows smoke test.

macOS clients ask before an app reads a network volume, and a background process like terrarium's helper can't be asked, so its reads block, then fail with "Operation not permitted". Run macOS client tests from Terminal in the VM's GUI, allowing its prompt once, and write results to a local file for `exec` to read. macOS handles `flock()` on NFS within the client; use `fcntl()` locks to test NLM. Debug builds log every RPC call (`debug(libnfsd)`), which shows what a client sent.

Windows needs the Client for NFS feature (`Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly,ClientForNFS-Infrastructure -All`; Pro or better). `mount -o anon` sends UID and GID 4294967294, which a map can make a host user. It writes back lazily, so changes reach the server a while after a command returns, and it locks with NLM's NM_LOCK, unmonitored, plus SHARE and UNSHARE.

If a VM gets only a `169.254.x` address, the host's DHCP isn't answering; give it a static address on `192.168.64.0/24` with gateway `192.168.64.1` and DNS `1.1.1.1`.

Test against each supported client: macOS 15.8+, Linux 6.12+, and Windows 10+. Boot install media from `~/Developer/Images` read-only, run VMs without audio, and save prepared clients as new layers rather than changing shared ones.

## Web admin

The activity monitor is a znfsd module (`web.zig`, `activity.zig`) in the daemon's process; libnfsd only offers the observer hook it feeds on. That suits today's monitor: read-only, loopback only, GET only, small.

The deferred admin features (users and passwords, changes from the web, perhaps TLS or non-loopback access) should move it into its own process, so HTTP parsing, password checks, and sessions never run in the NFS daemon, possibly as root:

* The snapshot is already a control-socket request (`znfsd activity`), so a separate web process needs nothing new.
* `serve` starts `znfsd web` as a child, unprivileged, and gives it one end of a socket pair: no file permissions involved, and the daemon answers only what that channel allows (read-only until admin features exist).
* Admin changes are the CLI's commands over that channel, so the web side never reimplements them.
* Live updates: polling the snapshot each second, or a streaming `watch` request.

## Documentation

With each change, update [AGENTS.md](AGENTS.md), [README.md](README.md), this file, [ARCHITECTURE.md](ARCHITECTURE.md), and [CHANGELOG.md](CHANGELOG.md). Copy each external specification the code relies on into `docs/specifications/` and index it there.
