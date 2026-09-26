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
- [x] Desktop verification: `./muslin image && ./muslin build && ./muslin test && ./muslin run`
- [x] KVM boot time: **0.100 s** to userspace

## Sprint 2: Trust & budgets ✅
- [x] Verify kernel/busybox tarballs (pinned SHA-256 + GPG signatures and signer fingerprints) in the fetch step
- [x] Size budget gate in `make size`: bzImage < 1.5 MiB, initramfs < 1 MiB
- [x] Boot-time budget gate: < 500 ms to userspace with KVM (**80 ms measured**)
- [x] Drop `quiet` noise and measure with `initcall_debug`; remove unused VT/input/HID/serio stack (**kernel 1,287,168 → 1,197,056 bytes**)
- [x] Reproducible builds: fixed epoch/build identity and normalized initramfs metadata; kernel, init, and initramfs hashes match across two clean builds

## Sprint 3: Our own userland (Rust + Go) ✅
- [x] Pinned Rust 1.78 toolchain for `x86_64-unknown-linux-musl` in the builder
- [x] Rust PID 1 (`init-rs`) with the C init retained as the reference; both pass the same guest selftest (**C 90 ms, Rust 100 ms**)
- [x] Native Rust `ls`, `cat`, `ps`, and `dmesg`; BusyBox reduced from **398 to 9 applets**
- [x] Static Go proof binary (`CGO_ENABLED=0`) shipped and executed by the in-guest selftest
- [x] C image remains inside the 1 MiB initramfs budget (**897,657 bytes**); experimental Rust PID 1 image is **1,102,160 bytes**

## Sprint 4: Networking ✅
- [x] Minimal IPv4/TCP + virtio-net kernel and BusyBox `udhcpc`; guest obtains **10.0.2.15** from QEMU
- [x] Loopback-only QEMU `hostfwd`, configurable for interactive boots and randomized by the integration test
- [x] Tiny raw-socket HTTP status service in the static Go binary, served on guest port 80
- [x] End-to-end `./muslin test-network` boots, leases, curls the forwarded endpoint, and cleans up QEMU
- [x] Budgets retained: **1,557,504-byte kernel**, **931,466-byte C initramfs**, and **90 ms** boot selftest
- [x] BusyBox remains minimal at **12 applets** (three added for networking: `ifconfig`, `route`, `udhcpc`)

## Sprint 5: Persistence & packages
- [ ] virtio-blk + ext4 disk image, `switch_root` from initramfs
- [ ] Package format: tar.zst + manifest + sha256, `mpkg install`
- [ ] Stretch: Postgres built against musl, running inside Muslin 😈

## Sprint 6: Beyond x86
- [ ] aarch64 cross build, boot on `qemu-system-aarch64 -M virt`
- [ ] Real hardware: Raspberry Pi or an old laptop on a USB stick
