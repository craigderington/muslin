#!/bin/sh
# run-qemu-arm64.sh KERNEL INITRD — Ctrl-A X quits.
set -eu
KERNEL=${1:?kernel} INITRD=${2:?initrd}
set -- -nic none
if [ "${ARM64_NETWORK:-0}" = 1 ]; then
    set -- -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${HOST_HTTP_PORT:-4217}-:80" \
        -device virtio-net-device,netdev=net0
else
    APPEND_EXTRA="muslin.offline ${APPEND_EXTRA:-}"
fi
if [ -n "${DISK_IMAGE:-}" ]; then
    set -- "$@" -drive "file=$DISK_IMAGE,format=raw,if=none,id=rootdisk" \
        -device virtio-blk-device,drive=rootdisk
fi
exec qemu-system-aarch64 -M virt -cpu cortex-a53 -accel tcg \
    -m "${MEM:-128M}" -smp 1 -nographic -no-reboot "$@" \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyAMA0 panic=1 ${QUIET-quiet} ${APPEND_EXTRA:-}"
