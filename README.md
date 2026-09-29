# Muslin Linux

A from-scratch Linux: **kernel + musl + static bootstrap userland + our own PID 1.**
Boots to a shell in QEMU in well under a second with KVM.

```
./muslin image   # build the Alpine builder image (musl-native toolchain)
./muslin build   # fetch + build kernel, busybox, init → out/
./muslin test    # headless boot, expects MUSLIN_SELFTEST_OK
./muslin test-all # A/B test the C and Rust PID 1 implementations
./muslin test-network # DHCP + forwarded HTTP integration test
./muslin test-persistence # state retained across two disk boots
./muslin test-package # install and execute a package in a disposable guest
./muslin test-s5 # complete C/Rust persistence, package and build regression suite
./muslin postgres # build the optional PostgreSQL profile
./muslin run-postgres # persistent local PostgreSQL guest, 256 MiB RAM/disk
./muslin test-postgres # install/write/reboot/read test with both C and Rust init
./muslin run     # serial console in your terminal (poweroff / Ctrl-A X)
./muslin verify  # verify pinned SHA-256 hashes and upstream signatures
./muslin budget  # enforce artifact sizes and <500 ms KVM boot
./muslin profile # show the slowest kernel initcalls
./muslin reproducible # two clean builds, byte-for-byte artifact comparison
./muslin shell   # drop into the builder
```

Kernel and BusyBox downloads are accepted only when both their pinned SHA-256
and detached signature match the pinned upstream signer fingerprint.
The optional PostgreSQL source uses a pinned SHA-256 from its official HTTPS
release archive; upstream does not provide a detached signature alongside that
archive. Reproducible builds use
a fixed epoch, kernel identity, build version, filesystem mtimes, cpio inode
numbers, ordering, and gzip headers. Disk images normalize ownership and all
inode timestamps, including ctime. Byte-for-byte reproduction assumes the same
builder toolchain; Alpine packages are not pinned independently of the image.

Interactive boots acquire `10.0.2.15` from QEMU over virtio-net and serve a
status response from the guest on `http://127.0.0.1:4217/`. Override the
loopback-only host port when needed:

```
HOST_HTTP_PORT=8080 ./muslin run
curl http://127.0.0.1:8080/
```

## Layout
| Path | What |
|---|---|
| `src/init/init.c` | Reference C PID 1 |
| `src/init-rs/main.rs` | Rust PID 1: mounts, console/ctty, rcS, shell respawn, reaping, shutdown |
| `src/tools/main.rs` | Native Rust replacements for `ls`, `cat`, `ps`, and `dmesg` |
| `src/go-proof/main.go` | Static Go proof tool and raw-socket HTTP status service |
| `src/mpkg/main.rs` | Disk-only Rust package installer: validation, conflicts, recovery |
| `src/postgres-user/main.c` | Disk-only helper that drops privileges to the postgres account |
| `config/kernel.fragment` | Everything added on top of `make tinyconfig` |
| `config/busybox.fragment` | Twenty-app minimal bootstrap shell/network userland |
| `config/postgres-kernel.fragment` | Optional PostgreSQL IPC/socket/event-loop kernel additions |
| `rootfs/` | Overlay copied into the initramfs (/etc etc.) |
| `scripts/` | initramfs builder, QEMU runner, selftest |
| `Makefile` | The real build; runs in the container or on any musl host |
| `compose*.yml`, `docker/` | Builder image; KVM layered in automatically |

## Swap parts
```
make test CC=musl-gcc KERNEL_IMAGE=/boot/vmlinuz BUSYBOX_BIN=/bin/busybox
```

Select the PID 1 implementation with `INIT_IMPL`:

```
./muslin make test INIT_IMPL=rs
./muslin make run INIT_IMPL=rs
```

`INIT_IMPL=c` is the default and remains below the 1 MiB initramfs budget. The
Rust image is currently about 1.1 MiB; `./muslin test-all` boots both variants
and runs the same native-userland checks in each guest.

`./muslin test-network` selects a temporary host port, boots the guest, obtains
a DHCP lease, and verifies the status service through QEMU's TCP forwarding.

## Persistent disks

Builds produce disposable `out/base-c.ext4` and `out/base-rs.ext4` images from
their matching initramfs archives. `./muslin run` copies the selected base to
`state/rootfs-c.ext4` on first use and reuses that disk thereafter. Builds,
`clean`, `distclean`, and reproducibility checks leave `state/` intact. The
kernel limit is 1.75 MiB, the default C initramfs limit is 1 MiB, and the base
disk capacity is 32 MiB. Rust init remains experimental and exceeds the 1 MiB
initramfs gate; `test-s5` checks C's size gate and exercises both variants.

Existing `out/rootfs-*.ext4` disks are migrated before `run` or cleanup: the
runtime copy goes under `state/`, and the original is archived as
`state/legacy-*.ext4`. A conflicting migration stops rather than overwriting
either disk. The migration preserves the old system contents as well as data.
Stop existing legacy guests before this one-time migration.

A runtime disk is a complete writable system, so rebuilding the base does not
upgrade it. To boot a newly built system, stop its guest, archive its runtime
disk under a new filename, then run again. Restore needed data from the saved
disk separately. There is no automatic OS upgrade or destructive reset command.

## Packages

`./muslin make package` builds `out/hello-1.0.0.mpkg` and its SHA-256 sidecar.
Inside a disk-root guest, install a local package with:

```
mpkg install /path/hello-1.0.0.mpkg
```

The format is a zstd-compressed POSIX ustar archive with `manifest`, `files`,
and `root/` payload entries. The manifest contains `name=` and `version=`;
`files` must list every payload file exactly once using absolute paths.
Names and versions use ASCII letters/digits plus `.`, `_`, `+`, and `-`, start
with a letter/digit, and are limited to 64 bytes. Payload paths use printable
ASCII without spaces or backslashes and are limited to 255 bytes.

The initial format supports regular files under `/usr`, `/opt`, `/etc`, `/var`,
`/bin`, `/sbin`, and `/lib`; parent directories are created as needed. Links,
special files, special permission bits, traversal paths, package-database
writes, existing destination files, and upgrades/reinstalls are rejected.
Directory entries describe structure; empty directories and directory modes
are not installed. The decompressed archive is limited to 32 MiB.

The installer validates the checksum and complete archive before touching
payload destinations. It stages files under `/var/lib/mpkg`, journals the
install, and publishes files without overwriting existing entries. An error
rolls back files from the unfinished install; the next valid installation
recovers a journal left by interruption. Empty directories may remain after
rollback. Package metadata is committed under `/var/lib/mpkg/NAME/`.
Payload and package database must be on the same filesystem.

Checksums must come from a trusted source; a sidecar alone does not authenticate
the publisher. Package signing, dependencies, removal, and upgrades remain
future work. `mpkg` is static; zstd and its musl/shared-library dependencies are
disk-only and do not increase the initramfs size.

## PostgreSQL workload

The optional profile builds PostgreSQL 18.6 against the builder's musl libc and
packages it with `mpkg`. Its [source archive and checksum](https://www.postgresql.org/ftp/source/v18.6/)
are pinned in the Makefile. PostgreSQL's [shared-memory requirements](https://www.postgresql.org/docs/18/kernel-resources.html)
and Linux event loop require additional kernel features: System V IPC, Unix
sockets, epoll, eventfd, and signalfd. They live in a separate kernel profile,
with a 2 MiB kernel limit; the tiny base kernel retains its 1.75 MiB limit.
Both init implementations mount `/dev/shm` for POSIX shared memory.

```
./muslin postgres
./muslin run-postgres
```

First boot installs the preloaded package, initializes the database, and starts
the server. Later boots reuse the installed package and existing database.
The server runs as `postgres` (UID/GID 70), with data under
`/var/lib/postgresql/data` and logs in `/var/lib/postgresql/server.log`.

From the guest shell:

```
/etc/init.d/postgresql sql -c 'SELECT version();'
/etc/init.d/postgresql sql -c 'CREATE TABLE notes (body text);'
/etc/init.d/postgresql sql -c "INSERT INTO notes VALUES ('hello from Muslin');"
/etc/init.d/postgresql status
reboot
```

QEMU exits on reboot; run `./muslin run-postgres` again, then query `notes`.
`postgres-user psql` opens an interactive SQL session. This helper has no setuid
bit; root invokes it to drop supplementary groups and switch to UID/GID 70.
Connections use a private Unix socket and peer authentication. PostgreSQL does
not listen on TCP, and no database port is forwarded to the host.

The profile uses `out/postgres-c.ext4` as its disposable base and
`state/postgres-c.ext4` as its runtime disk (or `-rs` for Rust init). Its disk
capacity and QEMU RAM are each 256 MiB; shared buffers are 16 MiB and the
connection limit is 10. Existing base-profile disks are untouched. Select the
Rust variant with `./muslin make run-postgres INIT_IMPL=rs`.

PID 1 runs `/etc/init.d/rcK` before signalling remaining processes. PostgreSQL
uses [fast shutdown](https://www.postgresql.org/docs/18/server-shutdown.html),
which disconnects clients and rolls back active transactions while preserving
committed data. The service waits up to 20 seconds and verifies the control
file reports a clean shutdown; PID 1 bounds all shutdown hooks to 30 seconds.

`./muslin test-postgres` uses disposable disks with both init implementations.
It checks package installation, the server's OS identity, PL/pgSQL, durability
settings, 1,000 committed rows surviving reboot, an active transaction rolling
back during shutdown, and clean reboot/poweroff. The profile keeps `fsync`,
`full_page_writes`, and `synchronous_commit` enabled. TLS, ICU, compression
libraries, and optional extension packages are omitted from this initial build.

## Signals (BusyBox conventions)
`halt` → SIGUSR1 · `poweroff` → SIGUSR2 · `reboot` → SIGTERM · Ctrl-Alt-Del → SIGINT

Nothing here needs root on the host; the initramfs is built without mknod.
