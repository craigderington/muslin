#!/bin/sh
# Boot noisily with initcall_debug and report the slowest measured calls.
set -eu

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
QUIET= APPEND_EXTRA="muslin.selftest initcall_debug" timeout "${TIMEOUT:-30}" \
    "$(dirname "$0")/run-qemu.sh" "$1" "$2" </dev/null >"$LOG" 2>&1 || true

grep -a 'MUSLIN_SELFTEST_OK' "$LOG" | tail -n 1 | tr -d '\r'
echo "slowest initcalls (microseconds):"
sed -n 's/.*: \([^ ]*\) took \([0-9][0-9]*\) usecs.*/\2 \1/p' "$LOG" | \
    sort -nr | head -n "${PROFILE_LIMIT:-10}"
