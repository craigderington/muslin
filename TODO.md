# Muslin Linux: Sprint Board

Loop: Plan → Work → Assess → Build → Test → Deploy → Iterate

## Sprint 1: Boot to a shell ✅ (verified in Claude's sandbox)
- [x] Repo scaffold, compose builder (Alpine = musl-native toolchain)
- [x] `muslin-init` PID 1 in C: mounts, real ctty, rcS, respawn, reaping, halt/poweroff/reboot
- [x] Rootless initramfs builder (no mknod, reproducible cpio ordering)
- [x] Kernel = tinyconfig + 21-line fragment (validated against 6.12.48: all options stick)
- [x] QEMU runner (auto KVM) + headless `make test` selftest
- [x] Sandbox results: our 6.12.48 kernel 1.3 MB, init 58 KB static, **0.75s to userspace under TCG (no KVM)**, ACPI poweroff exits QEMU
- [x] Fragment fix: TMPFS silently dropped without SHMEM (caught by validation)
- [ ] **Craig:** `./muslin image && ./muslin build && ./muslin test && ./muslin run` on the desktop
- [ ] **Craig:** record KVM boot time here → ______ s

## Sprint 2: Trust & budgets
- [ ] Verify kernel/busybox tarballs (sha256 + GPG sigs) in the fetch step
- [ ] Size budget gate in `make size`: bzImage < 1.5 MB, initramfs < 1 MB
- [ ] Boot-time budget gate: < 500 ms to userspace with KVM
- [ ] Drop `quiet` noise and measure with `initcall_debug`; prune the slowest initcalls
- [ ] Reproducible builds: SOURCE_DATE_EPOCH, KBUILD_BUILD_TIMESTAMP, hash out/ twice

## Sprint 3: Our own userland (Rust + Go)
- [ ] Rust toolchain for `x86_64-unknown-linux-musl` in the builder
- [ ] Rewrite PID 1 in Rust as `init-rs`; keep C init as the reference and A/B them on the selftest
- [ ] Replace BusyBox applets one at a time (ls, cat, ps, dmesg) and track the applet count shrinking
- [ ] Static Go tool (CGO_ENABLED=0) shipped in the image as proof both ecosystems land clean

## Sprint 4: Networking
- [ ] virtio-net in the kernel fragment, `udhcpc` or our own DHCP client
- [ ] QEMU `hostfwd` on a random port (e.g. host 4217 → guest 22/80)
- [ ] Tiny static HTTP status page served from the guest

## Sprint 5: Persistence & packages
- [ ] virtio-blk + ext4 disk image, `switch_root` from initramfs
- [ ] Package format: tar.zst + manifest + sha256, `mpkg install`
- [ ] Stretch: Postgres built against musl, running inside Muslin 😈

## Sprint 6: Beyond x86
- [ ] aarch64 cross build, boot on `qemu-system-aarch64 -M virt`
- [ ] Real hardware: Raspberry Pi or an old laptop on a USB stick
