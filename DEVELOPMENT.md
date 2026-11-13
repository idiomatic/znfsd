# Development

How to work on znfsd. [AGENTS.md](AGENTS.md) is the specification; [README.md](README.md) explains it for users, and [ARCHITECTURE.md](ARCHITECTURE.md) describes the design.

So far, `serve` runs the portmapper logic, MOUNT, and all of NFS v3, with ephemeral exports and groups; Linux 6.18 has mounted it read-write. NLM, NSM, maps, stored state, and the other commands are still to come.

## Requirements

* Zig 0.17+
* A Linux or macOS host

SQLite will be vendored as its C amalgamation and built by `zig build`; there are no other external dependencies.

## Layout

| Path | Contents |
| --- | --- |
| `src/libnfsd/` | Embeddable server: RPC, XDR, NFS v3, MOUNT, NLM, NSM, portmapper, and state-storage hooks |
| `src/znfsd/` | CLI daemon: arguments (`cli.zig`), control socket, SQLite storage, admin web server |
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

If a VM gets only a `169.254.x` address, the host's DHCP isn't answering; give it a static address on `192.168.64.0/24` with gateway `192.168.64.1` and DNS `1.1.1.1`.

Test against each supported client: macOS 15.8+, Linux 6.12+, and Windows 10+. Boot install media from `~/Developer/Images` read-only, run VMs without audio, and save prepared clients as new layers rather than changing shared ones.

## Documentation

With each change, update [AGENTS.md](AGENTS.md), [README.md](README.md), this file, [ARCHITECTURE.md](ARCHITECTURE.md), and [CHANGELOG.md](CHANGELOG.md). Copy each external specification the code relies on into `docs/specifications/` and index it there.
