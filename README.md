# znfsd

znfsd is an NFS v3 server for Linux and macOS hosts, serving macOS, Linux, and Windows clients. One process provides everything a v3 client needs: NFS, mountd, statd, lockd, and, when no portmapper is running, a portmapper too. It has few options, and its defaults are sensible.

[AGENTS.md](AGENTS.md) is the authoritative specification; this page explains and illustrates it. The protocol specifications znfsd relies on are collected in [docs/specifications](docs/specifications/README.md). znfsd is under construction. So far, `serve` runs the portmapper logic, MOUNT, and all of NFS v3, with stored and ephemeral exports and groups; Linux 6.18 has mounted it read-write. The `export`, `group`, and `mount` commands work on the database, but a running daemon reads it only at startup until the control socket exists. NLM, NSM, maps, `stop`, `lock`, and the activity monitor are still to come.

## Why

The NFS servers that ship with Linux and macOS spread one service across a kernel module, several daemons, `/etc/exports`, and an `exportfs` or `nfsd` reload step, each with its own syntax and quirks. znfsd is a single user-space process, configured from its command line, with changes taking effect immediately.

It's built on `libnfsd`, so other programs can embed the same server and plug in their own state storage.

## Quick start

Share a directory with everyone on the network, read-only, for as long as the command runs:

```sh
sudo znfsd serve /srv/media:ro
```

Store exports so they persist, then serve them:

```sh
sudo znfsd export add /srv/projects 10.0.0.0/8
sudo znfsd export add /srv/projects hal.example.com rw squash=none
sudo znfsd serve
```

While the daemon runs, commands reach it through its control socket and take effect at once; without it, they edit the database directly.

## Mounting

macOS:

```sh
sudo mount -t nfs -o vers=3 hal:/srv/projects /Volumes/projects
```

Linux:

```sh
sudo mount -t nfs -o vers=3 hal:/srv/projects /mnt/projects
```

Windows, with the Client for NFS feature installed:

```bat
mount \\hal\srv\projects P:
```

## Exports

An export rule pairs a path with a client and options:

* Clients are a host name, a `*.domain` wildcard, a CIDR, a `@group`, or `*`. When several rules match, the most specific wins outright: an exact host beats a CIDR, a longer CIDR beats a shorter one, and so on down to `*`. The winning rule's options aren't merged with others.
* Host names are checked with forward-confirmed reverse DNS, so a forged PTR record alone can't claim a name.
* `rw` is the default; `ro` makes the export read-only.
* `squash=root` (the default) treats the client's root as an anonymous user; `squash=all` does so for every user; `squash=none` trusts client IDs as sent.

Every export is synchronous, crosses mount points, and skips subtree checking; clients authenticate with AUTH_SYS. These aren't options because the alternatives trade safety or correctness for little benefit.

`export add` is idempotent and merges new options into an existing rule; `export set` replaces them.

## Groups

Groups name a set of clients for reuse across rules:

```sh
znfsd group add lab 10.1.0.0/16 perihelion.example.com
znfsd export add /srv/scratch @lab
```

## Maps

Maps translate client IDs to host IDs, which helps when the same person has different UIDs on different machines. UIDs and GIDs translate independently; write `UID`, `:GID`, or `UID:GID`, and on the host side, user and group names work too, resolved to numbers when the entry is added.

```sh
znfsd map add art art 501 1000     # client UIDs 501 and 1000 act as host user art
znfsd map add art :staff :20       # client GID 20 acts as host group staff
znfsd map add art nobody           # anon: everything else acts as nobody
znfsd export add /srv/home/art perihelion.example.com map=art
```

Replies translate back: files owned by `art` appear to the client as owned by UID 501, the first listed. Without an anon entry, unmapped IDs pass through unchanged, and squashed users become the host's `nobody`.

`--run-as` disables maps, because an unprivileged server can't act as other users.

## Ephemeral exports

Arguments to `serve` add exports, groups, and maps for that run only, overriding stored ones with the same key:

```sh
znfsd serve --group lab:10.1.0.0/16,fd00::/8 \
            --map art:art=501,1000 \
            /srv/home/art:rw,map=art:@lab
```

An export argument is `PATH[:OPTIONS[:CLIENTS]]`. Clients come last so IPv6 addresses need no escaping; only a `:` inside the path needs `\:`.

## Running unprivileged

As root, znfsd can start its own portmapper. With `--run-as USER`, it binds its ports and then drops to USER, accessing files as that user. Without root at all, it needs an existing portmapper to register with. Linux distributions' `rpcbind` accepts registrations from ordinary users, and on macOS, znfsd wakes the system's on-demand `rpcbind` itself, so an unprivileged znfsd normally registers, locking included. Its fixed ports (nfs 2049, mount 20048, stat 32765, lock 32803) are all unprivileged, which also keeps firewall rules stable.

On hosts with no portmapper at all, `--no-portmap` skips registration altogether. Clients must then name the ports, and file locking is off:

```sh
znfsd serve --no-portmap ~/scratch
sudo mount -t nfs -o vers=3,port=2049,mountport=20048,nolock perihelion:/Users/art/scratch /mnt/scratch
```

If the host's own NFS server or kernel lock manager already holds a port or RPC registration znfsd needs, znfsd exits rather than fight over it.

## State and recovery

znfsd keeps exports, groups, maps, file handles, mount records, and statd's monitor list in SQLite. Locks live only in memory: after a restart, znfsd notifies its clients, which reclaim their locks during a grace period of about 90 seconds.

File handles identify a file by filesystem and inode rather than path, so they survive renames, including ones made directly on the host.

## Activity monitor

While serving, znfsd shows live activity at <http://127.0.0.1:8049>; `--web` moves it.

## How it was made

znfsd was written with [Claude](https://claude.com).

## License

BSD 3-Clause; see [LICENSE](LICENSE).
