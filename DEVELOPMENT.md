# Development

How to work on znfsd. [AGENTS.md](AGENTS.md) is the specification; [README.md](README.md) explains it for users, and [ARCHITECTURE.md](ARCHITECTURE.md) describes the design.

No code exists yet; the layout and commands below are the plan.

## Requirements

* Zig 0.17+
* A Linux or macOS host

SQLite is vendored as its C amalgamation and built by `zig build`; there are no other external dependencies.

## Layout

| Path | Contents |
| --- | --- |
| `src/libnfsd/` | Embeddable server: RPC, XDR, NFS v3, MOUNT, NLM, NSM, portmapper, and state-storage hooks |
| `src/znfsd/` | CLI daemon: arguments, control socket, SQLite storage, admin web server |
| `docs/specifications/` | Copies of the external specifications, indexed in its [README.md](docs/specifications/README.md) |

## Building and testing

```sh
zig build                 # build znfsd
zig build test            # run unit tests
```

## Client testing

Test against each supported client: macOS 15.8+, Linux 6.12+, and Windows 10+. Run clients in VMs, booting install media from `~/Developer/Images` read-only, without audio.

## Documentation

With each change, update [AGENTS.md](AGENTS.md), [README.md](README.md), this file, [ARCHITECTURE.md](ARCHITECTURE.md), and [CHANGELOG.md](CHANGELOG.md). Copy each external specification the code relies on into `docs/specifications/` and index it there.
