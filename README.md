# Muslin Linux

A from-scratch Linux: **kernel + musl + static userland + our own PID 1.**
Boots to a shell in QEMU in well under a second with KVM.

```
./muslin image   # build the Alpine builder image (musl-native toolchain)
./muslin build   # fetch + build kernel, busybox, init → out/
./muslin test    # headless boot, expects MUSLIN_SELFTEST_OK
./muslin run     # serial console in your terminal (poweroff / Ctrl-A X)
./muslin shell   # drop into the builder
```

## Layout
| Path | What |
|---|---|
| `src/init/init.c` | PID 1: mounts, console/ctty, rcS, shell respawn, reaping, shutdown |
| `config/kernel.fragment` | Everything added on top of `make tinyconfig` |
| `rootfs/` | Overlay copied into the initramfs (/etc etc.) |
| `scripts/` | initramfs builder, QEMU runner, selftest |
| `Makefile` | The real build; runs in the container or on any musl host |
| `compose*.yml`, `docker/` | Builder image; KVM layered in automatically |

## Swap parts
```
make test CC=musl-gcc KERNEL_IMAGE=/boot/vmlinuz BUSYBOX_BIN=/bin/busybox
```

## Signals (BusyBox conventions)
`halt` → SIGUSR1 · `poweroff` → SIGUSR2 · `reboot` → SIGTERM · Ctrl-Alt-Del → SIGINT

Nothing here needs root on the host; the initramfs is built without mknod.
