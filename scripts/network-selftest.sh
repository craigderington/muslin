#!/bin/sh
# Boot a guest, wait for DHCP and the HTTP service, then test host forwarding.
set -eu

KERNEL=${1:?kernel}
INITRD=${2:?initrd}
PORT=${HOST_HTTP_PORT:-$((20000 + ($$ % 20000)))}
LOG=$(mktemp)
BODY=$(mktemp)
QEMU_PID=
cleanup() {
    [ -z "$QEMU_PID" ] || kill "$QEMU_PID" 2>/dev/null || true
    rm -f "$LOG" "$BODY"
}
trap cleanup EXIT INT TERM

HOST_HTTP_PORT=$PORT APPEND_EXTRA=muslin.networktest \
    "$(dirname "$0")/run-qemu.sh" "$KERNEL" "$INITRD" </dev/null >"$LOG" 2>&1 &
QEMU_PID=$!

attempt=0
while [ "$attempt" -lt 100 ]; do
    if curl -fsS --connect-timeout 0.1 --max-time 0.2 \
        "http://127.0.0.1:$PORT/" >"$BODY" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        tail -n 40 "$LOG"
        echo "FAIL: QEMU exited before the HTTP service became ready"
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.05
done

if ! grep -q '^Muslin Linux: networking works$' "$BODY"; then
    tail -n 40 "$LOG"
    echo "FAIL: HTTP service was not reachable on host port $PORT"
    exit 1
fi

echo "network: PASS (127.0.0.1:$PORT -> guest :80)"
