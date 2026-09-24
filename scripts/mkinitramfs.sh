#!/bin/sh
# mkinitramfs.sh STAGE BUSYBOX INIT OVERLAY OUT
# Rootless: no mknod needed, init mounts devtmpfs and opens the console itself.
set -eu
STAGE=$1 BB=$2 INIT=$3 OVERLAY=$4 OUT=$5

rm -rf "$STAGE"
mkdir -p "$STAGE"/bin "$STAGE"/sbin "$STAGE"/usr/bin "$STAGE"/usr/sbin \
         "$STAGE"/dev "$STAGE"/proc "$STAGE"/sys "$STAGE"/run "$STAGE"/tmp \
         "$STAGE"/root "$STAGE"/etc

cp "$BB" "$STAGE/bin/busybox"
"$BB" --list-full | while read -r applet; do
    case "$applet" in sbin/init|linuxrc|bin/busybox) continue ;; esac
    ln -sf /bin/busybox "$STAGE/$applet"
done

cp "$INIT" "$STAGE/sbin/init"
ln -sf /sbin/init "$STAGE/init"           # kernel runs /init from initramfs
cp -a "$OVERLAY"/. "$STAGE"/

( cd "$STAGE" && find . -print0 | sort -z | cpio --null -o -H newc --owner=0:0 --quiet ) \
    | gzip -9n > "$OUT"
echo "initramfs: $OUT ($(du -h "$OUT" | cut -f1))"
