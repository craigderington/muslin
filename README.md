# Muslin Linux

A from-scratch Linux: **kernel + musl + static userland + our own PID 1.**
Boots to a shell in QEMU in well under a second with KVM.

```
./muslin image   # build the Alpine builder image (musl-native toolchain)
./muslin build   # fetch + build kernel, busybox, init → out/
./muslin test    # headless boot, expects MUSLIN_SELFTEST_OK
./muslin test-all # A/B test the C and Rust PID 1 implementations
./muslin test-network # DHCP + forwarded HTTP integration test
./muslin run     # serial console in your terminal (poweroff / Ctrl-A X)
./muslin verify  # verify pinned SHA-256 hashes and upstream signatures
./muslin budget  # enforce artifact sizes and <500 ms KVM boot
./muslin profile # show the slowest kernel initcalls
./muslin reproducible # two clean builds, byte-for-byte artifact comparison
./muslin shell   # drop into the builder
```

Downloads are accepted only when both their pinned SHA-256 and detached
signature match the pinned upstream signer fingerprint. Reproducible builds use
a fixed epoch, kernel identity, build version, filesystem mtimes, cpio inode
numbers, ordering, and gzip headers.

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
| `config/kernel.fragment` | Everything added on top of `make tinyconfig` |
| `config/busybox.fragment` | Twelve-app minimal bootstrap shell/network userland |
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

## Signals (BusyBox conventions)
`halt` → SIGUSR1 · `poweroff` → SIGUSR2 · `reboot` → SIGTERM · Ctrl-Alt-Del → SIGINT

Nothing here needs root on the host; the initramfs is built without mknod.
