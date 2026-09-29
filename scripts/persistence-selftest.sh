#!/bin/sh
# Boot the same temporary ext4 image twice and prove guest state survives.
set -eu

KERNEL=${1:?kernel}
INITRD=${2:?initrd}
ROOTFS=${3:?rootfs}
DISK=$(mktemp)
LOG=$(mktemp)
cleanup() { rm -f "$DISK" "$LOG"; }
trap cleanup EXIT INT TERM
cp --sparse=always "$ROOTFS" "$DISK"

boot() {
    : >"$LOG"
    DISK_IMAGE=$DISK APPEND_EXTRA="muslin.root=/dev/vda muslin.persisttest" \
        timeout "${TIMEOUT:-30}" "$(dirname "$0")/run-qemu.sh" \
        "$KERNEL" "$INITRD" </dev/null >"$LOG" 2>&1 || {
            tail -n 40 "$LOG"; echo 'FAIL: guest did not exit cleanly'; exit 1;
        }
    if grep -a -E -q 'Kernel panic|MUSLIN_BOOT_FAILED' "$LOG"; then
        tail -n 40 "$LOG"; exit 1
    fi
}

boot
grep -a -q 'MUSLIN_PERSIST_OK state=created' "$LOG" || {
    tail -n 40 "$LOG"
    echo "FAIL: first boot did not create persistent state"
    exit 1
}

boot
grep -a -q 'MUSLIN_PERSIST_OK state=retained' "$LOG" || {
    tail -n 40 "$LOG"
    echo "FAIL: second boot did not retain persistent state"
    exit 1
}

echo "persistence: PASS (state retained across two boots)"
