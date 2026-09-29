#!/bin/sh
# Copy a base image once. Publishing with ln never replaces an existing disk.
set -eu
base=${1:?base image}
disk=${2:?runtime disk}
[ ! -e "$disk" ] || exit 0
mkdir -p "$(dirname "$disk")"
temp=$(mktemp "$disk.XXXXXX")
trap 'rm -f "$temp"' EXIT INT TERM
cp --sparse=always "$base" "$temp"
if ln "$temp" "$disk" 2>/dev/null; then
    echo "runtime disk: initialized $disk from $base"
elif [ ! -f "$disk" ]; then
    echo "cannot create runtime disk: $disk" >&2
    exit 1
fi
