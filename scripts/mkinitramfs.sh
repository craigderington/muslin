#!/bin/sh
# mkinitramfs.sh STAGE BUSYBOX INIT TOOLS GO_TOOL OVERLAY OUT
# Rootless: no mknod needed, init mounts devtmpfs and opens the console itself.
set -eu
STAGE=$1 BB=$2 INIT=$3 TOOLS=$4 GO_TOOL=$5 OVERLAY=$6 OUT=$7

rm -rf "$STAGE"
mkdir -p "$STAGE"/bin "$STAGE"/sbin "$STAGE"/usr/bin "$STAGE"/usr/sbin \
         "$STAGE"/dev "$STAGE"/proc "$STAGE"/sys "$STAGE"/run "$STAGE"/tmp \
         "$STAGE"/root "$STAGE"/etc

cp "$BB" "$STAGE/bin/busybox"
"$BB" --list-full | while read -r applet; do
    case "$applet" in sbin/init|linuxrc|bin/busybox) continue ;; esac
    case "$applet" in */*) ;; *) applet="bin/$applet" ;; esac
    ln -sf /bin/busybox "$STAGE/$applet"
done

cp "$INIT" "$STAGE/sbin/init"
ln -sf /sbin/init "$STAGE/init"           # kernel runs /init from initramfs
cp "$TOOLS" "$STAGE/bin/muslin-tools"
for applet in ls cat ps dmesg; do
    ln -sf /bin/muslin-tools "$STAGE/bin/$applet"
done
cp "$GO_TOOL" "$STAGE/bin/muslin-go"
cp -a "$OVERLAY"/. "$STAGE"/

busybox_applets=$("$BB" --list | wc -l)
echo "userland: $busybox_applets BusyBox applets + 4 native Rust applets + 1 Go tool"

# cpio stores mtimes; normalize every entry so identical inputs reproduce.
find "$STAGE" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +

( cd "$STAGE" && find . -print0 | sort -z | \
    cpio --null -o -H newc --owner=0:0 --reproducible --quiet ) \
    | gzip -9n > "$OUT"
echo "initramfs: $OUT ($(du -h "$OUT" | cut -f1))"
