#!/bin/sh
# run-qemu.sh KERNEL INITRD   — Ctrl-A X quits
set -eu
KERNEL=${1:?kernel} INITRD=${2:?initrd}
HOST_HTTP_PORT=${HOST_HTTP_PORT:-4217}
ACCEL="-accel tcg"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && ACCEL="-accel kvm -cpu host"
if [ "${REQUIRE_KVM:-0}" = 1 ] && [ "$ACCEL" = "-accel tcg" ]; then
    echo "KVM is required for this boot" >&2
    exit 1
fi
set --
if [ -n "${DISK_IMAGE:-}" ]; then
    set -- -drive "file=$DISK_IMAGE,format=raw,if=none,id=rootdisk" -device virtio-blk-pci,drive=rootdisk
fi
exec qemu-system-x86_64 $ACCEL -m "${MEM:-128M}" -smp 1 \
    -nographic -no-reboot \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${HOST_HTTP_PORT}-:80" \
    -device virtio-net-pci,netdev=net0 \
    "$@" \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyS0 panic=1 ${QUIET-quiet} ${APPEND_EXTRA:-}"
