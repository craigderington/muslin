#!/bin/sh
# mkrootfs.sh INITRAMFS MPKG OUT SIZE_MB [EXTRA_OVERLAY]
# Consume the matching archive, never a shared staging directory.
set -eu
INITRAMFS=${1:?initramfs}
MPKG=${2:?mpkg binary}
OUT=${3:?output}
SIZE_MB=${4:-32}
export E2FSPROGS_FAKE_TIME=${SOURCE_DATE_EPOCH:-1}
DISK_STAGE=$(mktemp -d)
TEMP=$(mktemp "$OUT.XXXXXX")
trap 'rm -rf "$DISK_STAGE"; rm -f "$TEMP"' EXIT INT TERM

gzip -dc "$INITRAMFS" >"$DISK_STAGE/archive.cpio"
(cd "$DISK_STAGE" && cpio -id --quiet --no-preserve-owner <archive.cpio)
rm "$DISK_STAGE/archive.cpio"
mkdir -p "$DISK_STAGE/var/lib/muslin" "$DISK_STAGE/usr/bin" "$DISK_STAGE/usr/lib" "$DISK_STAGE/lib"
# These dependencies are disk-only, leaving the bootstrap image small.
cp "$MPKG" "$DISK_STAGE/usr/bin/mpkg"
cp /usr/bin/zstd "$DISK_STAGE/usr/bin/zstd"
cp -L /usr/lib/libzstd.so.1 "$DISK_STAGE/usr/lib/libzstd.so.1"
cp /lib/ld-musl-x86_64.so.1 "$DISK_STAGE/lib/ld-musl-x86_64.so.1"
if [ -n "${5:-}" ]; then
    cp -a "$5"/. "$DISK_STAGE"/
fi
find "$DISK_STAGE" -exec touch -h -d "@$E2FSPROGS_FAKE_TIME" {} +
truncate -s "${SIZE_MB}M" "$TEMP"
mke2fs -q -t ext4 -L muslin-root \
    -U 6d75736c-696e-4000-8000-000000000005 \
    -E root_owner=0:0,lazy_itable_init=0,lazy_journal_init=0,hash_seed=6d75736c-696e-4000-8000-000000000005 \
    -d "$DISK_STAGE" "$TEMP"
python3 "$(dirname "$0")/normalize-ext4.py" "$DISK_STAGE" "$TEMP" "$E2FSPROGS_FAKE_TIME"
mv "$TEMP" "$OUT"
echo "rootfs: $OUT (${SIZE_MB} MiB sparse ext4)"
