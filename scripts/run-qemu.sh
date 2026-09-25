#!/bin/sh
# run-qemu.sh KERNEL INITRD   — Ctrl-A X quits
set -eu
KERNEL=${1:?kernel} INITRD=${2:?initrd}
ACCEL="-accel tcg"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && ACCEL="-accel kvm -cpu host"
if [ "${REQUIRE_KVM:-0}" = 1 ] && [ "$ACCEL" = "-accel tcg" ]; then
    echo "KVM is required for this boot" >&2
    exit 1
fi
exec qemu-system-x86_64 $ACCEL -m "${MEM:-128M}" -smp 1 \
    -nographic -no-reboot \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyS0 panic=1 ${QUIET-quiet} ${APPEND_EXTRA:-}"
