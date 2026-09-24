#!/bin/sh
# Boot headless, expect MUSLIN_SELFTEST_OK, fail on timeout/panic.
set -eu
LOG=$(mktemp)
APPEND_EXTRA=muslin.selftest timeout "${TIMEOUT:-90}" \
    "$(dirname "$0")/run-qemu.sh" "$1" "$2" </dev/null >"$LOG" 2>&1 || true
if grep -a -q MUSLIN_SELFTEST_OK "$LOG"; then
    grep -a MUSLIN_SELFTEST_OK "$LOG"; echo "PASS"; rm -f "$LOG"
else
    tail -n 30 "$LOG"; echo "FAIL (log: $LOG)"; exit 1
fi
