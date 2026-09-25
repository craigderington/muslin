#!/bin/sh
# Boot headless, expect MUSLIN_SELFTEST_OK, fail on timeout/panic.
set -eu
LOG=$(mktemp)
APPEND_EXTRA=muslin.selftest timeout "${TIMEOUT:-90}" \
    "$(dirname "$0")/run-qemu.sh" "$1" "$2" </dev/null >"$LOG" 2>&1 || true
if grep -a -q MUSLIN_SELFTEST_OK "$LOG"; then
    result=$(grep -a MUSLIN_SELFTEST_OK "$LOG" | tail -n 1 | tr -d '\r')
    echo "$result"
    if [ -n "${BOOT_BUDGET_MS:-}" ]; then
        seconds=${result##*uptime=}
        seconds=${seconds%s}
        milliseconds=$(awk -v seconds="$seconds" 'BEGIN { printf "%d", seconds * 1000 + 0.5 }')
        if [ "$milliseconds" -ge "$BOOT_BUDGET_MS" ]; then
            echo "FAIL: boot budget exceeded (${milliseconds}ms >= ${BOOT_BUDGET_MS}ms)"
            exit 1
        fi
        echo "boot budget: PASS (${milliseconds}ms < ${BOOT_BUDGET_MS}ms)"
    fi
    echo "PASS"; rm -f "$LOG"
else
    tail -n 30 "$LOG"; echo "FAIL (log: $LOG)"; exit 1
fi
