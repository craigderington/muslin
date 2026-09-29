#!/bin/sh
# Inject a package into a temporary disk and install it inside Muslin.
set -eu

KERNEL=${1:?kernel}
INITRD=${2:?initrd}
ROOTFS=${3:?rootfs}
PACKAGE=${4:?package}
DISK=$(mktemp)
LOG=$(mktemp)
cleanup() { rm -f "$DISK" "$LOG"; }
trap cleanup EXIT INT TERM
cp --sparse=always "$ROOTFS" "$DISK"

debugfs -w -R "write $PACKAGE /var/lib/muslin/test.mpkg" "$DISK" >/dev/null 2>&1
debugfs -w -R "write $PACKAGE.sha256 /var/lib/muslin/test.mpkg.sha256" "$DISK" >/dev/null 2>&1

DISK_IMAGE=$DISK APPEND_EXTRA="muslin.root=/dev/vda muslin.packagetest" \
    timeout "${TIMEOUT:-30}" "$(dirname "$0")/run-qemu.sh" \
    "$KERNEL" "$INITRD" </dev/null >"$LOG" 2>&1 || {
        tail -n 50 "$LOG"; echo 'FAIL: guest did not exit cleanly'; exit 1;
    }

if ! grep -a -E -q 'Kernel panic|MUSLIN_BOOT_FAILED' "$LOG" && \
   grep -a -q MUSLIN_PACKAGE_PAYLOAD_OK "$LOG" && \
   grep -a -q 'mpkg: installed hello 1.0.0' "$LOG"; then
    echo "package: PASS (verified, installed, and executed)"
else
    tail -n 50 "$LOG"
    echo "FAIL: package installation test failed"
    exit 1
fi
