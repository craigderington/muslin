#!/bin/sh
# Migrate pre-S5 runtime disks before build cleanup can remove out/.
set -eu
out=${1:?output directory}
for variant in c rs; do
    legacy=$out/rootfs-$variant.ext4
    [ -f "$legacy" ] || continue
    disk=state/rootfs-$variant.ext4
    [ ! -e "state/legacy-$variant.ext4" ] || {
        echo "legacy archive already exists: state/legacy-$variant.ext4" >&2
        exit 1
    }
    if [ -e "$disk" ]; then
        # Never discard a second legacy disk simply because state/ exists.
        echo "legacy disk still exists: $legacy; archive it before cleanup" >&2
        exit 1
    fi
    "$(dirname "$0")/prepare-runtime.sh" "$legacy" "$disk"
    cmp -s "$legacy" "$disk" || { echo 'legacy migration verification failed' >&2; exit 1; }
    # Keep the original as an archive outside all build/clean targets.
    mv "$legacy" "state/legacy-$variant.ext4"
done
