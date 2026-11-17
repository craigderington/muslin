#!/bin/sh
# Initramfs-only ARM64 boot; Ctrl-A X quits.
set -eu
exec qemu-system-aarch64 -M virt -cpu cortex-a53 -accel tcg \
    -m 128M -smp 1 -nographic -no-reboot -nic none \
    -kernel "${1:?kernel}" -initrd "${2:?initrd}" \
    -append "console=ttyAMA0 panic=1 muslin.offline ${QUIET-quiet} ${APPEND_EXTRA:-}"
